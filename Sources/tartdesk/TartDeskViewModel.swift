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
    var errorMessage: String?
    var lastCommandOutput = ""
    var selectedInfoMessage: String?
    var launchedGraphicsPIDs: [String: pid_t] = [:]
    var tartCapabilities: TartCapabilities?
    var guestAgentStatus: GuestAgentStatus = .unknown("Checking Tart capabilities...")
    var sshStatus: SSHStatus = .unavailable("Start a local VM to fetch its IP address.")
    var sshUsername = "admin"

    private let service = TartCLIService()

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

    var cloneSourceCandidates: [TartVM] {
        deduplicatedVMs
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

    var selectedVMSSHCommand: String? {
        guard let ipAddress = sshStatus.ipAddress else { return nil }
        let username = sshUsername.trimmingCharacters(in: .whitespacesAndNewlines)
        return username.isEmpty ? "ssh \(ipAddress)" : "ssh \(username)@\(ipAddress)"
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
            updateGuestAgentStatus()
        } catch {
            present(error)
        }
    }

    func refresh() async {
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

    func runVM(mode: TartRunMode) async {
        guard let vm = selectedVM else { return }
        guard vm.isLocal else {
            selectedInfoMessage = "Runtime actions are only available for local VMs. Clone this OCI image first."
            return
        }

        isWorking = true
        defer { isWorking = false }

        do {
            let pid = try await service.runVM(name: vm.name, mode: mode)
            if mode == .graphics {
                launchedGraphicsPIDs[vm.name] = pid
            }
            lastCommandOutput = "\(mode.title) started for \(vm.name)."
            try? await Task.sleep(for: .seconds(1))
            await refresh()
        } catch {
            present(error)
        }
    }

    func focusSelectedVMWindow() async {
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

    func createVM() async {
        let trimmedName = createForm.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            errorMessage = "Name is required."
            return
        }

        createForm.name = trimmedName
        isWorking = true
        defer { isWorking = false }

        do {
            let result = try await service.createVM(createForm)
            setCommandOutput(result, fallback: "Created \(createForm.name).")
            isShowingCreateSheet = false
            resetCreateForm()
            await refresh()
        } catch {
            present(error)
        }
    }

    func prepareEditSheet() {
        guard let vm = selectedVM, vm.isLocal, let details else { return }
        editForm = EditVMFormState(
            name: vm.name,
            cpu: details.cpu,
            memory: details.memory,
            diskSize: details.disk,
            displayWidth: parseDisplay(details.display).width,
            displayHeight: parseDisplay(details.display).height
        )
        isShowingEditSheet = true
    }

    func updateSelectedVM() async {
        guard !editForm.name.isEmpty else { return }

        isWorking = true
        defer { isWorking = false }

        do {
            let result = try await service.updateVM(editForm)
            setCommandOutput(result, fallback: "Updated \(editForm.name).")
            isShowingEditSheet = false
            await refresh()
        } catch {
            present(error)
        }
    }

    func prepareCreateSheet() {
        createForm = CreateVMFormState()
        if let selectedVM {
            createForm.sourceName = selectedVM.name
        } else if let firstCloneCandidate = vms.first {
            createForm.sourceName = firstCloneCandidate.name
        }
        isShowingCreateSheet = true
    }

    func prepareCloneFromSelectedVM() {
        guard let selectedVM else { return }
        createForm = CreateVMFormState()
        createForm.creationMode = .clone
        createForm.sourceName = selectedVM.name
        if !selectedVM.isLocal {
            createForm.name = suggestedCloneName(for: selectedVM.name)
        }
        isShowingCreateSheet = true
    }

    func dismissError() {
        errorMessage = nil
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
        let text = [result.stdout, result.stderr]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        lastCommandOutput = text.isEmpty ? fallback : text
    }

    private func resetCreateForm() {
        createForm = CreateVMFormState()
    }

    private func suggestedCloneName(for sourceName: String) -> String {
        let lastComponent = sourceName.split(separator: "/").last.map(String.init) ?? sourceName
        let sanitized = lastComponent
            .replacingOccurrences(of: ":latest", with: "")
            .replacingOccurrences(of: "@", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        return sanitized
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
