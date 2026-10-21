import Compression
import Foundation

/// Turns a qcow2 image, the format distributions publish their cloud images in, into the raw disk
/// the Virtualization framework needs.
///
/// Handles what cloud images use: version 2 and 3, no backing file, no encryption, clusters
/// compressed with zlib. See https://www.qemu.org/docs/master/interop/qcow2.html.
nonisolated enum QCOW2 {
    static func isQCOW2(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url), let magic = try? handle.read(upToCount: 4) else { return false }
        return magic == Data([0x51, 0x46, 0x49, 0xFB])
    }

    /// Writes only the clusters that hold data, so the raw image is sparse and takes the space the
    /// image's files do, not its full size.
    static func convert(_ source: URL, to destination: URL, progress: (Double) -> Void) throws {
        let image = try Data(contentsOf: source, options: .alwaysMapped)
        func u32(_ offset: Int) -> UInt32 { image[offset..<offset + 4].reduce(0) { $0 << 8 | UInt32($1) } }
        func u64(_ offset: Int) -> UInt64 { image[offset..<offset + 8].reduce(0) { $0 << 8 | UInt64($1) } }

        guard image.count > 104, u32(0) == 0x5146_49FB else { throw ControlError("\(source.lastPathComponent) isn't a qcow2 image.") }
        let version = u32(4)
        guard version == 2 || version == 3 else { throw ControlError("qcow2 version \(version) isn't supported.") }
        guard u64(8) == 0 else { throw ControlError("qcow2 images with a backing file aren't supported.") }
        guard u32(32) == 0 else { throw ControlError("Encrypted qcow2 images aren't supported.") }
        let clusterBits = Int(u32(20))
        guard (9...21).contains(clusterBits) else { throw ControlError("The qcow2 image is damaged.") }
        if version == 3 {
            let incompatible = u64(72)
            // External data files and extended L2 entries: not in cloud images.
            guard incompatible & 0b10100 == 0 else { throw ControlError("This qcow2 image uses features Hyperbox can't read.") }
            if incompatible & 0b1000 != 0, u32(100) > 104, image[104] != 0 {
                throw ControlError("qcow2 images compressed with zstd aren't supported.")
            }
        }
        let clusterSize = 1 << clusterBits
        let virtualSize = u64(24)
        let l1Size = Int(u32(36))
        let l1Offset = Int(u64(40))
        let offsetMask: UInt64 = 0x00FF_FFFF_FFFF_FE00
        let compressedBits = 62 - (clusterBits - 8)
        let entriesPerL2 = clusterSize / 8

        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let fd = open(destination.path, O_WRONLY | O_TRUNC)
        guard fd >= 0 else { throw ControlError("Couldn't write \(destination.path).") }
        defer { close(fd) }

        var cluster = [UInt8](repeating: 0, count: clusterSize)
        let zeros = [UInt8](repeating: 0, count: clusterSize)
        try image.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let base = raw.baseAddress!
            for l1 in 0..<l1Size {
                if l1 % 16 == 0 { progress(Double(l1) / Double(l1Size)) }
                let l2Offset = Int(u64(l1Offset + l1 * 8) & offsetMask)
                guard l2Offset != 0 else { continue }
                for l2 in 0..<entriesPerL2 {
                    let guestOffset = (UInt64(l1) * UInt64(entriesPerL2) + UInt64(l2)) * UInt64(clusterSize)
                    guard guestOffset < virtualSize else { break }
                    let entry = u64(l2Offset + l2 * 8)
                    if entry & (1 << 62) != 0 {
                        let host = Int(entry & ((1 << UInt64(compressedBits)) - 1))
                        let sectors = Int((entry >> UInt64(compressedBits)) & ((1 << UInt64(clusterBits - 8)) - 1)) + 1
                        let length = min(sectors * 512 - (host & 511), raw.count - host)
                        let n = cluster.withUnsafeMutableBufferPointer { out in
                            compression_decode_buffer(out.baseAddress!, clusterSize, base.advanced(by: host).assumingMemoryBound(to: UInt8.self),
                                                      length, nil, COMPRESSION_ZLIB)
                        }
                        guard n > 0 else { throw ControlError("The qcow2 image is damaged (a cluster didn't decompress).") }
                        if n < clusterSize { cluster.withUnsafeMutableBufferPointer { _ = memset($0.baseAddress! + n, 0, clusterSize - n) } }
                    } else {
                        let host = Int(entry & offsetMask)
                        // Unallocated, or marked all zeros: a hole in the raw image.
                        guard host != 0, entry & 1 == 0 else { continue }
                        guard host + clusterSize <= raw.count else { throw ControlError("The qcow2 image is cut short.") }
                        cluster.withUnsafeMutableBytes { _ = memcpy($0.baseAddress!, base + host, clusterSize) }
                    }
                    if memcmp(cluster, zeros, clusterSize) == 0 { continue }
                    let count = Int(min(UInt64(clusterSize), virtualSize - guestOffset))
                    let written = cluster.withUnsafeBytes { pwrite(fd, $0.baseAddress!, count, off_t(guestOffset)) }
                    guard written == count else { throw ControlError("Couldn't write the disk image: \(String(cString: strerror(errno))).") }
                }
            }
        }
        guard ftruncate(fd, off_t(virtualSize)) == 0 else { throw ControlError("Couldn't size the disk image.") }
        progress(1)
    }
}
