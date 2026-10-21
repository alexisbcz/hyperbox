import Foundation

/// The guest's address, SSH, and port forwards.
nonisolated extension Command {
    static let ip = Command(name: "ip", arguments: "<machine> [--wait]",
                            summary: "print the guest's address on the NAT network",
                            details: "With --wait, waits up to two minutes for the guest to get an address from DHCP.") { args in
        let wait = args.flag("--wait", "-w")
        let target = try Target.find(try args.next("a machine"))
        try args.done()
        print(try address(of: target, wait: wait))
    }

    static let ssh = Command(name: "ssh", arguments: "<machine> [ssh options] [-- command]",
                             summary: "SSH into the guest, as the user Hyperbox created when there is one",
                             details: """
                             Runs ssh to the guest's address. Options go to ssh as they are (-L 8000:localhost:8000, -l root); \
                             anything after -- runs in the guest instead of a shell. Each machine's host key is remembered \
                             on its own, so machines that get the same address in turn don't trip ssh's warning.
                             """) { args in
        let target = try Target.find(try args.next("a machine"))
        let options = args.rest()
        let address = try address(of: target, wait: true)
        let user = options.contains("-l") ? nil : target.config.guestUser?.name
        let arguments = ["ssh", "-o", "HostKeyAlias=hyperbox-\(target.id.uuidString.lowercased())", "-o", "StrictHostKeyChecking=accept-new"]
            + options + [(user.map { "\($0)@" } ?? "") + address] + (args.passthrough ?? [])
        // Replaces this process, so ssh owns the terminal.
        let argv = arguments.map { strdup($0) } + [nil]
        execv("/usr/bin/ssh", argv)
        throw Failure("couldn't run ssh: \(String(cString: strerror(errno))).")
    }

    static let forward = Command(name: "forward", arguments: "<machine> <mac-port>[:<guest-port>][/udp] [--all-interfaces]",
                                 summary: "reach a port in the guest through a port on this Mac",
                                 details: """
                                 Listens on 127.0.0.1:<mac-port>, or every interface with --all-interfaces, and passes connections \
                                 on to the guest's <guest-port> (the same port when left out). TCP unless /udp. It's saved, so it \
                                 comes back each time the machine runs, and starts now if it's running.

                                 Examples:
                                   hyperbox forward debian 8022:22     then: ssh -p 8022 127.0.0.1
                                   hyperbox forward debian 8080:80     then: open http://localhost:8080
                                   hyperbox forward debian 5353/udp
                                 """) { args in
        let allInterfaces = args.flag("--all-interfaces", "--all")
        let target = try Target.find(try args.next("a machine"))
        var forward = try parseForward(try args.next("a port, like 8080:80"))
        forward.allInterfaces = allInterfaces
        try args.done()
        var added = forward
        _ = try target.updateConfig { config in
            if let existing = config.network.portForwards.firstIndex(where: { $0.hostPort == forward.hostPort && $0.udp == forward.udp }) {
                // Same Mac port: point it somewhere new rather than fail to listen twice.
                forward.id = config.network.portForwards[existing].id
                config.network.portForwards[existing] = forward
            } else {
                config.network.portForwards.append(forward)
            }
            added = forward
        }
        let host = added.allInterfaces ? "*" : "127.0.0.1"
        guard let status = target.status else {
            return print("Forwarding \(host):\(added.label) when \(target.name) starts.")
        }
        // Give the listener a moment, so a port that's taken is reported here.
        let key = added.id.uuidString
        let settled = target.wait(timeout: 1.5) { $0?.portForwardErrors?[key] != nil }
        if let error = settled?.portForwardErrors?[key] { throw Failure(error) }
        print("Forwarding \(host):\(added.label)" + (status.ipAddress.map { " (guest \($0))" } ?? ", once the guest has an address"))
    }

    static let unforward = Command(name: "unforward", arguments: "<machine> <mac-port>[/udp] | --all",
                                   summary: "stop forwarding a port") { args in
        let all = args.flag("--all")
        let target = try Target.find(try args.next("a machine"))
        let spec = all ? nil : try parseForward(try args.next("a port, or --all"))
        try args.done()
        var removed = 0
        _ = try target.updateConfig { config in
            let before = config.network.portForwards.count
            config.network.portForwards.removeAll { spec == nil || ($0.hostPort == spec!.hostPort && $0.udp == spec!.udp) }
            removed = before - config.network.portForwards.count
        }
        if removed == 0, let spec { throw Failure("\(target.name) doesn't forward \(spec.hostPort)\(spec.udp ? "/udp" : "").") }
    }

    static let forwards = Command(name: "forwards", arguments: "<machine> [--json]", summary: "list a machine's port forwards") { args in
        let json = args.flag("--json")
        let target = try Target.find(try args.next("a machine"))
        try args.done()
        let forwards = target.config.network.portForwards
        if json { return try printJSON(forwards) }
        if forwards.isEmpty { return print("\(target.name) forwards no ports. Add one with `hyperbox forward \(quoted(target.name)) 8080:80`.") }
        let errors = target.status?.portForwardErrors ?? [:]
        printTable(["MAC", "GUEST", "PROTOCOL", "STATUS"], forwards.map { forward in
            ["\(forward.allInterfaces ? "*" : "127.0.0.1"):\(forward.hostPort)", "\(forward.guestPort)", forward.udp ? "UDP" : "TCP",
             errors[forward.id.uuidString] ?? (target.status == nil ? "starts with the machine" : "listening")]
        })
    }

    /// The guest's address, waiting for DHCP when asked to.
    private static func address(of target: Target, wait: Bool) throws -> String {
        guard target.config.network.enabled else { throw Failure("\(target.name)'s network is disconnected. Connect it in its settings.") }
        guard target.status != nil else { throw Failure("\(target.name) isn't running. Start it with `hyperbox start \(quoted(target.name))`.") }
        let status = wait ? target.wait(timeout: 120) { $0 == nil || $0?.ipAddress != nil } : target.status
        guard let ip = status?.ipAddress else {
            throw Failure("\(target.name) doesn't have an address yet\(wait ? "" : "; try --wait"). Is its network set up to use DHCP?")
        }
        return ip
    }

    /// "8080:80", "8080", "5353:53/udp".
    private static func parseForward(_ spec: String) throws -> MachineConfig.PortForward {
        var spec = Substring(spec)
        var udp = false
        if let slash = spec.lastIndex(of: "/") {
            switch spec[spec.index(after: slash)...].lowercased() {
            case "udp": udp = true
            case "tcp": break
            default: throw Failure("\(spec) should end in /tcp or /udp.")
            }
            spec = spec[..<slash]
        }
        let ports = spec.split(separator: ":", omittingEmptySubsequences: false).map { UInt16($0) }
        guard (1...2).contains(ports.count), let host = ports[0], let guest = ports.last!, host > 0, guest > 0 else {
            throw Failure("\(spec) isn't a port forward; write <mac-port>:<guest-port>, like 8080:80.")
        }
        return MachineConfig.PortForward(hostPort: host, guestPort: guest, udp: udp)
    }
}
