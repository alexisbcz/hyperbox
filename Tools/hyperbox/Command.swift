import Foundation

/// One `hyperbox` subcommand. Each group of commands lives in its own file as static members, and
/// main.swift lists them all in `commands`, so adding one touches one line there.
nonisolated struct Command: Sendable {
    let name: String
    var aliases: [String] = []
    /// The arguments, after the name: "<machine> [--wait]".
    var arguments = ""
    /// One line for `hyperbox --help`.
    let summary: String
    /// More, for `hyperbox help <command>`.
    var details = ""
    /// Left out of `hyperbox --help`: for Hyperbox's own use.
    var hidden = false
    let run: @Sendable (inout Arguments) throws -> Void

    var usage: String { "hyperbox \(name)\(arguments.isEmpty ? "" : " \(arguments)")" }
}

/// What's left of the command line, taken as a command reads it.
nonisolated struct Arguments {
    private(set) var items: [String]
    /// Everything after a lone `--`, passed through untouched (`exec`, `ssh`).
    private(set) var passthrough: [String]?

    init(_ items: [String]) {
        if let dash = items.firstIndex(of: "--") {
            self.items = Array(items[..<dash])
            passthrough = Array(items[(dash + 1)...])
        } else {
            self.items = items
        }
    }

    /// Takes `--name` if it's there.
    mutating func flag(_ names: String...) -> Bool {
        guard let i = items.firstIndex(where: names.contains) else { return false }
        items.remove(at: i)
        return true
    }

    /// Takes `--name value` or `--name=value`.
    mutating func option(_ name: String) throws -> String? {
        if let i = items.firstIndex(where: { $0.hasPrefix(name + "=") }) {
            return String(items.remove(at: i).dropFirst(name.count + 1))
        }
        guard let i = items.firstIndex(of: name) else { return nil }
        guard i + 1 < items.count else { throw Failure("\(name) needs a value.") }
        items.remove(at: i)
        return items.remove(at: i)
    }

    /// Takes the next argument that isn't an option.
    mutating func next(_ what: String) throws -> String {
        guard let value = optionalNext() else { throw Failure("missing \(what).") }
        return value
    }

    mutating func optionalNext() -> String? {
        guard let i = items.firstIndex(where: { !$0.hasPrefix("-") || $0 == "-" }) else { return nil }
        return items.remove(at: i)
    }

    /// Takes whatever's left, options included.
    mutating func rest() -> [String] {
        defer { items = [] }
        return items
    }

    /// Fails on anything a command didn't take, so a typo doesn't pass silently.
    func done() throws {
        if let extra = items.first { throw Failure("unexpected \(extra).") }
    }
}

nonisolated struct Failure: LocalizedError {
    let errorDescription: String?
    /// The process's exit status.
    var status: Int32 = 1
    init(_ message: String, status: Int32 = 1) {
        errorDescription = message
        self.status = status
    }
}

// MARK: - Machines

/// A machine from the library, found by name, id or bundle path.
nonisolated struct Target {
    let url: URL
    var config: MachineConfig
    var id: UUID { config.id }
    var name: String { config.name }
    /// Nil when it's stopped.
    var status: MachineStatus? { MachineStatus.read(for: config.id) }

    static func all() -> [Target] {
        Paths.machineBundles()
            .compactMap { url in (try? MachineConfig.load(from: url)).map { Target(url: url, config: $0) } }
            .sorted { $0.config.created < $1.config.created }
    }

    /// The exact name, then the name in any case, then the id or a unique start of it, then a bundle path.
    static func find(_ name: String) throws -> Target {
        let all = all()
        if let match = all.first(where: { $0.name == name }) ?? all.first(where: { $0.name.lowercased() == name.lowercased() }) {
            return match
        }
        let prefix = all.filter { $0.id.uuidString.lowercased().hasPrefix(name.lowercased()) }
        if prefix.count == 1, name.count >= 4 { return prefix[0] }
        let url = URL(fileURLWithPath: (name as NSString).expandingTildeInPath)
        if url.pathExtension == Paths.bundleExtension, let config = try? MachineConfig.load(from: url) {
            return Target(url: url, config: config)
        }
        throw Failure("no machine named \(name). Try `hyperbox list`.")
    }

    /// Sends a control request to the running machine.
    @discardableResult
    func send(_ method: ControlMethod, _ params: [String: JSONValue] = [:], timeout: TimeInterval = 30) throws -> JSONValue {
        guard status != nil else { throw Failure("\(name) isn't running. Start it with `hyperbox start \(quoted(name))`.") }
        return try ControlClient.send(method, to: id, params: params, timeout: timeout)
    }

    /// Rewrites config.json, and tells the machine when it's running so the change applies now.
    func updateConfig(_ change: (inout MachineConfig) throws -> Void) throws -> MachineConfig {
        var config = try MachineConfig.load(from: url)
        try change(&config)
        try config.save(to: url)
        if status != nil { try ControlClient.send(.reloadConfig, to: id) }
        return config
    }

    /// Waits until `condition` holds for the machine's status, or `timeout` passes.
    func wait(timeout: TimeInterval, until condition: (MachineStatus?) -> Bool) -> MachineStatus? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let status = status
            if condition(status) { return status }
            usleep(250_000)
        }
        return status
    }
}

// MARK: - The app

nonisolated enum AppLauncher {
    /// The Hyperbox.app this command belongs to: it lives at Hyperbox.app/Contents/Resources/bin/hyperbox, or
    /// beside it in a build folder. Nil when it's neither, and Launch Services finds the app by bundle id.
    static var url: URL? {
        // The executable's own path: argv[0] is only "hyperbox" when the shell found it on the PATH.
        let me = (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])).resolvingSymlinksInPath()
        let inside = me.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        if inside.pathExtension == "app" { return inside }
        let beside = me.deletingLastPathComponent().appending(path: "Hyperbox.app")
        return FileManager.default.fileExists(atPath: beside.path) ? beside : nil
    }

    /// Opens the machine in a new Hyperbox process, which boots it.
    static func launch(_ bundle: URL) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = ["-n"] + (url.map { ["-a", $0.path] } ?? ["-b", "dev.alexis.Hyperbox"]) + ["--args", "--machine", bundle.path]
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw Failure("couldn't open Hyperbox.") }
    }
}

// MARK: - Output

nonisolated func printJSON(_ value: some Encodable) throws {
    print(String(decoding: try JSONEncoder.machine.encode(value), as: UTF8.self))
}

/// Columns padded to line up, the last one left ragged.
nonisolated func printTable(_ header: [String], _ rows: [[String]]) {
    let all = [header] + rows
    let widths = header.indices.map { column in all.map { $0[column].count }.max() ?? 0 }
    for row in all {
        let cells = row.enumerated().map { i, cell in i == row.count - 1 ? cell : cell.padding(toLength: widths[i], withPad: " ", startingAt: 0) }
        print(cells.joined(separator: "  "))
    }
}

nonisolated func printError(_ message: String) {
    FileHandle.standardError.write(Data("hyperbox: \(message)\n".utf8))
}

/// Quotes for the shell when needed, so printed commands can be pasted back.
nonisolated func quoted(_ s: String) -> String {
    if !s.isEmpty, s.allSatisfy({ $0.isLetter || $0.isNumber || "-_./:@=+,".contains($0) }) { return s }
    return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

nonisolated func formatBytes(_ bytes: UInt64) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory)
}
