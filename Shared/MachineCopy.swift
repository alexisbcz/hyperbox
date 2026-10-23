import Foundation
import Virtualization

/// New machines made from another machine's files: duplicates in the library, and `hyperbox clone`, which makes
/// a machine from a template (any machine you've set up the way you like) or from one of its snapshots.
///
/// A copy is a new machine: new id, MAC address and machine identifier, so both can run at once and
/// macOS guests count as two Macs. It starts without the original's snapshots and suspended state:
/// both remember the old identity, so Virtualization wouldn't resume them in the copy anyway.
nonisolated enum MachineCopy {
    /// Makes a copied bundle a machine of its own.
    static func renew(_ bundle: MachineBundle, name: String) throws {
        var config = try MachineConfig.load(from: bundle.url)
        config.id = UUID()
        config.name = name
        config.created = Date()
        config.network.macAddress = MachineConfig.Network.randomMAC()
        let identifier = config.os == .macOS ? VZMacMachineIdentifier().dataRepresentation : VZGenericMachineIdentifier().dataRepresentation
        try identifier.write(to: bundle.machineIdentifier)
        for leftover in [bundle.snapshots, bundle.savedState, bundle.console] {
            try? FileManager.default.removeItem(at: leftover)
        }
        try config.save(to: bundle.url)
    }

    /// Clones `source`, or the disk it had in `snapshot`, to a new bundle at `destination`, and makes it a
    /// machine of its own named `name`. APFS clones: instant, and they take space only as either side changes.
    static func clone(_ source: MachineBundle, snapshot: SnapshotInfo?, to destination: URL, name: String) throws {
        let fm = FileManager.default
        let config = try MachineConfig.load(from: source.url)
        try fm.createDirectory(at: destination, withIntermediateDirectories: false)
        do {
            let new = MachineBundle(url: destination)
            // What a machine needs to boot; snapshots, the suspended state and the console log stay behind.
            let kept = [source.config, source.hardwareModel, source.thumbnail, source.seed]
            for file in kept where fm.fileExists(atPath: file.path) {
                try FileClone.clone(file, to: destination.appending(path: file.lastPathComponent))
            }
            let from = snapshot.map { SnapshotFiles.directory(source, $0.id) } ?? source.url
            for file in [new.disk, new.auxiliaryStorage, new.efiVariables] {
                let original = from.appending(path: file.lastPathComponent)
                if fm.fileExists(atPath: original.path) { try FileClone.clone(original, to: file) }
            }
            if let snapshot {
                let thumbnail = from.appending(path: SnapshotFiles.thumbnailName)
                if fm.fileExists(atPath: thumbnail.path) { try FileClone.replace(new.thumbnail, withCloneOf: thumbnail) }
                // The snapshot's disk may be another size than the machine's is now.
                var copied = try MachineConfig.load(from: destination)
                copied.diskSize = DiskUsage.size(new.disk)
                try copied.save(to: destination)
            }
            guard fm.fileExists(atPath: new.disk.path) else { throw ControlError("\(config.name) has no disk to clone.") }
            try renew(new, name: name)
        } catch {
            try? fm.removeItem(at: destination)
            throw error
        }
    }
}
