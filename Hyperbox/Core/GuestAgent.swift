import Virtualization

/// Talks to Hyperbox's agent inside the guest, over vsock port `VirtualMachineBuilder.agentPort`.
///
/// One JSON object per line each way. Every request has an `op`; every reply has `ok`, and `error` when
/// it's false. The agents in the guest (a Python script on Linux, `hyperbox-tools` on macOS) answer:
///
///     {"op": "ping"}                                    → {"ok": true, "os": "linux", "version": 1, "ready": Bool}
///     {"op": "exec", "command": String, "admin": Bool, "timeout": Number}
///                                                       → {"ok": true, "exitCode": Int, "stdout": String, "stderr": String}
///     {"op": "writeFile", "path": String, "data": base64, "mode": Int?}  → {"ok": true, "path": String}
///     {"op": "readFile", "path": String}                → {"ok": true, "data": base64}
///     {"op": "getClipboard"}                            → {"ok": true, "text": String?, "changeCount": Int}
///     {"op": "setClipboard", "text": String}            → {"ok": true}
///
/// `ready` is false while a first-boot setup is still running, and the Linux agent adds `setupError` when
/// that setup failed. Going the other way, the Linux agent connects to the host's port 7071 and sends
/// `{"event": "reboot"}` as the guest restarts, since Virtualization stops a Linux guest that reboots;
/// see `LinuxGuest`. `exec` runs `/bin/sh -c command` as the
/// desktop user, or as root when `admin` is true. Paths starting with `~` are the desktop user's home.
enum GuestAgent {
    static func request(_ request: [String: JSONValue], machine: Machine, timeout: TimeInterval = 30) async throws -> JSONValue {
        guard let vm = machine.virtualMachine, let device = vm.socketDevices.first as? VZVirtioSocketDevice else {
            throw ControlError("\(machine.config.name) isn't running.")
        }
        let connection: VZVirtioSocketConnection
        do {
            connection = try await device.connect(toPort: VirtualMachineBuilder.agentPort)
        } catch {
            throw ControlError("Hyperbox's agent isn't running in \(machine.config.name)\(machine.config.os == .macOS ? "; install Hyperbox Tools in the guest" : "") (\(error.localizedDescription)).")
        }
        let fd = dup(connection.fileDescriptor)
        connection.close()
        var line = try JSONEncoder().encode(JSONValue.object(request))
        line.append(0x0A)
        let reply = try await Task.detached { try exchange(fd: fd, line: line, timeout: timeout) }.value
        let value = try JSONDecoder().decode(JSONValue.self, from: reply)
        guard value["ok"]?.bool == true else {
            throw ControlError(value["error"]?.string ?? "The guest refused \(request["op"]?.string ?? "the request").")
        }
        return value
    }

    /// Runs a shell command in the guest; see `ControlMethod.exec`.
    static func exec(_ params: JSONValue, machine: Machine) async throws -> JSONValue {
        guard let command = params["command"]?.string else { throw ControlError("exec needs a command.") }
        let timeout = params["timeout"]?.double ?? 120
        let reply = try await request([
            "op": "exec", "command": .string(command), "admin": .bool(params["admin"]?.bool ?? false), "timeout": .number(timeout),
        ], machine: machine, timeout: timeout + 5)
        return .object([
            "exitCode": reply["exitCode"] ?? .number(-1),
            "stdout": reply["stdout"] ?? .string(""),
            "stderr": reply["stderr"] ?? .string(""),
        ])
    }

    /// Whether the agent answers, and has finished any first-boot setup.
    static func ping(_ machine: Machine) async -> JSONValue? {
        try? await request(["op": "ping"], machine: machine, timeout: 5)
    }

    private nonisolated static func exchange(fd: Int32, line: Data, timeout: TimeInterval) throws -> Data {
        defer { close(fd) }
        var tv = timeval(tv_sec: Int(timeout.rounded(.up)), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        try line.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let n = write(fd, buffer.baseAddress! + offset, buffer.count - offset)
                guard n > 0 else { throw ControlError("Lost the connection to the guest.") }
                offset += n
            }
        }
        var reply = Data()
        var chunk = [UInt8](repeating: 0, count: 65536)
        while !reply.contains(0x0A) {
            let n = read(fd, &chunk, chunk.count)
            guard n > 0 else { throw ControlError(n == 0 ? "The guest closed the connection." : "The guest didn't answer in time.") }
            reply.append(contentsOf: chunk[0..<n])
        }
        return reply.prefix { $0 != 0x0A }
    }
}
