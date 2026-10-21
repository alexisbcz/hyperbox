import SwiftUI
import Virtualization

/// What a running Linux machine needs beyond booting: following an automatic install to the end,
/// and plugging in, then ejecting, an installer ISO.
///
/// The ISO is a USB drive plugged in as the machine starts, rather than one in its configuration,
/// because only a drive attached at run time can be detached again. Virtualization restarts a Linux
/// guest that reboots in place, without stopping it, so an installer's final reboot comes back up with
/// the ISO still plugged in; installers put the new system first in the EFI boot order, so it boots the
/// disk anyway. The ISO then stays out from the next time the machine starts or stops with more than
/// `installedDiskSize` on its disk. A live session that never installed leaves the disk empty and keeps
/// its ISO. "Eject Installer" unplugs it at once.
enum LinuxGuest {
    static let installedDiskSize: Int64 = 64 << 20

    private static var installRestarts = 0
    private static var progress = InstallProgress()

    /// Call when the machine has booted.
    static func started(_ machine: Machine) {
        guard machine.config.os == .linux, let vm = machine.virtualMachine else { return }
        if let install = machine.config.install, install.kind == .iso, let source = install.source {
            if diskUsage(machine.bundle.disk) > installedDiskSize {
                machine.updateConfig { $0.install = nil }
            } else {
                attachInstaller(URL(fileURLWithPath: source), to: vm, machine: machine)
            }
        }
        if machine.config.install?.kind == .cloudInit {
            followInstall(machine, vm: vm)
        }
        #if DEBUG
        DebugTyping.watch(machine)
        #endif
    }

    /// Call when the guest has stopped; `requested` when the Mac asked it to.
    static func stopped(_ machine: Machine, requested: Bool) {
        guard machine.config.os == .linux else { return }
        switch machine.config.install?.kind {
        case .iso:
            ejectIfInstalled(machine)
        case .cloudInit where !requested:
            // The setup reboots in place, so a stop it didn't ask for is a guest that powered off midway:
            // carry on, unless it keeps stopping, which no reboot would.
            installRestarts += 1
            if installRestarts <= 3 { Task { await machine.start() } }
        default:
            break
        }
    }

    /// Stops attaching the ISO for the next boot once the guest has written a system to its disk.
    private static func ejectIfInstalled(_ machine: Machine) {
        if diskUsage(machine.bundle.disk) > installedDiskSize { machine.updateConfig { $0.install = nil } }
    }

    /// Plugs the ISO in as a USB drive, right as the firmware starts looking for something to boot.
    private static func attachInstaller(_ iso: URL, to vm: VZVirtualMachine, machine: Machine) {
        do {
            guard let controller = vm.usbControllers.first else { throw ControlError("The machine has no USB controller.") }
            let drive = VZUSBMassStorageDevice(configuration: VZUSBMassStorageDeviceConfiguration(
                attachment: try VZDiskImageStorageDeviceAttachment(url: iso, readOnly: true)))
            controller.attach(device: drive) { error in
                if let error { MainActor.assumeIsolated { machine.fail(error) } }
            }
        } catch {
            machine.fail(error)
        }
    }

    static func ejectInstaller(_ machine: Machine) async {
        if let vm = machine.virtualMachine {
            for controller in vm.usbControllers {
                for device in controller.usbDevices where device is VZUSBMassStorageDevice {
                    try? await controller.detach(device: device)
                }
            }
        }
        machine.updateConfig { $0.install = nil }
    }

    /// The bytes the disk takes on the Mac: it's sparse, so this is what the guest wrote.
    private static func diskUsage(_ url: URL) -> Int64 {
        var info = stat()
        guard stat(url.path, &info) == 0 else { return 0 }
        return Int64(info.st_blocks) * 512
    }

    // MARK: - Automatic installs

    /// Reads progress from the console while cloud-init sets the guest up, and asks the agent, every
    /// few seconds, whether it's done: it says `ready` once the setup ran and the guest restarted.
    private static func followInstall(_ machine: Machine, vm: VZVirtualMachine) {
        Task {
            var offset: UInt64 = 0
            var lastPing = Date.distantPast
            while machine.virtualMachine === vm, machine.config.install?.kind == .cloudInit {
                if let handle = try? FileHandle(forReadingFrom: machine.bundle.console) {
                    try? handle.seek(toOffset: offset)
                    let data = handle.readDataToEndOfFile()
                    try? handle.close()
                    offset += UInt64(data.count)
                    progress.feed(data)
                    if machine.progress != progress.fraction { machine.progress = progress.fraction }
                    if machine.activity != progress.activity { machine.activity = progress.activity }
                }
                if Date().timeIntervalSince(lastPing) > 4 {
                    lastPing = Date()
                    if let reply = await GuestAgent.ping(machine) {
                        if let problem = reply["setupError"]?.string {
                            machine.activity = "The setup stopped: \(problem) The log is in console.log in the machine's bundle."
                            machine.progress = nil
                            return
                        }
                        if reply["ready"]?.bool == true {
                            finishInstall(machine)
                            return
                        }
                    }
                }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private static func finishInstall(_ machine: Machine) {
        try? FileManager.default.removeItem(at: machine.bundle.seed)
        progress = InstallProgress()
        installRestarts = 0
        machine.installFinished()
    }
}

/// How far an automatic install has got, from what it prints to the console: the setup's
/// `hyperbox:` lines, and apt's or dnf's package counts.
struct InstallProgress {
    private(set) var fraction = 0.02
    private(set) var step = "Starting up"
    private var total = 0, fetched = 0, configured = 0
    private var pending = Data()

    var activity: String {
        if total > 0, configured > 0 { return "\(step) (\(min(configured, total)) of \(total) packages)" }
        if total > 0, fetched > 0 { return "\(step) (downloading \(min(fetched, total)) of \(total) packages)" }
        return step
    }

    mutating func feed(_ data: Data) {
        pending.append(data)
        while let end = pending.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
            let line = String(decoding: pending[pending.startIndex..<end], as: UTF8.self)
            pending.removeSubrange(pending.startIndex...end)
            read(line)
        }
    }

    private mutating func read(_ line: String) {
        if line.hasPrefix("hyperbox: ") {
            step = String(line.dropFirst("hyperbox: ".count))
            switch step {
            case "Signing in automatically": advance(to: 0.9)
            case "Finishing": advance(to: 0.92)
            case "Restarting": advance(to: 0.96)
            default: advance(to: 0.04)
            }
            return
        }
        // apt: "3 upgraded, 1520 newly installed, 0 to remove and 12 not upgraded."
        if let match = line.firstMatch(of: /(\d+) upgraded, (\d+) newly installed/) {
            total = (Int(match.1) ?? 0) + (Int(match.2) ?? 0)
            fetched = 0
            configured = 0
        } else if total > 0, line.hasPrefix("Get:") {
            fetched += 1
        } else if total > 0, line.hasPrefix("Setting up ") {
            configured += 1
        } else if let match = line.firstMatch(of: /^\[\s*(\d+)\/(\d+)\]/) {
            // dnf: "[ 12/1530] name-version.aarch64 …" while downloading, then "[ 12/1530] Installing …".
            let n = Int(match.1) ?? 0, count = Int(match.2) ?? 0
            if line.contains("Installing") || line.contains("Upgrading") || line.contains("Running scriptlet") {
                total = max(total, count)
                configured = max(configured, n)
            } else if configured == 0 {
                total = max(total, count)
                fetched = max(fetched, n)
            }
        } else {
            return
        }
        guard total > 0 else { return }
        advance(to: 0.05 + 0.3 * min(Double(fetched) / Double(total), 1) + 0.55 * min(Double(configured) / Double(total), 1))
    }

    private mutating func advance(to value: Double) { fraction = max(fraction, value) }
}

/// Stops attaching the installer ISO, for the Machine menu and the toolbar.
struct EjectInstallerButton: View {
    let machine: Machine

    var body: some View {
        if machine.config.install?.kind == .iso {
            Button("Eject Installer", systemImage: "eject") { Task { await LinuxGuest.ejectInstaller(machine) } }
        }
    }
}
