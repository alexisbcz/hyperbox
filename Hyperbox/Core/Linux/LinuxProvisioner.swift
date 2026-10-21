import Virtualization

/// Fetches a Linux cloud image and sets up cloud-init to install a desktop on first boot.
///
/// The bundle it makes boots with `install.kind == .cloudInit` and seed.iso attached; `LinuxGuest`
/// follows the install from there and clears it once the guest has restarted into its desktop.
enum LinuxProvisioner {
    static func create(_ config: inout MachineConfig, entry: CatalogEntry, progress: @escaping MachineFactory.Progress) async throws -> URL {
        guard let distribution = LinuxDistribution.named(entry.id) else { throw ControlError("Hyperbox can't install \(entry.name) yet.") }
        let image = try await cachedImage(distribution, name: entry.name, progress: progress)
        try Task.checkCancellation()

        if config.rosetta, VZLinuxRosettaDirectoryShare.availability == .notInstalled {
            progress("Installing Rosetta…", nil)
            // Not fatal: the machine runs without it, and the guest's setup skips it when it isn't shared.
            try? await VZLinuxRosettaDirectoryShare.installRosetta()
        }

        progress("Setting up \(config.name)…", nil)
        config.install = .init(kind: .cloudInit)
        config.guestUser = CloudInit.makeUser()
        let url = try MachineFactory.createBundle(config)
        do {
            let bundle = MachineBundle(url: url)
            try FileManager.default.removeItem(at: bundle.disk)
            // An APFS clone: instant, and it shares the image's blocks until the guest changes them.
            try FileManager.default.copyItem(at: image, to: bundle.disk)
            try MachineFactory.grow(bundle.disk, to: config.diskSize)
            try await CloudInit.makeSeed(for: config, distribution: distribution, at: bundle.seed)
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
        return url
    }

    /// The distribution's cloud image as a raw disk in `Paths.downloads`, fetched and converted the
    /// first time. Only the raw image is kept, so each image is there once.
    static func cachedImage(_ distribution: LinuxDistribution, name: String, progress: @escaping MachineFactory.Progress) async throws -> URL {
        progress("Looking for \(name)…", nil)
        let remote = try await distribution.image()
        let raw = Paths.downloads.appending(path: remote.deletingPathExtension().lastPathComponent + ".raw")
        if FileManager.default.fileExists(atPath: raw.path) { return raw }

        let qcow2 = Paths.downloads.appending(path: remote.lastPathComponent + ".download")
        progress("Downloading \(name)…", 0)
        try await Download.fetch(remote, to: qcow2) { fraction in
            Task { @MainActor in progress("Downloading \(name)…", fraction.map { $0 * 0.9 }) }
        }
        progress("Preparing the disk…", 0.9)
        let partial = raw.appendingPathExtension("partial")
        do {
            try await Task.detached {
                try QCOW2.convert(qcow2, to: partial) { fraction in
                    Task { @MainActor in progress("Preparing the disk…", 0.9 + fraction * 0.1) }
                }
            }.value
            try FileManager.default.moveItem(at: partial, to: raw)
        } catch {
            try? FileManager.default.removeItem(at: partial)
            throw error
        }
        try? FileManager.default.removeItem(at: qcow2)
        return raw
    }
}
