import Foundation

struct TartVM: Decodable, Identifiable, Hashable {
    let disk: Int
    let size: Int
    let source: String
    let running: Bool
    let name: String
    let state: String
    let sizeOnDisk: Int

    var id: String { name }
    var isLocal: Bool { source.caseInsensitiveCompare("local") == .orderedSame }
    var shortSource: String { isLocal ? "Local" : source }
    var stateLabel: String { running ? "running" : state }
    var displaySize: String { "\(sizeOnDisk) GB" }
    var displayDisk: String { "\(disk) GB" }
    var isDigestReference: Bool { name.contains("@sha256:") }
    var repositoryNameWithoutReference: String {
        let withoutDigest = name.split(separator: "@", maxSplits: 1).first.map(String.init) ?? name
        let lastSlashIndex = withoutDigest.lastIndex(of: "/")
        let lastColonIndex = withoutDigest.lastIndex(of: ":")
        if let colon = lastColonIndex, lastSlashIndex == nil || colon > lastSlashIndex! {
            return String(withoutDigest[..<colon])
        }
        return withoutDigest
    }

    enum CodingKeys: String, CodingKey {
        case disk = "Disk"
        case size = "Size"
        case source = "Source"
        case running = "Running"
        case name = "Name"
        case state = "State"
        case sizeOnDisk = "SizeOnDisk"
    }
}

struct TartVMDetails: Decodable, Hashable {
    let os: String
    let state: String
    let memory: Int
    let running: Bool
    let size: String
    let disk: Int
    let display: String
    let cpu: Int

    var memoryLabel: String { "\(memory) MB" }
    var diskLabel: String { "\(disk) GB" }
    var sizeLabel: String { "\(size) GB" }
    var cpuLabel: String { "\(cpu) cores" }

    enum CodingKeys: String, CodingKey {
        case os = "OS"
        case state = "State"
        case memory = "Memory"
        case running = "Running"
        case size = "Size"
        case disk = "Disk"
        case display = "Display"
        case cpu = "CPU"
    }
}

struct TartCommandResult {
    let stdout: String
    let stderr: String
}

enum TartSourceFilter: String, CaseIterable, Identifiable {
    case all
    case local
    case remote

    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: "All"
        case .local: "Local"
        case .remote: "OCI"
        }
    }

    func matches(_ vm: TartVM) -> Bool {
        switch self {
        case .all: true
        case .local: vm.isLocal
        case .remote: !vm.isLocal
        }
    }
}

enum TartAction: String, CaseIterable, Identifiable {
    case run
    case stop
    case suspend
    case delete

    var id: String { rawValue }

    var title: String {
        switch self {
        case .run: "Run"
        case .stop: "Stop"
        case .suspend: "Suspend"
        case .delete: "Delete"
        }
    }

    func commandArguments(for name: String) -> [String] {
        switch self {
        case .run: ["run", name]
        case .stop: ["stop", name]
        case .suspend: ["suspend", name]
        case .delete: ["delete", name]
        }
    }
}

enum TartRunMode: String, Identifiable {
    case graphics
    case headless

    var id: String { rawValue }

    var title: String {
        switch self {
        case .graphics: "Run"
        case .headless: "Run Headless"
        }
    }

    var commandArgumentsPrefix: [String] {
        switch self {
        case .graphics: ["run"]
        case .headless: ["run", "--no-graphics"]
        }
    }
}

struct CreateVMFormState {
    var name = ""
    var diskSize = 50
    var creationMode: CreationMode = .clone
    var sourceName = ""
    var linuxTemplate = false

    enum CreationMode: String, CaseIterable, Identifiable {
        case clone
        case new

        var id: String { rawValue }
        var title: String {
            switch self {
            case .clone: "Clone Existing"
            case .new: "Create Empty"
            }
        }
    }
}
