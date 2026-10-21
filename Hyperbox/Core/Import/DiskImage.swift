import Foundation

/// A virtual disk in some other app's format, read as the guest would see it.
///
/// Readers (`QCOW2Image`, `ParallelsImage`, `VMDKImage`, `RawImage`) depend only on Foundation, so they
/// build and test on their own: `swiftc Hyperbox/Core/Import/{DiskImage,QCOW2,Parallels,VMDK}.swift Shared/*.swift main.swift`.
nonisolated protocol DiskImage: AnyObject {
    /// The disk's size as the guest sees it, in bytes.
    var size: UInt64 { get }
    /// The unit the format allocates in.
    var clusterSize: Int { get }
    /// Fills `buffer` from `offset`, a range inside one cluster. Returns false when the guest never wrote
    /// there, which reads as zeros; the buffer is then left as it was.
    func read(at offset: UInt64, into buffer: UnsafeMutableRawBufferPointer) throws -> Bool
}

nonisolated extension DiskImage {
    /// Fills `buffer` from any range, zeros past the end or where nothing was written.
    /// Returns false when all of it is zeros.
    func readRange(at offset: UInt64, into buffer: UnsafeMutableRawBufferPointer) throws -> Bool {
        var any = false
        var done = 0
        let cluster = UInt64(clusterSize)
        while done < buffer.count {
            let position = offset + UInt64(done)
            let inCluster = Int(position % cluster)
            let count = min(buffer.count - done, clusterSize - inCluster)
            let slice = UnsafeMutableRawBufferPointer(rebasing: buffer[done..<(done + count)])
            if position < size {
                let readable = Int(min(UInt64(count), size - position))
                let part = UnsafeMutableRawBufferPointer(rebasing: slice[0..<readable])
                if try read(at: position, into: part) { any = true } else { part.initializeMemory(as: UInt8.self, repeating: 0) }
                if readable < count { UnsafeMutableRawBufferPointer(rebasing: slice[readable...]).initializeMemory(as: UInt8.self, repeating: 0) }
            } else {
                slice.initializeMemory(as: UInt8.self, repeating: 0)
            }
            done += count
        }
        return any
    }
}

/// Opens disk images by what's in them, not their name.
nonisolated enum DiskImages {
    static func open(_ url: URL) throws -> DiskImage {
        let file = try ImageFile(url)
        let magic = try file.bytes(at: 0, count: min(16, Int(file.size)))
        if magic.starts(with: [0x51, 0x46, 0x49, 0xFB]) { return try QCOW2Image(url) }
        if magic.starts(with: Array("KDMV".utf8)) || VMDKImage.isDescriptor(url) { return try VMDKImage(url) }
        if magic.starts(with: Array("WithoutFreeSpace".utf8)) || magic.starts(with: Array("WithouFreSpacExt".utf8)) { return try ParallelsImage(url) }
        if (magic.starts(with: Array("vhdxfile".utf8))) { throw ControlError("\(url.lastPathComponent) is a VHDX disk, which Hyperbox can't read yet.") }
        if (magic.starts(with: Array("conectix".utf8))) { throw ControlError("\(url.lastPathComponent) is a VHD disk, which Hyperbox can't read yet.") }
        return try RawImage(url)
    }

    /// Whether the file is a raw disk, which copies as it is, by cloning.
    static func isRaw(_ url: URL) -> Bool {
        (try? open(url)) is RawImage
    }
}

/// Writes a disk image out as a raw, sparse disk.img.
nonisolated enum DiskConverter {
    /// Holes are made per block of this size: zero blocks are skipped, not written.
    static let holeSize = 64 << 10
    static let chunkSize = 4 << 20

    /// `progress` gets 0 to 1. Cancelling the task stops it, leaving a partial file to delete.
    static func convert(_ image: DiskImage, to destination: URL, progress: (Double) -> Void = { _ in }) throws {
        let fd = Darwin.open(destination.path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        guard fd >= 0 else { throw FileClone.posixError(errno, "Couldn't create \(destination.lastPathComponent)") }
        defer { close(fd) }
        // Virtualization wants whole sectors.
        let size = (image.size + 511) / 512 * 512
        guard ftruncate(fd, off_t(size)) == 0 else { throw FileClone.posixError(errno, "Couldn't size \(destination.lastPathComponent)") }

        let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: chunkSize, alignment: 4096)
        defer { buffer.deallocate() }
        var offset: UInt64 = 0
        var reported = -1
        // Where the zeros since the last write began. APFS fills short gaps between writes with zeros
        // instead of leaving holes, so each gap is punched out once the write after it lands.
        var hole: UInt64?
        func written(at position: UInt64) {
            if let start = hole, start < position { punch(fd, from: start, to: position) }
            hole = nil
        }
        while offset < size {
            if Task.isCancelled { throw CancellationError() }
            let count = Int(min(UInt64(chunkSize), size - offset))
            let chunk = UnsafeMutableRawBufferPointer(rebasing: buffer[0..<count])
            if try image.readRange(at: offset, into: chunk) {
                var start = 0
                while start < count {
                    let end = min(start + holeSize, count)
                    let block = UnsafeMutableRawBufferPointer(rebasing: chunk[start..<end])
                    let position = offset + UInt64(start)
                    if isZero(UnsafeRawBufferPointer(block)) {
                        if hole == nil { hole = position }
                    } else {
                        try writeAll(fd, UnsafeRawBufferPointer(block), at: position)
                        written(at: position)
                    }
                    start = end
                }
            } else if hole == nil {
                hole = offset
            }
            offset += UInt64(count)
            let percent = Int(Double(offset) / Double(size) * 1000)
            if percent != reported {
                reported = percent
                progress(Double(offset) / Double(size))
            }
        }
        guard fsync(fd) == 0 else { throw FileClone.posixError(errno, "Couldn't save \(destination.lastPathComponent)") }
    }

    /// Frees the blocks of a range that's all zeros. Holes are whole filesystem blocks, and every range
    /// here starts and ends on a 64 KB boundary (or the end of the disk, a whole sector).
    private static func punch(_ fd: Int32, from start: UInt64, to end: UInt64) {
        var hole = fpunchhole_t(fp_flags: 0, reserved: 0, fp_offset: off_t(start), fp_length: off_t(end - start))
        _ = fcntl(fd, F_PUNCHHOLE, &hole)
    }

    static func isZero(_ buffer: UnsafeRawBufferPointer) -> Bool {
        let words = buffer.count / 8
        let wide = buffer.baseAddress!.assumingMemoryBound(to: UInt64.self)
        var i = 0
        while i < words {
            if wide[i] != 0 { return false }
            i += 1
        }
        for j in (words * 8)..<buffer.count where buffer[j] != 0 { return false }
        return true
    }

    private static func writeAll(_ fd: Int32, _ data: UnsafeRawBufferPointer, at offset: UInt64) throws {
        var done = 0
        while done < data.count {
            let n = pwrite(fd, data.baseAddress! + done, data.count - done, off_t(offset) + off_t(done))
            guard n > 0 else { throw FileClone.posixError(errno, "Couldn't write the disk") }
            done += n
        }
    }

    /// Punches holes where a file is all zeros, for disks that arrive written out in full (from a zip).
    static func makeSparse(_ url: URL) throws {
        let fd = Darwin.open(url.path, O_RDWR)
        guard fd >= 0 else { throw FileClone.posixError(errno, "Couldn't open \(url.lastPathComponent)") }
        defer { close(fd) }
        let size = DiskUsage.size(url)
        let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: holeSize, alignment: 4096)
        defer { buffer.deallocate() }
        var offset: UInt64 = 0
        while offset + UInt64(holeSize) <= size {
            let n = pread(fd, buffer.baseAddress, holeSize, off_t(offset))
            guard n == holeSize else { break }
            if isZero(UnsafeRawBufferPointer(buffer)) {
                var hole = fpunchhole_t(fp_flags: 0, reserved: 0, fp_offset: off_t(offset), fp_length: off_t(holeSize))
                _ = fcntl(fd, F_PUNCHHOLE, &hole)
            }
            offset += UInt64(holeSize)
        }
    }
}

/// A plain disk: every byte at its own offset.
nonisolated final class RawImage: DiskImage {
    let file: ImageFile
    let size: UInt64
    let clusterSize = 1 << 20

    init(_ url: URL) throws {
        file = try ImageFile(url)
        size = file.size
    }

    func read(at offset: UInt64, into buffer: UnsafeMutableRawBufferPointer) throws -> Bool {
        try file.read(at: offset, into: buffer)
        return true
    }
}

/// A file read at offsets, with the little and big-endian helpers formats need.
nonisolated final class ImageFile {
    let url: URL
    let size: UInt64
    private let fd: Int32

    init(_ url: URL) throws {
        self.url = url
        fd = Darwin.open(url.path, O_RDONLY)
        guard fd >= 0 else { throw FileClone.posixError(errno, "Couldn't open \(url.lastPathComponent)") }
        var info = stat()
        fstat(fd, &info)
        size = UInt64(info.st_size)
    }

    deinit { close(fd) }

    /// Reads exactly `buffer.count` bytes; past the end of the file reads as zeros.
    func read(at offset: UInt64, into buffer: UnsafeMutableRawBufferPointer) throws {
        var done = 0
        while done < buffer.count {
            let n = pread(fd, buffer.baseAddress! + done, buffer.count - done, off_t(offset) + off_t(done))
            if n < 0 { throw FileClone.posixError(errno, "Couldn't read \(url.lastPathComponent)") }
            if n == 0 {
                UnsafeMutableRawBufferPointer(rebasing: buffer[done...]).initializeMemory(as: UInt8.self, repeating: 0)
                return
            }
            done += n
        }
    }

    func bytes(at offset: UInt64, count: Int) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: count)
        try bytes.withUnsafeMutableBytes { try read(at: offset, into: $0) }
        return bytes
    }
}

nonisolated extension Array where Element == UInt8 {
    func le<T: FixedWidthInteger>(_ offset: Int, as: T.Type = T.self) -> T {
        var value: T = 0
        for i in 0..<MemoryLayout<T>.size { value |= T(self[offset + i]) << (8 * i) }
        return value
    }

    func be<T: FixedWidthInteger>(_ offset: Int, as: T.Type = T.self) -> T {
        var value: T = 0
        for i in 0..<MemoryLayout<T>.size { value = value << 8 | T(self[offset + i]) }
        return value
    }
}

/// Disks made of pieces laid end to end: split VMDKs, old Parallels disks.
nonisolated final class CompositeImage: DiskImage {
    let parts: [(start: UInt64, end: UInt64, image: DiskImage)]
    let size: UInt64
    let clusterSize: Int

    init(_ parts: [(start: UInt64, end: UInt64, image: DiskImage)], size: UInt64? = nil) {
        self.parts = parts.sorted { $0.start < $1.start }
        self.size = size ?? parts.map(\.end).max() ?? 0
        clusterSize = parts.map { $0.image.clusterSize }.min() ?? 1 << 20
    }

    func read(at offset: UInt64, into buffer: UnsafeMutableRawBufferPointer) throws -> Bool {
        var any = false
        var done = 0
        while done < buffer.count {
            let position = offset + UInt64(done)
            let rest = UnsafeMutableRawBufferPointer(rebasing: buffer[done...])
            guard let part = parts.first(where: { position >= $0.start && position < $0.end }) else {
                // A gap reads as zeros, up to the next part.
                let next = parts.first { $0.start > position }?.start ?? UInt64.max
                let count = Int(min(UInt64(rest.count), next - position))
                UnsafeMutableRawBufferPointer(rebasing: rest[0..<count]).initializeMemory(as: UInt8.self, repeating: 0)
                done += count
                continue
            }
            let count = Int(min(UInt64(rest.count), part.end - position))
            let slice = UnsafeMutableRawBufferPointer(rebasing: rest[0..<count])
            if try part.image.readRange(at: position - part.start, into: slice) { any = true }
            else { slice.initializeMemory(as: UInt8.self, repeating: 0) }
            done += count
        }
        return any
    }
}
