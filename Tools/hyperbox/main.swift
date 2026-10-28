import Foundation

// The `hyperbox` command: lists machines and drives the running ones through their control sockets
// (see `ControlMethod`). Each command is a `Command` in one of the *Commands.swift files; add yours to
// this table, in the group it belongs to, and `hyperbox --help` lists it.

let commands: [Command] = [
    // Machines: MachineCommands.swift
    .list, .status, .start, .stop, .kill, .pause, .resume, .open,
    // Network: NetworkCommands.swift
    .ip, .ssh, .forward, .unforward, .forwards,
    // Snapshots: SnapshotCommands.swift
    .snapshot, .snapshots, .restore, .deleteSnapshot,
    // In the guest: GuestCommands.swift
    .exec, .copy, .screenshot, .record, .display,
    // The screen, on local models: ScreenCommands.swift
    .check, .wait, .describe, .models, .modelServer,
    // Templates and setup: SetupCommands.swift
    .clone, .provision,
    // For AI agents: MCP.swift
    .mcp,
    // Docker: Containers.swift
    .containers,
]

func usage() -> String {
    let listed = commands.filter { !$0.hidden }
    let width = listed.map(\.name.count).max() ?? 0
    return """
    Usage: hyperbox <command> [arguments]

    Run and reach Hyperbox's virtual machines from a terminal.

    Commands:
    \(listed.map { "  \($0.name.padding(toLength: width + 2, withPad: " ", startingAt: 0))\($0.summary)" }.joined(separator: "\n"))

    A machine is its name, its id (or the start of it), or the path to its .hyperbox bundle.
    Run `hyperbox help <command>` for a command's arguments.

    Examples:
      hyperbox start debian --wait && hyperbox ssh debian
      hyperbox forward debian 8080:80 && open http://localhost:8080
      hyperbox exec debian -- uname -a
    """
}

func help(_ command: Command) -> String {
    var text = "Usage: \(command.usage)\n\n\(command.summary.prefix(1).uppercased() + command.summary.dropFirst())."
    if !command.details.isEmpty { text += "\n\n\(command.details)" }
    if !command.aliases.isEmpty { text += "\n\nAlso: \(command.aliases.joined(separator: ", "))" }
    return text
}

func lookup(_ name: String) -> Command? {
    commands.first { $0.name == name || $0.aliases.contains(name) }
}

var arguments = Array(CommandLine.arguments.dropFirst())
guard let name = arguments.first else {
    print(usage())
    exit(0)
}
arguments.removeFirst()

switch name {
case "-h", "--help", "help":
    if let topic = arguments.first {
        guard let command = lookup(topic) else {
            printError("no command \(topic). Run `hyperbox --help` for the list.")
            exit(1)
        }
        print(help(command))
    } else {
        print(usage())
    }
case "-v", "--version", "version":
    print("hyperbox \(AppLauncher.url.flatMap { Bundle(url: $0)?.infoDictionary?["CFBundleShortVersionString"] as? String } ?? "(development)")")
default:
    guard let command = lookup(name) else {
        printError("no command \(name). Run `hyperbox --help` for the list.")
        exit(1)
    }
    if arguments.prefix(while: { $0 != "--" }).contains(where: { $0 == "--help" || $0 == "-h" }) {
        print(help(command))
        exit(0)
    }
    var args = Arguments(arguments)
    do {
        try command.run(&args)
    } catch let failure as Failure {
        if let message = failure.errorDescription, !message.isEmpty { printError(message) }
        exit(failure.status)
    } catch {
        printError(error.localizedDescription)
        exit(1)
    }
}
