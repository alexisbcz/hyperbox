import Foundation

typealias Message = [String: Any]

/// One JSON object per line each way, a thread per connection.
enum LineServer {
    /// Listens on vsock, which only the host can reach.
    static func listenVsock(port: UInt32) throws -> Int32 {
        let fd = socket(AF_VSOCK, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ToolError("Couldn't open a vsock socket: \(String(cString: strerror(errno))).") }
        var addr = sockaddr_vm()
        addr.svm_len = UInt8(MemoryLayout<sockaddr_vm>.size)
        addr.svm_family = sa_family_t(AF_VSOCK)
        addr.svm_port = port
        addr.svm_cid = VMADDR_CID_ANY
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_vm>.size)) }
        }
        guard bound == 0, listen(fd, 16) == 0 else {
            let reason = String(cString: strerror(errno))
            close(fd)
            throw ToolError("Couldn't listen on vsock port \(port): \(reason).")
        }
        return fd
    }

    /// Listens on a Unix socket only `owner` can open.
    static func listenUnix(path: String, owner: uid_t) throws -> Int32 {
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ToolError("Couldn't open a socket.") }
        var addr = unixAddress(path)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, listen(fd, 16) == 0 else {
            close(fd)
            throw ToolError("Couldn't listen on \(path): \(String(cString: strerror(errno))).")
        }
        chown(path, owner, 0)
        chmod(path, 0o600)
        return fd
    }

    /// Accepts connections forever, answering each line with `handler`'s reply.
    static func serve(_ listener: Int32, handler: @escaping @Sendable (Message) -> Message) -> Never {
        while true {
            let client = accept(listener, nil, nil)
            if client < 0 {
                if errno == EINTR || errno == ECONNABORTED { continue }
                fatalError("accept failed: \(String(cString: strerror(errno)))")
            }
            Thread.detachNewThread { connection(client, handler: handler) }
        }
    }

    private static func connection(_ fd: Int32, handler: (Message) -> Message) {
        defer { close(fd) }
        var pending = Data()
        var chunk = [UInt8](repeating: 0, count: 1 << 20)
        while true {
            while let newline = pending.firstIndex(of: 0x0A) {
                let line = pending[pending.startIndex..<newline]
                pending.removeSubrange(pending.startIndex...newline)
                let reply: Message
                if let request = (try? JSONSerialization.jsonObject(with: line)) as? Message {
                    reply = handler(request)
                } else {
                    reply = ["ok": false, "error": "That isn't a JSON object."]
                }
                guard send(reply, to: fd) else { return }
            }
            let n = read(fd, &chunk, chunk.count)
            guard n > 0 else { return }
            pending.append(contentsOf: chunk[0..<n])
        }
    }

    static func send(_ message: Message, to fd: Int32) -> Bool {
        guard var data = try? JSONSerialization.data(withJSONObject: message) else { return false }
        data.append(0x0A)
        return data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let n = write(fd, buffer.baseAddress! + offset, buffer.count - offset)
                guard n > 0 else { return false }
                offset += n
            }
            return true
        }
    }

    /// Sends one request to a Unix socket and waits for the reply.
    static func request(_ message: Message, path: String, timeout: Double) throws -> Message {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ToolError("Couldn't open a socket.") }
        defer { close(fd) }
        var tv = timeval(tv_sec: Int(timeout.rounded(.up)), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var addr = unixAddress(path)
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else { throw ToolError("unreachable") }
        guard send(message, to: fd) else { throw ToolError("Lost the connection to the administrator helper.") }
        var reply = Data()
        var chunk = [UInt8](repeating: 0, count: 65536)
        while !reply.contains(0x0A) {
            let n = read(fd, &chunk, chunk.count)
            guard n > 0 else { throw ToolError("The administrator helper didn't answer.") }
            reply.append(contentsOf: chunk[0..<n])
        }
        guard let object = (try? JSONSerialization.jsonObject(with: reply.prefix { $0 != 0x0A })) as? Message else {
            throw ToolError("The administrator helper answered nonsense.")
        }
        return object
    }

    static func unixAddress(_ path: String) -> sockaddr_un {
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

struct ToolError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

func log(_ message: String) {
    FileHandle.standardError.write(Data("\(Date().formatted(.iso8601)) \(message)\n".utf8))
}
