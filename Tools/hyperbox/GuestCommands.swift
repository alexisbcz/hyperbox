import Foundation

/// Working inside the guest: commands and the screen. Both need agent control on in the machine's settings.
nonisolated extension Command {
    static let exec = Command(name: "exec", arguments: "<machine> [--admin] [--timeout <seconds>] -- <command>",
                              summary: "run a command in the guest, and exit with its status",
                              details: """
                              Runs the command with /bin/sh in the guest, through Hyperbox's guest agent, as the desktop user, \
                              or as root with --admin. Prints its output and exits with its status. Several words after -- are \
                              quoted for the shell; one is run as it is, so `-- 'ls | wc -l'` pipes in the guest.
                              """) { args in
        let admin = args.flag("--admin")
        let timeout = try args.option("--timeout").map { value in
            guard let seconds = Double(value), seconds > 0 else { throw Failure("--timeout takes seconds.") }
            return seconds
        } ?? 120
        let target = try Target.find(try args.next("a machine"))
        // `hyperbox exec debian uname -a` works too.
        let words = args.passthrough ?? args.rest()
        try args.done()
        guard !words.isEmpty else { throw Failure("missing the command, after --.") }
        let command = words.count == 1 ? words[0] : words.map(quoted).joined(separator: " ")
        let result = try target.send(.exec, ["command": .string(command), "admin": .bool(admin), "timeout": .number(timeout)],
                                     timeout: timeout + 10)
        if let out = result["stdout"]?.string { FileHandle.standardOutput.write(Data(out.utf8)) }
        if let err = result["stderr"]?.string { FileHandle.standardError.write(Data(err.utf8)) }
        let code = Int32(clamping: result["exitCode"]?.int ?? 1)
        if code != 0 { throw Failure("", status: code) }
    }

    static let screenshot = Command(name: "screenshot", arguments: "<machine> <file.png> [--max-width <pixels>]",
                                    summary: "save the guest's screen as a PNG") { args in
        let maxWidth = try args.option("--max-width").map { value in
            guard let width = Int(value), width > 0 else { throw Failure("--max-width takes pixels.") }
            return width
        }
        let target = try Target.find(try args.next("a machine"))
        let path = try args.next("a file to save to")
        try args.done()
        var params: [String: JSONValue] = [:]
        if let maxWidth { params["maxWidth"] = .number(Double(maxWidth)) }
        let result = try target.send(.screenshot, params)
        guard let base64 = result["png"]?.string, let png = Data(base64Encoded: base64) else {
            throw Failure("\(target.name) sent no screenshot.")
        }
        try png.write(to: URL(fileURLWithPath: (path as NSString).expandingTildeInPath))
    }

    static let record = Command(name: "record", arguments: "<machine> start <file.mov> | <machine> stop",
                                summary: "film the guest's screen to a movie",
                                details: """
                                Records the screen at 30 frames a second, with the pointer that agents and `hyperbox` move drawn in, \
                                until `hyperbox record <machine> stop`. The machine's window must be open.
                                """) { args in
        let target = try Target.find(try args.next("a machine"))
        switch try args.next("start or stop") {
        case "start":
            let path = URL(fileURLWithPath: (try args.next("a file to save to") as NSString).expandingTildeInPath).path
            try args.done()
            try target.send(.startRecording, ["path": .string(path)])
        case "stop":
            try args.done()
            let result = try target.send(.stopRecording, timeout: 60)
            print("\(result["path"]?.string ?? ""): \(String(format: "%.1f", result["seconds"]?.double ?? 0)) s")
        case let other:
            throw Failure("record takes start or stop, not \(other).")
        }
    }
}

/// Moving files in and out of a guest, and its screen's size.
nonisolated extension Command {
    static let copy = Command(name: "cp", aliases: ["copy"], arguments: "<from> <to>",
                              summary: "copy files and folders between this Mac and a guest",
                              details: """
                              One side is <machine>:<path>, as with scp; `~` in a guest path is the desktop user's home. \
                              A folder copies with everything in it. Copying to a folder that exists puts the copy inside it.

                              Examples:
                                hyperbox cp ./app.zip macos:~/Desktop/
                                hyperbox cp macos:~/Library/Logs/app.log .
                              """) { args in
        let from = try args.next("what to copy"), to = try args.next("where to copy it")
        try args.done()
        switch (GuestPath(from), GuestPath(to)) {
        case (nil, let guest?):
            try GuestFiles.push(URL(fileURLWithPath: (from as NSString).expandingTildeInPath), to: guest)
        case (let guest?, nil):
            try GuestFiles.pull(guest, to: URL(fileURLWithPath: (to as NSString).expandingTildeInPath))
        case (nil, nil):
            throw Failure("one side needs to be in a machine, as <machine>:<path>.")
        case (_?, _?):
            throw Failure("copy between machines through this Mac, in two steps.")
        }
    }

    static let display = Command(name: "display", arguments: "<machine> [<width>x<height>]",
                                 summary: "show the guest's screen size, or set it in pixels",
                                 details: """
                                 The guest's screen follows its window. This sizes the window so the screen is exactly \
                                 that many pixels, for recordings and screenshots that need a set shape: 2880x1620 is \
                                 16:9 at 1440 × 810 points. It has to fit on this Mac's screen.
                                 """) { args in
        let target = try Target.find(try args.next("a machine"))
        var params: [String: JSONValue] = [:]
        if let size = args.optionalNext() {
            let parts = size.lowercased().split(separator: "x").compactMap { Int($0) }
            guard parts.count == 2 else { throw Failure("give the size as <width>x<height>, like 2880x1620.") }
            params = ["width": .number(Double(parts[0])), "height": .number(Double(parts[1]))]
        }
        try args.done()
        let result = try target.send(.display, params, timeout: 20)
        let width = result["width"]?.int ?? 0, height = result["height"]?.int ?? 0
        print("\(width)x\(height)")
        if let wanted = params["width"]?.int, let tall = params["height"]?.int, wanted != width || tall != height {
            throw Failure("\(target.name)'s screen is still \(width)x\(height); the guest may not offer \(wanted)x\(tall).")
        }
    }
}

/// `<machine>:<path>`, when the part before the colon names a machine and the whole isn't a file here.
nonisolated struct GuestPath {
    let target: Target
    let path: String

    init?(_ argument: String) {
        guard let colon = argument.firstIndex(of: ":"), colon != argument.startIndex,
              !FileManager.default.fileExists(atPath: (argument as NSString).expandingTildeInPath),
              let target = try? Target.find(String(argument[..<colon])) else { return nil }
        self.target = target
        let path = String(argument[argument.index(after: colon)...])
        self.path = path.isEmpty ? "~" : path
    }

    var label: String { "\(target.name):\(path)" }

    /// The path for the guest's shell: quoted, with a leading `~` left for the shell to expand.
    var shell: String { GuestFiles.shellPath(path) }
}

/// Files through the guest's agent, in pieces, so a big one never becomes one huge message.
nonisolated enum GuestFiles {
    static let pieceSize = 4 << 20

    static func shellPath(_ path: String) -> String {
        if path == "~" { return "\"$HOME\"" }
        if path.hasPrefix("~/") { return "\"$HOME\"/" + quoted(String(path.dropFirst(2))) }
        return quoted(path)
    }

    static func push(_ local: URL, to guest: GuestPath) throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: local.path, isDirectory: &isDirectory) else { throw Failure("there's no \(local.path).") }
        let into = try run(guest.target, "test -d \(guest.shell)").exitCode == 0
        guard isDirectory.boolValue else {
            let destination = into || guest.path.hasSuffix("/") ? join(guest.path, local.lastPathComponent) : guest.path
            if guest.path.hasSuffix("/") { try check(run(guest.target, "mkdir -p \(guest.shell)"), "make \(guest.label)") }
            let bytes = try write(local, to: destination, in: guest.target)
            return print("Copied \(local.lastPathComponent) (\(formatBytes(bytes))) to \(guest.target.name):\(destination).")
        }
        // A folder goes as one tar archive, unpacked in the guest.
        let archive = FileManager.default.temporaryDirectory.appending(path: "hyperbox-cp-\(UUID().uuidString).tgz")
        defer { try? FileManager.default.removeItem(at: archive) }
        try tar(["-czf", archive.path, "-C", local.deletingLastPathComponent().path, local.lastPathComponent])
        let remote = "/tmp/hyperbox-cp-\(UUID().uuidString.lowercased()).tgz"
        let bytes = try write(archive, to: remote, in: guest.target)
        // Into a folder that's there, or as the folder named in the path.
        let unpack = into
            ? "tar -xzf \(quoted(remote)) -C \(guest.shell)"
            : "mkdir -p \(guest.shell) && tar -xzf \(quoted(remote)) -C \(guest.shell) --strip-components 1"
        try check(run(guest.target, "\(unpack); status=$?; rm -f \(quoted(remote)); exit $status"), "unpack \(local.lastPathComponent) in \(guest.label)")
        print("Copied \(local.lastPathComponent)/ (\(formatBytes(bytes)) compressed) to \(guest.label).")
    }

    static func pull(_ guest: GuestPath, to local: URL) throws {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: local.path, isDirectory: &isDirectory)
        let name = URL(fileURLWithPath: guest.path).lastPathComponent
        let destination = exists && isDirectory.boolValue ? local.appending(path: name) : local
        guard try run(guest.target, "test -d \(guest.shell)").exitCode == 0 else {
            let bytes = try read(guest.path, from: guest.target, to: destination)
            return print("Copied \(guest.label) (\(formatBytes(bytes))) to \(destination.path).")
        }
        let remote = "/tmp/hyperbox-cp-\(UUID().uuidString.lowercased()).tgz"
        try check(run(guest.target, "cd \(guest.shell) && tar -czf \(quoted(remote)) ."), "pack \(guest.label)")
        let archive = FileManager.default.temporaryDirectory.appending(path: "hyperbox-cp-\(UUID().uuidString).tgz")
        defer { try? FileManager.default.removeItem(at: archive) }
        defer { _ = try? run(guest.target, "rm -f \(quoted(remote))") }
        let bytes = try read(remote, from: guest.target, to: archive)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try tar(["-xzf", archive.path, "-C", destination.path])
        print("Copied \(guest.label)/ (\(formatBytes(bytes)) compressed) to \(destination.path).")
    }

    /// Sends a file in pieces, keeping its permissions. Returns its size.
    private static func write(_ local: URL, to path: String, in target: Target) throws -> UInt64 {
        let handle = try FileHandle(forReadingFrom: local)
        defer { try? handle.close() }
        let mode = (try? FileManager.default.attributesOfItem(atPath: local.path)[.posixPermissions] as? Int) ?? 0o644
        var sent: UInt64 = 0
        repeat {
            let piece = try handle.read(upToCount: pieceSize) ?? Data()
            if piece.isEmpty && sent > 0 { break }
            var params: [String: JSONValue] = ["path": .string(path), "data": .string(piece.base64EncodedString()), "mode": .number(Double(mode))]
            if sent > 0 { params["append"] = true }
            try target.send(.writeFile, params, timeout: 90)
            sent += UInt64(piece.count)
            if piece.count < pieceSize { break }
        } while true
        return sent
    }

    /// Fetches a file in pieces. Returns its size.
    private static func read(_ path: String, from target: Target, to local: URL) throws -> UInt64 {
        FileManager.default.createFile(atPath: local.path, contents: nil)
        let handle = try FileHandle(forWritingTo: local)
        defer { try? handle.close() }
        try handle.truncate(atOffset: 0)
        var offset: UInt64 = 0
        while true {
            let reply = try target.send(.readFile, ["path": .string(path), "offset": .number(Double(offset)), "length": .number(Double(pieceSize))], timeout: 90)
            guard let piece = reply["data"]?.string.flatMap({ Data(base64Encoded: $0) }) else { throw Failure("\(target.name) sent nothing back for \(path).") }
            try handle.write(contentsOf: piece)
            offset += UInt64(piece.count)
            let size = UInt64(max(reply["size"]?.int ?? 0, 0))
            if piece.isEmpty || offset >= size { return offset }
        }
    }

    private static func join(_ folder: String, _ name: String) -> String {
        folder.hasSuffix("/") ? folder + name : folder + "/" + name
    }

    struct Result { var exitCode: Int; var stderr: String }

    private static func run(_ target: Target, _ command: String) throws -> Result {
        let reply = try target.send(.exec, ["command": .string(command), "timeout": 300], timeout: 310)
        return Result(exitCode: reply["exitCode"]?.int ?? 1, stderr: reply["stderr"]?.string ?? "")
    }

    private static func check(_ result: Result, _ what: String) throws {
        guard result.exitCode == 0 else { throw Failure("couldn't \(what): \(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))") }
    }

    private static func tar(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = arguments
        // No AppleDouble ._ files for extended attributes.
        process.environment = ["COPYFILE_DISABLE": "1"]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw Failure("tar failed.") }
    }
}
