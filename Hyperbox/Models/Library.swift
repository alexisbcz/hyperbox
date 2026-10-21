import AppKit

/// The machines the library window lists, with the state of the ones running.
@Observable
final class Library {
    static let shared = Library()

    struct Entry: Identifiable, Equatable {
        var url: URL
        var config: MachineConfig
        var id: UUID { config.id }
        var bundle: MachineBundle { MachineBundle(url: url) }
    }

    private(set) var machines: [Entry] = []
    /// Running machines by id; a machine missing here is stopped.
    private(set) var statuses: [UUID: MachineStatus] = [:]
    var selection: UUID?
    var showingNewMachine = false
    /// Bumped when a thumbnail may have changed, so views reload it.
    private(set) var thumbnailGeneration = 0

    @ObservationIgnored private var timer: Timer?
    /// When each config.json last changed, so edits made in a machine's own window, or by the
    /// `hyperbox` command, show up here. Reading never writes back, so the two processes can't loop.
    @ObservationIgnored private var configDates: [UUID: Date] = [:]

    private init() {
        Paths.ensure(Paths.machines)
        reload()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshStatuses()
                self?.refreshConfigs()
            }
        }
    }

    func reload() {
        machines = Paths.machineBundles().compactMap { url in
            (try? MachineConfig.load(from: url)).map { Entry(url: url, config: $0) }
        }
        .sorted { $0.config.created < $1.config.created }
        configDates = Dictionary(machines.map { ($0.id, Self.modified($0.bundle.config)) }, uniquingKeysWith: { $1 })
        refreshStatuses()
        if selection == nil || !machines.contains(where: { $0.id == selection }) { selection = machines.first?.id }
    }

    private func refreshStatuses() {
        var new: [UUID: MachineStatus] = [:]
        for machine in machines {
            if let status = MachineStatus.read(for: machine.id) { new[machine.id] = status }
        }
        if new.keys != statuses.keys || new.contains(where: { statuses[$0.key]?.state != $0.value.state }) { thumbnailGeneration += 1 }
        if new != statuses { statuses = new }
    }

    private func refreshConfigs() {
        for index in machines.indices {
            let entry = machines[index]
            let date = Self.modified(entry.bundle.config)
            guard date != configDates[entry.id] else { continue }
            configDates[entry.id] = date
            if let config = try? MachineConfig.load(from: entry.url), config.id == entry.id, config != entry.config {
                machines[index].config = config
            }
        }
    }

    private static func modified(_ url: URL) -> Date {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date) ?? .distantPast
    }

    func entry(_ id: UUID?) -> Entry? { machines.first { $0.id == id } }

    func state(of id: UUID) -> MachineState { statuses[id]?.state ?? .stopped }

    func isRunning(_ id: UUID) -> Bool { statuses[id] != nil && state(of: id) != .stopped }

    // MARK: - Changing machines

    /// Writes a changed config, and tells the machine if it's running.
    func update(_ id: UUID, _ change: (inout MachineConfig) -> Void) {
        guard let index = machines.firstIndex(where: { $0.id == id }) else { return }
        change(&machines[index].config)
        try? machines[index].config.save(to: machines[index].url)
        if statuses[id] != nil {
            Task.detached { _ = try? ControlClient.send(.reloadConfig, to: id) }
        }
    }

    /// Opens the machine in its own process, which boots it.
    func start(_ id: UUID) {
        guard let entry = entry(id) else { return }
        if statuses[id] != nil {
            Task.detached { _ = try? ControlClient.send(.show, to: id) }
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.arguments = [MachineApp.argument, entry.url.path]
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, error in
            if let error { Task { @MainActor in NSAlert(error: error).runModal() } }
        }
    }

    func send(_ method: ControlMethod, to id: UUID) {
        Task.detached {
            do { _ = try ControlClient.send(method, to: id) } catch {
                await MainActor.run { NSAlert(error: error).runModal() }
            }
        }
    }

    /// Adds a new machine's bundle to the library, and selects it.
    func add(_ url: URL) {
        ExternalMachines.add(url)
        reload()
        if let config = try? MachineConfig.load(from: url) { selection = config.id }
    }

    /// Moves the machine to the Trash.
    func delete(_ id: UUID) {
        guard let entry = entry(id), statuses[id] == nil else { return }
        NSWorkspace.shared.recycle([entry.url]) { _, _ in
            Task { @MainActor in
                ExternalMachines.remove(entry.url)
                self.reload()
            }
        }
    }

    func reveal(_ id: UUID) {
        guard let entry = entry(id) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([entry.url])
    }

    /// A free bundle name in the library, like "Ubuntu 2".
    static func newBundleURL(named name: String) -> URL {
        var candidate = Paths.machines.appending(path: "\(name).\(Paths.bundleExtension)")
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = Paths.machines.appending(path: "\(name) \(n).\(Paths.bundleExtension)")
            n += 1
        }
        return candidate
    }

    func uniqueName(_ name: String) -> String {
        let names = Set(machines.map(\.config.name))
        guard names.contains(name) else { return name }
        var n = 2
        while names.contains("\(name) \(n)") { n += 1 }
        return "\(name) \(n)"
    }
}
