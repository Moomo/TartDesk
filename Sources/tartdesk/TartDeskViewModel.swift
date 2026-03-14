import AppKit
import Foundation
import Observation
import SwiftUI

@Observable
@MainActor
final class TartDeskViewModel {
    var vms: [TartVM] = []
    var selectedVMID: TartVM.ID?
    var details: TartVMDetails?
    var sourceFilter: TartSourceFilter = .all
    var isLoading = false
    var isWorking = false
    var isShowingCreateSheet = false
    var isShowingEditSheet = false
    var createForm = CreateVMFormState()
    var editForm = EditVMFormState()
    var editDirectoryShares: [TartDirectoryShare] = []
    var errorMessage: String?
    var lastCommandOutput = ""
    var createJobs: [TartCreateJob] = []
    var selectedInfoMessage: String?
    var launchedGraphicsPIDs: [String: pid_t] = [:]
    var tartCapabilities: TartCapabilities?
    var guestAgentStatus: GuestAgentStatus = .unknown("Checking Tart capabilities...")
    var sshStatus: SSHStatus = .unavailable("Start a local VM to fetch its IP address.")
    var sshUsername = "admin"
    var tartInstallationStatus: TartInstallationStatus = .checking

    private let service = TartCLIService()
    private let tartInstallCommand = "brew install cirruslabs/cli/tart"
    private let sharedFoldersDefaultsKey = "vmSharedFolders"
    private let sharedFoldersEncoder = JSONEncoder()
    private let sharedFoldersDecoder = JSONDecoder()
    private var activeCreateTasks: [UUID: Task<Void, Never>] = [:]

    private var deduplicatedVMs: [TartVM] {
        let taggedOCIRepositories = Set(
            vms
                .filter { !$0.isLocal && !$0.isDigestReference }
                .map(\.repositoryNameWithoutReference)
        )

        return vms.filter { vm in
            guard !vm.isLocal, vm.isDigestReference else { return true }
            return !taggedOCIRepositories.contains(vm.repositoryNameWithoutReference)
        }
    }

    var filteredVMs: [TartVM] {
        deduplicatedVMs.filter { vm in
            sourceFilter.matches(vm)
        }
    }

    var totalVisibleSourceCount: Int {
        deduplicatedVMs.count
    }

    var localSourceCount: Int {
        deduplicatedVMs.filter(\.isLocal).count
    }

    var ociSourceCount: Int {
        deduplicatedVMs.filter { !$0.isLocal }.count
    }

    var cloneSourceCandidates: [TartVM] {
        deduplicatedVMs
    }

    var officialCloneSourcePresets: [TartCloneSourcePreset] {
        tartOfficialImagePresets
    }

    func hasDownloadedCloneSource(_ sourceName: String) -> Bool {
        let trimmedSourceName = sourceName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSourceName.isEmpty else { return false }
        return vms.contains { $0.name == trimmedSourceName }
    }

    var selectedVM: TartVM? {
        guard let selectedVMID else { return filteredVMs.first ?? vms.first }
        return vms.first(where: { $0.id == selectedVMID })
    }

    var canCreateFromClone: Bool {
        !createForm.sourceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var selectedVMCanRun: Bool {
        selectedVM?.isLocal == true
    }

    var selectedVMCanFocusTrackedWindow: Bool {
        guard let vm = selectedVM else { return false }
        return vm.running && launchedGraphicsPIDs[vm.name] != nil
    }

    var selectedVMCanCreateLocalClone: Bool {
        guard let vm = selectedVM else { return false }
        return !vm.isLocal
    }

    var selectedVMCanEditSettings: Bool {
        guard let vm = selectedVM else { return false }
        return vm.isLocal && !vm.running && details != nil
    }

    var selectedVMCanUseSSH: Bool {
        guard let vm = selectedVM else { return false }
        return vm.isLocal && vm.running && sshStatus.ipAddress != nil
    }

    var isTartAvailable: Bool {
        tartInstallationStatus == .installed
    }

    var selectedVMSSHCommand: String? {
        guard let ipAddress = sshStatus.ipAddress else { return nil }
        let username = sshUsername.trimmingCharacters(in: .whitespacesAndNewlines)
        return username.isEmpty ? "ssh \(ipAddress)" : "ssh \(username)@\(ipAddress)"
    }

    var activeCreateJobs: [TartCreateJob] {
        createJobs.filter { !$0.state.isTerminal }
    }

    var recentCreateJobs: [TartCreateJob] {
        createJobs.sorted { $0.startedAt > $1.startedAt }
    }

    func loadInitialData() async {
        if vms.isEmpty {
            await loadCapabilities()
            await refresh()
        }
    }

    func loadCapabilities() async {
        do {
            tartCapabilities = try await service.detectCapabilities()
            tartInstallationStatus = .installed
            updateGuestAgentStatus()
        } catch {
            if case TartCLIError.tartNotInstalled = error {
                tartInstallationStatus = .missing
                vms = []
                details = nil
                selectedVMID = nil
                selectedInfoMessage = nil
                guestAgentStatus = .unknown("Install Tart to inspect Guest Agent support.")
                sshStatus = .unavailable("Install Tart to enable SSH-related features.")
                return
            }
            tartInstallationStatus = .unavailable(error.localizedDescription)
            present(error)
        }
    }

    func refresh() async {
        guard isTartAvailable else { return }
        isLoading = true
        defer { isLoading = false }

        do {
            let vms = try await service.fetchVMs()
            self.vms = vms
            selectedVMID = selectedVMID ?? vms.first?.id
            if let vm = selectedVM {
                try await loadDetails(for: vm)
                scheduleRuntimeStatusRefresh(for: vm)
            } else {
                details = nil
                selectedInfoMessage = nil
                guestAgentStatus = .unknown("Select a VM to inspect Guest Agent support.")
                sshStatus = .unavailable("Select a VM to inspect SSH connectivity.")
            }
        } catch {
            present(error)
        }
    }

    func selectVM(_ vm: TartVM?) async {
        guard isTartAvailable else { return }
        selectedVMID = vm?.id
        guard let vm else {
            details = nil
            selectedInfoMessage = nil
            return
        }

        do {
            try await loadDetails(for: vm)
            scheduleRuntimeStatusRefresh(for: vm)
        } catch {
            present(error)
        }
    }

    func runAction(_ action: TartAction) async {
        guard isTartAvailable else { return }
        guard let vm = selectedVM else { return }
        guard vm.isLocal else {
            selectedInfoMessage = "Runtime actions are only available for local VMs. Clone this OCI image first."
            return
        }
        isWorking = true
        defer { isWorking = false }

        do {
            let result = try await service.execute(action, name: vm.name)
            setCommandOutput(result, fallback: "\(action.title) completed for \(vm.name).")
            await refresh()
        } catch {
            present(error)
        }
    }

    func runVM(mode: TartRunMode, directoryShares: [TartDirectoryShare]? = nil) async {
        guard isTartAvailable else { return }
        guard let vm = selectedVM else { return }
        guard vm.isLocal else {
            selectedInfoMessage = "Runtime actions are only available for local VMs. Clone this OCI image first."
            return
        }

        let effectiveDirectoryShares = directoryShares ?? sharedDirectoryShares(for: vm.name)

        isWorking = true
        defer { isWorking = false }

        do {
            let pid = try await service.runVM(name: vm.name, mode: mode, directoryShares: effectiveDirectoryShares)
            if mode == .graphics {
                launchedGraphicsPIDs[vm.name] = pid
            }
            let shareSummary = effectiveDirectoryShares
                .filter { !$0.trimmedPath.isEmpty }
                .map(\.trimmedPath)
            if shareSummary.isEmpty {
                lastCommandOutput = "\(mode.title) started for \(vm.name)."
            } else {
                lastCommandOutput = "\(mode.title) started for \(vm.name) with shared folders:\n" + shareSummary.joined(separator: "\n")
            }
            try? await Task.sleep(for: .seconds(1))
            await refresh()
        } catch {
            present(error)
        }
    }

    func focusSelectedVMWindow() async {
        guard isTartAvailable else { return }
        guard let vm = selectedVM else { return }
        guard vm.isLocal else {
            selectedInfoMessage = "Window focus is only available for local VMs."
            return
        }
        guard let preferredPID = launchedGraphicsPIDs[vm.name] else {
            selectedInfoMessage = "Focus Window works only for VMs started with TartDesk's `Run` button in this session."
            return
        }

        do {
            let service = self.service
            let vmName = vm.name
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask(priority: .userInitiated) {
                    try service.focusVMWindow(name: vmName, preferredPID: preferredPID)
                }
                group.addTask {
                    try await Task.sleep(for: .seconds(2))
                    throw TartCLIError.windowFocusTimedOut(name: vmName)
                }

                try await group.next()
                group.cancelAll()
            }
            lastCommandOutput = "Focused window for \(vm.name)."
        } catch {
            present(error)
        }
    }

    func startCreateVM() {
        guard isTartAvailable else { return }
        let trimmedName = createForm.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            errorMessage = "Name is required."
            return
        }
        if createForm.creationMode == .clone && !canCreateFromClone {
            errorMessage = "Source VM or OCI image is required."
            return
        }

        createForm.name = trimmedName
        isShowingCreateSheet = false

        let form = createForm
        let job = TartCreateJob(
            name: form.name,
            sourceName: form.sourceName,
            creationMode: form.creationMode,
            state: form.creationMode == .clone ? .pulling : .creating,
            progressMessage: form.creationMode == .clone
                ? "Preparing source image..."
                : "Preparing VM creation..."
        )
        createJobs.insert(job, at: 0)
        let jobID = job.id

        let task = Task<Void, Never> { [weak self] in
            guard let self else { return }
            await self.performCreateVM(using: form, jobID: jobID)
        }
        activeCreateTasks[jobID] = task
        resetCreateForm()
    }

    func cancelCreateOperation(id: UUID) {
        activeCreateTasks[id]?.cancel()
    }

    func dismissCreateJob(id: UUID) {
        guard activeCreateTasks[id] == nil else { return }
        createJobs.removeAll { $0.id == id }
    }

    private func performCreateVM(using form: CreateVMFormState, jobID: UUID) async {
        defer {
            activeCreateTasks.removeValue(forKey: jobID)
        }

        do {
            var commandMessages: [String] = []
            if form.creationMode == .clone,
               shouldPullCloneSourceBeforeCreate(form.sourceName) {
                updateCreateJob(id: jobID, state: .pulling, progressMessage: "Pulling OCI image...", progressFraction: nil)
                let pullResult = try await service.pullImage(form.sourceName) { [weak self] progress in
                    await MainActor.run {
                        self?.updateCreateJob(
                            id: jobID,
                            state: .pulling,
                            progressMessage: progress.message,
                            progressFraction: progress.fractionCompleted
                        )
                    }
                }
                let pullMessage = formattedCommandMessage(
                    pullResult,
                    fallback: "Pulled \(form.sourceName)."
                )
                commandMessages.append(pullMessage)
            }
            updateCreateJob(
                id: jobID,
                state: .creating,
                progressMessage: form.creationMode == .clone
                    ? "Creating VM from source image..."
                    : "Creating empty VM...",
                progressFraction: nil
            )
            let result = try await service.createVM(form)
            commandMessages.append(
                formattedCommandMessage(result, fallback: "Created \(form.name).")
            )
            lastCommandOutput = commandMessages.joined(separator: "\n")
            updateCreateJob(
                id: jobID,
                state: .completed,
                progressMessage: "Created \(form.name).",
                progressFraction: 1
            )
            await refresh()
        } catch is CancellationError {
            lastCommandOutput = "Create canceled."
            updateCreateJob(
                id: jobID,
                state: .canceled,
                progressMessage: "Create canceled.",
                progressFraction: nil
            )
        } catch {
            updateCreateJob(
                id: jobID,
                state: .failed(error.localizedDescription),
                progressMessage: error.localizedDescription,
                progressFraction: nil
            )
            present(error)
        }
    }

    func prepareEditSheet() {
        guard isTartAvailable else { return }
        guard let vm = selectedVM, vm.isLocal, let details else { return }
        editForm = EditVMFormState(
            name: vm.name,
            cpu: details.cpu,
            memory: details.memory,
            diskSize: details.disk,
            displayWidth: parseDisplay(details.display).width,
            displayHeight: parseDisplay(details.display).height
        )
        editDirectoryShares = sharedDirectoryShares(for: vm.name)
        isShowingEditSheet = true
    }

    func updateSelectedVM() async {
        guard isTartAvailable else { return }
        guard let vm = selectedVM else { return }
        let trimmedName = editForm.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            errorMessage = "Name is required."
            return
        }

        editForm.name = trimmedName

        isWorking = true
        defer { isWorking = false }

        do {
            var commandMessages: [String] = []

            if trimmedName != vm.name {
                let renameResult = try await service.renameVM(from: vm.name, to: trimmedName)
                let renameMessage = [renameResult.stdout, renameResult.stderr]
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                    .joined(separator: "\n")
                commandMessages.append(renameMessage.isEmpty ? "Renamed \(vm.name) to \(trimmedName)." : renameMessage)

                if let trackedPID = launchedGraphicsPIDs.removeValue(forKey: vm.name) {
                    launchedGraphicsPIDs[trimmedName] = trackedPID
                }
                renameSharedDirectoryShares(from: vm.name, to: trimmedName)
                selectedVMID = trimmedName
            }

            let result = try await service.updateVM(editForm)
            let updateMessage = [result.stdout, result.stderr]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
            commandMessages.append(updateMessage.isEmpty ? "Updated \(editForm.name)." : updateMessage)
            try saveEditedDirectoryShares(for: editForm.name)
            lastCommandOutput = commandMessages.joined(separator: "\n")
            isShowingEditSheet = false
            await refresh()
        } catch {
            present(error)
        }
    }

    func prepareCreateSheet() {
        guard isTartAvailable else { return }
        createForm = CreateVMFormState()
        if let selectedVM {
            selectCreateSource(selectedVM.name)
        } else if let firstCloneCandidate = cloneSourceCandidates.first {
            selectCreateSource(firstCloneCandidate.name)
        } else if let defaultPreset = officialCloneSourcePresets.first {
            selectCreateSource(defaultPreset.sourceName)
        }
        isShowingCreateSheet = true
    }

    func prepareCloneFromSelectedVM() {
        guard isTartAvailable else { return }
        guard let selectedVM else { return }
        createForm = CreateVMFormState()
        createForm.creationMode = .clone
        selectCreateSource(selectedVM.name)
        isShowingCreateSheet = true
    }

    func selectCreateSource(_ sourceName: String) {
        let previousSourceName = createForm.sourceName
        let previousSuggestedName = isRemoteCloneSource(previousSourceName)
            ? suggestedCloneName(for: previousSourceName)
            : ""
        let trimmedCurrentName = createForm.name.trimmingCharacters(in: .whitespacesAndNewlines)

        createForm.sourceName = sourceName

        guard createForm.creationMode == .clone else { return }

        if isRemoteCloneSource(sourceName) {
            let suggestedName = suggestedCloneName(for: sourceName)
            if trimmedCurrentName.isEmpty || trimmedCurrentName == previousSuggestedName {
                createForm.name = suggestedName
            }
        } else if trimmedCurrentName == previousSuggestedName {
            createForm.name = ""
        }
    }

    func dismissError() {
        errorMessage = nil
    }

    func addEditDirectoryShare() {
        editDirectoryShares.append(TartDirectoryShare())
    }

    func removeEditDirectoryShare(id: TartDirectoryShare.ID) {
        editDirectoryShares.removeAll { $0.id == id }
    }

    func setEditDirectorySharePath(id: TartDirectoryShare.ID, path: String) {
        guard let index = editDirectoryShares.firstIndex(where: { $0.id == id }) else { return }
        editDirectoryShares[index].path = path
        if editDirectoryShares[index].trimmedName.isEmpty {
            editDirectoryShares[index].name = URL(fileURLWithPath: path).lastPathComponent
        }
    }

    func copyTartInstallCommand() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(tartInstallCommand, forType: .string)
        lastCommandOutput = "Copied install command: \(tartInstallCommand)"
    }

    func openTartWebsite() {
        guard let url = URL(string: "https://github.com/cirruslabs/tart") else { return }
        NSWorkspace.shared.open(url)
    }

    func copySSHCommand() {
        guard let command = selectedVMSSHCommand else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
        lastCommandOutput = "Copied SSH command: \(command)"
    }

    func openSSHInTerminal() {
        guard let command = selectedVMSSHCommand else {
            errorMessage = "SSH command is not available for the selected VM."
            return
        }

        do {
            try service.openSSHInTerminal(command: command)
            lastCommandOutput = "Opened Terminal with: \(command)"
        } catch {
            present(error)
        }
    }

    private func loadDetails(for vm: TartVM) async throws {
        guard vm.isLocal else {
            details = nil
            selectedInfoMessage = "OCI images do not support `tart get`. Clone this image to create a local VM, then inspect and run it."
            guestAgentStatus = .notLocalVM
            sshStatus = .unavailable("SSH applies only to local running VMs.")
            return
        }

        details = try await service.fetchDetails(for: vm.name)
        if vm.running {
            if launchedGraphicsPIDs[vm.name] == nil {
                selectedInfoMessage = "Focus Window works only for VMs started with TartDesk's `Run` button in this session."
            } else {
                selectedInfoMessage = "Stop the VM before editing CPU, memory, display, or disk settings."
            }
        } else if launchedGraphicsPIDs[vm.name] == nil {
            selectedInfoMessage = nil
        } else {
            selectedInfoMessage = nil
        }
        updateGuestAgentStatus()
    }

    private func setCommandOutput(_ result: TartCommandResult, fallback: String) {
        lastCommandOutput = formattedCommandMessage(result, fallback: fallback)
    }

    private func resetCreateForm() {
        createForm = CreateVMFormState()
    }

    private func saveEditedDirectoryShares(for vmName: String) throws {
        let normalizedShares = editDirectoryShares
            .map { share in
                var normalized = share
                normalized.name = share.trimmedName
                normalized.path = share.trimmedPath
                normalized.mountTag = share.trimmedMountTag
                return normalized
            }
            .filter { !$0.trimmedPath.isEmpty }

        let groupedShares = Dictionary(grouping: normalizedShares, by: \.effectiveMountTag)
        for (tag, items) in groupedShares where items.count > 1 {
            let names = items.map(\.displayName)
            guard Set(names).count == names.count else {
                throw CocoaError(.validationMultipleErrors, userInfo: [
                    NSLocalizedDescriptionKey: "Shared folders with mount tag `\(tag)` must have unique names."
                ])
            }
        }

        var sharedFolders = loadSharedFoldersMap()
        if normalizedShares.isEmpty {
            sharedFolders.removeValue(forKey: vmName)
        } else {
            sharedFolders[vmName] = normalizedShares
        }
        persistSharedFoldersMap(sharedFolders)
    }

    private func sharedDirectoryShares(for vmName: String) -> [TartDirectoryShare] {
        loadSharedFoldersMap()[vmName] ?? []
    }

    private func renameSharedDirectoryShares(from source: String, to destination: String) {
        var sharedFolders = loadSharedFoldersMap()
        guard let shares = sharedFolders.removeValue(forKey: source) else { return }
        sharedFolders[destination] = shares
        persistSharedFoldersMap(sharedFolders)
    }

    private func loadSharedFoldersMap() -> [String: [TartDirectoryShare]] {
        guard let data = UserDefaults.standard.data(forKey: sharedFoldersDefaultsKey) else { return [:] }
        return (try? sharedFoldersDecoder.decode([String: [TartDirectoryShare]].self, from: data)) ?? [:]
    }

    private func persistSharedFoldersMap(_ sharedFolders: [String: [TartDirectoryShare]]) {
        guard let data = try? sharedFoldersEncoder.encode(sharedFolders) else { return }
        UserDefaults.standard.set(data, forKey: sharedFoldersDefaultsKey)
    }

    private func suggestedCloneName(for sourceName: String) -> String {
        let lastComponent = sourceName.split(separator: "/").last.map(String.init) ?? sourceName
        let sanitized = lastComponent
            .replacingOccurrences(of: ":latest", with: "")
            .replacingOccurrences(of: "@", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        return sanitized
    }

    private func isRemoteCloneSource(_ sourceName: String) -> Bool {
        sourceName.contains("/")
    }

    private func shouldPullCloneSourceBeforeCreate(_ sourceName: String) -> Bool {
        guard isRemoteCloneSource(sourceName) else { return false }
        let trimmedSourceName = sourceName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSourceName.isEmpty else { return false }
        return !vms.contains { $0.name == trimmedSourceName }
    }

    private func formattedCommandMessage(_ result: TartCommandResult, fallback: String) -> String {
        let text = [result.stdout, result.stderr]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        return text.isEmpty ? fallback : text
    }

    private func updateCreateJob(
        id: UUID,
        state: TartCreateJobState,
        progressMessage: String,
        progressFraction: Double?
    ) {
        guard let index = createJobs.firstIndex(where: { $0.id == id }) else { return }
        createJobs[index].state = state
        createJobs[index].progressMessage = progressMessage
        createJobs[index].progressFraction = progressFraction
    }

    private func parseDisplay(_ display: String) -> (width: Int, height: Int) {
        let parts = display.split(separator: "x")
        guard parts.count == 2,
              let width = Int(parts[0]),
              let height = Int(parts[1]) else {
            return (1024, 768)
        }
        return (width, height)
    }

    private func present(_ error: Error) {
        errorMessage = error.localizedDescription
    }

    private func updateGuestAgentStatus() {
        guard let vm = selectedVM else {
            guestAgentStatus = .unknown("Select a VM to inspect Guest Agent support.")
            return
        }
        guard vm.isLocal else {
            guestAgentStatus = .notLocalVM
            return
        }
        guard let capabilities = tartCapabilities else {
            guestAgentStatus = .unknown("Checking Tart capabilities...")
            return
        }
        guard capabilities.supportsExec else {
            guestAgentStatus = .unsupportedCLI
            return
        }
        guard vm.running else {
            guestAgentStatus = .vmStopped
            return
        }
        guestAgentStatus = .unknown("Probing Guest Agent with `tart exec`...")
    }

    private func scheduleRuntimeStatusRefresh(for vm: TartVM) {
        let vmID = vm.id
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.loadSSHStatus(for: vm)
            guard self.selectedVM?.id == vmID else { return }
            await self.probeGuestAgentIfNeeded(for: vm)
        }
    }

    private func loadSSHStatus(for vm: TartVM) async {
        guard vm.isLocal else {
            sshStatus = .unavailable("SSH applies only to local running VMs.")
            return
        }
        guard vm.running else {
            sshStatus = .unavailable("Start the VM to fetch its IP address for SSH.")
            return
        }

        sshStatus = .loading
        do {
            let ipAddress = try await service.fetchIPAddress(for: vm.name)
            sshStatus = .available(ipAddress: ipAddress)
        } catch {
            sshStatus = .unavailable(error.localizedDescription)
        }
    }

    private func probeGuestAgentIfNeeded(for vm: TartVM) async {
        guard vm.isLocal else {
            guestAgentStatus = .notLocalVM
            return
        }
        guard let capabilities = tartCapabilities else {
            guestAgentStatus = .unknown("Checking Tart capabilities...")
            return
        }
        guard capabilities.supportsExec else {
            guestAgentStatus = .unsupportedCLI
            return
        }
        guard vm.running else {
            guestAgentStatus = .vmStopped
            return
        }

        guestAgentStatus = .unknown("Probing Guest Agent with `tart exec`...")
        do {
            let available = try await service.probeGuestAgentAvailability(for: vm.name)
            guestAgentStatus = available
                ? .available
                : .unavailable("Guest Agent probe failed for \(vm.name).")
        } catch {
            guestAgentStatus = .unavailable(error.localizedDescription)
        }
    }
}
