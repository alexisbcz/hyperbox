import Foundation

/// How the library window, the `hyperbox` command and the MCP server talk to a running machine.
///
/// Each machine runs in its own process, which listens on `Paths.socket(for:)` for one JSON object
/// per line, `{"method": "...", "params": {...}}`, and answers each with `{"ok": true, "result": ...}`
/// or `{"ok": false, "error": "..."}`. Methods are listed in `ControlMethod`.
nonisolated enum ControlMethod: String, CaseIterable, Sendable {
    /// → `MachineStatus`
    case status
    case start, stop, forceStop, pause, resume
    /// Brings the machine's window to the front.
    case show
    /// → `{"png": base64, "width": Int, "height": Int}`. Params: `maxWidth`.
    case screenshot
    /// Params: `text`.
    case type
    /// Params: `key` ("return", "a", "f5", …), `modifiers` (["command", "shift", …]).
    case key
    /// Params: `x`, `y` in screenshot pixels, `button` ("left", "right"), `count`.
    case click
    /// Params: `x`, `y`.
    case moveMouse
    /// Params: `x`, `y`, `deltaX`, `deltaY`.
    case scroll
    /// Holds the left button from `x`, `y` to `toX`, `toY`. Params also `width`, `height`, as for click.
    case drag
    /// Runs a shell command in the guest. Params: `command`, `admin` (Bool), `timeout` (seconds).
    /// → `{"exitCode": Int, "stdout": String, "stderr": String}`
    case exec
    /// → `[SnapshotInfo]`
    case listSnapshots
    /// Params: `name`. → `SnapshotInfo`
    case takeSnapshot
    /// Params: `id`.
    case restoreSnapshot, deleteSnapshot
    /// Rereads config.json and applies what can change while running (name, shared folders, network, ports).
    case reloadConfig
}

/// A running machine's state, written to `Paths.status(for:)` whenever it changes.
nonisolated struct MachineStatus: Codable, Equatable, Sendable {
    var pid: Int32
    var state: MachineState
    /// What went wrong, when `state` is `.error`.
    var message: String?
    /// The guest's address on the NAT network, once DHCP has handed one out.
    var ipAddress: String?
    /// Installer progress from 0 to 1, while installing.
    var progress: Double?
    /// Port forwards that couldn't start, by `PortForward.id` (as a string), with why: a port in use, say.
    var portForwardErrors: [String: String]?
    var updated = Date()

    static func read(for id: UUID) -> MachineStatus? {
        guard let data = try? Data(contentsOf: Paths.status(for: id)),
              let status = try? JSONDecoder.machine.decode(MachineStatus.self, from: data) else { return nil }
        // A crashed process leaves its status behind; only a live one counts.
        guard kill(status.pid, 0) == 0 || errno == EPERM else { return nil }
        return status
    }

    func write(for id: UUID) {
        Paths.ensure(Paths.run)
        try? JSONEncoder.machine.encode(self).write(to: Paths.status(for: id), options: .atomic)
    }
}

nonisolated enum MachineState: String, Codable, Sendable {
    case stopped, starting, running, paused, saving, restoring, installing, stopping, error

    var label: String {
        switch self {
        case .stopped: "Stopped"
        case .starting: "Starting"
        case .running: "Running"
        case .paused: "Paused"
        case .saving: "Saving"
        case .restoring: "Restoring"
        case .installing: "Installing"
        case .stopping: "Stopping"
        case .error: "Error"
        }
    }
}

nonisolated struct SnapshotInfo: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var name: String
    var created: Date
    /// Taken while running: restoring it resumes the machine where it was, apps and all.
    var hasState: Bool
}

/// Any JSON value, for method parameters and results.
nonisolated enum JSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let n): try c.encode(n)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }

    subscript(key: String) -> JSONValue? {
        if case .object(let o) = self { o[key] } else { nil }
    }

    var string: String? { if case .string(let s) = self { s } else { nil } }
    var double: Double? { if case .number(let n) = self { n } else { nil } }
    var int: Int? { double.map { Int($0) } }
    var bool: Bool? { if case .bool(let b) = self { b } else { nil } }
    var array: [JSONValue]? { if case .array(let a) = self { a } else { nil } }

    /// Round-trips any Encodable through JSON.
    init(encoding value: some Encodable) throws {
        self = try JSONDecoder.machine.decode(JSONValue.self, from: JSONEncoder.machine.encode(value))
    }

    func decode<T: Decodable>(_ type: T.Type) throws -> T {
        try JSONDecoder.machine.decode(T.self, from: JSONEncoder.machine.encode(self))
    }
}

nonisolated struct ControlRequest: Codable, Sendable {
    var method: String
    var params: [String: JSONValue] = [:]

    init(method: String, params: [String: JSONValue] = [:]) {
        self.method = method
        self.params = params
    }

    /// `params` may be left out: `{"method": "status"}`.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        method = try c.decode(String.self, forKey: .method)
        params = try c.decodeIfPresent([String: JSONValue].self, forKey: .params) ?? [:]
    }
}

nonisolated struct ControlResponse: Codable, Sendable {
    var ok: Bool
    var result: JSONValue?
    var error: String?
}

nonisolated struct ControlError: LocalizedError, Sendable {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

/// Sends requests to a running machine. Blocking, so call it off the main thread.
nonisolated enum ControlClient {
    static func send(_ method: ControlMethod, to id: UUID, params: [String: JSONValue] = [:], timeout: TimeInterval = 30) throws -> JSONValue {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ControlError("Couldn't open a socket.") }
        defer { close(fd) }
        var tv = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var addr = sockaddr_un.make(Paths.socket(for: id).path)
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else { throw ControlError("The machine isn't running.") }

        var line = try JSONEncoder().encode(ControlRequest(method: method.rawValue, params: params))
        line.append(0x0A)
        try line.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let n = write(fd, buffer.baseAddress! + offset, buffer.count - offset)
                guard n > 0 else { throw ControlError("Lost the connection to the machine.") }
                offset += n
            }
        }
        var reply = Data()
        var chunk = [UInt8](repeating: 0, count: 65536)
        while !reply.contains(0x0A) {
            let n = read(fd, &chunk, chunk.count)
            guard n > 0 else { throw ControlError(n == 0 ? "The machine closed the connection." : "The machine didn't answer in time.") }
            reply.append(contentsOf: chunk[0..<n])
        }
        let response = try JSONDecoder().decode(ControlResponse.self, from: reply.prefix { $0 != 0x0A })
        guard response.ok else { throw ControlError(response.error ?? "The machine refused \(method.rawValue).") }
        return response.result ?? .null
    }
}

nonisolated extension sockaddr_un {
    static func make(_ path: String) -> sockaddr_un {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { buffer in
            let bytes = Array(path.utf8.prefix(buffer.count - 1))
            buffer.copyBytes(from: bytes)
            buffer[bytes.count] = 0
        }
        return addr
    }
}

nonisolated extension JSONValue: ExpressibleByStringLiteral, ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral,
    ExpressibleByFloatLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral, ExpressibleByNilLiteral {
    init(stringLiteral value: String) { self = .string(value) }
    init(booleanLiteral value: Bool) { self = .bool(value) }
    init(integerLiteral value: Int) { self = .number(Double(value)) }
    init(floatLiteral value: Double) { self = .number(value) }
    init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    init(dictionaryLiteral elements: (String, JSONValue)...) { self = .object(Dictionary(elements, uniquingKeysWith: { $1 })) }
    init(nilLiteral: ()) { self = .null }
}
