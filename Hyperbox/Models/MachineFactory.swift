import Foundation

/// Makes new machine bundles.
enum MachineFactory {
    /// Reports what it's doing and how far along it is (0 to 1, nil when it can't tell).
    typealias Progress = @MainActor (String, Double?) -> Void

    /// An empty bundle with a sparse disk: it takes only the space the guest writes.
    static func createBundle(_ config: MachineConfig) throws -> URL {
        let url = Library.newBundleURL(named: config.name)
        let fm = FileManager.default
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        do {
            let bundle = MachineBundle(url: url)
            try createDisk(at: bundle.disk, size: config.diskSize)
            try config.save(to: url)
        } catch {
            try? fm.removeItem(at: url)
            throw error
        }
        return url
    }

    static func createDisk(at url: URL, size: UInt64) throws {
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw ControlError("Couldn't create the disk at \(url.path).")
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.truncate(atOffset: size)
    }

    /// Grows a disk image (it never shrinks), for when a cloud image is smaller than the disk asked for.
    static func grow(_ url: URL, to size: UInt64) throws {
        let current = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? UInt64) ?? 0
        guard size > current else { return }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.truncate(atOffset: size)
    }

    /// A machine that boots an ISO you picked, with nothing set up for you.
    static func createFromISO(_ iso: URL, name: String, cpus: Int, memoryGB: Int, diskGB: Int) throws -> URL {
        var config = MachineConfig(name: name, os: .linux, cpuCount: cpus, memorySize: UInt64(memoryGB) << 30, diskSize: UInt64(diskGB) << 30)
        config.install = .init(kind: .iso, source: iso.path)
        return try createBundle(config)
    }

    /// A machine from the catalog: downloads what it needs and sets up an automatic install.
    static func create(from entry: CatalogEntry, name: String, cpus: Int, memoryGB: Int, diskGB: Int, progress: @escaping Progress) async throws -> URL {
        var config = MachineConfig(name: name, os: entry.os, distribution: entry.id, cpuCount: cpus,
                                   memorySize: UInt64(memoryGB) << 30, diskSize: UInt64(diskGB) << 30)
        switch entry.os {
        case .macOS:
            return try await MacProvisioner.create(&config, ipsw: nil, progress: progress)
        case .linux:
            return try await LinuxProvisioner.create(&config, entry: entry, progress: progress)
        }
    }
}

/// Fetches an IPSW and makes a macOS bundle ready for `MacInstaller`.
enum MacProvisioner {
    /// `ipsw` is a restore image you picked; nil downloads the latest one this Mac supports.
    static func create(_ config: inout MachineConfig, ipsw: URL?, progress: @escaping MachineFactory.Progress) async throws -> URL {
        throw ControlError("macOS machines aren't built yet.")
    }
}
