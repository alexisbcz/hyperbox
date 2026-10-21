import Foundation

/// Copies that share blocks with the original (APFS clones): instant, and they cost space only as
/// either side changes. Snapshots, duplicates and same-disk exports are all clones.
nonisolated enum FileClone {
    /// Clones a file or a whole folder to `destination`, which mustn't exist. Off APFS, where there are
    /// no clones, it falls back to a copy that keeps sparse files sparse.
    static func clone(_ source: URL, to destination: URL) throws {
        if clonefile(source.path, destination.path, 0) == 0 { return }
        let error = errno
        guard error == ENOTSUP || error == EXDEV else { throw posixError(error, "Couldn't copy \(source.lastPathComponent)") }
        try copy(source, to: destination)
    }

    /// Copies a file or folder, cloning what it can and leaving holes in sparse files, so a 64 GB disk
    /// with 5 GB in it copies 5 GB. `progress` gets the bytes copied so far.
    static func copy(_ source: URL, to destination: URL, progress: (@Sendable (UInt64) -> Void)? = nil) throws {
        let flags = copyfile_flags_t(COPYFILE_ALL | COPYFILE_RECURSIVE | COPYFILE_CLONE | COPYFILE_DATA_SPARSE | COPYFILE_EXCL)
        let state = copyfile_state_alloc()
        defer { copyfile_state_free(state) }
        let tracker = CopyProgress(report: progress)
        let context = Unmanaged.passRetained(tracker)
        defer { context.release() }
        if progress != nil {
            let callback: copyfile_callback_t = { what, stage, state, _, _, context in
                guard let context else { return COPYFILE_CONTINUE }
                let tracker = Unmanaged<CopyProgress>.fromOpaque(context).takeUnretainedValue()
                if what == COPYFILE_COPY_DATA, stage == COPYFILE_PROGRESS {
                    var copied: off_t = 0
                    copyfile_state_get(state, UInt32(COPYFILE_STATE_COPIED), &copied)
                    tracker.current = UInt64(max(copied, 0))
                    tracker.report?(tracker.finished + tracker.current)
                } else if what == COPYFILE_RECURSE_FILE, stage == COPYFILE_FINISH {
                    tracker.finished += tracker.current
                    tracker.current = 0
                }
                return COPYFILE_CONTINUE
            }
            copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CB), unsafeBitCast(callback, to: UnsafeRawPointer.self))
            copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CTX), context.toOpaque())
        }
        guard copyfile(source.path, destination.path, state, flags) == 0 else {
            throw posixError(errno, "Couldn't copy \(source.lastPathComponent)")
        }
    }

    /// Swaps `destination` for a clone of `source` in one step, by cloning beside it and renaming over it,
    /// so a failure halfway leaves the original alone.
    static func replace(_ destination: URL, withCloneOf source: URL) throws {
        let temporary = destination.deletingLastPathComponent().appending(path: ".\(destination.lastPathComponent).\(UUID().uuidString)")
        try clone(source, to: temporary)
        guard rename(temporary.path, destination.path) == 0 else {
            let error = errno
            try? FileManager.default.removeItem(at: temporary)
            throw posixError(error, "Couldn't replace \(destination.lastPathComponent)")
        }
    }

    static func posixError(_ code: Int32, _ message: String) -> ControlError {
        ControlError("\(message): \(String(cString: strerror(code))).")
    }

    private final class CopyProgress: @unchecked Sendable {
        let report: (@Sendable (UInt64) -> Void)?
        var finished: UInt64 = 0
        var current: UInt64 = 0
        init(report: (@Sendable (UInt64) -> Void)?) { self.report = report }
    }
}

/// How much space files really take: sparse disks take less than their size, clones share blocks.
nonisolated enum DiskUsage {
    /// The bytes a file or folder's blocks take, counting blocks shared with clones as if they weren't.
    static func allocated(_ url: URL) -> UInt64 {
        files(in: url).reduce(0) { total, file in
            total + UInt64((try? file.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? 0)
        }
    }

    /// The bytes only this file or folder holds, which deleting it would free: blocks shared with a clone
    /// (a snapshot, a duplicate) don't count. nil off APFS.
    static func unshared(_ url: URL) -> UInt64? {
        var total: UInt64 = 0
        for file in files(in: url) {
            guard let size = privateSize(file) else { return nil }
            total += size
        }
        return total
    }

    /// The logical size of a file, holes included.
    static func size(_ url: URL) -> UInt64 {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? UInt64) ?? 0
    }

    private static func files(in url: URL) -> [URL] {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return [] }
        guard isDirectory.boolValue else { return [url] }
        let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey])
        return (enumerator?.allObjects as? [URL] ?? []).filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
    }

    /// APFS's private size, from getattrlist(2).
    private static func privateSize(_ url: URL) -> UInt64? {
        var request = attrlist()
        request.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        request.forkattr = attrgroup_t(ATTR_CMNEXT_PRIVATESIZE)
        // The reply is packed: its length (UInt32), then the size (off_t), unaligned.
        var buffer = [UInt8](repeating: 0, count: 16)
        let result = buffer.withUnsafeMutableBytes { raw in
            getattrlist(url.path, &request, raw.baseAddress, raw.count, UInt32(FSOPT_ATTR_CMN_EXTENDED | FSOPT_NOFOLLOW))
        }
        guard result == 0 else { return nil }
        return buffer.withUnsafeBytes { raw in
            raw.loadUnaligned(as: UInt32.self) >= 12 ? UInt64(max(raw.loadUnaligned(fromByteOffset: 4, as: off_t.self), 0)) : nil
        }
    }
}

/// A machine's snapshots on disk, as `MachineBundle.snapshots/<id>/`:
///
///     meta.json       SnapshotInfo
///     disk.img        clones of the machine's files when the snapshot was taken
///     efi.vars        (Linux) or aux.img (macOS)
///     state.vzsave    the running machine's memory and devices, when it was running
///     thumbnail.png   its screen, when it was running
///
/// Taking and restoring a running machine's state needs the machine's own process (see `Snapshots`);
/// everything here works on files, so the library and the `hyperbox` command use it on stopped machines.
nonisolated enum SnapshotFiles {
    static let metaName = "meta.json"
    static let stateName = "state.vzsave"
    static let thumbnailName = "thumbnail.png"

    static func directory(_ bundle: MachineBundle, _ id: UUID) -> URL {
        bundle.snapshots.appending(path: id.uuidString.lowercased())
    }

    static func list(_ bundle: MachineBundle) -> [SnapshotInfo] {
        let folders = (try? FileManager.default.contentsOfDirectory(at: bundle.snapshots, includingPropertiesForKeys: nil)) ?? []
        // A folder without meta.json is a snapshot still being taken, or one that failed halfway.
        return folders.compactMap { folder in
            (try? Data(contentsOf: folder.appending(path: metaName))).flatMap { try? JSONDecoder.machine.decode(SnapshotInfo.self, from: $0) }
        }
        .sorted { $0.created < $1.created }
    }

    static func info(_ bundle: MachineBundle, _ id: UUID) throws -> SnapshotInfo {
        guard let info = list(bundle).first(where: { $0.id == id }) else { throw ControlError("There's no snapshot \(id.uuidString.lowercased()).") }
        return info
    }

    /// Finds a snapshot by id, id prefix or name, for the command line and agents.
    static func find(_ bundle: MachineBundle, _ query: String) throws -> SnapshotInfo {
        let all = list(bundle)
        if let match = all.first(where: { $0.id.uuidString.lowercased().hasPrefix(query.lowercased()) || $0.name == query }) { return match }
        if let match = all.last(where: { $0.name.lowercased() == query.lowercased() }) { return match }
        throw ControlError("There's no snapshot named \(query).")
    }

    /// The files a snapshot keeps: the disk, and the firmware's store.
    static func machineFiles(_ bundle: MachineBundle, os: GuestOS) -> [URL] {
        [bundle.disk, os == .macOS ? bundle.auxiliaryStorage : bundle.efiVariables]
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Where a running machine saves its state before `create` moves it into the snapshot.
    static func stagingState(_ bundle: MachineBundle) -> URL {
        Paths.ensure(bundle.snapshots)
        return bundle.snapshots.appending(path: ".state-\(UUID().uuidString).vzsave")
    }

    /// Clones the machine's files into a new snapshot. A running machine passes the state it saved, which
    /// is moved in; a stopped one that was suspended keeps its suspended state, so restoring resumes it.
    static func create(_ bundle: MachineBundle, os: GuestOS, name: String, state: URL? = nil, thumbnail: Data? = nil) throws -> SnapshotInfo {
        let fm = FileManager.default
        let info = SnapshotInfo(id: UUID(), name: name, created: Date(),
                                hasState: state != nil || fm.fileExists(atPath: bundle.savedState.path))
        let folder = directory(bundle, info.id)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        do {
            if let state {
                try fm.moveItem(at: state, to: folder.appending(path: stateName))
            } else if fm.fileExists(atPath: bundle.savedState.path) {
                try FileClone.clone(bundle.savedState, to: folder.appending(path: stateName))
            }
            for file in machineFiles(bundle, os: os) {
                try FileClone.clone(file, to: folder.appending(path: file.lastPathComponent))
            }
            if let thumbnail { try? thumbnail.write(to: folder.appending(path: thumbnailName)) }
            else if state == nil, fm.fileExists(atPath: bundle.thumbnail.path) { try? FileClone.clone(bundle.thumbnail, to: folder.appending(path: thumbnailName)) }
            // Written last: a snapshot exists once its meta.json does.
            try JSONEncoder.machine.encode(info).write(to: folder.appending(path: metaName), options: .atomic)
        } catch {
            try? fm.removeItem(at: folder)
            throw error
        }
        return info
    }

    /// Puts a stopped machine's files back as they were in the snapshot. A snapshot with state becomes
    /// the machine's saved state, so its next start resumes where the snapshot was taken.
    @discardableResult
    static func restore(_ bundle: MachineBundle, _ id: UUID) throws -> SnapshotInfo {
        let info = try info(bundle, id)
        let folder = directory(bundle, id)
        let fm = FileManager.default
        // Whatever state the machine had belongs to the disk being replaced.
        try? fm.removeItem(at: bundle.savedState)
        for name in [bundle.disk, bundle.efiVariables, bundle.auxiliaryStorage].map(\.lastPathComponent) {
            let saved = folder.appending(path: name)
            if fm.fileExists(atPath: saved.path) { try FileClone.replace(bundle.url.appending(path: name), withCloneOf: saved) }
        }
        let state = folder.appending(path: stateName)
        if info.hasState, fm.fileExists(atPath: state.path) { try FileClone.clone(state, to: bundle.savedState) }
        let thumbnail = folder.appending(path: thumbnailName)
        if fm.fileExists(atPath: thumbnail.path) { try? FileClone.replace(bundle.thumbnail, withCloneOf: thumbnail) }
        return info
    }

    static func delete(_ bundle: MachineBundle, _ id: UUID) throws {
        let folder = directory(bundle, id)
        guard FileManager.default.fileExists(atPath: folder.path) else { throw ControlError("There's no snapshot \(id.uuidString.lowercased()).") }
        try FileManager.default.removeItem(at: folder)
    }

    /// A default name, like "Oct 21, 2026 at 3:40 PM".
    static func defaultName() -> String {
        Date().formatted(date: .abbreviated, time: .shortened)
    }
}
