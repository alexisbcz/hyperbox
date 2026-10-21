import Foundation

/// Adds Hyperbox's MCP server to the AI agents on this Mac, by writing each one's own config file, so
/// they can see and use your machines.
///
/// Every entry runs the `hyperbox` command inside this copy of the app with `mcp`. If you move the app,
/// `repair()` points the entries at the new copy the next time Hyperbox opens.
enum AgentIntegrations {
    static let serverName = "hyperbox"

    enum Format {
        /// A JSON file with servers under `key`. `typed` adds `"type": "stdio"`, which some agents want.
        case json(key: String, typed: Bool)
        /// A TOML file with a `[mcp_servers.hyperbox]` table, as Codex and Grok Build use.
        case toml
    }

    struct Agent: Identifiable {
        let id: String
        let name: String
        /// The config file Hyperbox edits.
        let file: URL
        let format: Format
        /// Any of these existing means the agent is on this Mac.
        let signs: [URL]
        /// Claude Code changes its config while running, so its own command edits it when it can.
        var cli: String?
    }

    enum State: Equatable {
        case notFound
        case notAdded
        case added
        /// Added, but for another copy of Hyperbox, which may be gone.
        case elsewhere(String)
    }

    private static var home: URL { FileManager.default.homeDirectoryForCurrentUser }
    private static var appSupport: URL { home.appending(path: "Library/Application Support") }

    static var agents: [Agent] {
        [
            Agent(id: "claude-code", name: "Claude Code", file: home.appending(path: ".claude.json"), format: .json(key: "mcpServers", typed: true),
                  signs: [home.appending(path: ".claude.json"), home.appending(path: ".claude")], cli: "claude"),
            Agent(id: "claude-desktop", name: "Claude", file: appSupport.appending(path: "Claude/claude_desktop_config.json"),
                  format: .json(key: "mcpServers", typed: false), signs: [URL(fileURLWithPath: "/Applications/Claude.app"), appSupport.appending(path: "Claude")]),
            Agent(id: "codex", name: "Codex", file: home.appending(path: ".codex/config.toml"), format: .toml,
                  signs: [home.appending(path: ".codex"), URL(fileURLWithPath: "/Applications/Codex.app")]),
            Agent(id: "cursor", name: "Cursor", file: home.appending(path: ".cursor/mcp.json"), format: .json(key: "mcpServers", typed: true),
                  signs: [home.appending(path: ".cursor"), URL(fileURLWithPath: "/Applications/Cursor.app")]),
            Agent(id: "gemini", name: "Gemini CLI", file: home.appending(path: ".gemini/settings.json"), format: .json(key: "mcpServers", typed: false),
                  signs: [home.appending(path: ".gemini/settings.json")]),
            // Antigravity moved its file; use the old one where it's still there.
            Agent(id: "antigravity", name: "Antigravity", file: antigravityFile, format: .json(key: "mcpServers", typed: false),
                  signs: [URL(fileURLWithPath: "/Applications/Antigravity.app"), home.appending(path: ".gemini/antigravity"), home.appending(path: ".gemini/config")]),
            Agent(id: "grok", name: "Grok Build", file: home.appending(path: ".grok/config.toml"), format: .toml, signs: [home.appending(path: ".grok")]),
            Agent(id: "vscode", name: "VS Code", file: appSupport.appending(path: "Code/User/mcp.json"), format: .json(key: "servers", typed: true),
                  signs: [appSupport.appending(path: "Code/User")]),
        ]
    }

    private static var antigravityFile: URL {
        let old = home.appending(path: ".gemini/antigravity/mcp_config.json")
        return FileManager.default.fileExists(atPath: old.path) ? old : home.appending(path: ".gemini/config/mcp_config.json")
    }

    /// The command every entry runs.
    static var command: String { CommandLineTool.bundled.path }

    /// For agents Hyperbox doesn't know: the usual `mcpServers` JSON.
    static var snippet: String {
        """
        {
          "mcpServers": {
            "hyperbox": {
              "command": "\(command)",
              "args": ["mcp"]
            }
          }
        }
        """
    }

    // MARK: - State

    static func state(of agent: Agent) -> State {
        let fm = FileManager.default
        guard let entry = installedCommand(agent) else {
            return agent.signs.contains { fm.fileExists(atPath: $0.path) } ? .notAdded : .notFound
        }
        return entry == command ? .added : .elsewhere(entry)
    }

    /// The command of the agent's `hyperbox` entry, if it has one.
    static func installedCommand(_ agent: Agent) -> String? {
        guard let data = try? Data(contentsOf: agent.file) else { return nil }
        switch agent.format {
        case .json(let key, _):
            let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let servers = root?[key] as? [String: Any]
            return (servers?[serverName] as? [String: Any])?["command"] as? String
        case .toml:
            let lines = TOML.table(in: String(decoding: data, as: UTF8.self))
            return lines.lazy.compactMap(TOML.command).first
        }
    }

    // MARK: - Changing

    static func add(_ agent: Agent) async throws {
        if let cli = agent.cli, let tool = Self.tool(cli) {
            // Replace rather than fail when there's an old entry.
            _ = try? await Shell.run(tool, ["mcp", "remove", "--scope", "user", serverName])
            try await Shell.run(tool, ["mcp", "add", "--scope", "user", serverName, "--", command, "mcp"])
            return
        }
        try edit(agent, adding: true)
    }

    static func remove(_ agent: Agent) async throws {
        if let cli = agent.cli, let tool = Self.tool(cli) {
            try await Shell.run(tool, ["mcp", "remove", "--scope", "user", serverName])
            return
        }
        try edit(agent, adding: false)
    }

    /// Points entries left by a copy of Hyperbox that's gone (moved, renamed, deleted) at this one.
    /// Entries for another copy that still exists stay: that may be a second install on purpose.
    static func repair() async {
        for agent in agents {
            guard case .elsewhere(let old) = state(of: agent), !FileManager.default.fileExists(atPath: old),
                  old.hasSuffix(".app/Contents/Resources/bin/hyperbox") else { continue }
            try? await add(agent)
        }
    }

    private static func edit(_ agent: Agent, adding: Bool) throws {
        let fm = FileManager.default
        let existing = try? Data(contentsOf: agent.file)
        let new: Data
        switch agent.format {
        case .json(let key, let typed):
            var root: [String: Any] = [:]
            if let existing, !existing.isEmpty {
                guard let parsed = (try? JSONSerialization.jsonObject(with: existing)) as? [String: Any] else {
                    throw ControlError("\(agent.file.path) isn't plain JSON (it may have comments), so Hyperbox left it alone. Add the snippet below to it yourself.")
                }
                root = parsed
            }
            var servers = root[key] as? [String: Any] ?? [:]
            if adding {
                var entry: [String: Any] = ["command": command, "args": ["mcp"]]
                if typed { entry["type"] = "stdio" }
                servers[serverName] = entry
            } else {
                servers[serverName] = nil
            }
            root[key] = servers
            new = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .withoutEscapingSlashes])
        case .toml:
            var text = TOML.removingTable(from: String(decoding: existing ?? Data(), as: UTF8.self))
            if adding {
                if !text.isEmpty, !text.hasSuffix("\n\n") { text += text.hasSuffix("\n") ? "\n" : "\n\n" }
                text += "[mcp_servers.\(serverName)]\ncommand = \(TOML.quoted(command))\nargs = [\"mcp\"]\n"
            }
            new = Data(text.utf8)
        }
        if existing == nil, !adding { return }
        try fm.createDirectory(at: agent.file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try new.write(to: agent.file, options: .atomic)
    }

    /// A command on your login shell's PATH.
    private static func tool(_ name: String) -> String? {
        let dirs = (Shell.environment["PATH"] ?? "").split(separator: ":").map(String.init)
            + [home.appending(path: ".local/bin").path, "/opt/homebrew/bin", "/usr/local/bin"]
        return dirs.map { "\($0)/\(name)" }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}

/// Just enough TOML for one `[mcp_servers.hyperbox]` table, leaving the rest of the file as it was.
private enum TOML {
    static let header = "[mcp_servers.\(AgentIntegrations.serverName)]"
    static let subheader = "[mcp_servers.\(AgentIntegrations.serverName)."

    private static func isOurs(_ line: Substring) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        return t == header || t.hasPrefix(subheader)
    }

    private static func isHeader(_ line: Substring) -> Bool {
        line.trimmingCharacters(in: .whitespaces).hasPrefix("[")
    }

    /// The lines of our table and its subtables.
    static func table(in text: String) -> [Substring] {
        var inside = false
        var lines: [Substring] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if isHeader(line) { inside = isOurs(line) }
            if inside { lines.append(line) }
        }
        return lines
    }

    static func removingTable(from text: String) -> String {
        var inside = false
        var kept: [Substring] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if isHeader(line) { inside = isOurs(line) }
            if !inside { kept.append(line) }
        }
        var result = kept.joined(separator: "\n")
        while result.hasSuffix("\n\n\n") { result.removeLast() }
        return result
    }

    static func command(_ line: Substring) -> String? {
        let parts = line.split(separator: "=", maxSplits: 1)
        guard parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces) == "command" else { return nil }
        let value = parts[1].trimmingCharacters(in: .whitespaces)
        guard value.count >= 2, let quote = value.first, quote == "\"" || quote == "'", value.last == quote else { return nil }
        let inner = String(value.dropFirst().dropLast())
        return quote == "'" ? inner : inner.replacingOccurrences(of: "\\\"", with: "\"").replacingOccurrences(of: "\\\\", with: "\\")
    }

    static func quoted(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
