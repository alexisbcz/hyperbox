import Foundation

/// One Parallels expanding image (`.hds`). Follows docs/interop/parallels.rst in QEMU: a 64-byte header,
/// then a block allocation table (BAT) giving each cluster's place in the file, or zero for none.
nonisolated final class ParallelsImage: DiskImage {
    let file: ImageFile
    let size: UInt64
    let clusterSize: Int
    /// The snapshot below this one, which clusters this one never wrote come from.
    let parent: DiskImage?
    private let bat: [UInt32]
    /// BAT entries count 512-byte sectors in old images, clusters in "Ext" ones.
    private let multiplier: UInt64

    init(_ url: URL, parent: DiskImage? = nil) throws {
        file = try ImageFile(url)
        self.parent = parent
        let name = url.lastPathComponent
        let header = try file.bytes(at: 0, count: 64)
        let magic = String(decoding: header[0..<16], as: UTF8.self)
        guard magic == "WithoutFreeSpace" || magic == "WithouFreSpacExt" else { throw ControlError("\(name) isn't a Parallels disk image.") }
        guard header.le(16, as: UInt32.self) == 2 else { throw ControlError("\(name) is a Parallels image version Hyperbox can't read.") }
        let tracks = UInt64(header.le(28, as: UInt32.self))
        guard tracks > 0 else { throw ControlError("\(name) is damaged: its clusters are empty.") }
        clusterSize = Int(tracks * 512)
        let entries = Int(header.le(32, as: UInt32.self))
        var sectors = header.le(36, as: UInt64.self)
        if magic == "WithoutFreeSpace" { sectors &= 0xFFFF_FFFF }
        size = sectors * 512
        multiplier = magic == "WithouFreSpacExt" ? tracks : 1
        let empty = header.le(52, as: UInt32.self) & 1 != 0
        let table = try file.bytes(at: 64, count: entries * 4)
        bat = empty ? [] : (0..<entries).map { table.le($0 * 4, as: UInt32.self) }
    }

    func read(at offset: UInt64, into buffer: UnsafeMutableRawBufferPointer) throws -> Bool {
        let index = Int(offset / UInt64(clusterSize))
        guard index < bat.count, bat[index] != 0 else {
            guard let parent, offset < parent.size else { return false }
            return try parent.readRange(at: offset, into: buffer)
        }
        let host = UInt64(bat[index]) * multiplier * 512 + offset % UInt64(clusterSize)
        try file.read(at: host, into: buffer)
        return true
    }
}

/// A Parallels disk: the `.hdd` folder, whose DiskDescriptor.xml lists its images. Each snapshot adds an
/// image holding only what changed; reading the newest falls through to older ones. Very old disks are
/// also split into several storages, each covering a range of sectors.
nonisolated final class ParallelsDisk: DiskImage {
    let size: UInt64
    let clusterSize: Int
    private let composite: CompositeImage

    init(_ folder: URL) throws {
        let descriptor = folder.appending(path: "DiskDescriptor.xml")
        guard FileManager.default.fileExists(atPath: descriptor.path) else {
            // A lone image, with no descriptor.
            let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            guard let image = files.first(where: { $0.pathExtension == "hds" }) else {
                throw ControlError("\(folder.lastPathComponent) has no disk image in it.")
            }
            let single = try ParallelsImage(image)
            composite = CompositeImage([(0, single.size, single)])
            size = composite.size
            clusterSize = composite.clusterSize
            return
        }
        let xml = try XMLDocument(contentsOf: descriptor)
        func text(_ node: XMLNode, _ path: String) -> String? {
            (try? node.nodes(forXPath: path))?.first?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if let engine = text(xml, "//Encryption/Engine"), !engine.isEmpty, engine.contains(where: { $0 != "0" && $0 != "{" && $0 != "}" && $0 != "-" }) {
            throw ControlError("\(folder.lastPathComponent) is encrypted. Decrypt the machine in Parallels first.")
        }

        // The current state is the top of the snapshot chain; each snapshot knows its parent.
        var parents: [String: String] = [:]
        for shot in (try? xml.nodes(forXPath: "//Snapshots/Shot")) ?? [] {
            if let guid = text(shot, "GUID"), let parent = text(shot, "ParentGUID") { parents[guid.lowercased()] = parent.lowercased() }
        }
        let top = text(xml, "//Snapshots/TopGUID")?.lowercased()

        var storages: [(UInt64, UInt64, DiskImage)] = []
        for storage in try xml.nodes(forXPath: "//StorageData/Storage") {
            let start = UInt64(text(storage, "Start") ?? "0") ?? 0
            let end = UInt64(text(storage, "End") ?? "0") ?? 0
            var images: [String: (type: String, file: URL)] = [:]
            for image in (try? storage.nodes(forXPath: "Image")) ?? [] {
                guard let guid = text(image, "GUID"), let file = text(image, "File") else { continue }
                let url = file.hasPrefix("/") ? URL(fileURLWithPath: file) : folder.appending(path: file)
                images[guid.lowercased()] = (text(image, "Type") ?? "Compressed", url)
            }
            var chain: [String] = []
            var guid = top ?? images.keys.first
            while let current = guid, let _ = images[current], !chain.contains(current) {
                chain.append(current)
                guid = parents[current]
            }
            if chain.isEmpty, let only = images.keys.first { chain = [only] }
            guard !chain.isEmpty else { throw ControlError("\(folder.lastPathComponent) lists no images.") }
            // Open from the oldest up, so each image gets the one below it.
            var image: DiskImage?
            for guid in chain.reversed() {
                let (type, file) = images[guid]!
                guard FileManager.default.fileExists(atPath: file.path) else { throw ControlError("\(file.lastPathComponent) is missing from \(folder.lastPathComponent).") }
                image = type.lowercased() == "plain" ? try RawImage(file) : try ParallelsImage(file, parent: image)
            }
            storages.append((start * 512, end * 512, image!))
        }
        guard !storages.isEmpty else { throw ControlError("\(folder.lastPathComponent) lists no storage.") }
        let sectors = UInt64(text(xml, "//Disk_Parameters/Disk_size") ?? "") ?? 0
        composite = CompositeImage(storages, size: max(sectors * 512, storages.map(\.1).max() ?? 0))
        size = composite.size
        clusterSize = composite.clusterSize
    }

    func read(at offset: UInt64, into buffer: UnsafeMutableRawBufferPointer) throws -> Bool {
        try composite.read(at: offset, into: buffer)
    }
}


/// A Parallels machine (`.pvm`): its name, processors and memory from config.pvs, and its boot disk.
nonisolated struct ParallelsMachine {
    var name: String
    var cpuCount: Int?
    var memoryMB: UInt64?
    var disk: URL

    init(_ bundle: URL) throws {
        let config = bundle.appending(path: "config.pvs")
        guard FileManager.default.fileExists(atPath: config.path) else { throw ControlError("\(bundle.lastPathComponent) has no config.pvs; is it a Parallels machine?") }
        let xml = try XMLDocument(contentsOf: config)
        func text(_ node: XMLNode, _ path: String) -> String? {
            (try? node.nodes(forXPath: path))?.first?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // Parallels' guest types: 7 macOS, 8 Windows, 9 Linux.
        let osType = text(xml, "//OsType")
        let hasMacVM = ((try? FileManager.default.contentsOfDirectory(atPath: bundle.path)) ?? []).contains { $0.hasSuffix(".macvm") }
        if osType == "7" || hasMacVM {
            throw ControlError("This is a macOS machine. Virtualization gives each Mac machine its own hardware model and identity, so it can't move between apps: make a new macOS machine in Hyperbox and use Migration Assistant instead.")
        }
        if osType == "8" {
            throw ControlError("This is a Windows machine. Hyperbox runs Linux and macOS.")
        }

        name = text(xml, "//Identification/VmName") ?? bundle.deletingPathExtension().lastPathComponent
        cpuCount = text(xml, "//Hardware/Cpu/Number").flatMap { Int($0) }
        memoryMB = text(xml, "//Hardware/Memory/RAM").flatMap { UInt64($0) }

        // The first enabled hard disk that's an image file, which is the one it boots from.
        var found: URL?
        for hdd in (try? xml.nodes(forXPath: "//Hardware/Hdd")) ?? [] {
            if text(hdd, "Enabled") == "0" { continue }
            guard let path = text(hdd, "SystemName"), !path.isEmpty else { continue }
            // Paths are relative to the bundle, or absolute on the Mac it came from.
            let candidates = [path.hasPrefix("/") ? URL(fileURLWithPath: path) : bundle.appending(path: path),
                              bundle.appending(path: (path as NSString).lastPathComponent)]
            if let url = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) {
                found = url
                break
            }
        }
        if found == nil {
            let files = (try? FileManager.default.contentsOfDirectory(at: bundle, includingPropertiesForKeys: nil)) ?? []
            found = files.first { $0.pathExtension == "hdd" }
        }
        guard let found else { throw ControlError("\(bundle.lastPathComponent) has no hard disk.") }
        disk = found
    }

    func open() throws -> DiskImage {
        var isDirectory: ObjCBool = false
        FileManager.default.fileExists(atPath: disk.path, isDirectory: &isDirectory)
        return isDirectory.boolValue ? try ParallelsDisk(disk) : try DiskImages.open(disk)
    }
}
