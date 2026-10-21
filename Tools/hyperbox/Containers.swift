import Foundation

// `hyperbox containers …`: the container engine behind ~/.hyperbox/docker.sock.

let containersUsage = """
Usage: hyperbox containers <command>

Commands:
  setup [--no-switch]   create the ‘hyperbox’ Docker context and switch to it
  unsetup               switch Docker back to the context you used before
  status                the engine's state, memory and forwarded ports
  start                 start the engine and wait for Docker
  stop                  shut the engine down (it starts again on the next docker command)

The engine starts on its own when a docker command connects, and stops after
a few idle minutes with no containers running.
"""

func containers(_ arguments: [String]) {
    switch arguments.first {
    case "setup":
        ensureEngineAgent()
        do {
            try DockerContext.setUp(use: !arguments.contains("--no-switch"))
        } catch { fail(error.localizedDescription) }
        print(DockerContext.isCurrent
              ? "docker now uses Hyperbox (context ‘\(DockerContext.name)’; it was ‘\(DockerContext.previous)’)."
              : "Created the ‘\(DockerContext.name)’ context. Use it with: docker context use \(DockerContext.name)")
        print("Try: docker run --rm hello-world\n")
        print(DockerContext.environmentHelp)
    case "unsetup":
        do { try DockerContext.restore() } catch { fail(error.localizedDescription) }
        print("docker uses ‘\(DockerContext.current)’ again.")
    case "status":
        guard let status = EngineStatus.read() else {
            print("Stopped. It starts on the next docker command, or with `hyperbox containers start`.")
            print("Socket: \(EnginePaths.socket.path)\(EngineAgent.isLoaded ? "" : " (not listening: run `hyperbox containers setup`)")")
            return
        }
        print(status.state.label + (status.message.map { ": \($0)" } ?? "") + (status.progress.map { String(format: " (%.0f%%)", $0 * 100) } ?? ""))
        if let used = status.memoryUsed {
            print("Memory: \(bytes(used)) used" + (status.memoryLimit.map { ", \(bytes($0)) allowed" } ?? ""))
        }
        if let boot = status.bootSeconds { print(String(format: "Booted in %.1f s", boot)) }
        if let running = status.runningContainers { print("Containers running: \(running)") }
        if !status.forwardedPorts.isEmpty { print("Forwarded to localhost: \(status.forwardedPorts.joined(separator: ", "))") }
        if !status.blockedPorts.isEmpty { print("In use on the Mac, not forwarded: \(status.blockedPorts.joined(separator: ", "))") }
        print("Docker context: \(DockerContext.current)")
    case "start":
        ensureEngineAgent()
        let started = Date()
        print("Starting the engine…")
        do { try ContainerEngine.ping() } catch { fail(error.localizedDescription) }
        print(String(format: "Docker is ready (%.1f s).", Date().timeIntervalSince(started)))
    case "stop":
        guard let status = EngineStatus.read() else { print("The engine isn't running."); return }
        kill(status.pid, SIGTERM)
        for _ in 0..<300 where EngineStatus.read() != nil { usleep(100_000) }
        print(EngineStatus.read() == nil ? "Stopped." : "Still stopping; check `hyperbox containers status`.")
    default:
        print(containersUsage)
    }
}

/// Makes sure launchd listens on the socket, for when the app hasn't been opened since it was installed.
func ensureEngineAgent() {
    let executable = appURL().appending(path: "Contents/MacOS/Hyperbox").path
    guard FileManager.default.isExecutableFile(atPath: executable) else {
        if !EngineAgent.isLoaded { fail("Open Hyperbox once, so it can set up the container engine.") }
        return
    }
    do { try EngineAgent.register(executable: executable) } catch { fail(error.localizedDescription) }
}

func bytes(_ count: UInt64) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .memory)
}
