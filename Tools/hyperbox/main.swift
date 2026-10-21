import Foundation

// The `hyperbox` command: lists machines and drives the running ones through their control sockets.

func usage() -> Never {
    print("""
    Usage: hyperbox <command> [arguments]

    Commands:
      list                       list machines and their state
      start <machine>            start a machine
      stop <machine>             shut a machine down
      status <machine>           print a machine's state as JSON
      mcp                        run the MCP server for AI agents, on stdin and stdout

    A machine is its name or its id.
    """)
    exit(0)
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("hyperbox: \(message)\n".utf8))
    exit(1)
}

func machines() -> [(url: URL, config: MachineConfig)] {
    Paths.machineBundles().compactMap { url in (try? MachineConfig.load(from: url)).map { (url, $0) } }
}

func find(_ name: String) -> (url: URL, config: MachineConfig) {
    let all = machines()
    if let match = all.first(where: { $0.config.name == name || $0.config.id.uuidString.lowercased() == name.lowercased() }) { return match }
    if let match = all.first(where: { $0.config.name.lowercased() == name.lowercased() }) { return match }
    fail("no machine named \(name). Try `hyperbox list`.")
}

/// The app this tool is inside: Hyperbox.app/Contents/Resources/bin/hyperbox.
func appURL() -> URL {
    let me = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
    return me.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
}

var arguments = Array(CommandLine.arguments.dropFirst())
guard let command = arguments.first else { usage() }
arguments.removeFirst()

switch command {
case "-h", "--help", "help":
    usage()
case "list", "ls":
    for machine in machines() {
        let state = MachineStatus.read(for: machine.config.id)?.state.label ?? "Stopped"
        print("\(machine.config.name)\t\(machine.config.os.label)\t\(state)")
    }
case "start":
    guard let name = arguments.first else { fail("start needs a machine.") }
    let machine = find(name)
    if MachineStatus.read(for: machine.config.id) != nil {
        _ = try? ControlClient.send(.start, to: machine.config.id)
    } else {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = ["-n", "-a", appURL().path, "--args", "--machine", machine.url.path]
        try p.run()
        p.waitUntilExit()
    }
case "stop":
    guard let name = arguments.first else { fail("stop needs a machine.") }
    do { _ = try ControlClient.send(.stop, to: find(name).config.id) } catch { fail(error.localizedDescription) }
case "status":
    guard let name = arguments.first else { fail("status needs a machine.") }
    do {
        let result = try ControlClient.send(.status, to: find(name).config.id)
        print(String(decoding: try JSONEncoder.machine.encode(result), as: UTF8.self))
    } catch { fail(error.localizedDescription) }
case "mcp":
    MCP.serve()
default:
    fail("unknown command \(command) (try --help)")
}
