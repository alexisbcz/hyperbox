import CryptoKit
import Foundation

/// The container engine: a hidden Linux machine running Docker, behind `~/.hyperbox/docker.sock`.
///
/// launchd owns the socket (see `EngineAgent`), so the engine needn't be running for the socket to
/// exist: the first `docker` command that connects makes launchd start `Hyperbox --engine`, which
/// boots the machine and holds the connection until Docker answers. With no containers running for
/// a while, the engine shuts the machine down and exits, and launchd waits for the next connection.
/// That keeps it working with the library window closed, after a crash, and across logins.
nonisolated enum EnginePaths {
    /// ~/Library/Application Support/Hyperbox/Engine: the disk with every image and volume, and the settings.
    static var root: URL { Paths.support.appending(path: "Engine") }
    static var disk: URL { root.appending(path: "disk.img") }
    static var efiVariables: URL { root.appending(path: "efi.vars") }
    static var machineIdentifier: URL { root.appending(path: "machine-id") }
    static var seed: URL { root.appending(path: "seed.iso") }
    static var console: URL { root.appending(path: "console.log") }
    static var log: URL { root.appending(path: "engine.log") }
    static var settings: URL { root.appending(path: "settings.json") }
    /// Written once Docker first answered, so the next start skips setup.
    static var ready: URL { root.appending(path: "ready") }
    /// The guest copies its kernel here, so the engine boots it directly and skips the firmware and GRUB.
    static var boot: URL { root.appending(path: "boot") }

    /// What `docker` connects to.
    static var socket: URL { Paths.home.appending(path: "docker.sock") }
    static var status: URL { Paths.run.appending(path: "engine.json") }
}

/// What you can change in Settings › Containers; applied the next time the engine starts.
nonisolated struct EngineSettings: Codable, Equatable, Sendable {
    var cpuCount = 2
    /// The most the engine may use. Stopping when idle frees it all.
    var memorySize: UInt64 = 2 << 30
    /// Shut down after this many minutes with no containers running; 0 never does.
    var idleMinutes = 5
    var diskSize: UInt64 = 64 << 30
    /// The machine's network address, kept so DHCP hands out the same IP each boot.
    var macAddress = MachineConfig.Network.randomMAC()

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = EngineSettings()
        cpuCount = try c.decodeIfPresent(Int.self, forKey: .cpuCount) ?? d.cpuCount
        memorySize = try c.decodeIfPresent(UInt64.self, forKey: .memorySize) ?? d.memorySize
        idleMinutes = try c.decodeIfPresent(Int.self, forKey: .idleMinutes) ?? d.idleMinutes
        diskSize = try c.decodeIfPresent(UInt64.self, forKey: .diskSize) ?? d.diskSize
        macAddress = try c.decodeIfPresent(String.self, forKey: .macAddress) ?? d.macAddress
    }

    static func load() -> EngineSettings {
        if let data = try? Data(contentsOf: EnginePaths.settings), let settings = try? JSONDecoder().decode(EngineSettings.self, from: data) {
            return settings
        }
        let settings = EngineSettings()
        settings.save()
        return settings
    }

    func save() {
        Paths.ensure(EnginePaths.root)
        try? JSONEncoder.machine.encode(self).write(to: EnginePaths.settings, options: .atomic)
    }
}

nonisolated enum EngineState: String, Codable, Sendable {
    case stopped, settingUp, starting, running, stopping, error

    var label: String {
        switch self {
        case .stopped: "Stopped"
        case .settingUp: "Setting Up"
        case .starting: "Starting"
        case .running: "Running"
        case .stopping: "Stopping"
        case .error: "Error"
        }
    }
}

/// The engine's state, written to `EnginePaths.status` by the engine process.
nonisolated struct EngineStatus: Codable, Equatable, Sendable {
    var pid: Int32
    var state: EngineState
    var message: String?
    /// Setup progress from 0 to 1, when it can tell.
    var progress: Double?
    /// Seconds from power on until Docker answered, for the last boot.
    var bootSeconds: Double?
    /// What the guest is using, without its caches.
    var memoryUsed: UInt64?
    /// The memory the guest has.
    var memoryLimit: UInt64?
    var runningContainers: Int?
    /// Published ports forwarded from the Mac, like "5432/tcp".
    var forwardedPorts: [String] = []
    /// Ports a container publishes that something else on the Mac already uses.
    var blockedPorts: [String] = []
    var updated = Date()

    /// The engine's status, or nil when it isn't running.
    static func read() -> EngineStatus? {
        guard let data = try? Data(contentsOf: EnginePaths.status),
              let status = try? JSONDecoder.machine.decode(EngineStatus.self, from: data) else { return nil }
        guard kill(status.pid, 0) == 0 || errno == EPERM else { return nil }
        return status
    }

    func write() {
        Paths.ensure(Paths.run)
        try? JSONEncoder.machine.encode(self).write(to: EnginePaths.status, options: .atomic)
    }
}

/// The LaunchAgent that owns `~/.hyperbox/docker.sock` and starts the engine on the first connection.
nonisolated enum EngineAgent {
    static let label = "dev.alexis.Hyperbox.engine"
    /// The name `launch_activate_socket` looks the socket up by.
    static let socketName = "Docker"
    static let argument = "--engine"

    static var plist: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/LaunchAgents/\(label).plist")
    }

    static func contents(executable: String) -> [String: Any] {
        [
            "Label": label,
            "ProgramArguments": [executable, argument],
            "Sockets": [socketName: ["SockPathName": EnginePaths.socket.path, "SockPathMode": 0o600]],
            "StandardErrorPath": EnginePaths.log.path,
            "StandardOutPath": EnginePaths.log.path,
            // Room for the guest to shut down cleanly when you log out.
            "ExitTimeOut": 30,
        ]
    }

    /// Installs or updates the agent for this copy of Hyperbox, and loads it. Cheap when nothing changed:
    /// launchd only holds the socket until something connects.
    static func register(executable: String) throws {
        Paths.ensure(Paths.home)
        Paths.ensure(EnginePaths.root)
        Paths.ensure(plist.deletingLastPathComponent())
        let data = try PropertyListSerialization.data(fromPropertyList: contents(executable: executable), format: .xml, options: 0)
        let changed = (try? Data(contentsOf: plist)) != data
        if changed {
            // A copy run from the DMG, or moved aside by Gatekeeper, would leave launchd pointing at a path
            // that soon disappears; keep whatever an installed copy registered.
            if executable.hasPrefix("/Volumes/") || executable.contains("/AppTranslocation/"), isLoaded { return }
            // Reloading stops a running engine and every container in it; the new path waits for a launch
            // that finds it stopped.
            if isLoaded, EngineStatus.read() != nil { return }
            try data.write(to: plist, options: .atomic)
            if isLoaded { launchctl(["bootout", target]) }
        }
        if !isLoaded {
            // A socket left behind by an engine started by hand would stop launchd from binding it.
            if !FileManager.default.fileExists(atPath: EnginePaths.status.path) || EngineStatus.read() == nil { unlink(EnginePaths.socket.path) }
            launchctl(["bootstrap", domain, plist.path])
        }
        guard isLoaded else { throw ControlError("Couldn't load the container engine's LaunchAgent (\(plist.path)).") }
    }

    static func unregister() {
        launchctl(["bootout", target])
        try? FileManager.default.removeItem(at: plist)
    }

    static var isLoaded: Bool { launchctl(["print", target]) == 0 }

    private static var domain: String { "gui/\(getuid())" }
    private static var target: String { "\(domain)/\(label)" }

    @discardableResult
    private static func launchctl(_ arguments: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = arguments
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return -1 }
        p.waitUntilExit()
        return p.terminationStatus
    }
}

/// The `hyperbox` Docker context, which points `docker` at the engine.
///
/// Written straight to ~/.docker, the way `docker context create` and `docker context use` do, so it
/// works without the Docker command installed (Compose and Testcontainers read the same files).
nonisolated enum DockerContext {
    static let name = "hyperbox"
    static var host: String { "unix://\(EnginePaths.socket.path)" }

    private static var docker: URL {
        if let config = ProcessInfo.processInfo.environment["DOCKER_CONFIG"] { return URL(fileURLWithPath: config) }
        return FileManager.default.homeDirectoryForCurrentUser.appending(path: ".docker")
    }
    private static var config: URL { docker.appending(path: "config.json") }
    private static var meta: URL {
        let hash = SHA256.hash(data: Data(name.utf8)).map { String(format: "%02x", $0) }.joined()
        return docker.appending(path: "contexts/meta/\(hash)/meta.json")
    }
    /// The context in use before ours, so turning Hyperbox off puts it back.
    private static var previousFile: URL { EnginePaths.root.appending(path: "previous-docker-context") }

    /// The context `docker` uses, "default" when none is set.
    static var current: String {
        readConfig()["currentContext"] as? String ?? "default"
    }

    static var isCurrent: Bool { current == name }

    static var previous: String {
        (try? String(contentsOf: previousFile, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "default"
    }

    /// Creates the context, and switches to it when `use` is true.
    static func setUp(use: Bool = true) throws {
        let description: [String: Any] = [
            "Name": name,
            "Metadata": ["Description": "Hyperbox"],
            "Endpoints": ["docker": ["Host": host, "SkipTLSVerify": false]],
        ]
        try FileManager.default.createDirectory(at: meta.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: description).write(to: meta, options: .atomic)
        guard use, !isCurrent else { return }
        Paths.ensure(EnginePaths.root)
        try current.write(to: previousFile, atomically: true, encoding: .utf8)
        try setCurrent(name)
    }

    /// Switches back to the context in use before Hyperbox's.
    static func restore() throws {
        guard isCurrent else { return }
        let back = previous == name ? "default" : previous
        try setCurrent(back)
    }

    private static func setCurrent(_ context: String) throws {
        var config = readConfig()
        if context == "default" { config.removeValue(forKey: "currentContext") } else { config["currentContext"] = context }
        try FileManager.default.createDirectory(at: docker, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys]).write(to: self.config, options: .atomic)
    }

    private static func readConfig() -> [String: Any] {
        guard let data = try? Data(contentsOf: config),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return object
    }

    /// What Compose, Testcontainers and other tools that ignore contexts need, as shell exports.
    static var environmentHelp: String {
        """
        # For tools that don't read Docker contexts (add to ~/.zshrc to keep):
        export DOCKER_HOST=\(host)
        # Testcontainers: Ryuk mounts the socket from inside the engine, and published ports are on localhost.
        export TESTCONTAINERS_DOCKER_SOCKET_OVERRIDE=/var/run/docker.sock
        export TESTCONTAINERS_HOST_OVERRIDE=127.0.0.1
        """
    }
}
