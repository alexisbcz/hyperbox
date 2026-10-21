import Foundation

/// A machine's settings, saved as config.json in its bundle.
///
/// The bundle holds everything else too:
///
///     Name.hyperbox/
///       config.json
///       disk.img           the main disk, sparse, so it takes only the space its contents use
///       efi.vars           Linux: the EFI variable store
///       aux.img            macOS: auxiliary storage
///       hardware-model     macOS: VZMacHardwareModel data
///       machine-id         VZMacMachineIdentifier or VZGenericMachineIdentifier data
///       thumbnail.png      the screen when the machine last stopped, for the library
///       console.log        the serial console
///       snapshots/<id>/    see Snapshot
///
/// New fields need defaults in `init(from:)`, so bundles from older versions still open.
nonisolated struct MachineConfig: Codable, Equatable, Sendable {
    var id = UUID()
    var name: String
    var os: GuestOS
    /// The catalog entry it came from ("ubuntu", "fedora", …), nil for a custom ISO or IPSW.
    var distribution: String?
    var cpuCount: Int
    var memorySize: UInt64
    var diskSize: UInt64
    var display = Display()
    var sharedFolders: [SharedFolder] = []
    var network = Network()
    var sound = true
    var microphone = false
    /// Linux: run Intel binaries with Rosetta.
    var rosetta = true
    /// Linux: virtual machines inside this one (M3 and later).
    var nestedVirtualization = false
    /// Lets AI agents see the screen and use the keyboard and mouse, through the MCP server.
    var agentControl = true
    var created = Date()
    /// Set until the installer has finished.
    var install: Install?
    /// The guest user, when Hyperbox created it (automatic installs), so agents can run commands.
    var guestUser: GuestUser?

    init(name: String, os: GuestOS, distribution: String? = nil, cpuCount: Int, memorySize: UInt64, diskSize: UInt64) {
        self.name = name
        self.os = os
        self.distribution = distribution
        self.cpuCount = cpuCount
        self.memorySize = memorySize
        self.diskSize = diskSize
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        os = try c.decode(GuestOS.self, forKey: .os)
        distribution = try c.decodeIfPresent(String.self, forKey: .distribution)
        cpuCount = try c.decode(Int.self, forKey: .cpuCount)
        memorySize = try c.decode(UInt64.self, forKey: .memorySize)
        diskSize = try c.decode(UInt64.self, forKey: .diskSize)
        display = try c.decodeIfPresent(Display.self, forKey: .display) ?? Display()
        sharedFolders = try c.decodeIfPresent([SharedFolder].self, forKey: .sharedFolders) ?? []
        network = try c.decodeIfPresent(Network.self, forKey: .network) ?? Network()
        sound = try c.decodeIfPresent(Bool.self, forKey: .sound) ?? true
        microphone = try c.decodeIfPresent(Bool.self, forKey: .microphone) ?? false
        rosetta = try c.decodeIfPresent(Bool.self, forKey: .rosetta) ?? true
        nestedVirtualization = try c.decodeIfPresent(Bool.self, forKey: .nestedVirtualization) ?? false
        agentControl = try c.decodeIfPresent(Bool.self, forKey: .agentControl) ?? true
        created = try c.decodeIfPresent(Date.self, forKey: .created) ?? Date()
        install = try c.decodeIfPresent(Install.self, forKey: .install)
        guestUser = try c.decodeIfPresent(GuestUser.self, forKey: .guestUser)
    }

    struct Display: Codable, Equatable, Sendable {
        var width = 1920
        var height = 1200
        var pixelsPerInch = 144
    }

    struct SharedFolder: Codable, Equatable, Identifiable, Sendable {
        var id = UUID()
        var path: String
        var readOnly = false
        /// The folder's name in the guest.
        var name: String { URL(fileURLWithPath: path).lastPathComponent }
    }

    struct Network: Codable, Equatable, Sendable {
        var enabled = true
        /// Kept, so the guest gets the same address from DHCP each boot.
        var macAddress = Self.randomMAC()
        var portForwards: [PortForward] = []

        static func randomMAC() -> String {
            // Locally administered, unicast.
            var bytes = (0..<6).map { _ in UInt8.random(in: 0...255) }
            bytes[0] = (bytes[0] & 0xFC) | 0x02
            return bytes.map { String(format: "%02x", $0) }.joined(separator: ":")
        }
    }

    struct PortForward: Codable, Equatable, Identifiable, Sendable {
        var id = UUID()
        var hostPort: UInt16
        var guestPort: UInt16
        var udp = false
    }

    /// What the next boot installs from.
    struct Install: Codable, Equatable, Sendable {
        enum Kind: String, Codable, Sendable {
            /// macOS from an IPSW restore image.
            case ipsw
            /// Boot an installer ISO attached as a USB drive.
            case iso
            /// A cloud image already written to disk.img, set up on first boot by cloud-init from seed.iso.
            case cloudInit
        }
        var kind: Kind
        /// The IPSW or ISO.
        var source: String?
    }

    struct GuestUser: Codable, Equatable, Sendable {
        var name: String
        var password: String
    }
}

nonisolated enum GuestOS: String, Codable, CaseIterable, Sendable {
    case macOS, linux

    var label: String {
        switch self {
        case .macOS: "macOS"
        case .linux: "Linux"
        }
    }
}

nonisolated extension MachineConfig {
    static let fileName = "config.json"

    static func load(from bundle: URL) throws -> MachineConfig {
        try JSONDecoder.machine.decode(MachineConfig.self, from: Data(contentsOf: bundle.appending(path: fileName)))
    }

    func save(to bundle: URL) throws {
        try JSONEncoder.machine.encode(self).write(to: bundle.appending(path: Self.fileName), options: .atomic)
    }
}

nonisolated extension JSONEncoder {
    static var machine: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

nonisolated extension JSONDecoder {
    static var machine: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

/// The files in a machine's bundle.
nonisolated struct MachineBundle: Sendable, Hashable {
    let url: URL

    var config: URL { url.appending(path: MachineConfig.fileName) }
    var disk: URL { url.appending(path: "disk.img") }
    var efiVariables: URL { url.appending(path: "efi.vars") }
    var auxiliaryStorage: URL { url.appending(path: "aux.img") }
    var hardwareModel: URL { url.appending(path: "hardware-model") }
    var machineIdentifier: URL { url.appending(path: "machine-id") }
    var seed: URL { url.appending(path: "seed.iso") }
    var thumbnail: URL { url.appending(path: "thumbnail.png") }
    var console: URL { url.appending(path: "console.log") }
    var snapshots: URL { url.appending(path: "snapshots") }
}
