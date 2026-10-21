import Foundation

/// Plain BSD socket plumbing for the engine: listeners, and byte pipes between two connections.
///
/// Threads rather than async: each connection is a pair of blocking copies, which is the simplest way to
/// carry Docker's streams (attach, exec -it, logs -f, build) byte for byte, hijacked or not.
nonisolated enum Sockets {
    /// Calls `handler` with each accepted connection, until the returned source is cancelled.
    static func accept(on listener: Int32, handler: @escaping @Sendable (Int32) -> Void) -> DispatchSourceRead {
        let source = DispatchSource.makeReadSource(fileDescriptor: listener, queue: .global())
        source.setEventHandler {
            let client = Darwin.accept(listener, nil, nil)
            guard client >= 0 else { return }
            noSigPipe(client)
            handler(client)
        }
        source.setCancelHandler { close(listener) }
        source.resume()
        return source
    }

    static func listenUnix(_ path: String) throws -> Int32 {
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = sockaddr_un.make(path)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard fd >= 0, bound == 0, listen(fd, 128) == 0 else {
            close(fd)
            throw ControlError("Couldn't listen on \(path).")
        }
        chmod(path, 0o600)
        return fd
    }

    /// A TCP or UDP socket bound to `port` on the loopback address, 127.0.0.1 or ::1.
    static func bindLoopback(port: Int, ipv6: Bool, udp: Bool) -> Int32? {
        let fd = socket(ipv6 ? AF_INET6 : AF_INET, udp ? SOCK_DGRAM : SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size))
        if ipv6 { setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &on, socklen_t(MemoryLayout<Int32>.size)) }
        let bound: Int32
        if ipv6 {
            var addr = sockaddr_in6()
            addr.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            addr.sin6_family = sa_family_t(AF_INET6)
            addr.sin6_port = in_port_t(UInt16(port).bigEndian)
            addr.sin6_addr = in6addr_loopback
            bound = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) } }
        } else {
            var addr = sockaddr_in()
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = in_port_t(UInt16(port).bigEndian)
            addr.sin_addr.s_addr = inet_addr("127.0.0.1")
            bound = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        }
        guard bound == 0, udp || listen(fd, 128) == 0 else {
            close(fd)
            return nil
        }
        return fd
    }

    /// Whether something on the Mac already listens on the TCP port.
    static func isFree(port: Int) -> Bool {
        guard let fd = bindLoopback(port: port, ipv6: false, udp: false) else { return false }
        close(fd)
        return true
    }

    static func connectTCP(host: String, port: Int, timeout: TimeInterval = 10) -> Int32? {
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port).bigEndian)
        guard inet_pton(AF_INET, host, &addr.sin_addr) == 1 else { return nil }
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        noSigPipe(fd)
        var on: Int32 = 1
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &on, socklen_t(MemoryLayout<Int32>.size))
        var tv = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        let result = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard result == 0 else {
            close(fd)
            return nil
        }
        tv = timeval()
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        return fd
    }

    static func noSigPipe(_ fd: Int32) {
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    }

    /// Copies bytes both ways until both sides are done, passing on half-closes (a client that's done
    /// sending but still reading, as `docker run -i` does with piped input), then closes both and calls `done`.
    static func pipe(_ a: Int32, _ b: Int32, done: @escaping @Sendable () -> Void = {}) {
        let group = DispatchGroup()
        for (from, to) in [(a, b), (b, a)] {
            group.enter()
            Thread.detachNewThread {
                copy(from: from, to: to)
                group.leave()
            }
        }
        group.notify(queue: .global()) {
            close(a)
            close(b)
            done()
        }
    }

    private static func copy(from: Int32, to: Int32) {
        var buffer = [UInt8](repeating: 0, count: 256 * 1024)
        while true {
            let n = read(from, &buffer, buffer.count)
            if n <= 0 {
                if n < 0, errno == EINTR { continue }
                // Done sending: tell the other side, which may still answer.
                shutdown(to, SHUT_WR)
                if n < 0 { shutdown(from, SHUT_RDWR) }
                return
            }
            var offset = 0
            while offset < n {
                let w = buffer.withUnsafeBytes { write(to, $0.baseAddress! + offset, n - offset) }
                if w <= 0 {
                    if w < 0, errno == EINTR { continue }
                    // The reader went away: stop both directions.
                    shutdown(from, SHUT_RDWR)
                    shutdown(to, SHUT_RDWR)
                    return
                }
                offset += w
            }
        }
    }
}

/// Forwards ports containers publish from the Mac's loopback to the engine, as Docker Desktop does:
/// `docker run -p 5432:5432 postgres` answers on localhost:5432. TCP goes over vsock to the agent,
/// which connects to the port inside the engine; UDP goes through `UserNetwork`.
nonisolated final class ContainerPorts: @unchecked Sendable {
    struct Key: Hashable, Comparable, Sendable {
        var port: Int
        var udp: Bool
        var label: String { "\(port)/\(udp ? "udp" : "tcp")" }
        static func < (a: Key, b: Key) -> Bool { (a.port, a.udp ? 1 : 0) < (b.port, b.udp ? 1 : 0) }
    }

    /// Opens a connection to a port in the guest; nil when the engine isn't running.
    typealias Connect = @Sendable (Int) async -> Int32?

    private let lock = NSLock()
    private var listeners: [Key: [DispatchSourceRead]] = [:]
    private var relays: [Key: ContainerUDPRelay] = [:]
    private var blocked: Set<Key> = []
    private let connections = Counter()
    private let connect: Connect
    private let network: UserNetwork?

    init(network: UserNetwork?, connect: @escaping Connect) {
        self.network = network
        self.connect = connect
    }

    var forwarded: [String] { lock.withLock { Set(listeners.keys).union(relays.keys).sorted().map(\.label) } }
    var unavailable: [String] { lock.withLock { blocked.sorted().map(\.label) } }
    var openConnections: Int { connections.value }

    /// Makes the forwarded ports match `wanted`.
    func update(_ wanted: Set<Key>) {
        lock.lock()
        defer { lock.unlock() }
        for (key, sources) in listeners where !wanted.contains(key) {
            sources.forEach { $0.cancel() }
            listeners[key] = nil
        }
        for (key, relay) in relays where !wanted.contains(key) {
            relay.stop()
            relays[key] = nil
        }
        blocked = blocked.intersection(wanted)
        for key in wanted where listeners[key] == nil && relays[key] == nil {
            if key.udp {
                if let network, let fd = Sockets.bindLoopback(port: key.port, ipv6: false, udp: true) {
                    relays[key] = ContainerUDPRelay(listener: fd, port: UInt16(key.port), network: network)
                    blocked.remove(key)
                } else {
                    blocked.insert(key)
                }
                continue
            }
            // Both loopbacks, since "localhost" is ::1 first for many clients.
            let fds = [false, true].compactMap { Sockets.bindLoopback(port: key.port, ipv6: $0, udp: false) }
            guard !fds.isEmpty else { blocked.insert(key); continue }
            blocked.remove(key)
            listeners[key] = fds.map { fd in
                Sockets.accept(on: fd) { [weak self] client in self?.forward(client, port: key.port) }
            }
        }
    }

    func removeAll() { update([]) }

    private func forward(_ client: Int32, port: Int) {
        connections.add(1)
        let connect = connect, connections = connections
        Task.detached {
            guard let upstream = await connect(port) else {
                close(client)
                connections.add(-1)
                return
            }
            Sockets.pipe(client, upstream) { connections.add(-1) }
        }
    }
}

/// A UDP port on the Mac's loopback relayed to the same port in the engine, through `UserNetwork`.
nonisolated final class ContainerUDPRelay: @unchecked Sendable {
    private let listener: Int32
    private let port: UInt16
    private let network: UserNetwork
    private let lock = NSLock()
    private var stopped = false
    /// Each client on the Mac gets its own source port toward the guest, so replies find their way back.
    private var clients: [Data: (handle: UInt16, seen: Date)] = [:]

    init(listener: Int32, port: UInt16, network: UserNetwork) {
        self.listener = listener
        self.port = port
        self.network = network
        var tv = timeval(tv_sec: 1, tv_usec: 0)
        setsockopt(listener, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        Thread.detachNewThread { [self] in receive() }
    }

    func stop() { lock.withLock { stopped = true } }

    private func receive() {
        var buffer = [UInt8](repeating: 0, count: 65536)
        var from = sockaddr_storage()
        while !lock.withLock({ stopped }) {
            var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
            let n = withUnsafeMutablePointer(to: &from) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(listener, &buffer, buffer.count, 0, $0, &length) }
            }
            expire()
            guard n > 0 else { continue }
            let client = withUnsafeBytes(of: &from) { Data($0.prefix(Int(length))) }
            let handle = lock.withLock { () -> UInt16 in
                if let existing = clients[client] {
                    clients[client]?.seen = Date()
                    return existing.handle
                }
                let listener = listener
                let handle = network.open { reply in
                    client.withUnsafeBytes { addr in
                        _ = reply.withUnsafeBytes {
                            sendto(listener, $0.baseAddress!, reply.count, 0, addr.baseAddress!.assumingMemoryBound(to: sockaddr.self), socklen_t(client.count))
                        }
                    }
                }
                clients[client] = (handle, Date())
                return handle
            }
            network.send(inbound: handle, Data(buffer[0..<n]), toGuestPort: port)
        }
        lock.withLock { clients.values.forEach { network.close(inbound: $0.handle) } }
        close(listener)
    }

    private func expire() {
        lock.withLock {
            for (client, entry) in clients where Date().timeIntervalSince(entry.seen) > 120 {
                network.close(inbound: entry.handle)
                clients[client] = nil
            }
        }
    }
}
