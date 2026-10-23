import Foundation

/// Machines made from templates, and setting them up: clone one you've prepared instead of installing again,
/// and run recipes in it instead of clicking through the same settings each time.
nonisolated extension Command {
    static let clone = Command(name: "clone", arguments: "<machine> <new name> [--snapshot <snapshot>]",
                               summary: "make a new machine from another one, or from one of its snapshots",
                               details: """
                               Any machine works as a template: set one up the way you like, then clone it for each \
                               project or experiment, and throw the clones away. Clones are instant and take space only \
                               as they change. The clone is a machine of its own (new id, address and Mac identity), so \
                               both can run at once; it boots fresh, without the original's snapshots or suspended state. \
                               The original must be shut down, unless you clone one of its snapshots.
                               """) { args in
        let snapshotName = try args.option("--snapshot")
        let source = try Target.find(try args.next("a machine"))
        let name = try args.next("a name for the new machine")
        try args.done()
        if Target.all().contains(where: { $0.name.lowercased() == name.lowercased() }) {
            throw Failure("there's already a machine named \(name).")
        }
        let bundle = MachineBundle(url: source.url)
        var snapshot: SnapshotInfo?
        if let snapshotName {
            snapshot = try SnapshotFiles.find(bundle, snapshotName)
        } else if source.status != nil {
            throw Failure("\(source.name) is running, so its disk is changing. Shut it down first, or clone a snapshot: `hyperbox snapshot \(quoted(source.name)) template && hyperbox clone \(quoted(source.name)) \(quoted(name)) --snapshot template`.")
        }
        let safe = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        guard !safe.isEmpty, !safe.hasPrefix(".") else { throw Failure("\(name) can't be a machine's name.") }
        let destination = Paths.machines.appending(path: "\(safe).\(Paths.bundleExtension)")
        guard !FileManager.default.fileExists(atPath: destination.path) else { throw Failure("\(destination.path) already exists.") }
        try MachineCopy.clone(bundle, snapshot: snapshot, to: destination, name: name)
        print("Made \(name) from \(source.name)\(snapshot.map { "'s snapshot \($0.name)" } ?? ""). Start it with `hyperbox start \(quoted(name))`.")
    }

    static let provision = Command(name: "provision", arguments: "<machine> <recipe or script>... [--timeout <seconds>] | --list",
                                   summary: "set a machine up with recipes or your own scripts",
                                   details: """
                                   Runs each recipe in the guest, in order, and stops at the first that fails. A recipe is \
                                   one of Hyperbox's own (`hyperbox provision --list` shows them) or the path to a shell \
                                   script of yours. Scripts run as the desktop user; one with a `# admin: yes` line runs as \
                                   root, with HYPERBOX_USER set to the desktop user. Recipes are safe to run again. Each \
                                   one gets --timeout seconds, 30 minutes unless you say.

                                   Example: hyperbox provision macos dock-autohide homebrew vscode ./my-setup.sh
                                   """) { args in
        let list = args.flag("--list")
        let timeout = try args.option("--timeout").map { value in
            guard let seconds = Double(value), seconds > 0 else { throw Failure("--timeout takes seconds.") }
            return seconds
        } ?? 1800
        if list {
            try args.done()
            let recipes = Recipe.builtIn()
            if recipes.isEmpty { throw Failure("no recipes found beside this hyperbox command.") }
            printTable(["RECIPE", "OS", "WHAT IT DOES"], recipes.map { [$0.name, $0.os?.label ?? "any", $0.summary] })
            return
        }
        let target = try Target.find(try args.next("a machine"))
        let names = args.rest()
        guard !names.isEmpty else { throw Failure("say which recipes to run. `hyperbox provision --list` shows them.") }
        let recipes = try names.map { try Recipe.find($0) }
        for recipe in recipes {
            if let os = recipe.os, os != target.config.os {
                throw Failure("\(recipe.name) is for \(os.label), and \(target.name) runs \(target.config.os.label).")
            }
        }
        for recipe in recipes {
            print("→ \(recipe.name)\(recipe.summary.isEmpty ? "" : ": \(recipe.summary)")")
            // Before the guest's output, which goes straight to the file handles.
            fflush(stdout)
            let script = "/tmp/hyperbox-recipe-\(UUID().uuidString.lowercased()).sh"
            try target.send(.writeFile, ["path": .string(script), "data": .string(Data(recipe.text.utf8).base64EncodedString()), "mode": 0o755])
            let run = recipe.text.hasPrefix("#!") ? quoted(script) : "/bin/sh \(quoted(script))"
            var command = "\(run); status=$?; rm -f \(quoted(script)); exit $status"
            if recipe.admin, let user = target.config.guestUser?.name { command = "HYPERBOX_USER=\(quoted(user)) " + command }
            let result = try target.send(.exec, ["command": .string(command), "admin": .bool(recipe.admin), "timeout": .number(timeout)],
                                         timeout: timeout + 10)
            if let out = result["stdout"]?.string { FileHandle.standardOutput.write(Data(out.utf8)) }
            if let err = result["stderr"]?.string { FileHandle.standardError.write(Data(err.utf8)) }
            let code = Int32(clamping: result["exitCode"]?.int ?? 1)
            if code != 0 { throw Failure("\(recipe.name) failed with status \(code).", status: code) }
        }
    }
}

/// A shell script that sets something up in a guest. The comments at its top say what it does, and how it runs:
///
///     #!/bin/sh
///     # Hides the Dock until the pointer reaches the bottom of the screen.
///     # os: macOS
///     # admin: yes
nonisolated struct Recipe {
    var name: String
    var text: String
    var summary: String
    var os: GuestOS?
    var admin: Bool

    init(name: String, text: String) {
        self.name = name
        self.text = text
        let comments = text.split(separator: "\n").drop { $0.hasPrefix("#!") }.prefix { $0.hasPrefix("#") }
            .map { $0.dropFirst().trimmingCharacters(in: .whitespaces) }
        func value(_ key: String) -> String? {
            comments.first { $0.lowercased().hasPrefix(key + ":") }.map { $0.dropFirst(key.count + 1).trimmingCharacters(in: .whitespaces) }
        }
        summary = comments.first { line in !line.isEmpty && !["os:", "admin:"].contains { line.lowercased().hasPrefix($0) } } ?? ""
        os = value("os").flatMap { os in GuestOS.allCases.first { $0.rawValue.lowercased() == os.lowercased() } }
        admin = ["yes", "true"].contains(value("admin")?.lowercased() ?? "")
    }

    /// Hyperbox's own recipes, in Hyperbox.app/Contents/Resources/recipes.
    static var folder: URL? { AppLauncher.url?.appending(path: "Contents/Resources/recipes") }

    static func builtIn() -> [Recipe] {
        guard let folder, let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { return [] }
        return files.filter { $0.pathExtension == "sh" }.sorted { $0.lastPathComponent < $1.lastPathComponent }.compactMap { url in
            (try? String(contentsOf: url, encoding: .utf8)).map { Recipe(name: url.deletingPathExtension().lastPathComponent, text: $0) }
        }
    }

    /// A script of yours by its path, or one of Hyperbox's by its name.
    static func find(_ name: String) throws -> Recipe {
        let path = (name as NSString).expandingTildeInPath
        if name.contains("/") || FileManager.default.fileExists(atPath: path) {
            guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { throw Failure("can't read \(name).") }
            return Recipe(name: URL(fileURLWithPath: path).lastPathComponent, text: text)
        }
        if let recipe = builtIn().first(where: { $0.name == name }) { return recipe }
        throw Failure("no recipe \(name). `hyperbox provision --list` shows Hyperbox's; a script of yours needs its path, like ./\(name).")
    }
}
