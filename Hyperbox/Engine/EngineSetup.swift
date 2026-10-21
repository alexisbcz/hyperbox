import Foundation

/// Makes the engine's disk the first time: Debian's generic cloud image, which cloud-init sets up on first
/// boot with Docker and the few services Hyperbox talks to over vsock.
///
/// Debian rather than a smaller distribution because its kernel has everything Docker needs (overlayfs,
/// netfilter, virtiofs, vsock, the balloon) and its docker.io package is maintained; the first boot
/// takes a minute or two, and later boots skip the firmware and GRUB (see `EngineHost.bootLoader`).
enum EngineSetup {
    static let imageURL = URL(string: "https://cloud.debian.org/images/cloud/trixie/latest/debian-13-generic-arm64.tar.xz")!

    /// vsock ports of the services in the guest.
    static let dockerPort: UInt32 = 2375
    static let infoPort: UInt32 = 2376
    /// The Mac connects here with "port\n" to reach a published port.
    static let forwardPort: UInt32 = 2377
    /// The guest connects to the Mac here with "ip port\n" for each outgoing TCP connection.
    static let proxyPort: UInt32 = 3129

    /// virtiofs tags.
    static let homeTag = "hyperbox-home"
    static let foldersTag = "hyperbox-folders"
    static let bootTag = "hyperbox-boot"
    static let rosettaTag = "rosetta"

    static var isSetUp: Bool { FileManager.default.fileExists(atPath: EnginePaths.ready.path) }

    /// Downloads the image (or reuses the copy in Downloads), writes the disk and the cloud-init seed.
    static func prepare(settings: EngineSettings, progress: @escaping @MainActor (String, Double?) -> Void) async throws {
        let fm = FileManager.default
        Paths.ensure(EnginePaths.root)
        Paths.ensure(EnginePaths.boot)
        if !fm.fileExists(atPath: EnginePaths.disk.path) {
            let archive = try await EngineDownload.fetch(imageURL) { fraction in progress("Downloading Debian", fraction) }
            progress("Unpacking Debian", nil)
            let partial = EnginePaths.root.appending(path: "disk.img.part")
            try await unpackSparse(archive, member: "disk.raw", to: partial)
            try MachineFactory.grow(partial, to: settings.diskSize)
            try fm.moveItem(at: partial, to: EnginePaths.disk)
        }
        try await writeSeed()
    }

    /// Extracts one file of a tar.xz, skipping runs of zeros so the disk stays sparse: the 3 GB image
    /// takes only the 1 GB it uses (tar itself writes every zero).
    nonisolated static func unpackSparse(_ archive: URL, member: String, to destination: URL) async throws {
        try await Task.detached {
            let p = Process(), out = Pipe()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
            p.arguments = ["-xJOf", archive.path, member]
            p.standardOutput = out
            p.standardError = FileHandle.nullDevice
            try p.run()
            FileManager.default.createFile(atPath: destination.path, contents: nil)
            let file = try FileHandle(forWritingTo: destination)
            defer { try? file.close() }
            let block = 1 << 20
            var pending = Data()
            var offset: UInt64 = 0
            let zeros = Data(count: block)
            func flush(_ chunk: Data) throws {
                let empty = chunk.withUnsafeBytes { a in zeros.withUnsafeBytes { memcmp(a.baseAddress!, $0.baseAddress!, a.count) == 0 } }
                if empty {
                    offset += UInt64(chunk.count)
                } else {
                    try file.seek(toOffset: offset)
                    try file.write(contentsOf: chunk)
                    offset += UInt64(chunk.count)
                }
            }
            while let data = try out.fileHandleForReading.read(upToCount: block), !data.isEmpty {
                pending.append(data)
                while pending.count >= block {
                    try flush(pending.prefix(block))
                    pending.removeFirst(block)
                }
            }
            if !pending.isEmpty { try flush(pending) }
            try file.truncate(atOffset: offset)
            p.waitUntilExit()
            guard p.terminationStatus == 0 else { throw ControlError("Couldn't unpack \(archive.lastPathComponent).") }
        }.value
    }

    /// The cloud-init seed: a small ISO labelled "cidata" with user-data and meta-data.
    static func writeSeed() async throws {
        let fm = FileManager.default
        let dir = EnginePaths.root.appending(path: "seed")
        try? fm.removeItem(at: dir)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        try "instance-id: hyperbox-engine-\(UUID().uuidString.lowercased())\nlocal-hostname: hyperbox\n"
            .write(to: dir.appending(path: "meta-data"), atomically: true, encoding: .utf8)
        try userData.write(to: dir.appending(path: "user-data"), atomically: true, encoding: .utf8)
        try? fm.removeItem(at: EnginePaths.seed)
        try await Shell.run("/usr/bin/hdiutil", ["makehybrid", "-iso", "-joliet", "-default-volume-name", "cidata", "-o", EnginePaths.seed.path, dir.path])
    }

    /// Puts the guest agent and its service in the boot share, before every boot, so the agent in the
    /// guest is always the one this copy of Hyperbox ships.
    static func installAgent() throws {
        Paths.ensure(EnginePaths.boot)
        guard let agent = Bundle.main.url(forResource: "hyperbox-engine", withExtension: "py") else {
            throw ControlError("The engine agent is missing from Hyperbox.app.")
        }
        let script = try Data(contentsOf: agent)
        if (try? Data(contentsOf: EnginePaths.boot.appending(path: "hyperbox-engine.py"))) != script {
            try script.write(to: EnginePaths.boot.appending(path: "hyperbox-engine.py"), options: .atomic)
        }
        try unit.write(to: EnginePaths.boot.appending(path: "hyperbox-engine.service"), atomically: true, encoding: .utf8)
    }

    static let unit = """
        [Unit]
        Description=Hyperbox engine agent: Docker, published ports and the network, over vsock
        RequiresMountsFor=/mnt/hyperbox-boot
        Before=docker.service
        [Service]
        ExecStart=/usr/bin/python3 /mnt/hyperbox-boot/hyperbox-engine.py
        Restart=always
        RestartSec=1
        [Install]
        WantedBy=multi-user.target

        """

    static var userData: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return """
        #cloud-config
        hostname: hyperbox
        # The agent first: it carries the network, which the package install below needs.
        bootcmd:
          - [mkdir, -p, /mnt/hyperbox-boot]
          - [sh, -c, "mountpoint -q /mnt/hyperbox-boot || mount -t virtiofs \(bootTag) /mnt/hyperbox-boot"]
          # First boot: hand the Mac the kernel and power off; it boots that kernel directly from then on.
          - - sh
            - -c
            - |
              d=/mnt/hyperbox-boot
              [ -e $d/Image ] && exit 0
              k=$(ls -v /boot/vmlinuz-* | tail -1)
              zcat "$k" > $d/Image.new 2>/dev/null || cp "$k" $d/Image.new
              cp "$(ls -v /boot/initrd.img-* | tail -1)" $d/initrd
              echo "root=UUID=$(findmnt -no UUID /)" > $d/cmdline
              mv $d/Image.new $d/Image
              sync
              systemctl poweroff
          - [cp, /mnt/hyperbox-boot/hyperbox-engine.service, /etc/systemd/system/]
          - [systemctl, daemon-reload]
          - [systemctl, enable, hyperbox-engine.service]
          - [systemctl, start, --no-block, hyperbox-engine.service]
        package_update: true
        packages: [docker.io]
        mounts:
          - [\(homeTag), "\(home)", virtiofs, "defaults,nofail", "0", "0"]
          - [\(foldersTag), /var/folders, virtiofs, "defaults,nofail", "0", "0"]
          - [\(bootTag), /mnt/hyperbox-boot, virtiofs, "defaults,nofail", "0", "0"]
          - [\(rosettaTag), /mnt/rosetta, virtiofs, "defaults,nofail", "0", "0"]
        write_files:
          # Docker's networks stay in 172.16.0.0/12, which the agent keeps local; the rest leaves through the Mac.
          - path: /etc/docker/daemon.json
            content: |
              {"log-driver": "json-file", "log-opts": {"max-size": "10m", "max-file": "3"},
               "default-address-pools": [{"base": "172.16.0.0/12", "size": 20}]}
          # MODULES=dep: a small initrd with only this machine's drivers, which loads faster.
          - path: /etc/initramfs-tools/conf.d/hyperbox.conf
            content: |
              MODULES=dep
        runcmd:
          - [update-initramfs, -u]
          - [systemctl, disable, --now, apt-daily.timer, apt-daily-upgrade.timer, man-db.timer, e2scrub_all.timer, fstrim.timer]
          - [systemctl, enable, --now, docker.service]
          # Set up once; later boots skip cloud-init entirely.
          - [touch, /etc/cloud/cloud-init.disabled]
        """
    }
}

/// Downloads into Downloads, reusing a finished file and resuming nothing: a partial one starts over.
enum EngineDownload {
    static func fetch(_ url: URL, progress: @escaping @MainActor (Double?) -> Void) async throws -> URL {
        Paths.ensure(Paths.downloads)
        let destination = Paths.downloads.appending(path: url.lastPathComponent)
        if FileManager.default.fileExists(atPath: destination.path) { return destination }
        let delegate = Delegate(progress: progress)
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let (temporary, response) = try await session.download(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw ControlError("Couldn't download \(url.lastPathComponent) (HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)).")
        }
        try FileManager.default.moveItem(at: temporary, to: destination)
        return destination
    }

    private nonisolated final class Delegate: NSObject, URLSessionDownloadDelegate, Sendable {
        let progress: @MainActor (Double?) -> Void
        init(progress: @escaping @MainActor (Double?) -> Void) { self.progress = progress }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                        totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
            let fraction = totalBytesExpectedToWrite > 0 ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite) : nil
            let progress = progress
            Task { @MainActor in progress(fraction) }
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
    }
}
