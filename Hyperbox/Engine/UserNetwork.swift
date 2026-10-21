import Foundation

/// The engine's network, run in this process instead of macOS's NAT.
///
/// macOS's NAT (VZNATNetworkDeviceAttachment) depends on InternetSharing and bootpd, which VPNs and
/// firewalls often break: then the guest gets no address and nothing works. So the engine's network
/// card is a socket pair to this class, which plays a tiny router: it answers DHCP and ARP, relays UDP
/// (DNS, NTP, anything) through ordinary sockets on the Mac, and answers ping for itself. TCP doesn't
/// come here at all: the agent in the guest redirects it to vsock (see hyperbox-engine.py and
/// `EngineHost.proxy`), so connections leave from the Mac like any app's, through whatever VPN it uses.
///
///     192.168.127.1    the gateway and DNS server (this class)
///     192.168.127.2    the engine
///     192.168.127.254  the Mac itself, as host.docker.internal
nonisolated final class UserNetwork: @unchecked Sendable {
    static let gateway: [UInt8] = [192, 168, 127, 1]
    static let guest: [UInt8] = [192, 168, 127, 2]
    static let mac: [UInt8] = [192, 168, 127, 254]
    private static let gatewayMAC: [UInt8] = [0x5A, 0x94, 0xEF, 0xE4, 0x0C, 0xEE]
    private static let broadcastMAC: [UInt8] = [0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]
    static let hostNames: Set<String> = ["host.docker.internal", "gateway.docker.internal", "host.hyperbox.internal"]

    /// The guest's end, for `VZFileHandleNetworkDeviceAttachment`.
    let guestHandle: FileHandle
    private let fd: Int32
    private let lock = NSLock()
    private var guestMAC: [UInt8]?
    private var flows: [String: Int32] = [:]
    /// Replies to UDP the Mac sent in (published UDP ports), by the gateway port it came from.
    private var inbound: [UInt16: @Sendable (Data) -> Void] = [:]
    private var nextPort: UInt16 = 40000
    private var stopped = false

    init() throws {
        var pair: [Int32] = [0, 0]
        guard socketpair(AF_UNIX, SOCK_DGRAM, 0, &pair) == 0 else { throw ControlError("Couldn't make the engine's network.") }
        for s in pair {
            var size: Int32 = 4 << 20
            setsockopt(s, SOL_SOCKET, SO_RCVBUF, &size, socklen_t(MemoryLayout<Int32>.size))
            size = 1 << 20
            setsockopt(s, SOL_SOCKET, SO_SNDBUF, &size, socklen_t(MemoryLayout<Int32>.size))
        }
        fd = pair[0]
        guestHandle = FileHandle(fileDescriptor: pair[1], closeOnDealloc: true)
        Thread.detachNewThread { [self] in receive() }
    }

    func stop() {
        lock.withLock {
            stopped = true
            flows.values.forEach { Darwin.close($0) }
            flows = [:]
        }
        shutdown(fd, SHUT_RDWR)
        Darwin.close(fd)
    }

    private var isStopped: Bool { lock.withLock { stopped } }

    // MARK: - Frames from the guest

    private func receive() {
        var buffer = [UInt8](repeating: 0, count: 65536)
        while !isStopped {
            let n = recv(fd, &buffer, buffer.count, 0)
            if n < 0, errno == EINTR { continue }
            guard n > 0 else { return }
            handle(Array(buffer[0..<n]))
        }
    }

    private func handle(_ frame: [UInt8]) {
        guard frame.count >= 14 else { return }
        let type = UInt16(frame[12]) << 8 | UInt16(frame[13])
        lock.withLock { guestMAC = Array(frame[6..<12]) }
        switch type {
        case 0x0806: arp(Array(frame[14...]))
        case 0x0800: ipv4(Array(frame[14...]))
        default: break // IPv6 and the rest: the engine is IPv4 only.
        }
    }

    private func arp(_ p: [UInt8]) {
        guard p.count >= 28, p[6] == 0, p[7] == 1 else { return } // requests only
        let senderMAC = Array(p[8..<14]), senderIP = Array(p[14..<18]), targetIP = Array(p[24..<28])
        // Everything on the subnet but the guest is us: the gateway, and the Mac.
        guard targetIP[0..<3] == Self.gateway[0..<3], targetIP != Self.guest else { return }
        var reply: [UInt8] = [0, 1, 0x08, 0x00, 6, 4, 0, 2]
        reply += Self.gatewayMAC + targetIP + senderMAC + senderIP
        send(ethernet: senderMAC, type: 0x0806, reply)
    }

    private func ipv4(_ p: [UInt8]) {
        guard p.count >= 20, p[0] >> 4 == 4 else { return }
        let headerLength = Int(p[0] & 0x0F) * 4
        let total = min(p.count, Int(p[2]) << 8 | Int(p[3]))
        guard headerLength >= 20, total > headerLength else { return }
        // Fragments: nothing the engine sends needs them (TCP goes over vsock).
        if p[6] & 0x20 != 0 || (Int(p[6] & 0x1F) << 8 | Int(p[7])) != 0 { return }
        let source = Array(p[12..<16]), destination = Array(p[16..<20])
        let payload = Array(p[headerLength..<total])
        switch p[9] {
        case 17: udp(payload, from: source, to: destination)
        case 1: icmp(payload, from: source, to: destination)
        default: break
        }
    }

    private func icmp(_ p: [UInt8], from source: [UInt8], to destination: [UInt8]) {
        guard p.count >= 8, p[0] == 8, destination == Self.gateway || destination == Self.mac else { return }
        var reply = p
        reply[0] = 0
        reply[2] = 0
        reply[3] = 0
        let sum = Self.checksum(reply)
        reply[2] = UInt8(sum >> 8)
        reply[3] = UInt8(sum & 0xFF)
        send(ip: 1, from: destination, to: source, reply)
    }

    private func udp(_ p: [UInt8], from source: [UInt8], to destination: [UInt8]) {
        guard p.count >= 8 else { return }
        let sourcePort = UInt16(p[0]) << 8 | UInt16(p[1])
        let destinationPort = UInt16(p[2]) << 8 | UInt16(p[3])
        let data = Data(p[8..<min(p.count, Int(p[4]) << 8 | Int(p[5]))])
        if destinationPort == 67 {
            dhcp([UInt8](data))
        } else if destination == Self.gateway, destinationPort == 53 {
            dns(data, port: sourcePort)
        } else if destination == Self.gateway, let handler = lock.withLock({ inbound[destinationPort] }) {
            handler(data)
        } else {
            relay(data, from: sourcePort, to: destination, port: destinationPort)
        }
    }

    // MARK: - DHCP

    private func dhcp(_ p: [UInt8]) {
        guard p.count >= 240, p[0] == 1, p[236..<240] == [99, 130, 83, 99] else { return }
        var kind: UInt8?
        var i = 240
        while i + 1 < p.count, p[i] != 255 {
            if p[i] == 0 { i += 1; continue }
            let length = Int(p[i + 1])
            if p[i] == 53, length >= 1, i + 2 < p.count { kind = p[i + 2] }
            i += 2 + length
        }
        let answer: UInt8
        switch kind {
        case 1: answer = 2 // discover → offer
        case 3: answer = 5 // request → ack
        default: return
        }
        var reply = [UInt8](repeating: 0, count: 240)
        reply[0] = 2
        reply[1] = 1
        reply[2] = 6
        reply[4..<8] = p[4..<8]       // xid
        reply[10..<12] = p[10..<12]   // flags
        reply[16..<20] = Self.guest[...]
        reply[20..<24] = Self.gateway[...]
        reply[28..<44] = p[28..<44]   // chaddr
        reply[236..<240] = [99, 130, 83, 99]
        reply += [53, 1, answer]
        reply += [54, 4] + Self.gateway
        reply += [51, 4, 0x00, 0x01, 0x51, 0x80] // a day
        reply += [1, 4, 255, 255, 255, 0]
        reply += [3, 4] + Self.gateway
        reply += [6, 4] + Self.gateway
        reply += [255]
        while reply.count < 300 { reply.append(0) }
        send(udp: Data(reply), from: Self.gateway, port: 67, to: [255, 255, 255, 255], port: 68, ethernet: Self.broadcastMAC)
    }

    // MARK: - DNS

    /// Answers host.docker.internal itself, and passes the rest to the Mac's own DNS server, so names
    /// resolve as they do on the Mac (VPN and corporate DNS included).
    private func dns(_ query: Data, port: UInt16) {
        if let answer = Self.hostAnswer(query) {
            send(udp: answer, from: Self.gateway, port: 53, to: Self.guest, port: port)
            return
        }
        Thread.detachNewThread { [self] in
            for server in Self.nameservers() {
                guard let s = Self.udpSocket(to: server, port: 53) else { continue }
                defer { Darwin.close(s) }
                var tv = timeval(tv_sec: 4, tv_usec: 0)
                setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
                _ = query.withUnsafeBytes { Darwin.send(s, $0.baseAddress!, query.count, 0) }
                var buffer = [UInt8](repeating: 0, count: 65536)
                let n = recv(s, &buffer, buffer.count, 0)
                if n > 0 {
                    send(udp: Data(buffer[0..<n]), from: Self.gateway, port: 53, to: Self.guest, port: port)
                    return
                }
            }
        }
    }

    static func nameservers() -> [String] {
        let conf = (try? String(contentsOfFile: "/etc/resolv.conf", encoding: .utf8)) ?? ""
        let servers = conf.split(separator: "\n").compactMap { line -> String? in
            let parts = line.split(whereSeparator: \.isWhitespace)
            return parts.count >= 2 && parts[0] == "nameserver" ? String(parts[1]) : nil
        }
        return servers.isEmpty ? ["1.1.1.1"] : servers
    }

    /// An A record for the Mac's names, or nil for any other question.
    static func hostAnswer(_ query: Data) -> Data? {
        let q = [UInt8](query)
        guard q.count > 12 else { return nil }
        var labels: [String] = []
        var i = 12
        while i < q.count, q[i] != 0 {
            let length = Int(q[i])
            guard length < 64, i + 1 + length <= q.count else { return nil }
            labels.append(String(decoding: q[(i + 1)..<(i + 1 + length)], as: UTF8.self))
            i += 1 + length
        }
        guard i + 5 <= q.count, hostNames.contains(labels.joined(separator: ".").lowercased()) else { return nil }
        let questionEnd = i + 5
        let isA = q[i + 1] == 0 && q[i + 2] == 1
        var reply = Array(q[0..<2]) + [0x81, 0x80, 0, 1, 0, isA ? 1 : 0, 0, 0, 0, 0]
        reply += q[12..<questionEnd]
        if isA { reply += [0xC0, 0x0C, 0, 1, 0, 1, 0, 0, 0, 60, 0, 4] + mac }
        return Data(reply)
    }

    // MARK: - UDP

    /// Sends the guest's datagram from a socket on the Mac, one per flow, and relays what comes back.
    private func relay(_ data: Data, from sourcePort: UInt16, to destination: [UInt8], port: UInt16) {
        let key = "\(sourcePort)>\(destination.map(String.init).joined(separator: ".")):\(port)"
        let existing = lock.withLock { flows[key] }
        let s: Int32
        if let existing {
            s = existing
        } else {
            let address = destination == Self.mac ? "127.0.0.1" : destination.map(String.init).joined(separator: ".")
            guard let new = Self.udpSocket(to: address, port: port) else { return }
            s = new
            lock.withLock { flows[key] = s }
            Thread.detachNewThread { [self] in
                var tv = timeval(tv_sec: 1, tv_usec: 0)
                setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
                var buffer = [UInt8](repeating: 0, count: 65536)
                var quiet = 0
                // A flow quiet for a minute goes; DNS and NTP are done in one exchange.
                while !isStopped, quiet < 60 {
                    let n = recv(s, &buffer, buffer.count, 0)
                    if n <= 0 { quiet += 1; continue }
                    quiet = 0
                    send(udp: Data(buffer[0..<n]), from: destination, port: port, to: Self.guest, port: sourcePort)
                }
                lock.withLock {
                    if flows[key] == s { flows[key] = nil; Darwin.close(s) }
                }
            }
        }
        _ = data.withUnsafeBytes { Darwin.send(s, $0.baseAddress!, data.count, 0) }
    }

    /// Sends a datagram from the Mac to a port in the guest; `reply` gets the guest's answers. Returns
    /// a handle for `send(inbound:)` and `close(inbound:)`.
    func open(inbound reply: @escaping @Sendable (Data) -> Void) -> UInt16 {
        lock.withLock {
            repeat { nextPort = nextPort >= 60000 ? 40000 : nextPort + 1 } while inbound[nextPort] != nil
            inbound[nextPort] = reply
            return nextPort
        }
    }

    func send(inbound handle: UInt16, _ data: Data, toGuestPort port: UInt16) {
        send(udp: data, from: Self.gateway, port: handle, to: Self.guest, port: port)
    }

    func close(inbound handle: UInt16) {
        _ = lock.withLock { inbound.removeValue(forKey: handle) }
    }

    static func udpSocket(to address: String, port: UInt16) -> Int32? {
        var hints = addrinfo()
        hints.ai_flags = AI_NUMERICHOST
        hints.ai_socktype = SOCK_DGRAM
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(address, String(port), &hints, &result) == 0, let info = result else { return nil }
        defer { freeaddrinfo(result) }
        let s = socket(info.pointee.ai_family, SOCK_DGRAM, 0)
        guard s >= 0 else { return nil }
        guard connect(s, info.pointee.ai_addr, info.pointee.ai_addrlen) == 0 else {
            Darwin.close(s)
            return nil
        }
        return s
    }

    // MARK: - Frames to the guest

    private func send(udp data: Data, from source: [UInt8], port sourcePort: UInt16, to destination: [UInt8], port destinationPort: UInt16,
                      ethernet: [UInt8]? = nil) {
        let length = 8 + data.count
        var p: [UInt8] = [UInt8(sourcePort >> 8), UInt8(sourcePort & 0xFF), UInt8(destinationPort >> 8), UInt8(destinationPort & 0xFF),
                          UInt8(length >> 8), UInt8(length & 0xFF), 0, 0] // no checksum: optional over IPv4
        p += data
        send(ip: 17, from: source, to: destination, p, ethernet: ethernet)
    }

    /// Wraps a payload in IPv4 and Ethernet, splitting it into fragments when it's over the MTU.
    private func send(ip proto: UInt8, from source: [UInt8], to destination: [UInt8], _ payload: [UInt8], ethernet: [UInt8]? = nil) {
        let mtuPayload = 1480
        let id = UInt16.random(in: 1...UInt16.max)
        var offset = 0
        repeat {
            let size = min(mtuPayload, payload.count - offset)
            let more = offset + size < payload.count
            let total = 20 + size
            let flags: UInt16 = (more ? 0x2000 : 0) | UInt16(offset / 8)
            var header: [UInt8] = [0x45, 0, UInt8(total >> 8), UInt8(total & 0xFF), UInt8(id >> 8), UInt8(id & 0xFF),
                                   UInt8(flags >> 8), UInt8(flags & 0xFF), 64, proto, 0, 0]
            header += source + destination
            let sum = Self.checksum(header)
            header[10] = UInt8(sum >> 8)
            header[11] = UInt8(sum & 0xFF)
            send(ethernet: ethernet ?? lock.withLock({ guestMAC }) ?? Self.broadcastMAC, type: 0x0800, header + payload[offset..<(offset + size)])
            offset += size
        } while offset < payload.count
    }

    private func send(ethernet destination: [UInt8], type: UInt16, _ payload: [UInt8]) {
        let frame = destination + Self.gatewayMAC + [UInt8(type >> 8), UInt8(type & 0xFF)] + payload
        _ = frame.withUnsafeBytes { Darwin.send(fd, $0.baseAddress!, frame.count, 0) }
    }

    static func checksum(_ bytes: [UInt8]) -> UInt16 {
        var sum: UInt32 = 0
        var i = 0
        while i + 1 < bytes.count {
            sum += UInt32(bytes[i]) << 8 | UInt32(bytes[i + 1])
            i += 2
        }
        if i < bytes.count { sum += UInt32(bytes[i]) << 8 }
        while sum >> 16 != 0 { sum = (sum & 0xFFFF) + (sum >> 16) }
        return ~UInt16(sum)
    }
}
