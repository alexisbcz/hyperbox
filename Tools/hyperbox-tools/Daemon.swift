import Foundation

/// The optional LaunchDaemon: runs administrator commands for the agent, over a Unix socket only the
/// user who installed it can open, so it doesn't let anyone else in the guest become root.
enum Daemon {
    static let socketPath = "/var/run/hyperbox-tools.sock"

    static var isReachable: Bool { access(socketPath, W_OK) == 0 }

    static func run(owner: uid_t) -> Never {
        let listener: Int32
        do { listener = try LineServer.listenUnix(path: socketPath, owner: owner) } catch {
            log("\(error)")
            exit(1)
        }
        log("running administrator commands for uid \(owner)")
        LineServer.serve(listener) { request in
            guard request["op"] as? String == "exec", let command = request["command"] as? String else {
                return ["ok": false, "error": "The administrator helper only runs commands."]
            }
            return Exec.run(["/bin/sh", "-c", command], timeout: (request["timeout"] as? Double) ?? 120, directory: URL(fileURLWithPath: "/"))
        }
    }
}
