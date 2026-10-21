import Compression
import Foundation

/// VMware's disk format, as VMware's "Virtual Disk Format 5.0" describes it: a sparse extent (a grain
/// directory pointing to grain tables pointing to grains), optionally stream-optimized (each grain
/// deflated, the directory at the end), or a text descriptor listing extents, flat or sparse.
nonisolated final class VMDKImage: DiskImage {
    let size: UInt64
    let clusterSize: Int
    private let composite: CompositeImage

    init(_ url: URL) throws {
        if Self.isDescriptor(url) {
            let text = try String(contentsOf: url, encoding: .utf8)
            var extents: [(UInt64, UInt64, DiskImage)] = []
            var start: UInt64 = 0
            // RW 4192256 SPARSE "disk-s001.vmdk"   or   RW 8388608 FLAT "disk-flat.vmdk" 0
            for line in text.split(whereSeparator: \.isNewline) {
                let parts = line.split(separator: " ", omittingEmptySubsequences: true)
                guard parts.count >= 4, ["RW", "RDONLY", "NOACCESS"].contains(parts[0]), let sectors = UInt64(parts[1]) else { continue }
                guard let first = line.firstIndex(of: "\""), let last = line.lastIndex(of: "\""), first < last else { continue }
                let file = url.deletingLastPathComponent().appending(path: String(line[line.index(after: first)..<last]))
                let image: DiskImage
                switch parts[2] {
                case "FLAT", "VMFS":
                    let offset = parts.count > 4 ? (UInt64(parts.last!) ?? 0) * 512 : 0
                    image = try OffsetImage(RawImage(file), offset: offset)
                case "SPARSE", "VMFSSPARSE":
                    image = try SparseExtent(file)
                case "ZERO":
                    image = ZeroImage(size: sectors * 512)
                default:
                    throw ControlError("\(url.lastPathComponent) has a \(parts[2]) extent, which Hyperbox can't read.")
                }
                extents.append((start, start + sectors * 512, image))
                start += sectors * 512
            }
            guard !extents.isEmpty else { throw ControlError("\(url.lastPathComponent) lists no extents.") }
            composite = CompositeImage(extents)
        } else {
            let extent = try SparseExtent(url)
            composite = CompositeImage([(0, extent.size, extent)])
        }
        size = composite.size
        clusterSize = composite.clusterSize
    }

    /// A small text file starting with "# Disk DescriptorFile".
    static func isDescriptor(_ url: URL) -> Bool {
        guard let file = try? ImageFile(url), file.size < 64 << 10, let head = try? file.bytes(at: 0, count: min(Int(file.size), 64)) else { return false }
        return String(decoding: head, as: UTF8.self).contains("Disk DescriptorFile")
    }

    func read(at offset: UInt64, into buffer: UnsafeMutableRawBufferPointer) throws -> Bool {
        try composite.read(at: offset, into: buffer)
    }

    /// One hosted sparse extent file, starting with "KDMV".
    final class SparseExtent: DiskImage {
        let file: ImageFile
        let size: UInt64
        let clusterSize: Int
        private let tablesPerDirectory: Int
        private let entriesPerTable: Int
        private let directory: [UInt32]
        private let compressed: Bool
        private var tableCache: [UInt32: [UInt32]] = [:]

        init(_ url: URL) throws {
            file = try ImageFile(url)
            let name = url.lastPathComponent
            var header = try file.bytes(at: 0, count: 512)
            guard header.le(0, as: UInt32.self) == 0x564D_444B else { throw ControlError("\(name) isn't a VMDK sparse extent.") }
            var directoryOffset = header.le(56, as: UInt64.self)
            if directoryOffset == UInt64.max {
                // Stream-optimized: the real header is the footer, 1 KB before the end.
                header = try file.bytes(at: file.size - 1024, count: 512)
                directoryOffset = header.le(56, as: UInt64.self)
            }
            let flags = header.le(8, as: UInt32.self)
            size = header.le(12, as: UInt64.self) * 512
            clusterSize = Int(header.le(20, as: UInt64.self) * 512)
            entriesPerTable = Int(header.le(44, as: UInt32.self))
            compressed = flags & (1 << 16) != 0 && header.le(77, as: UInt16.self) == 1
            guard clusterSize > 0, entriesPerTable > 0, directoryOffset != 0, directoryOffset != UInt64.max else {
                throw ControlError("\(name) is damaged: its header makes no sense.")
            }
            let span = UInt64(clusterSize) * UInt64(entriesPerTable)
            tablesPerDirectory = Int((size + span - 1) / span)
            let bytes = try file.bytes(at: directoryOffset * 512, count: tablesPerDirectory * 4)
            directory = (0..<tablesPerDirectory).map { bytes.le($0 * 4, as: UInt32.self) }
        }

        func read(at offset: UInt64, into buffer: UnsafeMutableRawBufferPointer) throws -> Bool {
            let grain = Int(offset / UInt64(clusterSize))
            let inGrain = Int(offset % UInt64(clusterSize))
            let tableIndex = grain / entriesPerTable
            guard tableIndex < directory.count, directory[tableIndex] != 0 else { return false }
            let table = try grainTable(directory[tableIndex])
            let sector = UInt64(table[grain % entriesPerTable])
            // 0 is never written; 1 is written as zeros.
            guard sector > 1 else { return false }
            guard compressed else {
                try file.read(at: sector * 512 + UInt64(inGrain), into: buffer)
                return true
            }
            // A grain marker: the sector it holds (8 bytes), the deflated size (4), then zlib data.
            let marker = try file.bytes(at: sector * 512, count: 12)
            let length = Int(marker.le(8, as: UInt32.self))
            let data = try file.bytes(at: sector * 512 + 12, count: length)
            guard data.count > 2 else { return false }
            var grainData = [UInt8](repeating: 0, count: clusterSize)
            let written = grainData.withUnsafeMutableBufferPointer { out in
                // Skip zlib's 2-byte header: Compression wants raw deflate.
                data.withUnsafeBufferPointer { compression_decode_buffer(out.baseAddress!, clusterSize, $0.baseAddress! + 2, length - 2, nil, COMPRESSION_ZLIB) }
            }
            guard written > 0 else { throw ControlError("\(file.url.lastPathComponent) has a damaged grain at sector \(sector).") }
            grainData.withUnsafeBytes { buffer.copyMemory(from: UnsafeRawBufferPointer(rebasing: $0[inGrain..<(inGrain + buffer.count)])) }
            return true
        }

        private func grainTable(_ sector: UInt32) throws -> [UInt32] {
            if let table = tableCache[sector] { return table }
            let bytes = try file.bytes(at: UInt64(sector) * 512, count: entriesPerTable * 4)
            let table = (0..<entriesPerTable).map { bytes.le($0 * 4, as: UInt32.self) }
            if tableCache.count > 256 { tableCache.removeAll(keepingCapacity: true) }
            tableCache[sector] = table
            return table
        }
    }
}

/// A raw file whose disk starts somewhere inside it.
nonisolated final class OffsetImage: DiskImage {
    let base: DiskImage
    let offset: UInt64
    var size: UInt64 { base.size - min(offset, base.size) }
    var clusterSize: Int { base.clusterSize }

    init(_ base: DiskImage, offset: UInt64) {
        self.base = base
        self.offset = offset
    }

    func read(at position: UInt64, into buffer: UnsafeMutableRawBufferPointer) throws -> Bool {
        try base.readRange(at: position + offset, into: buffer)
    }
}

/// Nothing but zeros.
nonisolated final class ZeroImage: DiskImage {
    let size: UInt64
    let clusterSize = 1 << 20
    init(size: UInt64) { self.size = size }
    func read(at offset: UInt64, into buffer: UnsafeMutableRawBufferPointer) throws -> Bool { false }
}
