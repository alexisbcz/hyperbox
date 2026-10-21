import Foundation

/// Where Hyperbox keeps things, shared by the app and the `hyperbox` command.
nonisolated enum Paths {
    static let bundleExtension = "hyperbox"

    /// ~/Library/Application Support/Hyperbox
    static var support: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support/Hyperbox")
    }

    /// The machines Hyperbox lists, each a `<name>.hyperbox` folder.
    static var machines: URL { support.appending(path: "Machines") }

    /// Downloaded installers and images, kept so a second machine doesn't fetch them again.
    static var downloads: URL { support.appending(path: "Downloads") }

    /// ~/.hyperbox: short enough for Unix socket paths, which can't pass 104 bytes.
    static var home: URL { FileManager.default.homeDirectoryForCurrentUser.appending(path: ".hyperbox") }

    /// Where each running machine says it's running, and listens for commands.
    static var run: URL { home.appending(path: "run") }

    static func socket(for id: UUID) -> URL { run.appending(path: "\(id.uuidString.lowercased()).sock") }
    static func status(for id: UUID) -> URL { run.appending(path: "\(id.uuidString.lowercased()).json") }

    /// Every machine bundle in the library, plus any opened from elsewhere and remembered.
    static func machineBundles() -> [URL] {
        let fm = FileManager.default
        var urls = (try? fm.contentsOfDirectory(at: machines, includingPropertiesForKeys: nil)) ?? []
        urls = urls.filter { $0.pathExtension == bundleExtension }
        for path in ExternalMachines.paths where fm.fileExists(atPath: path) {
            let url = URL(fileURLWithPath: path)
            if !urls.contains(url) { urls.append(url) }
        }
        return urls
    }

    static func ensure(_ url: URL) {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        // ~/.hyperbox holds the sockets that drive machines and Docker: only you get in.
        if url.path.hasPrefix(home.path) {
            chmod(home.path, 0o700)
            chmod(url.path, 0o700)
        }
    }
}

/// Machines opened from outside the library (a bundle on an external disk, say), so they stay listed.
nonisolated enum ExternalMachines {
    private static var file: URL { Paths.support.appending(path: "external.json") }

    static var paths: [String] {
        get { (try? JSONDecoder().decode([String].self, from: Data(contentsOf: file))) ?? [] }
        set {
            Paths.ensure(Paths.support)
            try? JSONEncoder().encode(newValue).write(to: file, options: .atomic)
        }
    }

    static func add(_ url: URL) {
        guard !url.path.hasPrefix(Paths.machines.path), !paths.contains(url.path) else { return }
        paths.append(url.path)
    }

    static func remove(_ url: URL) { paths.removeAll { $0 == url.path } }
}
