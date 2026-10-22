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
