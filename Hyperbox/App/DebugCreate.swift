#if DEBUG
import AppKit

/// For testing automatic installs without clicking through the New Machine sheet:
/// `HYPERBOX_CREATE=ubuntu` makes that catalog machine, and `HYPERBOX_CREATE=/path/to.iso` one that boots
/// the ISO (`HYPERBOX_CPUS`, `HYPERBOX_MEMORY_GB`, `HYPERBOX_DISK_GB`, `HYPERBOX_NAME` optional), prints
/// its bundle's path, and quits.
enum DebugCreate {
    static func runIfRequested() {
        let environment = ProcessInfo.processInfo.environment
        guard let id = environment["HYPERBOX_CREATE"] else { return }
        Task {
            do {
                let cpus = environment["HYPERBOX_CPUS"].flatMap(Int.init) ?? 2
                let memoryGB = environment["HYPERBOX_MEMORY_GB"].flatMap(Int.init) ?? 4
                if id.hasPrefix("/") {
                    let url = try MachineFactory.createFromISO(URL(fileURLWithPath: id), name: environment["HYPERBOX_NAME"] ?? "ISO",
                                                               cpus: cpus, memoryGB: memoryGB, diskGB: environment["HYPERBOX_DISK_GB"].flatMap(Int.init) ?? 8)
                    print("created \(url.path)")
                    exit(0)
                }
                guard let entry = Catalog.entry(id) else { throw ControlError("No catalog entry \(id).") }
                let url = try await MachineFactory.create(
                    from: entry, name: environment["HYPERBOX_NAME"] ?? entry.name,
                    cpus: cpus, memoryGB: memoryGB,
                    diskGB: environment["HYPERBOX_DISK_GB"].flatMap(Int.init) ?? entry.defaultDiskGB
                ) { status, fraction in
                    print("\(status) \(fraction.map { String(format: "%.0f%%", $0 * 100) } ?? "")")
                }
                print("created \(url.path)")
            } catch {
                print("failed: \(error.localizedDescription)")
            }
            exit(0)
        }
    }
}
#endif
