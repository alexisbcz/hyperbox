#if DEBUG
import AppKit

/// For testing macOS machines without clicking through the New Machine sheet:
/// `HYPERBOX_CREATE_MACOS=<name>` makes one through the real code path (downloading the latest macOS,
/// or using `HYPERBOX_IPSW`), with `HYPERBOX_CPUS` (4), `HYPERBOX_MEMORY_GB` (6) and `HYPERBOX_DISK_GB` (64),
/// then starts it, which installs it. Progress goes to standard error.
enum MacTestHook {
    /// In a machine's process, `HYPERBOX_DROP=/a:/b` drops those files on the window once the guest's
    /// agent answers, as dragging them there would.
    static func dropIfRequested(_ machine: Machine) {
        guard let paths = ProcessInfo.processInfo.environment["HYPERBOX_DROP"] else { return }
        Task {
            while await GuestAgent.ping(machine) == nil { try? await Task.sleep(for: .seconds(2)) }
            let providers = paths.split(separator: ":").map { NSItemProvider(object: URL(fileURLWithPath: String($0)) as NSURL) }
            FileHandle.standardError.write(Data("[macos-test] dropping \(providers.count) items: \(FileDrop.drop(providers, on: machine))\n".utf8))
            while FileDrop.shared.transfer == nil { try? await Task.sleep(for: .milliseconds(100)) }
            while let transfer = FileDrop.shared.transfer {
                FileHandle.standardError.write(Data("[macos-test] \(transfer.title) \(transfer.fraction ?? -1)\n".utf8))
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    static func runIfRequested() {
        let environment = ProcessInfo.processInfo.environment
        guard let name = environment["HYPERBOX_CREATE_MACOS"] else { return }
        func number(_ key: String, _ fallback: Int) -> Int { environment[key].flatMap(Int.init) ?? fallback }
        var config = MachineConfig(name: name, os: .macOS, distribution: "macos", cpuCount: number("HYPERBOX_CPUS", 4),
                                   memorySize: UInt64(number("HYPERBOX_MEMORY_GB", 6)) << 30, diskSize: UInt64(number("HYPERBOX_DISK_GB", 64)) << 30)
        var last = ""
        let progress: MachineFactory.Progress = { status, fraction in
            let line = status + (fraction.map { String(format: " %.1f%%", $0 * 100) } ?? "")
            if line != last { last = line; FileHandle.standardError.write(Data("[macos-test] \(line)\n".utf8)) }
        }
        Task {
            do {
                let url = try await MacProvisioner.create(&config, ipsw: environment["HYPERBOX_IPSW"].map { URL(fileURLWithPath: $0) }, progress: progress)
                FileHandle.standardError.write(Data("[macos-test] created \(url.path)\n".utf8))
                Library.shared.add(url)
                Library.shared.start(config.id)
            } catch {
                FileHandle.standardError.write(Data("[macos-test] failed: \(error.localizedDescription)\n".utf8))
            }
        }
    }
}
#endif
