import AppKit
import ApplicationServices
import Foundation

struct TartCLIService {
    private let decoder = JSONDecoder()
    private let knownExecutablePaths = [
        "/opt/homebrew/bin/tart",
        "/usr/local/bin/tart"
    ]

    func isTartInstalled() -> Bool {
        tartExecutableURL() != nil
    }

    func detectCapabilities() async throws -> TartCapabilities {
        guard isTartInstalled() else {
            throw TartCLIError.tartNotInstalled
        }
        async let versionResult = run(arguments: ["--version"])
        async let helpResult = run(arguments: ["--help"])
        let (version, help) = try await (versionResult, helpResult)
        return TartCapabilities(
            version: version.stdout.trimmingCharacters(in: .whitespacesAndNewlines),
            supportsExec: help.stdout.contains("exec")
        )
    }

    func fetchVMs() async throws -> [TartVM] {
        let result = try await run(arguments: ["list", "--format", "json"])
        return try decoder.decode([TartVM].self, from: Data(result.stdout.utf8))
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func fetchDetails(for name: String) async throws -> TartVMDetails {
        let result = try await run(arguments: ["get", name, "--format", "json"])
        return try decoder.decode(TartVMDetails.self, from: Data(result.stdout.utf8))
    }

    @discardableResult
    func execute(_ action: TartAction, name: String) async throws -> TartCommandResult {
        try await run(arguments: action.commandArguments(for: name))
    }

    func runVM(name: String, mode: TartRunMode, directoryShares: [TartDirectoryShare] = []) async throws -> pid_t {
        var arguments = mode.commandArgumentsPrefix + [name]
        let sharesRequiringExplicitNames = Set(
            Dictionary(grouping: directoryShares.filter { !$0.trimmedPath.isEmpty }, by: \.effectiveMountTag)
                .filter { $0.value.count > 1 }
                .flatMap(\.value)
                .map(\.id)
        )

        for share in directoryShares where !share.trimmedPath.isEmpty {
            arguments.append("--dir")
            arguments.append(share.commandArgument(needsExplicitName: sharesRequiringExplicitNames.contains(share.id)))
        }

        return try launch(arguments: arguments)
    }

    func focusVMWindow(name: String, preferredPID: pid_t? = nil) throws {
        guard ensureAccessibilityPermission() else {
            throw TartCLIError.accessibilityPermissionRequired
        }

        let pid: pid_t
        if let preferredPID {
            pid = preferredPID
        } else {
            pid = try findGraphicsRunProcessID(for: name)
        }
        guard let application = NSRunningApplication(processIdentifier: pid) else {
            throw TartCLIError.windowFocusFailed(name: name)
        }

        application.unhide()
        let activated = application.activate(options: [.activateAllWindows])
        guard activated else {
            throw TartCLIError.windowFocusFailed(name: name)
        }

        let appElement = AXUIElementCreateApplication(pid)
        let truthy: CFTypeRef = kCFBooleanTrue
        AXUIElementSetAttributeValue(appElement, kAXFrontmostAttribute as CFString, truthy)

        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &value)
        guard status == .success else {
            return
        }
        guard let windows = value as? [AXUIElement] else {
            return
        }

        if preferredPID != nil, let firstWindow = windows.first {
            try raiseWindow(firstWindow, name: name)
            return
        }

        for window in windows {
            guard let title = copyStringAttribute(kAXTitleAttribute, from: window) else { continue }
            guard title.localizedCaseInsensitiveContains(name) else { continue }

            try raiseWindow(window, name: name)
            return
        }

        if let firstWindow = windows.first {
            try raiseWindow(firstWindow, name: name)
            return
        }

        return
    }

    @discardableResult
    func createVM(_ form: CreateVMFormState) async throws -> TartCommandResult {
        switch form.creationMode {
        case .clone:
            return try await run(arguments: ["clone", form.sourceName, form.name])
        case .new:
            var args = ["create", form.name, "--disk-size", String(form.diskSize)]
            if form.linuxTemplate {
                args.append("--linux")
            }
            return try await run(arguments: args)
        }
    }

    @discardableResult
    func pullImage(_ sourceName: String) async throws -> TartCommandResult {
        try await runStreaming(arguments: ["pull", sourceName])
    }

    @discardableResult
    func pullImage(
        _ sourceName: String,
        onProgress: @escaping @Sendable (TartPullProgress) async -> Void
    ) async throws -> TartCommandResult {
        try await runStreaming(arguments: ["pull", sourceName], onProgress: onProgress)
    }

    @discardableResult
    func renameVM(from source: String, to destination: String) async throws -> TartCommandResult {
        try await run(arguments: ["rename", source, destination])
    }

    @discardableResult
    func updateVM(_ form: EditVMFormState) async throws -> TartCommandResult {
        try await run(arguments: [
            "set",
            form.name,
            "--cpu", String(form.cpu),
            "--memory", String(form.memory),
            "--display", form.display,
            "--disk-size", String(form.diskSize)
        ])
    }

    func probeGuestAgentAvailability(for name: String) async throws -> Bool {
        do {
            _ = try await run(arguments: ["exec", name, "/usr/bin/true"])
            return true
        } catch {
            if let cliError = error as? TartCLIError {
                throw cliError
            }
            throw error
        }
    }

    func fetchIPAddress(for name: String) async throws -> String {
        let result = try await run(arguments: ["ip", name])
        let ipAddress = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !ipAddress.isEmpty else {
            throw TartCLIError.ipAddressUnavailable(name: name)
        }
        return ipAddress
    }

    func openSSHInTerminal(command: String) throws {
        let escapedCommand = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")

        let scriptSource = """
        tell application "Terminal"
            activate
            do script "\(escapedCommand)"
        end tell
        """

        var error: NSDictionary?
        NSAppleScript(source: scriptSource)?.executeAndReturnError(&error)
        if error != nil {
            throw TartCLIError.openTerminalFailed
        }
    }

    @discardableResult
    func run(arguments: [String]) async throws -> TartCommandResult {
        try await runStreaming(arguments: arguments)
    }

    @discardableResult
    func runStreaming(
        arguments: [String],
        onProgress: (@Sendable (TartPullProgress) async -> Void)? = nil
    ) async throws -> TartCommandResult {
        guard let onProgress else {
            let process = configuredProcess(arguments: arguments)
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            try process.run()
            process.waitUntilExit()

            let stdout = String(decoding: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            let stderr = String(decoding: stderrPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)

            guard process.terminationStatus == 0 else {
                throw TartCLIError.commandFailed(
                    arguments: arguments,
                    exitCode: Int(process.terminationStatus),
                    stderr: stderr.isEmpty ? stdout : stderr
                )
            }

            return TartCommandResult(stdout: stdout, stderr: stderr)
        }

        let process = configuredProcess(arguments: arguments)
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let stdoutCollector = StreamCollector()
        let stderrCollector = StreamCollector()
        let progressParser = TartPullProgressParser()
        let cancellationController = ProcessCancellationController()

        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task {
                await stdoutCollector.append(data)
                if let progress = await progressParser.ingest(data: data) {
                    await onProgress(progress)
                }
            }
        }

        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task {
                await stderrCollector.append(data)
                if let progress = await progressParser.ingest(data: data) {
                    await onProgress(progress)
                }
            }
        }

        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try process.run()
            await cancellationController.set(process: process)
            process.waitUntilExit()

            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil

            await stdoutCollector.append(stdoutPipe.fileHandleForReading.readDataToEndOfFile())
            await stderrCollector.append(stderrPipe.fileHandleForReading.readDataToEndOfFile())

            let stdout = await stdoutCollector.stringValue
            let stderr = await stderrCollector.stringValue

            if await cancellationController.wasCancelled || Task.isCancelled {
                throw CancellationError()
            }

            guard process.terminationStatus == 0 else {
                throw TartCLIError.commandFailed(
                    arguments: arguments,
                    exitCode: Int(process.terminationStatus),
                    stderr: stderr.isEmpty ? stdout : stderr
                )
            }

            return TartCommandResult(stdout: stdout, stderr: stderr)
        } onCancel: {
            Task {
                await cancellationController.cancel()
            }
        }
    }

    func launch(arguments: [String]) throws -> pid_t {
        let process = configuredProcess(arguments: arguments)
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        return process.processIdentifier
    }

    private func configuredProcess(arguments: [String]) -> Process {
        let process = Process()
        guard let executableURL = tartExecutableURL() else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/false")
            process.arguments = []
            return process
        }
        process.executableURL = executableURL
        process.arguments = arguments
        return process
    }

    private func tartExecutableURL() -> URL? {
        for path in knownExecutablePaths where FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }

        let pathEntries = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":")
            .map(String.init)

        for entry in pathEntries {
            let candidate = URL(fileURLWithPath: entry).appendingPathComponent("tart").path
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return URL(fileURLWithPath: candidate)
            }
        }

        return nil
    }

    private func findGraphicsRunProcessID(for name: String) throws -> pid_t {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "pid=,command="]

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()
        process.waitUntilExit()

        let stdout = String(decoding: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let stderr = String(decoding: stderrPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)

        guard process.terminationStatus == 0 else {
            throw TartCLIError.commandFailed(arguments: ["ps", "-axo", "pid=,command="], exitCode: Int(process.terminationStatus), stderr: stderr)
        }

        for line in stdout.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }

            let parts = trimmed.split(maxSplits: 1, whereSeparator: \.isWhitespace)
            guard parts.count == 2, let pid = Int32(parts[0]) else { continue }

            let command = String(parts[1])
            let tokens = command.split(whereSeparator: \.isWhitespace).map(String.init)
            guard tokens.count >= 3 else { continue }
            guard URL(fileURLWithPath: tokens[0]).lastPathComponent == "tart" else { continue }
            guard tokens[1] == "run" else { continue }
            guard !tokens.contains("--no-graphics") else { continue }
            guard tokens.last == name else { continue }

            return pid
        }

        throw TartCLIError.vmWindowNotFound(name: name)
    }

    private func copyStringAttribute(_ attribute: String, from element: AXUIElement) -> String? {
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard status == .success else { return nil }
        return value as? String
    }

    private func copyBoolAttribute(_ attribute: String, from element: AXUIElement) -> Bool? {
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard status == .success else { return nil }
        return (value as? Bool) ?? ((value as? NSNumber)?.boolValue)
    }

    private func raiseWindow(_ window: AXUIElement, name: String) throws {
        let truthy: CFTypeRef = kCFBooleanTrue
        AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, truthy)
        AXUIElementSetAttributeValue(window, kAXFocusedAttribute as CFString, truthy)
        let raiseStatus = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        if raiseStatus == .success {
            return
        }

        let isMain = copyBoolAttribute(kAXMainAttribute, from: window) ?? false
        let isFocused = copyBoolAttribute(kAXFocusedAttribute, from: window) ?? false
        guard isMain || isFocused else {
            throw TartCLIError.windowFocusFailed(name: name)
        }
    }

    private func bringProcessToFront(_ pid: pid_t) throws {
        let scriptSource = """
        tell application "System Events"
            set frontmost of first application process whose unix id is \(pid) to true
        end tell
        """

        guard let script = NSAppleScript(source: scriptSource) else { return }

        var error: NSDictionary?
        script.executeAndReturnError(&error)
        if error != nil {
            throw TartCLIError.windowFocusFailed(name: "process \(pid)")
        }
    }

    private func ensureAccessibilityPermission() -> Bool {
        if AXIsProcessTrusted() {
            return true
        }

        let promptKey = "AXTrustedCheckOptionPrompt"
        let options = [promptKey: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }
}

private actor StreamCollector {
    private var buffer = Data()

    func append(_ data: Data) {
        guard !data.isEmpty else { return }
        buffer.append(data)
    }

    var stringValue: String {
        String(decoding: buffer, as: UTF8.self)
    }
}

private actor TartPullProgressParser {
    private var recentText = ""
    private let percentRegex = try? NSRegularExpression(pattern: #"(\d{1,3}(?:\.\d+)?)%"#)

    func ingest(data: Data) -> TartPullProgress? {
        let chunk = String(decoding: data, as: UTF8.self)
        guard !chunk.isEmpty else { return nil }

        recentText.append(chunk)
        if recentText.count > 4096 {
            recentText = String(recentText.suffix(4096))
        }

        guard let percentRegex else {
            return TartPullProgress(fractionCompleted: nil, message: "Pulling OCI image...")
        }

        let range = NSRange(recentText.startIndex..<recentText.endIndex, in: recentText)
        let matches = percentRegex.matches(in: recentText, range: range)
        guard let match = matches.last,
              let percentRange = Range(match.range(at: 1), in: recentText),
              let percent = Double(recentText[percentRange]) else {
            return TartPullProgress(fractionCompleted: nil, message: "Pulling OCI image...")
        }

        let clampedPercent = max(0, min(percent, 100))
        return TartPullProgress(
            fractionCompleted: clampedPercent / 100,
            message: "Pulling OCI image... \(Int(clampedPercent.rounded()))%"
        )
    }
}

private actor ProcessCancellationController {
    private var process: Process?
    private(set) var wasCancelled = false

    func set(process: Process) {
        self.process = process
    }

    func cancel() {
        wasCancelled = true
        guard let process, process.isRunning else { return }
        process.terminate()
    }
}

enum TartCLIError: LocalizedError {
    case tartNotInstalled
    case commandFailed(arguments: [String], exitCode: Int, stderr: String)
    case vmWindowNotFound(name: String)
    case windowFocusFailed(name: String)
    case windowFocusTimedOut(name: String)
    case accessibilityPermissionRequired
    case ipAddressUnavailable(name: String)
    case openTerminalFailed

    var errorDescription: String? {
        switch self {
        case .tartNotInstalled:
            return "Tart is not installed. Install it first to use TartDesk."
        case let .commandFailed(arguments, exitCode, stderr):
            let message = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return "`tart \(arguments.joined(separator: " "))` failed with exit code \(exitCode).\n\(message)"
        case let .vmWindowNotFound(name):
            return "No visible Tart window was found for \(name). Start it with `Run` instead of `Run Headless` first."
        case let .windowFocusFailed(name):
            return "Failed to focus the Tart window for \(name)."
        case let .windowFocusTimedOut(name):
            return "Timed out while trying to focus the Tart window for \(name). Check Accessibility permission for TartDesk."
        case .accessibilityPermissionRequired:
            return "Accessibility permission is required to focus a specific Tart window. Allow TartDesk in System Settings > Privacy & Security > Accessibility."
        case let .ipAddressUnavailable(name):
            return "No IP address was reported for \(name). Start the VM and wait until networking is ready."
        case .openTerminalFailed:
            return "Failed to open Terminal for the SSH command."
        }
    }
}
