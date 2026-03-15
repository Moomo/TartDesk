import SwiftUI
import UniformTypeIdentifiers

private let slate900 = Color(NSColor.labelColor)
private let slate700 = Color(NSColor.secondaryLabelColor)
private let slate200 = Color(NSColor.separatorColor)
private let surfaceBlue = Color(NSColor.controlBackgroundColor)
private let sidebarSurface = Color(NSColor.underPageBackgroundColor)

struct ContentView: View {
    @Bindable var viewModel: TartDeskViewModel
    @State private var isShowingDeleteConfirmation = false
    @State private var isSidebarVisible = true
    @State private var isShowingDownloadsPanel = false

    var body: some View {
        GeometryReader { proxy in
            if viewModel.isTartAvailable {
                let layout = layoutMetrics(for: proxy.size.width)

                HStack(spacing: 0) {
                    if isSidebarVisible {
                        sidebar
                            .frame(width: layout.sidebarWidth)
                            .transition(.move(edge: .leading).combined(with: .opacity))

                        Divider()
                    }

                    vmList
                        .frame(width: layout.listWidth)

                    Divider()

                    detailPanel
                        .frame(minWidth: layout.detailMinWidth, maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                tartInstallFullscreen
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(NSColor.windowBackgroundColor))
            }
        }
        .animation(.snappy(duration: 0.18, extraBounce: 0), value: isSidebarVisible)
        .task {
            await viewModel.loadInitialData()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            guard viewModel.isTartAvailable else { return }
            Task { await viewModel.refresh() }
        }
        .toolbarBackground(.visible, for: .windowToolbar)
        .toolbar {
            ToolbarItemGroup {
                Button {
                    isSidebarVisible.toggle()
                } label: {
                    Label(isSidebarVisible ? "Hide Sidebar" : "Show Sidebar", systemImage: "sidebar.leading")
                }

                Button {
                    viewModel.prepareCreateSheet()
                } label: {
                    Label("Create", systemImage: "plus")
                }
                .disabled(!viewModel.isTartAvailable)

                Button {
                    Task { await viewModel.refresh() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(!viewModel.isTartAvailable || viewModel.isLoading || viewModel.isWorking)

                Button {
                    isShowingDownloadsPanel.toggle()
                } label: {
                    downloadsToolbarButton
                }
                .help(isShowingDownloadsPanel ? "Hide Downloads" : "Show Downloads")
                .disabled(viewModel.recentCreateJobs.isEmpty)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(isPresented: $viewModel.isShowingCreateSheet) {
            CreateVMSheet(viewModel: viewModel)
        }
        .sheet(isPresented: $viewModel.isShowingEditSheet) {
            EditVMSheet(viewModel: viewModel)
        }
        .sheet(
            isPresented: Binding(
                get: { viewModel.errorMessage != nil },
                set: { if !$0 { viewModel.dismissError() } }
            )
        ) {
            ErrorSheet(viewModel: viewModel)
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
        .onChange(of: viewModel.activeCreateJobs.count) { _, newValue in
            if newValue > 0 {
                isShowingDownloadsPanel = true
            }
        }
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
                        .foregroundStyle(viewModel.sourceFilter == filter ? Color(NSColor.selectedMenuItemTextColor) : Color.primary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .background(
                            viewModel.sourceFilter == filter
                                ? Color.accentColor
                                : Color.clear,
                            in: RoundedRectangle(cornerRadius: 12)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(8)
        .background(Color(NSColor.controlBackgroundColor), in: RoundedRectangle(cornerRadius: 18))
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
            if !viewModel.isTartAvailable {
                ContentUnavailableView(
                    "Tart Not Available",
                    systemImage: "shippingbox.circle",
                    description: Text(viewModel.tartInstallationStatus.message)
                )
            } else if viewModel.filteredVMs.isEmpty && !viewModel.isLoading {
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
                if !viewModel.isTartAvailable {
                    tartInstallCard
                } else if let vm = viewModel.selectedVM {
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
            VStack(alignment: .trailing, spacing: 12) {
                if viewModel.isLoading || viewModel.isWorking {
                    ProgressView()
                }

                if isShowingDownloadsPanel && !viewModel.recentCreateJobs.isEmpty {
                    CreateJobsPanel(viewModel: viewModel)
                }
            }
            .padding()
        }
    }

    private var downloadsToolbarButton: some View {
        ZStack(alignment: .topTrailing) {
            Image(systemName: viewModel.activeCreateJobs.isEmpty ? "arrow.down.circle" : "arrow.down.circle.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(slate900)

            if !viewModel.activeCreateJobs.isEmpty {
                Text("\(viewModel.activeCreateJobs.count)")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Color.red, in: Capsule())
                    .offset(x: 10, y: -8)
            }
        }
        .frame(width: 24, height: 20)
        .contentShape(Rectangle())
    }

    private func layoutMetrics(for totalWidth: CGFloat) -> (sidebarWidth: CGFloat, listWidth: CGFloat, detailMinWidth: CGFloat) {
        let hasSidebar = isSidebarVisible
        let dividerCount: CGFloat = hasSidebar ? 2 : 1
        let availableWidth = max(totalWidth - dividerCount, 720)

        if hasSidebar {
            let sidebarWidth = min(max(availableWidth * 0.22, 200), 270)
            let listWidth = min(max(availableWidth * 0.30, 240), 340)
            let detailMinWidth = max(availableWidth - sidebarWidth - listWidth, 280)
            return (sidebarWidth, listWidth, detailMinWidth)
        } else {
            let listWidth = min(max(availableWidth * 0.34, 250), 340)
            let detailMinWidth = max(availableWidth - listWidth, 320)
            return (0, listWidth, detailMinWidth)
        }
    }

    private var tartInstallFullscreen: some View {
        ScrollView {
            VStack {
                tartInstallCard
                    .frame(maxWidth: 760)
            }
            .frame(maxWidth: .infinity, minHeight: 0)
            .padding(.horizontal, 32)
            .padding(.vertical, 40)
        }
    }

    private var tartInstallCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Tart Required", systemImage: "shippingbox.circle.fill")
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .foregroundStyle(slate900)

            Text(viewModel.tartInstallationStatus.message)
                .foregroundStyle(.secondary)

            Text("Install command")
                .font(.headline)

            Text("brew install cirruslabs/cli/tart")
                .frame(maxWidth: .infinity, alignment: .leading)
                .font(.system(.body, design: .monospaced))
                .padding(12)
                .background(Color(NSColor.textBackgroundColor), in: RoundedRectangle(cornerRadius: 12))

            HStack(spacing: 10) {
                Button(viewModel.isInstallingTart ? "Installing..." : "Install Tart") {
                    viewModel.installTart()
                }
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.isInstallingTart)

                Button("Copy Install Command") {
                    viewModel.copyTartInstallCommand()
                }
                .buttonStyle(.bordered)
                .disabled(viewModel.isInstallingTart)

                Button("Open Tart Website") {
                    viewModel.openTartWebsite()
                }
                .buttonStyle(.bordered)
            }

            if viewModel.isInstallingTart || !(viewModel.tartInstallLog.isEmpty && viewModel.tartInstallProgressMessage == nil) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) {
                        if viewModel.isInstallingTart {
                            ProgressView()
                                .controlSize(.regular)
                        }
                        Text(viewModel.tartInstallProgressMessage ?? "Waiting for installer output...")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    ScrollView {
                        Text(viewModel.tartInstallLog.isEmpty ? "Installer output will appear here." : viewModel.tartInstallLog)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .font(.system(size: 12, design: .monospaced))
                            .textSelection(.enabled)
                            .padding(12)
                    }
                    .frame(minHeight: 140, maxHeight: 180)
                    .background(Color(NSColor.textBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 360, alignment: .topLeading)
        .padding(24)
        .background(Color(NSColor.controlBackgroundColor), in: RoundedRectangle(cornerRadius: 24))
    }

    private var statsCard: some View {
        let total = viewModel.totalVisibleSourceCount
        let running = viewModel.vms.filter(\.running).count
        let local = viewModel.localSourceCount
        let oci = viewModel.ociSourceCount

        return VStack(alignment: .leading, spacing: 12) {
            statLine(label: "Total", value: "\(total)")
            statLine(label: "Running", value: "\(running)")
            statLine(label: "Local", value: "\(local)")
            statLine(label: "OCI", value: "\(oci)")
        }
        .padding(16)
        .background(Color(NSColor.controlBackgroundColor), in: RoundedRectangle(cornerRadius: 20))
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
                    Text(vm.isLocal ? vm.name : vm.displayTitle)
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                    if vm.isLocal {
                        Text(vm.source)
                            .foregroundStyle(.secondary)
                    } else {
                        Text(vm.displayReference)
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(slate700)
                            .textSelection(.enabled)
                        Text(vm.source)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if vm.isLocal {
                    HStack(spacing: 8) {
                        Button {
                            Task { await viewModel.focusSelectedVMWindow() }
                        } label: {
                            Image(systemName: "macwindow.badge.plus")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.white)
                                .frame(width: 30, height: 30)
                                .background(Color.green.opacity(0.88), in: Circle())
                                .overlay(
                                    Circle()
                                        .stroke(Color.white.opacity(0.22), lineWidth: 1)
                                )
                        }
                        .buttonStyle(.plain)
                        .disabled(viewModel.isWorking || !viewModel.selectedVMCanFocusTrackedWindow)
                        .help("Focus VM window")

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

                        Menu {
                            Button("Delete VM", role: .destructive) {
                                isShowingDeleteConfirmation = true
                            }
                            .disabled(viewModel.isWorking)
                        } label: {
                            Image(systemName: "ellipsis")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(slate900)
                                .frame(width: 30, height: 30)
                                .background(Color(NSColor.controlBackgroundColor), in: Circle())
                                .overlay(
                                    Circle()
                                        .stroke(slate200.opacity(0.9), lineWidth: 1)
                                )
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .help("More actions")
                    }
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
                HStack(spacing: 0) {
                    Button("Run") {
                        Task { await viewModel.runVM(mode: .graphics) }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(vm.running || viewModel.isWorking)

                    Menu {
                        Button("Run Headless") {
                            Task { await viewModel.runVM(mode: .headless) }
                        }
                    } label: {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 32, height: 32)
                            .background(Color.accentColor)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .padding(.leading, 6)
                    .disabled(vm.running || viewModel.isWorking)
                }

                Button("Stop") {
                    Task { await viewModel.runAction(.stop) }
                }
                .disabled(!vm.running || viewModel.isWorking)
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

            sshCard
            guestAgentCard
        }
    }

    private var sshCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("SSH")
                .font(.headline)

            Text(viewModel.sshStatus.title)
                .frame(maxWidth: .infinity, alignment: .leading)
                .foregroundStyle(Color.white.opacity(0.92))

            if viewModel.sshStatus.ipAddress != nil {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) {
                        Text("User")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)

                        TextField("admin", text: $viewModel.sshUsername)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 180)
                    }

                    Text(viewModel.selectedVMSSHCommand ?? "")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(Color.white.opacity(0.94))
                        .padding(12)
                        .background(Color.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))

                    HStack(spacing: 10) {
                        Button("Copy SSH Command") {
                            viewModel.copySSHCommand()
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!viewModel.selectedVMCanUseSSH)

                        Button("Open in Terminal") {
                            viewModel.openSSHInTerminal()
                        }
                        .buttonStyle(.bordered)
                        .disabled(!viewModel.selectedVMCanUseSSH)
                    }
                }
            }
        }
        .padding(16)
        .background(Color(NSColor.controlBackgroundColor), in: RoundedRectangle(cornerRadius: 18))
    }

    private var guestAgentCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Guest Agent")
                .font(.headline)

            if let capabilities = viewModel.tartCapabilities {
                Text("Tart \(capabilities.version)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text("`tart exec`: \(capabilities.supportsExec ? "available" : "unavailable")")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                Text("Checking Tart CLI capabilities...")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Text(viewModel.guestAgentStatus.title)
                .frame(maxWidth: .infinity, alignment: .leading)
                .foregroundStyle(Color.white.opacity(0.92))
        }
        .padding(16)
        .background(Color(NSColor.controlBackgroundColor), in: RoundedRectangle(cornerRadius: 18))
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
                HStack(spacing: 10) {
                    Image(systemName: osFamily.iconName)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(osIconForeground)
                        .frame(width: 28, height: 28)
                        .background(osIconBackground, in: RoundedRectangle(cornerRadius: 9))
                    Text(vm.isLocal ? vm.name : vm.displayTitle)
                        .fontWeight(.semibold)
                        .lineLimit(1)
                        .foregroundStyle(slate900)
                }
                Spacer()
                Text(vm.stateLabel.capitalized)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(stateForegroundColor)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(stateBackgroundColor, in: Capsule())
            }

            HStack(spacing: 12) {
                Label(vm.shortSource, systemImage: vm.isLocal ? "internaldrive.fill" : "shippingbox")
                if !vm.isLocal {
                    Label(osFamily.title, systemImage: osFamily.iconName)
                }
                Label(vm.displaySize, systemImage: "externaldrive")
            }
            .font(.caption)
            .foregroundStyle(slate700)

            if !vm.isLocal {
                Text(vm.displayReference)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(slate700)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(
            isSelected
                ? Color.accentColor.opacity(0.14)
                : Color(NSColor.controlBackgroundColor),
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

    private var stateForegroundColor: Color {
        if vm.running { return Color(red: 0.05, green: 0.45, blue: 0.20) }
        if vm.state.caseInsensitiveCompare("suspended") == .orderedSame {
            return Color(red: 0.70, green: 0.38, blue: 0.02)
        }
        return Color(red: 0.26, green: 0.31, blue: 0.39)
    }

    private var stateBackgroundColor: Color {
        if vm.running { return Color.green.opacity(0.16) }
        if vm.state.caseInsensitiveCompare("suspended") == .orderedSame {
            return Color.orange.opacity(0.18)
        }
        return Color.black.opacity(0.07)
    }

    private var osFamily: TartGuestOSFamily {
        TartGuestOSFamily.infer(from: vm.name)
    }

    private var osIconForeground: Color {
        switch osFamily {
        case .macOS:
            return Color(red: 0.10, green: 0.33, blue: 0.80)
        case .linux:
            return Color(red: 0.06, green: 0.47, blue: 0.28)
        case .unknown:
            return slate700
        }
    }

    private var osIconBackground: Color {
        switch osFamily {
        case .macOS:
            return Color(red: 0.84, green: 0.90, blue: 0.99)
        case .linux:
            return Color(red: 0.84, green: 0.95, blue: 0.88)
        case .unknown:
            return slate200
        }
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
    @State private var sourceListMode: SourceListMode = .official
    @State private var sourceSearchText = ""

    private enum SourceListMode: String, CaseIterable, Identifiable {
        case official
        case available

        var id: String { rawValue }

        var title: String {
            switch self {
            case .official: "Official OCI Images"
            case .available: "Available in TartDesk"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 18) {
                Text("Create Instance")
                    .font(.system(size: 26, weight: .bold, design: .rounded))

                Picker("Mode", selection: $viewModel.createForm.creationMode) {
                    ForEach(CreateVMFormState.CreationMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                VStack(alignment: .leading, spacing: 6) {
                    Text("Local VM Name")
                        .font(.headline)
                    Text("Saved locally in Tart after creation.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    TextField("my-macos-vm", text: $viewModel.createForm.name)
                        .textFieldStyle(.roundedBorder)
                }

                if viewModel.createForm.creationMode == .clone {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Source VM or OCI image")
                            .font(.headline)

                        TextField("ghcr.io/cirruslabs/macos-tahoe-base:latest", text: $viewModel.createForm.sourceName)
                            .textFieldStyle(.roundedBorder)

                        Picker("Source Library", selection: $sourceListMode) {
                            ForEach(availableSourceListModes) { mode in
                                Text(mode.title).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)

                        TextField("Search images or VMs", text: $sourceSearchText)
                            .textFieldStyle(.roundedBorder)

                        Text(sourceListMode == .official
                             ? "Pulled from Tart's current Quick Start image lineup."
                             : "Images and VMs already available in TartDesk.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Stepper(value: $viewModel.createForm.diskSize, in: 10...500, step: 10) {
                        Text("Disk Size: \(viewModel.createForm.diskSize) GB")
                    }

                    Toggle("Linux template", isOn: $viewModel.createForm.linuxTemplate)
                }
            }
            .padding(24)

            Divider()

            Group {
                if viewModel.createForm.creationMode == .clone {
                    ScrollView {
                        VStack(spacing: 6) {
                            if sourceListMode == .official {
                                ForEach(filteredOfficialPresets) { preset in
                                    Button {
                                        viewModel.selectCreateSource(preset.sourceName)
                                    } label: {
                                        CompactCloneSourceRow(
                                            title: preset.title,
                                            osFamily: preset.osFamily,
                                            statusLabel: viewModel.hasDownloadedCloneSource(preset.sourceName) ? "Downloaded" : "Not Downloaded",
                                            isSelected: viewModel.createForm.sourceName == preset.sourceName
                                        )
                                    }
                                    .buttonStyle(.plain)
                                }
                                if filteredOfficialPresets.isEmpty {
                                    emptySearchState
                                }
                            } else if viewModel.cloneSourceCandidates.isEmpty {
                                Text("No local VMs or downloaded OCI images yet.")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(16)
                                    .background(Color(NSColor.controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
                            } else if filteredCloneCandidates.isEmpty {
                                emptySearchState
                            } else {
                                ForEach(filteredCloneCandidates, id: \.name) { vm in
                                    Button {
                                        viewModel.selectCreateSource(vm.name)
                                    } label: {
                                        CompactCloneSourceRow(
                                            title: vm.displayTitle,
                                            osFamily: TartGuestOSFamily.infer(from: vm.name),
                                            statusLabel: vm.isLocal ? "Local" : "Downloaded",
                                            isSelected: viewModel.createForm.sourceName == vm.name
                                        )
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                        .padding(.horizontal, 24)
                        .padding(.vertical, 10)
                    }
                } else {
                    Color.clear
                }
            }

            Divider()
            HStack {
                Spacer()
                Button("Cancel") {
                    dismiss()
                }
                Button("Create") {
                    viewModel.startCreateVM()
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(
                    viewModel.createForm.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                    (viewModel.createForm.creationMode == .clone && !viewModel.canCreateFromClone)
                )
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
            .background(.bar)
        }
        .frame(width: 560, height: 560)
        .onAppear {
            if sourceListMode == .available && viewModel.cloneSourceCandidates.isEmpty {
                sourceListMode = .official
            }
        }
        .onChange(of: viewModel.createForm.creationMode) { _, newValue in
            guard newValue == .clone else { return }
            if sourceListMode == .available && viewModel.cloneSourceCandidates.isEmpty {
                sourceListMode = .official
            }
        }
    }

    private var availableSourceListModes: [SourceListMode] {
        viewModel.cloneSourceCandidates.isEmpty ? [.official] : SourceListMode.allCases
    }

    private var filteredOfficialPresets: [TartCloneSourcePreset] {
        let query = sourceSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return viewModel.officialCloneSourcePresets }
        return viewModel.officialCloneSourcePresets.filter { preset in
            preset.title.localizedCaseInsensitiveContains(query) ||
            preset.sourceName.localizedCaseInsensitiveContains(query) ||
            preset.osFamily.title.localizedCaseInsensitiveContains(query)
        }
    }

    private var filteredCloneCandidates: [TartVM] {
        let query = sourceSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return viewModel.cloneSourceCandidates }
        return viewModel.cloneSourceCandidates.filter { vm in
            vm.displayTitle.localizedCaseInsensitiveContains(query) ||
            vm.displayReference.localizedCaseInsensitiveContains(query) ||
            vm.shortSource.localizedCaseInsensitiveContains(query)
        }
    }

    private var emptySearchState: some View {
        Text("No matching sources.")
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(Color(NSColor.controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
    }
}

private struct CreateJobsPanel: View {
    @Bindable var viewModel: TartDeskViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Downloads", systemImage: "arrow.down.circle")
                    .font(.headline)
                Spacer()
                if !viewModel.activeCreateJobs.isEmpty {
                    Text("\(viewModel.activeCreateJobs.count) active")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }

            VStack(spacing: 10) {
                ForEach(viewModel.recentCreateJobs.prefix(6)) { job in
                    CreateJobRow(
                        job: job,
                        onCancel: { viewModel.cancelCreateOperation(id: job.id) },
                        onDismiss: { viewModel.dismissCreateJob(id: job.id) }
                    )
                }
            }
        }
        .padding(14)
        .frame(width: 360, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .stroke(Color.white.opacity(0.4), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.10), radius: 20, y: 8)
    }
}

private struct CreateJobRow: View {
    let job: TartCreateJob
    let onCancel: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: osFamily.iconName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(osIconForeground)
                        .frame(width: 28, height: 28)
                        .background(osIconBackground, in: RoundedRectangle(cornerRadius: 9))

                    VStack(alignment: .leading, spacing: 2) {
                        Text(job.displayTitle)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Color.primary)
                            .lineLimit(1)
                        Text(job.state.title)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(stateColor)
                    }
                }
                Spacer()
                if job.state.isTerminal {
                    Button {
                        onDismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 11, weight: .bold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                } else {
                    Button("Cancel") {
                        onCancel()
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                }
            }

            Text(job.progressMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)

            if let progressFraction = job.progressFraction, !job.state.isTerminal {
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: progressFraction, total: 1)
                        .progressViewStyle(.linear)
                    Text("\(Int((progressFraction * 100).rounded()))%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(NSColor.controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
    }

    private var stateColor: Color {
        switch job.state {
        case .pulling:
            return Color(red: 0.10, green: 0.33, blue: 0.80)
        case .creating:
            return Color(red: 0.48, green: 0.27, blue: 0.78)
        case .completed:
            return Color(red: 0.06, green: 0.47, blue: 0.28)
        case .failed:
            return Color.red
        case .canceled:
            return Color.orange
        }
    }

    private var osFamily: TartGuestOSFamily {
        let candidate = job.sourceName.isEmpty ? job.name : job.sourceName
        return TartGuestOSFamily.infer(from: candidate)
    }

    private var osIconForeground: Color {
        switch osFamily {
        case .macOS:
            return Color(red: 0.10, green: 0.33, blue: 0.80)
        case .linux:
            return Color(red: 0.06, green: 0.47, blue: 0.28)
        case .unknown:
            return Color.primary.opacity(0.8)
        }
    }

    private var osIconBackground: Color {
        switch osFamily {
        case .macOS:
            return Color(red: 0.84, green: 0.90, blue: 0.99)
        case .linux:
            return Color(red: 0.84, green: 0.95, blue: 0.88)
        case .unknown:
            return Color(NSColor.quaternaryLabelColor).opacity(0.18)
        }
    }
}

private struct CompactCloneSourceRow: View {
    let title: String
    let osFamily: TartGuestOSFamily
    let statusLabel: String?
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: osFamily.iconName)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(iconForeground)
                .frame(width: 24, height: 24)
                .background(iconBackground, in: RoundedRectangle(cornerRadius: 7))

            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(titleColor)
                .lineLimit(1)

            Spacer(minLength: 6)

            Text(osFamily.title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(badgeForeground)
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(badgeBackground, in: Capsule())
                .overlay(
                    Capsule()
                        .stroke(badgeBorder, lineWidth: 1)
                )

            if let statusLabel {
                Text(statusLabel)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(statusForeground)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(statusBackground, in: Capsule())
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            isSelected ? Color.accentColor.opacity(0.12) : Color(NSColor.controlBackgroundColor),
            in: RoundedRectangle(cornerRadius: 14)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(isSelected ? Color.accentColor.opacity(0.45) : slate200, lineWidth: 1)
        )
    }

    private var iconForeground: Color {
        switch osFamily {
        case .macOS:
            return Color(red: 0.10, green: 0.33, blue: 0.80)
        case .linux:
            return Color(red: 0.06, green: 0.47, blue: 0.28)
        case .unknown:
            return slate700
        }
    }

    private var iconBackground: Color {
        switch osFamily {
        case .macOS:
            return Color(red: 0.84, green: 0.90, blue: 0.99)
        case .linux:
            return Color(red: 0.84, green: 0.95, blue: 0.88)
        case .unknown:
            return slate200
        }
    }

    private var badgeForeground: Color {
        switch osFamily {
        case .macOS:
            return Color(red: 0.07, green: 0.24, blue: 0.58)
        case .linux:
            return Color(red: 0.06, green: 0.38, blue: 0.22)
        case .unknown:
            return slate900
        }
    }

    private var badgeBackground: Color {
        switch osFamily {
        case .macOS:
            return Color(red: 0.90, green: 0.94, blue: 1.00)
        case .linux:
            return Color(red: 0.89, green: 0.97, blue: 0.91)
        case .unknown:
            return Color.white
        }
    }

    private var badgeBorder: Color {
        switch osFamily {
        case .macOS:
            return Color(red: 0.72, green: 0.82, blue: 0.98)
        case .linux:
            return Color(red: 0.70, green: 0.88, blue: 0.75)
        case .unknown:
            return slate200
        }
    }

    private var titleColor: Color {
        Color.primary
    }

    private var statusForeground: Color {
        switch statusLabel {
        case "Downloaded", "Local":
            return Color(red: 0.06, green: 0.38, blue: 0.22)
        case "Not Downloaded":
            return Color(red: 0.52, green: 0.36, blue: 0.05)
        default:
            return Color.secondary
        }
    }

    private var statusBackground: Color {
        switch statusLabel {
        case "Downloaded", "Local":
            return Color(red: 0.89, green: 0.97, blue: 0.91)
        case "Not Downloaded":
            return Color(red: 0.99, green: 0.94, blue: 0.82)
        default:
            return Color(NSColor.controlBackgroundColor)
        }
    }
}

private struct EditVMSheet: View {
    @Bindable var viewModel: TartDeskViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var isImportingDirectory = false
    @State private var selectedDirectoryShareID: TartDirectoryShare.ID?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Edit VM Settings")
                .font(.system(size: 26, weight: .bold, design: .rounded))

            VStack(alignment: .leading, spacing: 6) {
                Text("VM Name")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("VM Name", text: $viewModel.editForm.name)
                    .textFieldStyle(.roundedBorder)
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

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Shared Folders")
                        .font(.headline)
                    Spacer()
                    Button("Add Folder") {
                        viewModel.addEditDirectoryShare()
                    }
                }

                Text("Saved per VM in TartDesk and applied automatically on Run via `tart run --dir`.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                if viewModel.editDirectoryShares.isEmpty {
                    Text("No shared folders configured.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                        .background(Color(NSColor.controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
                } else {
                    ScrollView {
                        VStack(spacing: 12) {
                            ForEach($viewModel.editDirectoryShares) { $share in
                                VStack(alignment: .leading, spacing: 10) {
                                    HStack {
                                        Text(share.trimmedPath.isEmpty ? "New Share" : share.displayName)
                                            .font(.headline)
                                        Spacer()
                                        Button("Remove") {
                                            viewModel.removeEditDirectoryShare(id: share.id)
                                        }
                                    }

                                    HStack(spacing: 10) {
                                        TextField("Folder path", text: $share.path)
                                            .textFieldStyle(.roundedBorder)

                                        Button("Choose") {
                                            selectedDirectoryShareID = share.id
                                            isImportingDirectory = true
                                        }
                                    }

                                    HStack(spacing: 12) {
                                        VStack(alignment: .leading, spacing: 6) {
                                            Text("Share Name")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                            TextField("Optional", text: $share.name)
                                                .textFieldStyle(.roundedBorder)
                                        }

                                        VStack(alignment: .leading, spacing: 6) {
                                            Text("Mount Tag")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                            TextField("Optional", text: $share.mountTag)
                                                .textFieldStyle(.roundedBorder)
                                        }
                                    }

                                    Toggle("Read-only", isOn: $share.isReadOnly)
                                }
                                .padding(14)
                                .background(Color(NSColor.controlBackgroundColor), in: RoundedRectangle(cornerRadius: 16))
                            }
                        }
                    }
                    .frame(minHeight: 160, maxHeight: 260)
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
                .disabled(
                    viewModel.isWorking ||
                    viewModel.editForm.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                )
            }
        }
        .padding(24)
        .frame(width: 560)
        .fileImporter(
            isPresented: $isImportingDirectory,
            allowedContentTypes: [UTType.folder],
            allowsMultipleSelection: false
        ) { result in
            guard let selectedDirectoryShareID else { return }
            switch result {
            case let .success(urls):
                guard let url = urls.first else { return }
                viewModel.setEditDirectorySharePath(id: selectedDirectoryShareID, path: url.path(percentEncoded: false))
            case let .failure(error):
                viewModel.errorMessage = error.localizedDescription
            }
        }
    }
}

private struct ErrorSheet: View {
    @Bindable var viewModel: TartDeskViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline) {
                Label("Tart Error", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(.primary)

                Spacer()

                Button("Close") {
                    viewModel.dismissError()
                }
                .keyboardShortcut(.cancelAction)
            }

            ScrollView {
                Text(viewModel.errorMessage ?? "")
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
            }
            .frame(minHeight: 180, maxHeight: 320)
            .background(Color(NSColor.textBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(slate200.opacity(0.9), lineWidth: 1)
            )

            HStack {
                Spacer()

                Button("OK") {
                    viewModel.dismissError()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 560)
        .background(Color(NSColor.windowBackgroundColor))
    }
}
