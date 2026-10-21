import AppKit

/// The LaunchAgent: runs in your login session, so its commands run as you and it can reach the clipboard.
enum Agent {
    /// 2 added `append` and `unique` to writeFile, and `offset`/`length` to readFile.
    static let version = 2
    static let port: UInt32 = 7070

    static func run() -> Never {
        // vsock may not be up yet right after login, so keep trying.
        var listener: Int32 = -1
        while listener < 0 {
            do { listener = try LineServer.listenVsock(port: port) } catch {
                log("\(error); trying again")
                sleep(2)
            }
        }
        log("listening on vsock port \(port) as \(NSUserName())")
        let fd = listener
        Thread.detachNewThread { LineServer.serve(fd, handler: handle) }
        // The clipboard wants the main thread.
        RunLoop.main.run()
        exit(0)
    }

    @Sendable static func handle(_ request: Message) -> Message {
        do {
            switch request["op"] as? String {
            case "ping":
                return ["ok": true, "os": "macos", "version": version, "ready": true, "user": NSUserName(), "admin": Daemon.isReachable]
            case "exec":
                return try exec(request)
            case "writeFile":
                return try writeFile(request)
            case "readFile":
                return try readFile(request)
            case "getClipboard":
                return Pasteboard.get().merging(["ok": true]) { $1 }
            case "setClipboard":
                Pasteboard.set(text: request["text"] as? String ?? "")
                return ["ok": true]
            case let op:
                return ["ok": false, "error": "Hyperbox Tools \(version) doesn't know \(op ?? "requests without an op")."]
            }
        } catch {
            return ["ok": false, "error": "\(error)"]
        }
    }

    private static func exec(_ request: Message) throws -> Message {
        guard let command = request["command"] as? String else { throw ToolError("exec needs a command.") }
        let timeout = (request["timeout"] as? Double) ?? 120
        guard request["admin"] as? Bool == true else { return Exec.run(["/bin/sh", "-c", command], timeout: timeout) }
        // Administrator commands go to the LaunchDaemon, if you installed it; otherwise sudo, which works
        // only when it doesn't need a password.
        if let reply = try? LineServer.request(request, path: Daemon.socketPath, timeout: timeout + 5) { return reply }
        var result = Exec.run(["/usr/bin/sudo", "-n", "/bin/sh", "-c", command], timeout: timeout)
        if let stderr = result["stderr"] as? String, stderr.contains("password is required") {
            result["stderr"] = stderr + "Hyperbox Tools can't run administrator commands yet: run Install Hyperbox Tools again and allow them.\n"
        }
        return result
    }

    private static func writeFile(_ request: Message) throws -> Message {
        guard let path = request["path"] as? String else { throw ToolError("writeFile needs a path.") }
        guard let base64 = request["data"] as? String, let data = Data(base64Encoded: base64) else { throw ToolError("writeFile needs base64 data.") }
        var url = resolve(path)
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if request["append"] as? Bool == true, fm.fileExists(atPath: url.path) {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } else {
            if request["unique"] as? Bool == true { url = unique(url) }
            try data.write(to: url)
        }
        if let mode = request["mode"] as? Int { chmod(url.path, mode_t(mode)) }
        return ["ok": true, "path": url.path]
    }

    private static func readFile(_ request: Message) throws -> Message {
        guard let path = request["path"] as? String else { throw ToolError("readFile needs a path.") }
        let url = resolve(path)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        let offset = UInt64(request["offset"] as? Int ?? 0)
        try handle.seek(toOffset: min(offset, size))
        let length = (request["length"] as? Int).map { min(UInt64($0), size - min(offset, size)) } ?? (size - min(offset, size))
        let data = try handle.read(upToCount: Int(length)) ?? Data()
        return ["ok": true, "data": data.base64EncodedString(), "size": size]
    }

    /// `~` is your home, and so is where relative paths start.
    static func resolve(_ path: String) -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        if path == "~" { return home }
        if path.hasPrefix("~/") { return home.appending(path: String(path.dropFirst(2))) }
        if path.hasPrefix("/") { return URL(fileURLWithPath: path) }
        return home.appending(path: path)
    }

    /// "Notes.txt", or "Notes 2.txt" when that's taken, as Finder names copies.
    static func unique(_ url: URL) -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return url }
        let folder = url.deletingLastPathComponent()
        let ext = url.pathExtension
        let stem = url.deletingPathExtension().lastPathComponent
        var n = 2
        while true {
            let candidate = folder.appending(path: ext.isEmpty ? "\(stem) \(n)" : "\(stem) \(n).\(ext)")
            if !fm.fileExists(atPath: candidate.path) { return candidate }
            n += 1
        }
    }
}

/// The general pasteboard, read and written on the main thread.
enum Pasteboard {
    static func get() -> Message {
        let (count, text) = DispatchQueue.main.sync {
            MainActor.assumeIsolated { (NSPasteboard.general.changeCount, NSPasteboard.general.string(forType: .string)) }
        }
        var reply: Message = ["changeCount": count]
        if let text { reply["text"] = text }
        return reply
    }

    static func set(text: String) {
        DispatchQueue.main.sync {
            MainActor.assumeIsolated {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
        }
    }
}
