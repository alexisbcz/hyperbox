import AppKit
import Virtualization

/// Machines from elsewhere: Hyperbox bundles and archives, Parallels and UTM machines, disk images.
///
/// Other apps' Linux machines become Hyperbox machines booting the same disk with EFI. Their disk
/// is converted to a raw, sparse disk.img; their firmware settings stay behind, so a guest whose boot
/// loader is only in its EFI boot entries (not at the removable path, \EFI\BOOT\BOOTAA64.EFI) stops at
/// the EFI shell: there, `fs0:\EFI\debian\grubaa64.efi` boots it, then `grub-install --removable` fixes it.
/// Most distributions' installers and all cloud images put a copy at the removable path.
enum Importer {
    static let diskExtensions: Set<String> = ["img", "raw", "qcow2", "vmdk", "hds", "hdd"]
    static let machineExtensions: Set<String> = [Paths.bundleExtension, "aar", "zip", "pvm", "utm"]

    static func chooseAndImport() {
        let panel = NSOpenPanel()
        panel.title = "Import"
        panel.message = "Choose a Hyperbox machine or archive, a Parallels or UTM machine, or a disk image."
        panel.prompt = "Import"
        panel.canChooseFiles = true
        // Parallels and UTM machines look like folders when their apps aren't installed.
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        let filter = OpenFilter()
        panel.delegate = filter
        guard panel.runModal() == .OK else { return }
        importFiles(panel.urls)
    }

    static func importFiles(_ urls: [URL]) {
        for url in urls { importFile(url) }
    }

    static func importFile(_ url: URL) {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case Paths.bundleExtension:
            importBundle(url)
        case "aar", "zip":
            importArchive(url)
        case "pvm":
            importMachine(url, title: "Importing \(url.deletingPathExtension().lastPathComponent) from Parallels") {
                let machine = try ParallelsMachine(url)
                return (machine.name, machine.cpuCount, machine.memoryMB, try machine.open(), nil)
            }
        case "utm":
            importMachine(url, title: "Importing \(url.deletingPathExtension().lastPathComponent) from UTM") {
                let machine = try UTMMachine(url)
                return (machine.name, machine.cpuCount, machine.memoryMB, try DiskImages.open(machine.disk), machine.efiVariables)
            }
        case "hdd":
            importMachine(url, title: "Importing \(url.deletingPathExtension().lastPathComponent)") {
                (url.deletingPathExtension().lastPathComponent, nil, nil, try ParallelsDisk(url), nil)
            }
        default:
            importMachine(url, title: "Importing \(url.deletingPathExtension().lastPathComponent)") {
                (url.deletingPathExtension().lastPathComponent, nil, nil, try DiskImages.open(url), nil)
            }
        }
    }

    // MARK: - Hyperbox

    private static func importBundle(_ url: URL) {
        let alert = NSAlert()
        alert.messageText = "Copy “\(url.deletingPathExtension().lastPathComponent)” into your library?"
        alert.informativeText = "A copy lives with your other machines. Opening it where it is keeps it there, on an external disk for example; don't move it while Hyperbox lists it."
        alert.addButton(withTitle: "Copy")
        alert.addButton(withTitle: "Open Where It Is")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            copyIntoLibrary(url)
        case .alertSecondButtonReturn:
            do {
                try makeUnique(url)
                Library.shared.add(url)
            } catch { show(error) }
        default:
            return
        }
    }

    static func copyIntoLibrary(_ url: URL) {
        guard let config = try? MachineConfig.load(from: url) else { return show(ControlError("\(url.lastPathComponent) isn't a Hyperbox machine.")) }
        let destination = Library.newBundleURL(named: config.name)
        StorageActivity.shared.run("Copying \(config.name)") { report in
            try StorageCopy.copy(url, to: destination, report: report)
            await adopt(destination)
        }
    }

    /// Unpacks into a hidden folder in the library, then moves the machine into place.
    private static func importArchive(_ url: URL) {
        let staging = Paths.machines.appending(path: ".import-\(UUID().uuidString)")
        StorageActivity.shared.run("Opening \(url.lastPathComponent)") { report in
            let fm = FileManager.default
            try fm.createDirectory(at: staging, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: staging) }
            if url.pathExtension.lowercased() == "zip" {
                try runDitto(["-x", "-k", url.path, staging.path])
            } else {
                try StorageArchive.extract(url, into: staging, report: report)
            }
            // Our archives hold the bundle's contents; zips made in Finder hold the bundle.
            var bundle = staging
            if !fm.fileExists(atPath: staging.appending(path: MachineConfig.fileName).path) {
                let inside = try fm.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil)
                guard let found = inside.first(where: { fm.fileExists(atPath: $0.appending(path: MachineConfig.fileName).path) }) else {
                    throw ControlError("\(url.lastPathComponent) has no Hyperbox machine in it.")
                }
                bundle = found
            }
            if url.pathExtension.lowercased() == "zip" {
                // Zips unpack with every zero written out; give the space back.
                report.status("Freeing empty space…")
                for disk in [bundle.appending(path: "disk.img")] + SnapshotFiles.list(MachineBundle(url: bundle)).map({
                    SnapshotFiles.directory(MachineBundle(url: bundle), $0.id).appending(path: "disk.img")
                }) where fm.fileExists(atPath: disk.path) {
                    try DiskConverter.makeSparse(disk)
                }
            }
            let config = try MachineConfig.load(from: bundle)
            let destination = await Library.newBundleURL(named: config.name)
            try fm.moveItem(at: bundle, to: destination)
            await adopt(destination)
        }
    }

    nonisolated private static func runDitto(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = arguments
        let errors = Pipe()
        process.standardError = errors
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            throw ControlError("Couldn't unzip it: \(message.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
    }

    /// Adds a bundle copied into the library, as a machine of its own if its id is taken.
    private static func adopt(_ url: URL) async {
        do { try makeUnique(url) } catch { show(error) }
        Library.shared.add(url)
    }

    /// Two machines can't share an id: it names their control socket. Nor a MAC address, or DHCP would give
    /// both the same IP. The copy keeps its machine identifier; a saved state that no longer matches the new
    /// MAC boots fresh instead of resuming.
    private static func makeUnique(_ url: URL) throws {
        var config = try MachineConfig.load(from: url)
        guard Library.shared.machines.contains(where: { $0.id == config.id && $0.url.standardizedFileURL != url.standardizedFileURL }) else { return }
        config.id = UUID()
        config.name = Library.shared.uniqueName(config.name)
        config.network.macAddress = MachineConfig.Network.randomMAC()
        try config.save(to: url)
    }

    // MARK: - Other apps

    typealias Source = (name: String, cpuCount: Int?, memoryMB: UInt64?, disk: DiskImage, efiVariables: URL?)

    /// Makes a new Linux machine around a disk from elsewhere, converting it to a sparse raw disk.
    private static func importMachine(_ url: URL, title: String, open: @escaping @Sendable () throws -> Source) {
        StorageActivity.shared.run(title) { report in
            let source = try open()
            let name = await Library.shared.uniqueName(source.name)
            let destination = await Library.newBundleURL(named: name)
            let cores = ProcessInfo.processInfo.processorCount
            let cpus = min(max(source.cpuCount ?? 4, 1), cores)
            let memory = min(max(source.memoryMB ?? 4096, 1024), (ProcessInfo.processInfo.physicalMemory >> 20) / 2)
            let config = MachineConfig(name: name, os: .linux, cpuCount: cpus, memorySize: memory << 20, diskSize: (source.disk.size + 511) / 512 * 512)
            let bundle = MachineBundle(url: destination)
            let fm = FileManager.default
            try fm.createDirectory(at: destination, withIntermediateDirectories: true)
            do {
                if let raw = source.disk as? RawImage {
                    // Already what Virtualization reads: clone it (the original stays as it was).
                    try FileClone.clone(raw.file.url, to: bundle.disk)
                    // Virtualization wants whole sectors.
                    truncate(bundle.disk.path, off_t(config.diskSize))
                } else {
                    try DiskConverter.convert(source.disk, to: bundle.disk) { report.progress($0) }
                }
                if let efi = source.efiVariables { try FileClone.clone(efi, to: bundle.efiVariables) }
                try config.save(to: destination)
            } catch {
                try? fm.removeItem(at: destination)
                throw error
            }
            await MainActor.run { Library.shared.add(destination) }
        }
    }

    private static func show(_ error: Error) {
        NSAlert(error: error).runModal()
    }

    /// Greys out files Hyperbox can't import, in the open panel.
    private final class OpenFilter: NSObject, NSOpenSavePanelDelegate {
        func panel(_ sender: Any, shouldEnable url: URL) -> Bool {
            let ext = url.pathExtension.lowercased()
            if Importer.diskExtensions.contains(ext) || Importer.machineExtensions.contains(ext) { return true }
            return url.hasDirectoryPath && ext.isEmpty
        }
    }
}

/// A UTM machine (`.utm`): config.plist, and its disks in Data/.
///
/// UTM machines on Apple's Virtualization ("Apple" backend) use raw disks and Virtualization's own EFI
/// store, both kept as they are. QEMU ones use QCOW2, converted. Intel (x86_64) machines can't move:
/// Hyperbox runs Arm guests natively and doesn't emulate. Nor can macOS ones, yet.
nonisolated struct UTMMachine {
    var name: String
    var cpuCount: Int?
    var memoryMB: UInt64?
    var disk: URL
    /// Apple backend: Virtualization's EFI variable store, which keeps the guest's boot entries.
    var efiVariables: URL?

    init(_ bundle: URL) throws {
        let configURL = bundle.appending(path: "config.plist")
        guard let data = try? Data(contentsOf: configURL),
              let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { throw ControlError("\(bundle.lastPathComponent) has no config.plist; is it a UTM machine?") }
        let system = plist["System"] as? [String: Any] ?? [:]
        let information = plist["Information"] as? [String: Any] ?? plist["Info"] as? [String: Any] ?? [:]
        let backend = plist["Backend"] as? String ?? "QEMU"

        if let architecture = system["Architecture"] as? String, !["aarch64", "arm64"].contains(architecture) {
            throw ControlError("This UTM machine emulates a \(architecture) computer. Hyperbox runs Arm machines only, at full speed, and doesn't emulate others.")
        }
        let boot = system["Boot"] as? [String: Any]
        if (boot?["OperatingSystem"] as? String)?.lowercased() == "macos" || system["MacPlatform"] != nil {
            throw ControlError("This is a macOS machine. Hyperbox can't import macOS machines from UTM yet: make a new one and use Migration Assistant.")
        }

        name = information["Name"] as? String ?? bundle.deletingPathExtension().lastPathComponent
        cpuCount = (system["CPUCount"] as? Int).flatMap { $0 > 0 ? $0 : nil }
        memoryMB = (system["MemorySize"] as? Int ?? system["Memory"] as? Int).map { UInt64($0) }

        let dataFolder = bundle.appending(path: "Data")
        let drives = plist["Drive"] as? [[String: Any]] ?? plist["Drives"] as? [[String: Any]] ?? []
        let disks = drives.compactMap { drive -> URL? in
            guard let image = drive["ImageName"] as? String else { return nil }
            let type = (drive["ImageType"] as? String)?.lowercased()
            if let type, type != "disk" { return nil }
            if drive["IsExternal"] as? Bool == true || image.lowercased().hasSuffix(".iso") { return nil }
            let url = dataFolder.appending(path: image)
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }
        guard let first = disks.first else { throw ControlError("\(bundle.lastPathComponent) has no disk.") }
        disk = first
        let efi = dataFolder.appending(path: "efi_vars.fd")
        efiVariables = backend == "Apple" && FileManager.default.fileExists(atPath: efi.path) ? efi : nil
    }
}
