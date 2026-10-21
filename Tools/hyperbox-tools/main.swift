import Foundation

// Hyperbox Tools, inside a macOS guest.
//
//     hyperbox-tools agent                 the LaunchAgent: answers Hyperbox on vsock port 7070, as you
//     hyperbox-tools daemon --owner <uid>  the optional LaunchDaemon: runs administrator commands for the agent
//
// `Install Hyperbox Tools.command` sets both up. The protocol is in GuestAgent.swift, in the app.

let arguments = CommandLine.arguments.dropFirst()
switch arguments.first {
case "agent", nil:
    Agent.run()
case "daemon":
    guard let i = arguments.firstIndex(of: "--owner"), i + 1 < arguments.endIndex, let owner = uid_t(arguments[i + 1]) else {
        FileHandle.standardError.write(Data("usage: hyperbox-tools daemon --owner <uid>\n".utf8))
        exit(64)
    }
    Daemon.run(owner: owner)
case "version", "--version":
    print("hyperbox-tools \(Agent.version)")
default:
    FileHandle.standardError.write(Data("usage: hyperbox-tools [agent | daemon --owner <uid> | version]\n".utf8))
    exit(64)
}
