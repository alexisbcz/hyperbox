import Compression
import Foundation

/// QEMU's disk format, which UTM and most cloud images use. Follows docs/interop/qcow2.txt in QEMU:
/// a two-level table (L1, then L2 tables of cluster offsets) maps the guest's clusters to the file's,
/// a cluster can be zlib-compressed, and a missing one reads from the backing file, if there is one.
///
/// Reads versions 2 and 3, with extended L2 entries (subclusters). Not encrypted images, external
/// data files, or zstd compression, which Apple's Compression framework lacks.
nonisolated final class QCOW2Image: DiskImage {
    let file: ImageFile
    let size: UInt64
    let clusterSize: Int
    /// The image this one only records changes to, when it has one.
    let backing: DiskImage?

    private let clusterBits: Int
    private let l2Entries: Int
    private let extendedL2: Bool
    private let l1: [UInt64]
    private var l2Cache: [UInt64: [UInt64]] = [:]
    private var compressedCache: (offset: UInt64, data: [UInt8])?

    private static let offsetMask: UInt64 = 0x00FF_FFFF_FFFF_FE00
    private static let compressedFlag: UInt64 = 1 << 62

    init(_ url: URL) throws {
        file = try ImageFile(url)
        let name = url.lastPathComponent
        let header = try file.bytes(at: 0, count: 112)
        guard header.be(0, as: UInt32.self) == 0x5146_49FB else { throw ControlError("\(name) isn't a QCOW2 image.") }
        let version = header.be(4, as: UInt32.self)
        guard version == 2 || version == 3 else { throw ControlError("\(name) is QCOW2 version \(version), which Hyperbox can't read.") }
        clusterBits = Int(header.be(20, as: UInt32.self))
        guard (9...21).contains(clusterBits) else { throw ControlError("\(name) is damaged: its clusters are 2^\(clusterBits) bytes.") }
        clusterSize = 1 << clusterBits
        size = header.be(24, as: UInt64.self)
        guard header.be(32, as: UInt32.self) == 0 else { throw ControlError("\(name) is encrypted. Decrypt it with qemu-img convert first.") }

        var extended = false
        if version == 3 {
            let incompatible = header.be(72, as: UInt64.self)
            let headerLength = header.be(100, as: UInt32.self)
            if incompatible & (1 << 1) != 0 { throw ControlError("\(name) is marked as damaged. Repair it with qemu-img check -r all first.") }
            if incompatible & (1 << 2) != 0 { throw ControlError("\(name) keeps its data in a separate file, which Hyperbox can't read.") }
            if incompatible & (1 << 3) != 0, headerLength > 104, header[104] != 0 {
                throw ControlError("\(name) is compressed with zstd, which Hyperbox can't read. Convert it with qemu-img convert -O qcow2 first.")
            }
            extended = incompatible & (1 << 4) != 0
            if incompatible & ~UInt64(0b11111) != 0 { throw ControlError("\(name) uses QCOW2 features Hyperbox doesn't know.") }
        }
        extendedL2 = extended
        l2Entries = clusterSize / (extended ? 16 : 8)

        let l1Size = Int(header.be(36, as: UInt32.self))
        let l1Offset = header.be(40, as: UInt64.self)
        let table = try file.bytes(at: l1Offset, count: l1Size * 8)
        l1 = (0..<l1Size).map { table.be($0 * 8, as: UInt64.self) }

        let backingOffset = header.be(8, as: UInt64.self)
        let backingLength = Int(header.be(16, as: UInt32.self))
        if backingOffset != 0, backingLength > 0 {
            let backingName = String(decoding: try file.bytes(at: backingOffset, count: backingLength), as: UTF8.self)
            let candidates = [URL(fileURLWithPath: backingName, relativeTo: url.deletingLastPathComponent()).standardizedFileURL,
                              url.deletingLastPathComponent().appending(path: (backingName as NSString).lastPathComponent)]
            guard let found = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
                throw ControlError("\(name) records only changes to \(backingName), which isn't next to it. Put it in the same folder and try again.")
            }
            backing = try DiskImages.open(found)
        } else {
            backing = nil
        }
    }

    func read(at offset: UInt64, into buffer: UnsafeMutableRawBufferPointer) throws -> Bool {
        let cluster = offset >> clusterBits
        let inCluster = Int(offset & UInt64(clusterSize - 1))
        let l1Index = Int(cluster / UInt64(l2Entries))
        guard l1Index < l1.count, l1[l1Index] & Self.offsetMask != 0 else { return try fromBacking(offset, buffer) }
        let table = try l2Table(at: l1[l1Index] & Self.offsetMask)
        let index = Int(cluster % UInt64(l2Entries))
        let entry = extendedL2 ? table[index * 2] : table[index]

        if entry & Self.compressedFlag != 0 {
            let data = try decompress(entry)
            data.withUnsafeBytes { source in
                buffer.copyMemory(from: UnsafeRawBufferPointer(rebasing: source[inCluster..<(inCluster + buffer.count)]))
            }
            return true
        }
        let host = entry & Self.offsetMask
        guard extendedL2 else {
            if entry & 1 != 0 { return false }  // reads as zeros, whatever the backing file has
            if host == 0 { return try fromBacking(offset, buffer) }
            try file.read(at: host + UInt64(inCluster), into: buffer)
            return true
        }

        // Extended L2: 32 subclusters, each allocated (bits 0-31), zero (bits 32-63), or neither (backing).
        let bitmap = table[index * 2 + 1]
        let subcluster = clusterSize / 32
        var any = false
        var done = 0
        while done < buffer.count {
            let position = inCluster + done
            let sub = position / subcluster
            let count = min(buffer.count - done, (sub + 1) * subcluster - position)
            let part = UnsafeMutableRawBufferPointer(rebasing: buffer[done..<(done + count)])
            if bitmap & (1 << (32 + sub)) != 0 {
                part.initializeMemory(as: UInt8.self, repeating: 0)
            } else if bitmap & (1 << sub) != 0 {
                try file.read(at: host + UInt64(position), into: part)
                any = true
            } else if try fromBacking(offset + UInt64(done), part) {
                any = true
            } else {
                part.initializeMemory(as: UInt8.self, repeating: 0)
            }
            done += count
        }
        return any
    }

    private func fromBacking(_ offset: UInt64, _ buffer: UnsafeMutableRawBufferPointer) throws -> Bool {
        guard let backing, offset < backing.size else { return false }
        return try backing.readRange(at: offset, into: buffer)
    }

    private func l2Table(at offset: UInt64) throws -> [UInt64] {
        if let table = l2Cache[offset] { return table }
        let bytes = try file.bytes(at: offset, count: clusterSize)
        let table = (0..<(clusterSize / 8)).map { bytes.be($0 * 8, as: UInt64.self) }
        if l2Cache.count > 64 { l2Cache.removeAll(keepingCapacity: true) }
        l2Cache[offset] = table
        return table
    }

    /// A compressed cluster: raw deflate, starting anywhere, taking a count of 512-byte sectors.
    private func decompress(_ entry: UInt64) throws -> [UInt8] {
        let shift = 62 - (clusterBits - 8)
        let offset = entry & ((1 << UInt64(shift)) - 1)
        if let cached = compressedCache, cached.offset == offset { return cached.data }
        let sectors = ((entry >> UInt64(shift)) & ((1 << UInt64(clusterBits - 8)) - 1)) + 1
        let length = Int(min(sectors * 512 - (offset & 511), file.size - min(offset, file.size)))
        let compressed = try file.bytes(at: offset, count: length)
        var data = [UInt8](repeating: 0, count: clusterSize)
        let written = data.withUnsafeMutableBufferPointer { out in
            compressed.withUnsafeBufferPointer { input in
                compression_decode_buffer(out.baseAddress!, clusterSize, input.baseAddress!, length, nil, COMPRESSION_ZLIB)
            }
        }
        guard written > 0 else { throw ControlError("\(file.url.lastPathComponent) has a damaged compressed cluster at \(offset).") }
        compressedCache = (offset, data)
        return data
    }
}
