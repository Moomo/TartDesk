import SwiftUI

private let slate900 = Color(red: 0.10, green: 0.14, blue: 0.22)
private let slate700 = Color(red: 0.30, green: 0.36, blue: 0.46)
private let slate200 = Color(red: 0.86, green: 0.90, blue: 0.95)
private let surfaceBlue = Color(red: 0.95, green: 0.97, blue: 0.99)
private let sidebarSurface = Color(red: 0.83, green: 0.89, blue: 0.96)

struct ContentView: View {
    @Bindable var viewModel: TartDeskViewModel
    @State private var isShowingDeleteConfirmation = false

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 220, ideal: 270)
        } content: {
            vmList
        } detail: {
            detailPanel
        }
        .navigationSplitViewStyle(.balanced)
        .task {
            await viewModel.loadInitialData()
        }
        .toolbarColorScheme(.dark, for: .windowToolbar)
        .toolbarBackground(.visible, for: .windowToolbar)
        .toolbar {
            ToolbarItemGroup {
                Button {
                    viewModel.prepareCreateSheet()
                } label: {
                    Label("Create", systemImage: "plus")
                }

                Button {
                    Task { await viewModel.refresh() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(viewModel.isLoading || viewModel.isWorking)
            }
        }
        .sheet(isPresented: $viewModel.isShowingCreateSheet) {
            CreateVMSheet(viewModel: viewModel)
        }
        .sheet(isPresented: $viewModel.isShowingEditSheet) {
            EditVMSheet(viewModel: viewModel)
        }
        .confirmationDialog(
            "Delete VM?",
            isPresented: $isShowingDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                Task { await viewModel.runAction(.delete) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will permanently delete the selected local VM.")
        }
        .alert(
            "Tart Error",
            isPresented: Binding(
                get: { viewModel.errorMessage != nil },
                set: { if !$0 { viewModel.dismissError() } }
            ),
            actions: {
                Button("OK", role: .cancel) {
                    viewModel.dismissError()
                }
            },
            message: {
                Text(viewModel.errorMessage ?? "")
            }
        )
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("TartDesk")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundStyle(slate900)
                    .lineLimit(1)
                    .minimumScaleFactor(0.9)
                Text("Manage Tart images and VM instances from a native macOS app.")
                    .foregroundStyle(slate700)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            sourceFilterTabs

            statsCard

            Spacer()
        }
        .padding(20)
        .background(sidebarSurface)
        .clipped()
    }

    private var sourceFilterTabs: some View {
        HStack(spacing: 8) {
            ForEach(TartSourceFilter.allCases) { filter in
                Button {
                    viewModel.sourceFilter = filter
                } label: {
                    Text(filter.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(viewModel.sourceFilter == filter ? .white : slate900)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .background(
                            viewModel.sourceFilter == filter
                                ? slate900
                                : Color.clear,
                            in: RoundedRectangle(cornerRadius: 12)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(8)
        .background(.white, in: RoundedRectangle(cornerRadius: 18))
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .stroke(slate200.opacity(0.9), lineWidth: 1)
        )
    }

    private var vmList: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                ForEach(viewModel.filteredVMs) { vm in
                    Button {
                        Task { await viewModel.selectVM(vm) }
                    } label: {
                        VMRow(vm: vm, isSelected: vm.id == viewModel.selectedVMID)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(16)
        .background(surfaceBlue)
        .overlay {
            if viewModel.filteredVMs.isEmpty && !viewModel.isLoading {
                ContentUnavailableView(
                    "No Matching VMs",
                    systemImage: "externaldrive.badge.questionmark",
                    description: Text("Try another source filter or create a new instance.")
                )
            }
        }
    }

    private var detailPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let vm = viewModel.selectedVM {
                    header(for: vm)
                    actionBar(for: vm)
                    detailsGrid
                    commandOutput
                } else {
                    ContentUnavailableView(
                        "Select a VM",
                        systemImage: "macwindow",
                        description: Text("Choose an image or instance from the list.")
                    )
                    .frame(maxWidth: .infinity, minHeight: 480)
                }
            }
            .padding(24)
        }
        .background(Color(NSColor.windowBackgroundColor))
        .overlay(alignment: .topTrailing) {
            if viewModel.isLoading || viewModel.isWorking {
                ProgressView()
                    .padding()
            }
        }
    }

    private var statsCard: some View {
        let total = viewModel.vms.count
        let running = viewModel.vms.filter(\.running).count
        let local = viewModel.vms.filter(\.isLocal).count

        return VStack(alignment: .leading, spacing: 12) {
            statLine(label: "Total", value: "\(total)")
            statLine(label: "Running", value: "\(running)")
            statLine(label: "Local", value: "\(local)")
        }
        .padding(16)
        .background(.white, in: RoundedRectangle(cornerRadius: 20))
        .overlay(
            RoundedRectangle(cornerRadius: 20)
                .stroke(slate200.opacity(0.8), lineWidth: 1)
        )
    }

    private func statLine(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(slate700)
            Spacer()
            Text(value)
                .fontWeight(.semibold)
                .foregroundStyle(slate900)
        }
    }

    private func header(for vm: TartVM) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(vm.name)
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                    Text(vm.source)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if vm.isLocal {
                    Button {
                        viewModel.prepareEditSheet()
                    } label: {
                        Image(systemName: "gearshape.fill")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 30, height: 30)
                            .background(Color.accentColor, in: Circle())
                            .overlay(
                                Circle()
                                    .stroke(Color.white.opacity(0.22), lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(viewModel.isWorking || !viewModel.selectedVMCanEditSettings)
                    .help(vm.running ? "Stop the VM to edit settings" : "Edit VM settings")
                }
                Text(vm.stateLabel.capitalized)
                    .font(.headline)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(stateColor(for: vm).opacity(0.15), in: Capsule())
                    .foregroundStyle(stateColor(for: vm))
            }

            HStack(spacing: 10) {
                Label(vm.displayDisk, systemImage: "internaldrive")
                Label(vm.displaySize, systemImage: "externaldrive")
                Label(vm.shortSource, systemImage: vm.isLocal ? "internaldrive.fill" : "shippingbox")
            }
            .foregroundStyle(.secondary)
        }
    }

    private func actionBar(for vm: TartVM) -> some View {
        HStack(spacing: 10) {
            if vm.isLocal {
                Button("Run") {
                    Task { await viewModel.runVM(mode: .graphics) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.isWorking)

                Button("Run Headless") {
                    Task { await viewModel.runVM(mode: .headless) }
                }
                .disabled(viewModel.isWorking)

                Button("Focus Window") {
                    Task { await viewModel.focusSelectedVMWindow() }
                }
                .disabled(!viewModel.selectedVMCanFocusTrackedWindow || viewModel.isWorking)

                Button("Stop") {
                    Task { await viewModel.runAction(.stop) }
                }
                .disabled(!vm.running || viewModel.isWorking)

                Button("Suspend") {
                    Task { await viewModel.runAction(.suspend) }
                }
                .disabled(!vm.running || viewModel.isWorking)

                Button("Delete", role: .destructive) {
                    isShowingDeleteConfirmation = true
                }
                .disabled(viewModel.isWorking)
            } else {
                Button("Create Local VM") {
                    viewModel.prepareCloneFromSelectedVM()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!viewModel.selectedVMCanCreateLocalClone || viewModel.isWorking)
            }

            Spacer()
        }
    }

    private var detailsGrid: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let message = viewModel.selectedInfoMessage {
                Text(message)
                    .foregroundStyle(.secondary)
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(NSColor.controlBackgroundColor), in: RoundedRectangle(cornerRadius: 18))
            }

            if let details = viewModel.details {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 14)], spacing: 14) {
                    DetailCard(title: "OS", value: details.os)
                    DetailCard(title: "CPU", value: details.cpuLabel)
                    DetailCard(title: "Memory", value: details.memoryLabel)
                    DetailCard(title: "Display", value: details.display)
                    DetailCard(title: "Disk", value: details.diskLabel)
                    DetailCard(title: "Usage", value: details.sizeLabel)
                }
            }
        }
    }

    private var commandOutput: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Last Command Output")
                .font(.headline)

            ScrollView {
                Text(viewModel.lastCommandOutput.isEmpty ? "No commands executed yet." : viewModel.lastCommandOutput)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(12)
            }
            .frame(minHeight: 140)
            .background(Color(NSColor.textBackgroundColor), in: RoundedRectangle(cornerRadius: 16))
        }
    }

    private func stateColor(for vm: TartVM) -> Color {
        if vm.running { return .green }
        if vm.state.caseInsensitiveCompare("suspended") == .orderedSame { return .orange }
        return .secondary
    }
}

private struct VMRow: View {
    let vm: TartVM
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(vm.name)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                    .foregroundStyle(slate900)
                Spacer()
                Text(vm.stateLabel.capitalized)
                    .font(.caption)
                    .foregroundStyle(vm.running ? .green : .secondary)
            }

            HStack(spacing: 12) {
                Label(vm.shortSource, systemImage: vm.isLocal ? "internaldrive.fill" : "shippingbox")
                Label(vm.displaySize, systemImage: "externaldrive")
            }
            .font(.caption)
            .foregroundStyle(slate700)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(
            isSelected
                ? Color.accentColor.opacity(0.14)
                : .white,
            in: RoundedRectangle(cornerRadius: 12)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(
                    isSelected ? Color.accentColor.opacity(0.32) : slate200,
                    lineWidth: 1
                )
        )
    }
}

private struct DetailCard: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title3.weight(.semibold))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color(NSColor.controlBackgroundColor), in: RoundedRectangle(cornerRadius: 18))
    }
}

private struct CreateVMSheet: View {
    @Bindable var viewModel: TartDeskViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Create Instance")
                .font(.system(size: 26, weight: .bold, design: .rounded))

            Picker("Mode", selection: $viewModel.createForm.creationMode) {
                ForEach(CreateVMFormState.CreationMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            TextField("New VM name", text: $viewModel.createForm.name)

            if viewModel.createForm.creationMode == .clone {
                Picker("Source VM", selection: $viewModel.createForm.sourceName) {
                    ForEach(viewModel.cloneSourceCandidates, id: \.name) { vm in
                        Text(vm.name).tag(vm.name)
                    }
                }
            } else {
                Stepper(value: $viewModel.createForm.diskSize, in: 10...500, step: 10) {
                    Text("Disk Size: \(viewModel.createForm.diskSize) GB")
                }

                Toggle("Linux template", isOn: $viewModel.createForm.linuxTemplate)
            }

            HStack {
                Spacer()
                Button("Cancel") {
                    dismiss()
                }
                Button("Create") {
                    Task { await viewModel.createVM() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(
                    viewModel.createForm.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                    (viewModel.createForm.creationMode == .clone && !viewModel.canCreateFromClone) ||
                    viewModel.isWorking
                )
            }
        }
        .padding(24)
        .frame(width: 460)
    }
}

private struct EditVMSheet: View {
    @Bindable var viewModel: TartDeskViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Edit VM Settings")
                .font(.system(size: 26, weight: .bold, design: .rounded))

            LabeledContent("VM") {
                Text(viewModel.editForm.name)
            }

            Stepper(value: $viewModel.editForm.cpu, in: 1...16) {
                Text("CPU: \(viewModel.editForm.cpu)")
            }

            Stepper(value: $viewModel.editForm.memory, in: 1024...65536, step: 1024) {
                Text("Memory: \(viewModel.editForm.memory) MB")
            }

            Stepper(value: $viewModel.editForm.diskSize, in: 10...1000, step: 10) {
                Text("Disk Size: \(viewModel.editForm.diskSize) GB")
            }

            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Display Width")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("Width", value: $viewModel.editForm.displayWidth, format: .number)
                        .textFieldStyle(.roundedBorder)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Display Height")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("Height", value: $viewModel.editForm.displayHeight, format: .number)
                        .textFieldStyle(.roundedBorder)
                }
            }

            HStack {
                Spacer()
                Button("Cancel") {
                    dismiss()
                }
                Button("Save") {
                    Task { await viewModel.updateSelectedVM() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.isWorking)
            }
        }
        .padding(24)
        .frame(width: 460)
    }
}
