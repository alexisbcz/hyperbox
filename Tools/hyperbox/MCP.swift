import Foundation

// `hyperbox mcp`: a Model Context Protocol server on stdin and stdout, so AI agents (Claude Code, Codex,
// Cursor, …) can see and use your machines. It speaks JSON-RPC 2.0, one message per line, and drives each
// machine through its control socket, so the app does the work and enforces each machine's Agent control
// setting.
//
// It's dual-era: legacy clients open with `initialize` (2025-11-25 and earlier), modern ones (2026-07-28)
// send their version in every request's `_meta` and may probe with `server/discover`.

nonisolated enum MCP {
    static let modernVersion = "2026-07-28"
    static let legacyVersions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]
    static let versionKey = "io.modelcontextprotocol/protocolVersion"

    static let instructions = """
    Hyperbox runs macOS and Linux virtual machines on this Mac. These tools see a machine's screen and use \
    its own keyboard and mouse, as a person at that machine would, and run shell commands inside it. Each \
    machine is isolated from this Mac. Start with list_machines. To work on a screen: take a screenshot, \
    then click or type using x, y in that screenshot's pixels, then take another screenshot to check the \
    result. Prefer run_command for anything a shell can do; it's faster and more reliable than typing. \
    Take a snapshot before risky changes, so they can be undone with restore_snapshot.
    """

    /// Reads requests until stdin closes. Each request runs on its own thread, so a long command doesn't
    /// hold up the rest; replies go out whole, one per line.
    static func serve() -> Never {
        setvbuf(stdout, nil, _IOFBF, 1 << 16)
        let session = Session()
        let group = DispatchGroup()
        while let line = readLine(strippingNewline: true) {
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            guard let message = try? JSONDecoder().decode(JSONValue.self, from: Data(line.utf8)) else {
                session.send(error: -32700, message: "Parse error: send one JSON-RPC message per line.", id: .null)
                continue
            }
            // A batch, from clients of 2025-03-26.
            let messages = message.array ?? [message]
            for message in messages {
                group.enter()
                DispatchQueue.global().async {
                    session.handle(message)
                    group.leave()
                }
            }
        }
        group.wait()
        exit(0)
    }

    final class Session: @unchecked Sendable {
        private let lock = NSLock()
        /// Screenshot sizes this session handed out, per machine, so clicks are in the pixels the agent saw.
        private var spaces: [UUID: (width: Int, height: Int)] = [:]
        /// Machines this session has already used, for the snapshot taken before an agent's first change.
        private var touched: Set<UUID> = []

        func handle(_ message: JSONValue) {
            guard let method = message["method"]?.string else { return } // A response to us; we never ask.
            let id = message["id"]
            let params = message["params"] ?? .object([:])
            // Notifications (initialized, cancelled, …) need no answer.
            guard let id else { return }
            let requested = params["_meta"]?[MCP.versionKey]?.string
            let modern = requested != nil
            if let requested, requested != MCP.modernVersion, !MCP.legacyVersions.contains(requested) {
                send(error: -32022, message: "Unsupported protocol version", id: id,
                     data: ["supported": .array(([MCP.modernVersion] + MCP.legacyVersions).map { .string($0) }), "requested": .string(requested)])
                return
            }
            do {
                var result: [String: JSONValue]
                switch method {
                case "initialize":
                    let asked = params["protocolVersion"]?.string ?? ""
                    result = [
                        "protocolVersion": .string(MCP.legacyVersions.contains(asked) ? asked : MCP.legacyVersions[0]),
                        "capabilities": ["tools": ["listChanged": false]],
                        "serverInfo": serverInfo,
                        "instructions": .string(MCP.instructions),
                    ]
                case "server/discover":
                    result = [
                        "supportedVersions": .array(([MCP.modernVersion] + MCP.legacyVersions).map { .string($0) }),
                        "capabilities": ["tools": [:]],
                        "instructions": .string(MCP.instructions),
                        "ttlMs": 3_600_000, "cacheScope": "public",
                    ]
                case "ping":
                    result = [:]
                case "tools/list":
                    result = ["tools": .array(Tools.all.map(\.definition))]
                    if modern { result["ttlMs"] = 3_600_000; result["cacheScope"] = "public" }
                case "tools/call":
                    guard let name = params["name"]?.string else { throw RPCError(-32602, "tools/call needs a tool name.") }
                    guard let tool = Tools.all.first(where: { $0.name == name }) else {
                        throw RPCError(-32602, "Unknown tool \(name). Call tools/list to see them.")
                    }
                    let arguments = params["arguments"] ?? .object([:])
                    do {
                        result = ["content": .array(try tool.run(arguments, self).map(\.json)), "isError": false]
                    } catch {
                        // Tool failures go back to the model as results, so it can read them and adjust.
                        result = ["content": [["type": "text", "text": .string(error.localizedDescription)]], "isError": true]
                    }
                default:
                    throw RPCError(-32601, "Method not found: \(method)")
                }
                if modern {
                    result["resultType"] = "complete"
                    result["_meta"] = ["io.modelcontextprotocol/serverInfo": serverInfo]
                }
                send(["jsonrpc": "2.0", "id": id, "result": .object(result)])
            } catch let error as RPCError {
                send(error: error.code, message: error.message, id: id)
            } catch {
                send(error: -32603, message: error.localizedDescription, id: id)
            }
        }

        func space(for id: UUID) -> (width: Int, height: Int)? { lock.withLock { spaces[id] } }
        func setSpace(_ space: (width: Int, height: Int), for id: UUID) { lock.withLock { spaces[id] = space } }

        /// True the first time this session uses a machine.
        func firstTouch(_ id: UUID) -> Bool { lock.withLock { touched.insert(id).inserted } }

        /// Something to tell the agent once, after its next change to the machine.
        private var notes: [UUID: String] = [:]
        func setNote(_ note: String, for id: UUID) { lock.withLock { notes[id] = note } }
        func takeNote(for id: UUID) -> String { lock.withLock { notes.removeValue(forKey: id) ?? "" } }

        func send(error code: Int, message: String, id: JSONValue, data: JSONValue? = nil) {
            var error: [String: JSONValue] = ["code": .number(Double(code)), "message": .string(message)]
            if let data { error["data"] = data }
            send(["jsonrpc": "2.0", "id": id, "error": .object(error)])
        }

        private func send(_ message: JSONValue) {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.withoutEscapingSlashes]
            guard var data = try? encoder.encode(message) else { return }
            data.append(0x0A)
            lock.withLock {
                FileHandle.standardOutput.write(data)
            }
        }

        private var serverInfo: JSONValue {
            ["name": "hyperbox", "title": "Hyperbox", "version": .string(MCP.version)]
        }
    }

    struct RPCError: Error {
        let code: Int
        let message: String
        init(_ code: Int, _ message: String) { self.code = code; self.message = message }
    }

    static var version: String {
        Bundle(url: MCP.appURL)?.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }

    /// The app this tool is inside: Hyperbox.app/Contents/Resources/bin/hyperbox.
    static var appURL: URL {
        var url = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        for _ in 0..<4 { url.deleteLastPathComponent() }
        return url
    }
}

// MARK: - Tool results

nonisolated enum Content {
    case text(String)
    case png(Data)

    var json: JSONValue {
        switch self {
        case .text(let text): ["type": "text", "text": .string(text)]
        case .png(let data): ["type": "image", "data": .string(data.base64EncodedString()), "mimeType": "image/png"]
        }
    }
}

nonisolated struct ToolFailure: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

// MARK: - Tools

nonisolated struct Tool: Sendable {
    let name: String
    let title: String
    let description: String
    /// JSON Schema properties, and which are required.
    let properties: [String: JSONValue]
    let required: [String]
    let readOnly: Bool
    let destructive: Bool
    let run: @Sendable (JSONValue, MCP.Session) throws -> [Content]

    var definition: JSONValue {
        [
            "name": .string(name), "title": .string(title), "description": .string(description),
            "inputSchema": ["type": "object", "properties": .object(properties), "required": .array(required.map { .string($0) })],
            "annotations": ["title": .string(title), "readOnlyHint": .bool(readOnly), "destructiveHint": .bool(destructive), "openWorldHint": false],
        ]
    }
}

nonisolated enum Tools {
    private static let machine: JSONValue = [
        "type": "string",
        "description": "The machine's name or id, from list_machines. Can be left out when exactly one machine is running.",
    ]
    private static let x: JSONValue = ["type": "number", "description": "Pixels from the left edge of your last screenshot of this machine."]
    private static let y: JSONValue = ["type": "number", "description": "Pixels from the top edge of your last screenshot of this machine."]
    private static let modifiers: JSONValue = [
        "type": "array", "items": ["type": "string", "enum": ["command", "shift", "option", "control"]],
        "description": "Keys held down meanwhile. On a Linux guest, command is the Super (Windows) key and option is Alt.",
    ]

    static let all: [Tool] = [
        Tool(name: "list_machines", title: "List Machines",
             description: "Lists the virtual machines in Hyperbox: name, id, operating system, state (Running, Stopped, …), and whether agents may control them. Call this first to find a machine's name.",
             properties: [:], required: [], readOnly: true, destructive: false) { _, _ in
            let lines = Machines.all().map { m in
                let status = MachineStatus.read(for: m.config.id)
                var line = "\(m.config.name) (id \(m.config.id.uuidString.lowercased())): \(m.config.os.label), \(status?.state.label ?? "Stopped")"
                if let ip = status?.ipAddress { line += ", IP \(ip)" }
                if !m.config.agentControl { line += ", agent control OFF" }
                return line
            }
            return [.text(lines.isEmpty ? "There are no machines. Make one in the Hyperbox app." : lines.joined(separator: "\n"))]
        },

        Tool(name: "machine_status", title: "Machine Status",
             description: "A machine's state, IP address, operating system, CPUs, memory and whether agent control is on.",
             properties: ["machine": machine], required: [], readOnly: true, destructive: false) { args, _ in
            let m = try Machines.find(args["machine"]?.string)
            let status = MachineStatus.read(for: m.config.id)
            var lines = [
                "\(m.config.name) (id \(m.config.id.uuidString.lowercased()))",
                "State: \(status?.state.label ?? "Stopped")",
                "OS: \(m.config.os.label)\(m.config.distribution.map { " (\($0))" } ?? "")",
                "CPUs: \(m.config.cpuCount), memory: \(m.config.memorySize >> 30) GB",
                "Agent control: \(m.config.agentControl ? "on" : "off")",
            ]
            if let ip = status?.ipAddress { lines.append("IP address: \(ip)") }
            if let message = status?.message { lines.append("Message: \(message)") }
            if let user = m.config.guestUser { lines.append("Guest user: \(user.name)") }
            return [.text(lines.joined(separator: "\n"))]
        },

        Tool(name: "start_machine", title: "Start Machine",
             description: "Starts a machine, opening Hyperbox if it isn't open, and waits until it's running (up to 60 seconds). The guest OS may still be booting when this returns: take a screenshot to see.",
             properties: ["machine": machine], required: ["machine"], readOnly: false, destructive: false) { args, _ in
            let m = try Machines.find(args["machine"]?.string, running: false)
            if let status = MachineStatus.read(for: m.config.id), status.state == .running {
                return [.text("\(m.config.name) is already running.")]
            }
            if MachineStatus.read(for: m.config.id) != nil {
                _ = try ControlClient.send(.start, to: m.config.id)
            } else {
                // -g: in the background, so the agent's work doesn't pull Hyperbox in front of yours.
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
                p.arguments = ["-g", "-n", "-a", MCP.appURL.path, "--args", "--machine", m.url.path]
                try p.run()
                p.waitUntilExit()
                guard p.terminationStatus == 0 else { throw ToolFailure("Couldn't open Hyperbox at \(MCP.appURL.path).") }
            }
            let deadline = Date().addingTimeInterval(60)
            while Date() < deadline {
                if let status = MachineStatus.read(for: m.config.id) {
                    switch status.state {
                    case .running: return [.text("\(m.config.name) is running.")]
                    case .installing: return [.text("\(m.config.name) is installing its operating system\(status.progress.map { " (\(Int($0 * 100))%)" } ?? ""). Wait, then check machine_status.")]
                    case .error: throw ToolFailure("\(m.config.name) couldn't start: \(status.message ?? "unknown error").")
                    default: break
                    }
                }
                Thread.sleep(forTimeInterval: 0.5)
            }
            return [.text("\(m.config.name) is still starting. Check machine_status in a moment.")]
        },

        Tool(name: "stop_machine", title: "Stop Machine",
             description: "Shuts a machine down, as pressing its power button would: the guest gets to close its apps. With force, pulls the plug instead, losing anything unsaved.",
             properties: ["machine": machine, "force": ["type": "boolean", "description": "Pull the plug instead of asking the guest to shut down."]],
             required: ["machine"], readOnly: false, destructive: true) { args, _ in
            let m = try Machines.find(args["machine"]?.string)
            let force = args["force"]?.bool ?? false
            _ = try ControlClient.send(force ? .forceStop : .stop, to: m.config.id)
            return [.text(force ? "\(m.config.name) is off." : "Asked \(m.config.name) to shut down.")]
        },

        Tool(name: "screenshot", title: "Screenshot",
             description: "Shows a machine's screen as a PNG, scaled to maxWidth pixels wide (1280 unless you ask). Click, move and scroll take x, y in this screenshot's pixels, with (0, 0) at the top left, so take a new screenshot after the screen changes size. Works while the machine's window is in the background.",
             properties: ["machine": machine, "maxWidth": ["type": "integer", "description": "Widest the image may be, in pixels. Default 1280."]],
             required: [], readOnly: true, destructive: false) { args, session in
            let m = try Machines.find(args["machine"]?.string)
            try Machines.checkAgentControl(m)
            let maxWidth = args["maxWidth"]?.int ?? 1280
            let reply = try ControlClient.send(.screenshot, to: m.config.id, params: ["maxWidth": .number(Double(maxWidth))])
            guard let base64 = reply["png"]?.string, let png = Data(base64Encoded: base64),
                  let width = reply["width"]?.int, let height = reply["height"]?.int
            else { throw ToolFailure("\(m.config.name) sent no picture.") }
            session.setSpace((width, height), for: m.config.id)
            var text = "\(m.config.name)'s screen, \(width)×\(height) pixels. Use x from 0 to \(width) and y from 0 to \(height) (top left is 0, 0)."
            if let sw = reply["screenWidth"]?.int, let sh = reply["screenHeight"]?.int, sw != width { text += " The guest's real resolution is \(sw)×\(sh)." }
            return [.png(png), .text(text)]
        },

        pointerTool("click", "Click", "Clicks at x, y with the left mouse button.", button: "left", count: 1),
        pointerTool("double_click", "Double-Click", "Double-clicks at x, y, to open a file or select a word.", button: "left", count: 2),
        pointerTool("right_click", "Right-Click", "Right-clicks at x, y, which usually opens a context menu.", button: "right", count: 1),

        Tool(name: "move_mouse", title: "Move Mouse",
             description: "Moves the machine's pointer to x, y without clicking, to show a tooltip or a hover menu.",
             properties: ["machine": machine, "x": x, "y": y], required: ["x", "y"], readOnly: false, destructive: false) { args, session in
            let m = try Machines.prepare(args, session)
            _ = try ControlClient.send(.moveMouse, to: m.config.id, params: try Machines.point(args, m, session))
            return [.text("Moved the pointer.")]
        },

        Tool(name: "scroll", title: "Scroll",
             description: "Scrolls with the mouse wheel, at x, y when given. deltaY > 0 scrolls the content down (to read further), < 0 up; deltaX > 0 right. Units are wheel notches, about 3 lines each; 5 is a good start.",
             properties: ["machine": machine, "x": x, "y": y,
                          "deltaX": ["type": "number", "description": "Notches right (negative for left)."],
                          "deltaY": ["type": "number", "description": "Notches down (negative for up)."]],
             required: [], readOnly: false, destructive: false) { args, session in
            let m = try Machines.prepare(args, session)
            var params: [String: JSONValue] = ["deltaX": args["deltaX"] ?? 0, "deltaY": args["deltaY"] ?? 0]
            if args["x"] != nil { params.merge(try Machines.point(args, m, session)) { $1 } }
            _ = try ControlClient.send(.scroll, to: m.config.id, params: params)
            return [.text("Scrolled.")]
        },

        Tool(name: "type_text", title: "Type Text",
             description: "Types text on the machine's keyboard, into whatever has focus, as a US keyboard would. A newline presses Return. Click into a field first. For long text, or characters a US keyboard lacks, write a file with run_command instead.",
             properties: ["machine": machine, "text": ["type": "string", "description": "What to type."]],
             required: ["text"], readOnly: false, destructive: false) { args, session in
            let m = try Machines.prepare(args, session)
            guard let text = args["text"]?.string else { throw ToolFailure("type_text needs text.") }
            _ = try ControlClient.send(.type, to: m.config.id, params: ["text": .string(text)], timeout: 30 + Double(text.count) / 10)
            return [.text("Typed \(text.count) characters.\(session.takeNote(for: m.config.id))")]
        },

        Tool(name: "press_key", title: "Press Key",
             description: "Presses one key, with modifiers held: Return, Escape, Tab, arrows, F-keys, or shortcuts like key \"c\" with [\"control\"] to copy on Linux, or [\"command\"] on macOS. Key names: return, enter, tab, space, delete (backspace), forwarddelete, escape, up, down, left, right, home, end, pageup, pagedown, f1–f12, or any single character. \"ctrl+alt+t\" works too.",
             properties: ["machine": machine, "key": ["type": "string", "description": "The key, such as \"return\", \"a\" or \"f5\"."], "modifiers": modifiers],
             required: ["key"], readOnly: false, destructive: false) { args, session in
            let m = try Machines.prepare(args, session)
            guard let key = args["key"]?.string else { throw ToolFailure("press_key needs a key.") }
            _ = try ControlClient.send(.key, to: m.config.id, params: ["key": .string(key), "modifiers": args["modifiers"] ?? []])
            let held = args["modifiers"]?.array?.compactMap(\.string) ?? []
            return [.text("Pressed \((held + [key]).joined(separator: "+")).\(session.takeNote(for: m.config.id))")]
        },

        Tool(name: "run_command", title: "Run Command",
             description: "Runs a shell command (/bin/sh -c) inside the machine and returns its exit code, stdout and stderr. Runs as the machine's desktop user, or as root with admin. Needs Hyperbox's agent in the guest, which Hyperbox installs in machines it set up; on macOS guests install Hyperbox Tools. Use it for anything a shell can do: installing packages, reading files, checking state. Don't start GUI apps or interactive programs that wait for input; they'd hang until the timeout.",
             properties: ["machine": machine, "command": ["type": "string", "description": "The shell command."],
                          "admin": ["type": "boolean", "description": "Run as root (Linux) or an administrator (macOS)."],
                          "timeout": ["type": "number", "description": "Seconds before it's stopped. Default 120."]],
             required: ["command"], readOnly: false, destructive: true) { args, session in
            let m = try Machines.prepare(args, session)
            guard let command = args["command"]?.string else { throw ToolFailure("run_command needs a command.") }
            let timeout = args["timeout"]?.double ?? 120
            let reply = try ControlClient.send(.exec, to: m.config.id, params: [
                "command": .string(command), "admin": .bool(args["admin"]?.bool ?? false), "timeout": .number(timeout),
            ], timeout: timeout + 10)
            var text = "Exit code: \(reply["exitCode"]?.int ?? -1)"
            if let out = reply["stdout"]?.string, !out.isEmpty { text += "\n\nstdout:\n\(out)" }
            if let err = reply["stderr"]?.string, !err.isEmpty { text += "\n\nstderr:\n\(err)" }
            return [.text(text + session.takeNote(for: m.config.id))]
        },

        Tool(name: "list_snapshots", title: "List Snapshots",
             description: "Lists a machine's snapshots: id, name, when it was taken, and whether it includes the running state.",
             properties: ["machine": machine], required: [], readOnly: true, destructive: false) { args, _ in
            let m = try Machines.find(args["machine"]?.string, running: false)
            let snapshots = try Machines.snapshots(m)
            guard !snapshots.isEmpty else { return [.text("\(m.config.name) has no snapshots.")] }
            return [.text(snapshots.map { s in
                "\(s.name) (id \(s.id.uuidString.lowercased())), \(s.created.formatted(date: .abbreviated, time: .standard))\(s.hasState ? ", running state" : "")"
            }.joined(separator: "\n"))]
        },

        Tool(name: "take_snapshot", title: "Take Snapshot",
             description: "Saves a snapshot of a machine, disk and (while running) memory, so restore_snapshot can bring it back exactly. Take one before risky changes.",
             properties: ["machine": machine, "name": ["type": "string", "description": "A name to find it by later."]],
             required: [], readOnly: false, destructive: false) { args, _ in
            let m = try Machines.find(args["machine"]?.string, running: false)
            let name = args["name"]?.string ?? "Agent snapshot \(Date().formatted(date: .abbreviated, time: .shortened))"
            let snapshot = try Machines.takeSnapshot(m, name: name)
            return [.text("Took snapshot “\(snapshot.name)” (id \(snapshot.id.uuidString.lowercased())).")]
        },

        Tool(name: "restore_snapshot", title: "Restore Snapshot",
             description: "Puts a machine back exactly as it was in a snapshot, discarding everything since. Give the snapshot's id or name, from list_snapshots.",
             properties: ["machine": machine, "snapshot": ["type": "string", "description": "The snapshot's id or name."]],
             required: ["snapshot"], readOnly: false, destructive: true) { args, _ in
            let m = try Machines.find(args["machine"]?.string, running: false)
            guard let wanted = args["snapshot"]?.string else { throw ToolFailure("restore_snapshot needs a snapshot id or name.") }
            let snapshots = try Machines.snapshots(m)
            guard let snapshot = snapshots.first(where: { $0.id.uuidString.lowercased() == wanted.lowercased() })
                    ?? snapshots.last(where: { $0.name == wanted }) ?? snapshots.last(where: { $0.name.lowercased() == wanted.lowercased() })
            else { throw ToolFailure("\(m.config.name) has no snapshot “\(wanted)”. list_snapshots shows them.") }
            _ = try ControlClient.send(.restoreSnapshot, to: m.config.id, params: ["id": .string(snapshot.id.uuidString)], timeout: 300)
            return [.text("Restored \(m.config.name) to “\(snapshot.name)”. Take a screenshot to see where it is.")]
        },
    ]

    private static func pointerTool(_ name: String, _ title: String, _ description: String, button: String, count: Int) -> Tool {
        Tool(name: name, title: title,
             description: description + " x, y are pixels in your last screenshot of this machine; take one first.",
             properties: ["machine": machine, "x": x, "y": y, "modifiers": modifiers], required: ["x", "y"], readOnly: false, destructive: false) { args, session in
            let m = try Machines.prepare(args, session)
            var params = try Machines.point(args, m, session)
            params["button"] = .string(button)
            params["count"] = .number(Double(count))
            if let modifiers = args["modifiers"] { params["modifiers"] = modifiers }
            _ = try ControlClient.send(.click, to: m.config.id, params: params)
            return [.text("\(title) at (\(args["x"]?.int ?? 0), \(args["y"]?.int ?? 0)).\(session.takeNote(for: m.config.id))")]
        }
    }
}

// MARK: - Machines

nonisolated enum Machines {
    typealias Entry = (url: URL, config: MachineConfig)

    static func all() -> [Entry] {
        Paths.machineBundles().compactMap { url in (try? MachineConfig.load(from: url)).map { (url, $0) } }
            .sorted { $0.config.created < $1.config.created }
    }

    /// By name or id; with none given, the one running machine. `running` asks that it be running.
    static func find(_ name: String?, running: Bool = true) throws -> Entry {
        let all = all()
        let machine: Entry
        if let name, !name.isEmpty {
            guard let match = all.first(where: { $0.config.name == name || $0.config.id.uuidString.lowercased() == name.lowercased() })
                    ?? all.first(where: { $0.config.name.lowercased() == name.lowercased() })
            else { throw ToolFailure("There's no machine named “\(name)”. Machines: \(all.map(\.config.name).joined(separator: ", ")).") }
            machine = match
        } else {
            let live = all.filter { MachineStatus.read(for: $0.config.id) != nil }
            guard live.count == 1 else {
                throw ToolFailure(live.isEmpty ? "No machine is running. Name one, or start one with start_machine." : "Several machines are running (\(live.map(\.config.name).joined(separator: ", "))); say which.")
            }
            machine = live[0]
        }
        if running, MachineStatus.read(for: machine.config.id) == nil {
            throw ToolFailure("\(machine.config.name) isn't running. Start it with start_machine.")
        }
        return machine
    }

    static func checkAgentControl(_ m: Entry) throws {
        guard m.config.agentControl else {
            throw ToolFailure("Agent control is off for \(m.config.name), so agents can't see its screen, use its keyboard and mouse, or run commands in it. This is the owner's choice; don't try to get around it. If you need this machine, ask them to turn on Agent Control in its settings (the slider icon in the machine's window).")
        }
    }

    /// A machine an agent is about to change: running, allowed, and snapshotted first when the owner asked for that.
    static func prepare(_ args: JSONValue, _ session: MCP.Session) throws -> Entry {
        let m = try find(args["machine"]?.string)
        try checkAgentControl(m)
        if session.firstTouch(m.config.id), snapshotsBeforeSessions {
            let name = "Before agent session, \(Date().formatted(date: .abbreviated, time: .shortened))"
            do {
                _ = try takeSnapshot(m, name: name)
                session.setNote("\n\nHyperbox took the snapshot “\(name)” before your first change, as its owner asked; restore_snapshot undoes everything since.", for: m.config.id)
            } catch {
                session.setNote("\n\nHyperbox tried to take a snapshot before your first change and couldn't: \(error.localizedDescription)", for: m.config.id)
            }
        }
        return m
    }

    /// The app's setting, Settings › Agents › Snapshot before each agent session.
    static var snapshotsBeforeSessions: Bool {
        UserDefaults(suiteName: "dev.alexis.Hyperbox")?.bool(forKey: "agents.snapshotBeforeSession") ?? false
    }

    static func point(_ args: JSONValue, _ m: Entry, _ session: MCP.Session) throws -> [String: JSONValue] {
        guard let x = args["x"]?.double, let y = args["y"]?.double else { throw ToolFailure("Needs x and y, in screenshot pixels.") }
        var params: [String: JSONValue] = ["x": .number(x), "y": .number(y)]
        if let space = session.space(for: m.config.id) {
            params["width"] = .number(Double(space.width))
            params["height"] = .number(Double(space.height))
        }
        return params
    }

    static func snapshots(_ m: Entry) throws -> [SnapshotInfo] {
        try ControlClient.send(.listSnapshots, to: m.config.id).decode([SnapshotInfo].self)
    }

    static func takeSnapshot(_ m: Entry, name: String) throws -> SnapshotInfo {
        try ControlClient.send(.takeSnapshot, to: m.config.id, params: ["name": .string(name)], timeout: 300).decode(SnapshotInfo.self)
    }
}
