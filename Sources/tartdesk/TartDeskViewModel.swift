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

    func loadInitialData() async {
        if vms.isEmpty {
            await refresh()
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
            } else {
                details = nil
                selectedInfoMessage = nil
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

    private func loadDetails(for vm: TartVM) async throws {
        guard vm.isLocal else {
            details = nil
            selectedInfoMessage = "OCI images do not support `tart get`. Clone this image to create a local VM, then inspect and run it."
            return
        }

        details = try await service.fetchDetails(for: vm.name)
        if vm.running && launchedGraphicsPIDs[vm.name] == nil {
            selectedInfoMessage = "Focus Window works only for VMs started with TartDesk's `Run` button in this session."
        } else {
            selectedInfoMessage = nil
        }
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
}
