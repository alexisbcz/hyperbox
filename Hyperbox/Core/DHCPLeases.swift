import Foundation

/// The addresses macOS's DHCP server (bootpd) hands out on the NAT network Virtualization sets up.
///
/// bootpd writes each lease to /var/db/dhcpd_leases as a block like this, readable by everyone:
///
///     {
///         name=debian
///         ip_address=192.168.64.3
///         hw_address=1,2:6c:d:a:1f:3
///         identifier=1,2:6c:d:a:1f:3
///         lease=0x6ab56d8e
///     }
///
/// The MAC drops each byte's leading zero, and `lease` is when the lease expires, in seconds since 1970.
nonisolated enum DHCPLeases {
    static let file = URL(fileURLWithPath: "/var/db/dhcpd_leases")

    struct Lease: Equatable, Sendable {
        var ipAddress: String
        var macAddress: [UInt8]
        var expires: Date
    }

    /// The guest's current address: its newest lease that hasn't expired.
    static func address(for macAddress: String, now: Date = Date()) -> String? {
        guard let mac = bytes(macAddress), let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        return parse(text)
            .filter { $0.macAddress == mac && $0.expires > now }
            .max { $0.expires < $1.expires }?
            .ipAddress
    }

    static func parse(_ text: String) -> [Lease] {
        var leases: [Lease] = []
        var fields: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let line = line.trimmingCharacters(in: .whitespaces)
            if line == "{" {
                fields = [:]
            } else if line == "}" {
                // "1," is the hardware type: Ethernet.
                if let ip = fields["ip_address"], let hw = fields["hw_address"], let mac = bytes(hw.drop(while: { $0 != "," }).dropFirst()),
                   let lease = fields["lease"].flatMap({ UInt64($0.replacingOccurrences(of: "0x", with: ""), radix: 16) }) {
                    leases.append(Lease(ipAddress: ip, macAddress: mac, expires: Date(timeIntervalSince1970: TimeInterval(lease))))
                }
            } else if let equals = line.firstIndex(of: "=") {
                fields[String(line[..<equals])] = String(line[line.index(after: equals)...])
            }
        }
        return leases
    }

    /// "02:6c:0d:0a:1f:03" or "2:6c:d:a:1f:3" → six bytes.
    static func bytes(_ mac: some StringProtocol) -> [UInt8]? {
        let parts = mac.split(separator: ":").compactMap { UInt8($0, radix: 16) }
        return parts.count == 6 ? parts : nil
    }
}
