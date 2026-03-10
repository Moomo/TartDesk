import Foundation

struct TartCLIService {
    private let decoder = JSONDecoder()

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

    @discardableResult
    func runVM(name: String, mode: TartRunMode) async throws -> TartCommandResult {
        try await run(arguments: mode.commandArgumentsPrefix + [name])
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
    func renameVM(from source: String, to destination: String) async throws -> TartCommandResult {
        try await run(arguments: ["rename", source, destination])
    }

    @discardableResult
    func run(arguments: [String]) async throws -> TartCommandResult {
        let executable = "/opt/homebrew/bin/tart"
        let process = Process()
        process.executableURL = FileManager.default.fileExists(atPath: executable)
            ? URL(fileURLWithPath: executable)
            : URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = FileManager.default.fileExists(atPath: executable)
            ? arguments
            : ["tart"] + arguments

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
}

enum TartCLIError: LocalizedError {
    case commandFailed(arguments: [String], exitCode: Int, stderr: String)

    var errorDescription: String? {
        switch self {
        case let .commandFailed(arguments, exitCode, stderr):
            let message = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return "`tart \(arguments.joined(separator: " "))` failed with exit code \(exitCode).\n\(message)"
        }
    }
}
