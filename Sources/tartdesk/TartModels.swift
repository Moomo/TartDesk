import Foundation

struct TartVM: Decodable, Identifiable, Hashable {
    let disk: Int
    let size: Int
    let source: String
    let running: Bool
    let name: String
    let state: String
    let sizeOnDisk: Int
    let accessed: String?

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
        case accessed = "Accessed"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        disk = try container.decode(Int.self, forKey: .disk)
        size = try container.decode(Int.self, forKey: .size)
        source = try container.decode(String.self, forKey: .source)
        running = try container.decode(Bool.self, forKey: .running)
        name = try container.decode(String.self, forKey: .name)
        state = try container.decode(String.self, forKey: .state)
        sizeOnDisk = try container.decodeIfPresent(Int.self, forKey: .sizeOnDisk) ?? size
        accessed = try container.decodeIfPresent(String.self, forKey: .accessed)
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
    let diskFormat: String?

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
        case diskFormat = "DiskFormat"
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

struct EditVMFormState {
    var name = ""
    var cpu = 4
    var memory = 8192
    var diskSize = 50
    var displayWidth = 1024
    var displayHeight = 768

    var display: String {
        "\(displayWidth)x\(displayHeight)"
    }
}
