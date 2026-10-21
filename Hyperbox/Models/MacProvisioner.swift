import AppKit
import Virtualization

/// Fetches an IPSW and makes a macOS bundle ready for `MacInstaller`.
enum MacProvisioner {
    /// What installing needs on top of the download: the system, and room for it to grow.
    static let installSpace: Int64 = 30 << 30

    /// `ipsw` is a restore image you picked; nil downloads the latest one this Mac supports.
    static func create(_ config: inout MachineConfig, ipsw: URL?, progress: @escaping MachineFactory.Progress) async throws -> URL {
        let ipsw = if let ipsw { ipsw } else { try await download(progress: progress) }
        progress("Checking the restore image…", nil)
        let image: VZMacOSRestoreImage
        do { image = try await VZMacOSRestoreImage.image(from: ipsw) } catch {
            throw ControlError("\(ipsw.lastPathComponent) isn't a macOS restore image Hyperbox can read (\(error.localizedDescription)).")
        }
        guard let requirements = image.mostFeaturefulSupportedConfiguration, requirements.hardwareModel.isSupported else {
            throw ControlError("This Mac can't run macOS \(image.operatingSystemVersion.label). Try a newer restore image.")
        }
        try Task.checkCancellation()

        config.cpuCount = max(config.cpuCount, requirements.minimumSupportedCPUCount)
        config.memorySize = max(config.memorySize, requirements.minimumSupportedMemorySize)
        config.display = .matchingMainScreen()
        config.install = .init(kind: .ipsw, source: ipsw.path)
        // macOS 27 and later set up this user on their own, instead of showing Setup Assistant.
        if #available(macOS 27, *), image.operatingSystemVersion.majorVersion >= 27 { config.guestUser = MacSetup.newGuestUser() }

        progress("Creating \(config.name)…", nil)
        let url = try MachineFactory.createBundle(config)
        do {
            let bundle = MachineBundle(url: url)
            try requirements.hardwareModel.dataRepresentation.write(to: bundle.hardwareModel)
            try VZMacMachineIdentifier().dataRepresentation.write(to: bundle.machineIdentifier)
            _ = try VZMacAuxiliaryStorage(creatingStorageAt: bundle.auxiliaryStorage, hardwareModel: requirements.hardwareModel, options: [])
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
        return url
    }

    /// The latest macOS this Mac supports, from Apple, kept in `Paths.downloads` so the next machine
    /// installs without downloading it again.
    static func download(progress: @escaping MachineFactory.Progress) async throws -> URL {
        progress("Asking Apple for the latest macOS…", nil)
        let image: VZMacOSRestoreImage
        do { image = try await VZMacOSRestoreImage.latestSupported } catch {
            // Offline, say: an image downloaded before still installs.
            if let cached = cachedImages().first { return cached }
            throw ControlError("Couldn't find the latest macOS (\(error.localizedDescription)).")
        }
        let version = image.operatingSystemVersion
        let file = Paths.downloads.appending(path: "macOS \(version.label) (\(image.buildVersion)).ipsw")
        if FileManager.default.fileExists(atPath: file.path) { return file }

        let partial = ResumableDownload.partial(file)
        let have = (try? FileManager.default.attributesOfItem(atPath: partial.path)[.size] as? Int64) ?? 0
        if let size = await ResumableDownload.size(of: image.url) {
            try checkSpace(needed: size - have + installSpace)
        }

        let title = "Downloading macOS \(version.majorVersion)…"
        progress(title, have > 0 ? nil : 0)
        try await ResumableDownload.fetch(image.url, to: file) { received, total in
            Task { @MainActor in
                guard let total, total > 0 else { return progress("\(title) \(bytes(received))", nil) }
                progress("\(title) \(bytes(received)) of \(bytes(total))", Double(received) / Double(total))
            }
        }
        return file
    }

    /// Restore images downloaded earlier, newest first.
    static func cachedImages() -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: Paths.downloads, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return files.filter { $0.pathExtension == "ipsw" }.sorted {
            let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return a > b
        }
    }

    private static func checkSpace(needed: Int64) throws {
        Paths.ensure(Paths.downloads)
        let free = (try? Paths.downloads.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage ?? .max
        guard free >= needed else {
            throw ControlError("macOS needs about \(bytes(needed)) free to download and install, and this Mac has \(bytes(free)).")
        }
    }

    private static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }
}

extension OperatingSystemVersion {
    /// "27.0.1", or "27.1" when there's no patch.
    var label: String {
        patchVersion > 0 ? "\(majorVersion).\(minorVersion).\(patchVersion)" : "\(majorVersion).\(minorVersion)"
    }
}

extension MachineConfig.Display {
    /// A display as sharp as the Mac's own main screen, filling most of it, up to 5K.
    static func matchingMainScreen() -> Self {
        guard let screen = NSScreen.main else { return Self() }
        let visible = screen.visibleFrame.size
        var points = CGSize(width: (visible.width * 0.85).rounded(), height: (visible.height * 0.85).rounded())
        let scale = screen.backingScaleFactor
        let limit = CGSize(width: 5120 / scale, height: 2880 / scale)
        if points.width > limit.width || points.height > limit.height {
            let shrink = min(limit.width / points.width, limit.height / points.height)
            points = CGSize(width: (points.width * shrink).rounded(), height: (points.height * shrink).rounded())
        }
        // Virtualization picks the pixel size and density that make the guest look the same as the Mac.
        let display = VZMacGraphicsDisplayConfiguration(for: screen, sizeInPoints: points)
        return Self(width: display.widthInPixels, height: display.heightInPixels, pixelsPerInch: display.pixelsPerInch)
    }

    /// The display's size in points on the Mac's main screen, for sizing the window to show it.
    /// The window can't be bigger than the screen anyway, and the guest resizes its display to fit.
    var sizeInPoints: CGSize {
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        return CGSize(width: CGFloat(width) / scale, height: CGFloat(height) / scale)
    }
}
