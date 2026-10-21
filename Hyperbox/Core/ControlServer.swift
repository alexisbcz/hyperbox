import Foundation

/// Listens on a machine's socket and hands each request to `handler` on the main actor.
/// See `ControlMethod` for the protocol.
nonisolated final class ControlServer: @unchecked Sendable {
    typealias Handler = @MainActor (ControlRequest) async throws -> JSONValue

    private let path: String
    private let handler: Handler
    private var fd: Int32 = -1

    init(path: String, handler: @escaping Handler) {
        self.path = path
        self.handler = handler
    }

    func start() throws {
        Paths.ensure(URL(fileURLWithPath: path).deletingLastPathComponent())
        unlink(path)
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ControlError("Couldn't open the control socket.") }
        var addr = sockaddr_un.make(path)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, listen(fd, 16) == 0 else { throw ControlError("Couldn't listen on \(path).") }
        chmod(path, 0o600)
        let listener = fd
        Thread.detachNewThread { [self] in
            while true {
                let client = accept(listener, nil, nil)
                if client < 0 { if errno == EINTR { continue } else { return } }
                Thread.detachNewThread { [self] in serve(client) }
            }
        }
    }

    func stop() {
        if fd >= 0 { close(fd) }
        fd = -1
        unlink(path)
    }

    private func serve(_ client: Int32) {
        defer { close(client) }
        var pending = Data()
        var chunk = [UInt8](repeating: 0, count: 65536)
        while true {
            while let newline = pending.firstIndex(of: 0x0A) {
                let line = pending[pending.startIndex..<newline]
                pending.removeSubrange(pending.startIndex...newline)
                var reply = respond(to: Data(line))
                reply.append(0x0A)
                guard writeAll(client, reply) else { return }
            }
            let n = read(client, &chunk, chunk.count)
            guard n > 0 else { return }
            pending.append(contentsOf: chunk[0..<n])
        }
    }

    private func respond(to line: Data) -> Data {
        let response: ControlResponse
        if let request = try? JSONDecoder().decode(ControlRequest.self, from: line) {
            let semaphore = DispatchSemaphore(value: 0)
            nonisolated(unsafe) var result: Result<JSONValue, Error> = .success(.null)
            let handler = handler
            Task { @MainActor in
                do { result = .success(try await handler(request)) } catch { result = .failure(error) }
                semaphore.signal()
            }
            semaphore.wait()
            switch result {
            case .success(let value): response = ControlResponse(ok: true, result: value)
            case .failure(let error): response = ControlResponse(ok: false, error: error.localizedDescription)
            }
        } else {
            response = ControlResponse(ok: false, error: "Not a request: send {\"method\": \"...\", \"params\": {...}} on one line.")
        }
        return (try? JSONEncoder().encode(response)) ?? Data("{\"ok\":false}".utf8)
    }

    private func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let n = write(fd, buffer.baseAddress! + offset, buffer.count - offset)
                if n <= 0 { return false }
                offset += n
            }
            return true
        }
    }
}
