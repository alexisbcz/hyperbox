import Foundation

/// Listing machines, and turning them on and off.
nonisolated extension Command {
    static let list = Command(name: "list", aliases: ["ls"], arguments: "[--running] [--json]",
                              summary: "list machines, their state and address") { args in
        let running = args.flag("--running")
        let json = args.flag("--json")
        try args.done()
        let machines = Target.all().map { ($0, $0.status) }.filter { !running || $0.1 != nil }
        if json {
            try printJSON(machines.map { MachineSummary($0.0, status: $0.1) })
        } else if machines.isEmpty {
            print(running ? "No machines are running." : "No machines yet. Make one in the Hyperbox app.")
        } else {
            printTable(["NAME", "OS", "STATE", "ADDRESS", "CPUS", "MEMORY"], machines.map { target, status in
                [target.name, target.config.os.label, (status?.state ?? .stopped).label, status?.ipAddress ?? "-",
                 "\(target.config.cpuCount)", formatBytes(target.config.memorySize)]
            })
        }
    }

    static let status = Command(name: "status", arguments: "[<machine>] [--json]",
                                summary: "show a machine's state, address and port forwards") { args in
        let json = args.flag("--json")
        guard let name = args.optionalNext() else {
            try args.done()
            var list = Arguments(["--running"] + (json ? ["--json"] : []))
            return try Command.list.run(&list)
        }
        try args.done()
        let target = try Target.find(name)
        let status = target.status
        if json { return try printJSON(MachineSummary(target, status: status)) }
        var rows: [(String, String)] = [
            ("Name", target.name),
            ("State", (status?.state ?? .stopped).label + (status?.progress.map { " (\(Int($0 * 100))%)" } ?? "")),
        ]
        if let message = status?.message { rows.append(("Message", message)) }
        rows.append(("Address", status?.ipAddress ?? (status == nil ? "-" : "waiting for DHCP")))
        rows.append(("Network", target.config.network.enabled ? "connected (NAT)" : "disconnected"))
        for forward in target.config.network.portForwards {
            let error = status?.portForwardErrors?[forward.id.uuidString]
            rows.append(("Forward", "\(forward.allInterfaces ? "*" : "127.0.0.1"):\(forward.label)\(error.map { " (\($0))" } ?? "")"))
        }
        if let pid = status?.pid { rows.append(("Process", "\(pid)")) }
        rows.append(("Bundle", target.url.path))
        for (key, value) in rows { print("\(key.padding(toLength: 9, withPad: " ", startingAt: 0))\(value)") }
    }

    static let start = Command(name: "start", arguments: "<machine> [--wait]", summary: "start a machine",
                               details: """
                               Opens the machine in its own Hyperbox window, which boots it. With --wait, returns once it's \
                               running and, when its network is connected, has an address, so `hyperbox ssh` works next.
                               """) { args in
        let wait = args.flag("--wait", "-w")
        let target = try Target.find(try args.next("a machine"))
        try args.done()
        if let status = target.status {
            if status.state == .stopped || status.state == .error { try target.send(.start) }
        } else {
            try AppLauncher.launch(target.url)
        }
        guard wait else { return }
        let network = target.config.network.enabled
        let status = target.wait(timeout: 180) { status in
            guard let status else { return false }
            if status.state == .error { return true }
            return status.state == .running && (!network || status.ipAddress != nil)
        }
        if status?.state == .error { throw Failure(status?.message ?? "\(target.name) failed to start.") }
        guard status?.state == .running else { throw Failure("\(target.name) didn't start in time.") }
        if network, status?.ipAddress == nil { throw Failure("\(target.name) is running, but hasn't asked DHCP for an address yet.") }
    }

    static let stop = Command(name: "stop", arguments: "<machine> [--wait]",
                              summary: "shut a machine down, as its power button would") { args in
        let wait = args.flag("--wait", "-w")
        let target = try Target.find(try args.next("a machine"))
        try args.done()
        try target.send(.stop)
        guard wait else { return }
        if let status = target.wait(timeout: 120, until: { $0 == nil || $0?.state == .stopped }), status.state != .stopped {
            throw Failure("\(target.name) is still shutting down. `hyperbox kill \(quoted(target.name))` pulls the plug.")
        }
    }

    static let kill = Command(name: "kill", arguments: "<machine>", summary: "stop a machine at once, losing unsaved work") { args in
        let target = try Target.find(try args.next("a machine"))
        try args.done()
        try target.send(.forceStop)
    }

    static let pause = Command(name: "pause", arguments: "<machine>", summary: "freeze a running machine") { args in
        let target = try Target.find(try args.next("a machine"))
        try args.done()
        try target.send(.pause)
    }

    static let resume = Command(name: "resume", arguments: "<machine>", summary: "carry on after pause") { args in
        let target = try Target.find(try args.next("a machine"))
        try args.done()
        try target.send(.resume)
    }

    static let open = Command(name: "open", arguments: "<bundle.hyperbox>",
                              summary: "open a machine bundle from anywhere, and start it") { args in
        let path = try args.next("a .hyperbox bundle")
        try args.done()
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
        guard let config = try? MachineConfig.load(from: url) else { throw Failure("\(path) isn't a Hyperbox machine.") }
        ExternalMachines.add(url)
        if MachineStatus.read(for: config.id) != nil {
            try ControlClient.send(.show, to: config.id)
        } else {
            try AppLauncher.launch(url)
        }
    }
}

/// A machine as `list --json` and `status --json` print it.
nonisolated struct MachineSummary: Encodable {
    var id: UUID
    var name: String
    var os: GuestOS
    var state: MachineState
    var ipAddress: String?
    var cpuCount: Int
    var memorySize: UInt64
    var path: String
    var portForwards: [MachineConfig.PortForward]
    var portForwardErrors: [String: String]?
    var message: String?

    init(_ target: Target, status: MachineStatus?) {
        id = target.id
        name = target.name
        os = target.config.os
        state = status?.state ?? .stopped
        ipAddress = status?.ipAddress
        cpuCount = target.config.cpuCount
        memorySize = target.config.memorySize
        path = target.url.path
        portForwards = target.config.network.portForwards
        portForwardErrors = status?.portForwardErrors
        message = status?.message
    }
}
