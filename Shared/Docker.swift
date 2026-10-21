import Foundation

/// A small HTTP/1.1 client for the Docker Engine API, over a Unix socket or any connected file descriptor.
/// Blocking, so call it off the main thread.
nonisolated enum DockerHTTP {
    struct Response: Sendable {
        var status: Int
        var headers: [String: String]
        var body: Data

        var ok: Bool { (200..<300).contains(status) }

        func decode<T: Decodable>(_ type: T.Type) throws -> T {
            try JSONDecoder().decode(T.self, from: body)
        }

        /// Docker's error message, `{"message": "..."}`, or the status.
        var errorMessage: String {
            (try? JSONDecoder().decode([String: String].self, from: body))?["message"]
                ?? (String(data: body, encoding: .utf8).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }).flatMap { $0.isEmpty ? nil : $0 }
                ?? "HTTP \(status)"
        }
    }

    static func connect(_ path: String, timeout: TimeInterval) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ControlError("Couldn't open a socket.") }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        setTimeout(fd, timeout)
        var addr = sockaddr_un.make(path)
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else {
            close(fd)
            throw ControlError("The container engine isn't running (nothing listens on \(path)).")
        }
        return fd
    }

    static func setTimeout(_ fd: Int32, _ timeout: TimeInterval) {
        var tv = timeval(tv_sec: Int(timeout), tv_usec: Int32((timeout - timeout.rounded(.down)) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    /// Sends one request on `fd` and reads the response, closing `fd` when done. `onChunk` gets the body
    /// as it arrives, for streams like pull progress and events; the returned body is then empty.
    static func exchange(fd: Int32, method: String, path: String, body: Data? = nil,
                         onChunk: ((Data) -> Bool)? = nil) throws -> Response {
        defer { close(fd) }
        var head = "\(method) \(path) HTTP/1.1\r\nHost: docker\r\nUser-Agent: Hyperbox\r\nConnection: close\r\n"
        if let body {
            head += "Content-Type: application/json\r\nContent-Length: \(body.count)\r\n"
        } else if method == "POST" {
            head += "Content-Length: 0\r\n"
        }
        head += "\r\n"
        var request = Data(head.utf8)
        if let body { request.append(body) }
        try writeAll(fd, request)

        var reader = Reader(fd: fd)
        let statusLine = try reader.line()
        let parts = statusLine.split(separator: " ", maxSplits: 2)
        guard parts.count >= 2, let status = Int(parts[1]) else { throw ControlError("Docker sent a response Hyperbox can't read: \(statusLine)") }
        var headers: [String: String] = [:]
        while true {
            let line = try reader.line()
            if line.isEmpty { break }
            if let colon = line.firstIndex(of: ":") {
                headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
        }

        var collected = Data()
        let deliver: (Data) -> Bool = { data in
            if let onChunk, (200..<300).contains(status) { return onChunk(data) }
            collected.append(data)
            return true
        }
        if status == 204 || status == 304 || method == "HEAD" {
        } else if headers["transfer-encoding"]?.lowercased().contains("chunked") == true {
            while true {
                let sizeLine = try reader.line()
                guard let size = Int(sizeLine.split(separator: ";").first ?? "", radix: 16) else { break }
                if size == 0 { break }
                let chunk = try reader.bytes(size)
                _ = try reader.line()
                if !deliver(chunk) { break }
            }
        } else if let length = headers["content-length"].flatMap(Int.init) {
            _ = deliver(try reader.bytes(length))
        } else {
            while let data = try reader.some() { if !deliver(data) { break } }
        }
        return Response(status: status, headers: headers, body: collected)
    }

    static func writeAll(_ fd: Int32, _ data: Data) throws {
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let n = write(fd, buffer.baseAddress! + offset, buffer.count - offset)
                guard n > 0 else { throw ControlError("Lost the connection to the container engine.") }
                offset += n
            }
        }
    }

    /// Buffered reads, for lines and exact byte counts.
    struct Reader {
        let fd: Int32
        var buffer = Data()

        mutating func fill() throws -> Bool {
            var chunk = [UInt8](repeating: 0, count: 65536)
            let n = read(fd, &chunk, chunk.count)
            if n < 0 { throw ControlError(errno == EAGAIN ? "The container engine didn't answer in time." : "Lost the connection to the container engine.") }
            if n == 0 { return false }
            buffer.append(contentsOf: chunk[0..<n])
            return true
        }

        mutating func line() throws -> String {
            while true {
                if let i = buffer.firstIndex(of: 0x0A) {
                    var line = buffer[buffer.startIndex..<i]
                    if line.last == 0x0D { line = line.dropLast() }
                    buffer.removeSubrange(buffer.startIndex...i)
                    return String(decoding: line, as: UTF8.self)
                }
                guard try fill() else { throw ControlError("The container engine closed the connection.") }
            }
        }

        mutating func bytes(_ count: Int) throws -> Data {
            while buffer.count < count {
                guard try fill() else { throw ControlError("The container engine closed the connection.") }
            }
            let data = buffer.prefix(count)
            buffer.removeFirst(count)
            return Data(data)
        }

        /// What's been read past the last line or bytes taken, without reading more.
        mutating func leftover() throws -> Data {
            defer { buffer.removeAll() }
            return buffer
        }

        mutating func some() throws -> Data? {
            if buffer.isEmpty, try !fill() { return nil }
            defer { buffer.removeAll() }
            return buffer
        }
    }
}

// MARK: - API types

/// A container, as `GET /containers/json` lists it.
nonisolated struct ContainerSummary: Codable, Identifiable, Equatable, Hashable, Sendable {
    var id: String
    var names: [String]
    var image: String
    var state: String
    var status: String
    var created: Int
    var ports: [Port]
    var labels: [String: String]?

    struct Port: Codable, Equatable, Hashable, Sendable {
        var ip: String?
        var privatePort: Int
        var publicPort: Int?
        var type: String

        enum CodingKeys: String, CodingKey {
            case ip = "IP", privatePort = "PrivatePort", publicPort = "PublicPort", type = "Type"
        }
    }

    enum CodingKeys: String, CodingKey {
        case id = "Id", names = "Names", image = "Image", state = "State", status = "Status", created = "Created", ports = "Ports", labels = "Labels"
    }

    var name: String { (names.first ?? id).trimmingCharacters(in: CharacterSet(charactersIn: "/")) }
    var shortID: String { String(id.prefix(12)) }
    var isRunning: Bool { state == "running" }

    /// Published ports, once each, like "5432→5432/tcp".
    var publishedPorts: [Port] {
        var seen = Set<String>()
        return ports.filter { $0.publicPort != nil && seen.insert("\($0.publicPort!)/\($0.type)").inserted }
            .sorted { ($0.publicPort ?? 0) < ($1.publicPort ?? 0) }
    }
}

/// A port to publish on the Mac's localhost.
nonisolated struct PortMapping: Codable, Hashable, Sendable {
    var host: Int
    var container: Int
    var udp = false

    init(host: Int, container: Int, udp: Bool = false) {
        self.host = host
        self.container = container
        self.udp = udp
    }

    /// "5432", "8080:80", "53:53/udp".
    init?(_ string: String) {
        var spec = Substring(string)
        if spec.hasSuffix("/udp") { udp = true; spec = spec.dropLast(4) } else if spec.hasSuffix("/tcp") { spec = spec.dropLast(4) }
        let parts = spec.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 1 || parts.count == 2 else { return nil }
        host = parts[0]
        container = parts.last!
    }
}

// MARK: - Engine API

/// Containers on the Hyperbox engine, through the Docker Engine API on `~/.hyperbox/docker.sock`.
///
/// For the app, the `hyperbox` command and AI agents (MCP tools like `list_containers` and `run_container`
/// can call these directly). Every call is blocking, so call it off the main thread; the first one starts
/// the engine if it isn't running, which takes a few seconds (minutes the very first time, to set it up).
nonisolated enum ContainerEngine {
    /// Containers made from the gallery or by agents carry this label, so the app can tell them apart.
    static let label = "dev.alexis.hyperbox"

    static func request(_ method: String, _ path: String, body: Data? = nil, timeout: TimeInterval = 120,
                        onChunk: ((Data) -> Bool)? = nil) throws -> DockerHTTP.Response {
        let fd = try DockerHTTP.connect(EnginePaths.socket.path, timeout: timeout)
        return try DockerHTTP.exchange(fd: fd, method: method, path: path, body: body, onChunk: onChunk)
    }

    /// Fails with Docker's message unless the response was a success.
    @discardableResult
    static func call(_ method: String, _ path: String, json: Any? = nil, timeout: TimeInterval = 120) throws -> DockerHTTP.Response {
        let body = try json.map { try JSONSerialization.data(withJSONObject: $0) }
        let response = try request(method, path, body: body, timeout: timeout)
        guard response.ok || response.status == 304 else { throw ControlError(response.errorMessage) }
        return response
    }

    /// Waits for Docker to answer, starting the engine if needed.
    static func ping(timeout: TimeInterval = 900) throws {
        let response = try request("GET", "/_ping", timeout: timeout)
        guard response.ok else { throw ControlError(response.errorMessage) }
    }

    /// Doesn't start the engine.
    static var isRunning: Bool { EngineStatus.read()?.state == .running }

    static func containers(all: Bool = true) throws -> [ContainerSummary] {
        try call("GET", "/containers/json?all=\(all ? 1 : 0)").decode([ContainerSummary].self)
    }

    /// Pulls `image` ("postgres", "postgres:17", "ghcr.io/owner/name:tag"). `progress` gets Docker's status lines.
    static func pull(_ image: String, progress: ((String) -> Void)? = nil) throws {
        let (name, tag) = split(image)
        var failure: String?
        var pending = Data()
        let response = try request("POST", "/images/create?fromImage=\(escape(name))&tag=\(escape(tag))", timeout: 600) { chunk in
            pending.append(chunk)
            while let newline = pending.firstIndex(of: 0x0A) {
                let line = pending[pending.startIndex..<newline]
                pending.removeSubrange(pending.startIndex...newline)
                guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
                if let error = object["error"] as? String { failure = error }
                if let status = object["status"] as? String {
                    progress?([object["id"] as? String, status, object["progress"] as? String].compactMap { $0 }.joined(separator: " "))
                }
            }
            return true
        }
        guard response.ok else { throw ControlError(response.errorMessage) }
        if let failure { throw ControlError(failure) }
    }

    static func hasImage(_ image: String) -> Bool {
        (try? request("GET", "/images/\(escape(image, path: true))/json", timeout: 30))?.ok == true
    }

    /// Pulls the image if needed, then creates and starts a container; returns its id.
    ///
    /// `volumes` maps a named volume or an absolute Mac path (your home folder is shared with the engine at
    /// the same path) to a path in the container. `restart` is a Docker restart policy, "unless-stopped" to
    /// come back when the engine restarts.
    @discardableResult
    static func run(image: String, name: String? = nil, ports: [PortMapping] = [], env: [String: String] = [:],
                    volumes: [String: String] = [:], command: [String]? = nil, restart: String? = nil,
                    labels: [String: String] = [:], progress: ((String) -> Void)? = nil) throws -> String {
        if !hasImage(image) { try pull(image, progress: progress) }
        var exposed: [String: Any] = [:]
        var bindings: [String: Any] = [:]
        for port in ports {
            let key = "\(port.container)/\(port.udp ? "udp" : "tcp")"
            exposed[key] = [String: Any]()
            var list = bindings[key] as? [[String: String]] ?? []
            list.append(["HostPort": String(port.host)])
            bindings[key] = list
        }
        var host: [String: Any] = [
            "PortBindings": bindings,
            "Binds": volumes.map { "\($0.key):\($0.value)" }.sorted(),
        ]
        if let restart { host["RestartPolicy"] = ["Name": restart] }
        var config: [String: Any] = [
            "Image": image,
            "Env": env.map { "\($0.key)=\($0.value)" }.sorted(),
            "ExposedPorts": exposed,
            "HostConfig": host,
            "Labels": labels.merging([label: "1"]) { a, _ in a },
        ]
        if let command { config["Cmd"] = command }
        let query = name.map { "?name=\(escape($0))" } ?? ""
        let created = try call("POST", "/containers/create\(query)", json: config)
        guard let id = (try? JSONSerialization.jsonObject(with: created.body) as? [String: Any])?["Id"] as? String else {
            throw ControlError("Docker didn't say which container it made.")
        }
        try start(id)
        return id
    }

    static func start(_ id: String) throws { try call("POST", "/containers/\(escape(id))/start") }
    static func stop(_ id: String) throws { try call("POST", "/containers/\(escape(id))/stop?t=10", timeout: 60) }
    static func restart(_ id: String) throws { try call("POST", "/containers/\(escape(id))/restart?t=10", timeout: 60) }
    static func remove(_ id: String, force: Bool = true) throws { try call("DELETE", "/containers/\(escape(id))?force=\(force ? 1 : 0)&v=0") }

    /// `docker inspect`, as JSON.
    static func inspect(_ id: String) throws -> JSONValue {
        try call("GET", "/containers/\(escape(id))/json").decode(JSONValue.self)
    }

    /// The container's environment, from its config, e.g. to show a generated password again.
    static func environment(_ id: String) throws -> [String: String] {
        let env = try inspect(id)["Config"]?["Env"]?.array?.compactMap(\.string) ?? []
        return Dictionary(env.compactMap { entry -> (String, String)? in
            guard let eq = entry.firstIndex(of: "=") else { return nil }
            return (String(entry[..<eq]), String(entry[entry.index(after: eq)...]))
        }, uniquingKeysWith: { $1 })
    }

    /// The last `tail` lines of output, stdout and stderr interleaved.
    static func logs(_ id: String, tail: Int = 500) throws -> String {
        let response = try call("GET", "/containers/\(escape(id))/logs?stdout=1&stderr=1&tail=\(tail)")
        return String(decoding: demultiplex(response.body), as: UTF8.self)
    }

    /// Strips the 8-byte frame headers Docker puts on output of containers without a TTY.
    static func demultiplex(_ data: Data) -> Data {
        let bytes = [UInt8](data)
        guard bytes.count >= 8, bytes[0] <= 2, bytes[1] == 0, bytes[2] == 0, bytes[3] == 0 else { return data }
        var out = Data()
        var i = 0
        while i + 8 <= bytes.count {
            let size = Int(bytes[i + 4]) << 24 | Int(bytes[i + 5]) << 16 | Int(bytes[i + 6]) << 8 | Int(bytes[i + 7])
            let end = min(i + 8 + size, bytes.count)
            out.append(contentsOf: bytes[(i + 8)..<end])
            i = end
        }
        return out
    }

    /// "postgres" → ("postgres", "latest"); "localhost:5000/app:1" → ("localhost:5000/app", "1").
    static func split(_ image: String) -> (String, String) {
        if let at = image.firstIndex(of: "@") { return (String(image[..<at]), String(image[image.index(after: at)...])) }
        if let colon = image.lastIndex(of: ":"), !image[colon...].contains("/") {
            return (String(image[..<colon]), String(image[image.index(after: colon)...]))
        }
        return (image, "latest")
    }

    static func escape(_ s: String, path: Bool = false) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: path ? "-._~:/" : "-._~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }
}
