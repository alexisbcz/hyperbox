import AppKit

/// The Containers page's view of the engine: its status, from the file the engine writes, and its
/// containers, from Docker, polled while the page is open.
///
/// It reads the status file rather than Docker while the engine is stopped, since connecting to the
/// socket would start it.
@Observable
final class Containers {
    static let shared = Containers()

    private(set) var status: EngineStatus?
    private(set) var containers: [ContainerSummary] = []
    private(set) var error: String?
    /// Something in progress: "Starting the engine", "Pulling postgres:17", …
    private(set) var activity: String?
    private(set) var usesHyperbox = DockerContext.isCurrent

    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var polling = false
    @ObservationIgnored private var watchers = 0
    /// Views that show the container list, which is only fetched while one is open.
    @ObservationIgnored private var listWatchers = 0

    var state: EngineState { status?.state ?? .stopped }
    var isRunning: Bool { state == .running }

    private init() {}

    /// Registers the LaunchAgent for this copy of the app, so `docker` can start the engine with Hyperbox closed.
    static func registerAgent() {
        guard let executable = Bundle.main.executableURL?.path else { return }
        Task.detached {
            do { try EngineAgent.register(executable: executable) } catch {
                NSLog("Hyperbox: couldn't register the container engine: \(error.localizedDescription)")
            }
        }
    }

    /// Polls while a view showing the engine is on screen; `containers` also fetches the list.
    func watch(containers: Bool = false) {
        watchers += 1
        if containers { listWatchers += 1 }
        refresh()
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func unwatch(containers: Bool = false) {
        watchers -= 1
        if containers { listWatchers = max(0, listWatchers - 1) }
        guard watchers <= 0 else { return }
        watchers = 0
        timer?.invalidate()
        timer = nil
    }

    func refresh() {
        let new = EngineStatus.read()
        if new != status { status = new }
        usesHyperbox = DockerContext.isCurrent
        guard new?.state == .running else {
            if !containers.isEmpty { containers = [] }
            return
        }
        guard !polling, listWatchers > 0 else { return }
        polling = true
        Task.detached {
            let result = Result { try ContainerEngine.containers() }
            await MainActor.run {
                self.polling = false
                switch result {
                case .success(let list):
                    let sorted = list.sorted { ($0.isRunning ? 0 : 1, -$0.created) < ($1.isRunning ? 0 : 1, -$1.created) }
                    if sorted != self.containers { self.containers = sorted }
                case .failure(let error):
                    self.error = error.localizedDescription
                }
            }
        }
    }

    // MARK: - Engine

    func startEngine() {
        perform("Starting the engine") { try ContainerEngine.ping() }
    }

    func stopEngine() {
        guard let pid = status?.pid else { return }
        kill(pid, SIGTERM)
        refresh()
    }

    /// Stops the engine so new settings apply; the next docker command or `startEngine` boots it with them.
    func restartEngine() {
        guard let pid = status?.pid else { return }
        kill(pid, SIGTERM)
        perform("Restarting the engine") {
            for _ in 0..<300 where EngineStatus.read() != nil { try await Task.sleep(for: .milliseconds(100)) }
            try ContainerEngine.ping()
        }
    }

    /// Points `docker` at Hyperbox, or back at what it used before.
    func setUsesHyperbox(_ on: Bool) {
        do {
            if on { try DockerContext.setUp() } else { try DockerContext.restore() }
        } catch {
            self.error = error.localizedDescription
        }
        usesHyperbox = DockerContext.isCurrent
    }

    // MARK: - Containers

    func start(_ container: ContainerSummary) { perform("Starting \(container.name)") { try ContainerEngine.start(container.id) } }
    func stop(_ container: ContainerSummary) { perform("Stopping \(container.name)") { try ContainerEngine.stop(container.id) } }
    func restart(_ container: ContainerSummary) { perform("Restarting \(container.name)") { try ContainerEngine.restart(container.id) } }
    func remove(_ container: ContainerSummary) { perform("Removing \(container.name)") { try ContainerEngine.remove(container.id) } }

    /// Runs `work` off the main thread, showing `label` meanwhile and any error after.
    func perform(_ label: String, _ work: @escaping @Sendable () async throws -> Void) {
        activity = label
        error = nil
        Task.detached {
            let result = await Result { try await work() }
            await MainActor.run {
                if self.activity == label { self.activity = nil }
                if case .failure(let error) = result { self.error = error.localizedDescription }
                self.refresh()
            }
        }
    }

    func setActivity(_ text: String?) { activity = text }
    func clearError() { error = nil }
}

extension Result where Failure == Error {
    init(catching body: () async throws -> Success) async {
        do { self = .success(try await body()) } catch { self = .failure(error) }
    }
}
