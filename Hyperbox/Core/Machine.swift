import AppKit
import Virtualization

/// One running machine. Each machine runs in its own Hyperbox process (see `MachineApp`), so a
/// crash takes down only that machine, and it gets its own Dock icon.
@Observable
final class Machine: NSObject {
    let bundle: MachineBundle
    private(set) var config: MachineConfig
    private(set) var virtualMachine: VZVirtualMachine?
    /// Snapshots set it too, while they save and restore.
    var state: MachineState = .stopped {
        didSet {
            writeStatus()
            network.update()
        }
    }
    private(set) var message: String?
    /// Installer progress from 0 to 1.
    var progress: Double? {
        didSet { writeStatus() }
    }
    /// The guest's address on the NAT network, from its DHCP lease; see `GuestNetwork`.
    var ipAddress: String? {
        didSet { writeStatus() }
    }
    /// Port forwards that couldn't listen, by `PortForward.id`, with why.
    var portForwardErrors: [UUID: String] = [:] {
        didSet { writeStatus() }
    }

    /// Finds the guest's address and runs its port forwards.
    @ObservationIgnored private(set) lazy var network = GuestNetwork(machine: self)

    /// True while an agent has used the machine in the last few seconds, for the window's Agent badge.
    private(set) var agentActive = false
    @ObservationIgnored private var agentIdle: Task<Void, Never>?

    /// The view showing the screen, set by `MachineScreen`, for screenshots and agent input.
    @ObservationIgnored weak var screenView: VZVirtualMachineView?

    @ObservationIgnored private var server: ControlServer?

    init(bundle url: URL) throws {
        bundle = MachineBundle(url: url)
        config = try MachineConfig.load(from: url)
        super.init()
    }

    var id: UUID { config.id }

    // MARK: - Lifecycle

    /// Starts listening for commands; call once at launch.
    func listen() {
        let server = ControlServer(path: Paths.socket(for: id).path) { [weak self] request in
            guard let self else { throw ControlError("The machine is gone.") }
            return try await self.handle(request)
        }
        do { try server.start() } catch { fail(error) }
        self.server = server
        writeStatus()
    }

    func start() async {
        guard virtualMachine == nil || state == .stopped || state == .error else { return }
        message = nil
        do {
            if let install = config.install, install.kind == .ipsw {
                state = .installing
                try await MacInstaller.install(self)
                updateConfig { $0.install = nil }
            }
            state = .starting
            try growDisk()
            var extras = VirtualMachineBuilder.Extras()
            if let install = config.install, install.kind == .iso, let source = install.source {
                extras.installerISO = URL(fileURLWithPath: source)
            }
            let vm = VZVirtualMachine(configuration: try VirtualMachineBuilder.make(config, bundle: bundle, extras: extras))
            vm.delegate = self
            virtualMachine = vm
            try await bootOrResume(vm)
            state = .running
            MacSetup.installToolsWhenReady(self)
            if config.install?.kind == .cloudInit { state = .installing }
        } catch {
            fail(error)
        }
    }

    /// Asks the guest to shut down, as pressing the power button would.
    func stop() throws {
        guard let vm = virtualMachine else { return }
        // macOS answers the power button with a dialog that waits for a click, so with Hyperbox Tools
        // in the guest, ask it to shut down instead.
        if config.os == .macOS, state == .running {
            state = .stopping
            Task {
                let asked = (try? await GuestAgent.request(["op": "exec", "command": "shutdown -h now", "admin": true, "timeout": 10],
                                                          machine: self, timeout: 15)) != nil
                if !asked, vm.canRequestStop { try? vm.requestStop() }
            }
            return
        }
        if vm.canRequestStop {
            try vm.requestStop()
            state = .stopping
        } else {
            Task { await forceStop() }
        }
    }

    /// Pulls the plug.
    func forceStop() async {
        guard let vm = virtualMachine, vm.canStop else { return }
        saveThumbnail()
        try? await vm.stop()
        stopped()
    }

    func pause() async throws {
        guard let vm = virtualMachine, vm.canPause else { return }
        try await vm.pause()
        state = .paused
    }

    func resume() async throws {
        guard let vm = virtualMachine, vm.canResume else { return }
        try await vm.resume()
        state = .running
    }

    /// The guest stopped, by shutting down or from `forceStop`.
    private func stopped() {
        virtualMachine = nil
        screenView?.virtualMachine = nil
        state = .stopped
    }

    func fail(_ error: Error) {
        message = error.localizedDescription
        // A machine that never started, or died, has nothing left to stop.
        if let vm = virtualMachine, vm.state == .stopped || vm.state == .error { virtualMachine = nil }
        state = .error
    }

    /// Saves the config, and applies what can change while running.
    func updateConfig(_ change: (inout MachineConfig) -> Void) {
        var new = config
        change(&new)
        guard new != config else { return }
        let old = config
        config = new
        try? new.save(to: bundle.url)
        LiveSettings.apply(old: old, new: new, to: self)
    }

    /// Rereads config.json, after the library or the command line changed it.
    func reloadConfig() throws {
        let new = try MachineConfig.load(from: bundle.url)
        let old = config
        config = new
        LiveSettings.apply(old: old, new: new, to: self)
    }

    func shutdown() {
        server?.stop()
        try? FileManager.default.removeItem(at: Paths.status(for: id))
    }

    private var status: MachineStatus {
        MachineStatus(pid: getpid(), state: state, message: message, ipAddress: ipAddress, progress: progress,
                      portForwardErrors: portForwardErrors.isEmpty ? nil : Dictionary(uniqueKeysWithValues: portForwardErrors.map { ($0.key.uuidString, $0.value) }))
    }

    private func writeStatus() {
        status.write(for: id)
    }

    // MARK: - Screen

    /// The guest's screen as the window shows it.
    func screenshot() -> NSImage? {
        guard let view = screenView else { return nil }
        return ScreenCapture.image(of: view)
    }

    func saveThumbnail() {
        guard let image = screenshot(), let png = image.pngData(maxWidth: 640) else { return }
        try? png.write(to: bundle.thumbnail, options: .atomic)
    }

    // MARK: - Control

    func noteAgentActivity() {
        agentActive = true
        agentIdle?.cancel()
        agentIdle = Task {
            try? await Task.sleep(for: .seconds(4))
            if !Task.isCancelled { agentActive = false }
        }
    }

    private func handle(_ request: ControlRequest) async throws -> JSONValue {
        guard let method = ControlMethod(rawValue: request.method) else {
            throw ControlError("Unknown method \(request.method). Known: \(ControlMethod.allCases.map(\.rawValue).joined(separator: ", ")).")
        }
        let params = JSONValue.object(request.params)
        switch method {
        case .status:
            return try JSONValue(encoding: status)
        case .start:
            Task { await start() }
            return .null
        case .stop:
            try stop()
            return .null
        case .forceStop:
            await forceStop()
            return .null
        case .pause:
            try await pause()
            return .null
        case .resume:
            try await resume()
            return .null
        case .show:
            NSApp.activate()
            NSApp.windows.first { $0.isVisible }?.makeKeyAndOrderFront(nil)
            return .null
        case .reloadConfig:
            try reloadConfig()
            return .null
        case .screenshot, .type, .key, .click, .moveMouse, .scroll, .drag:
            guard config.agentControl else { throw ControlError("Agent control is off for \(config.name). Turn it on in the machine's settings.") }
            noteAgentActivity()
            return try await AgentControl.handle(method, params: params, machine: self)
        case .exec:
            guard config.agentControl else { throw ControlError("Agent control is off for \(config.name). Turn it on in the machine's settings.") }
            noteAgentActivity()
            return try await GuestAgent.exec(params, machine: self)
        case .listSnapshots, .takeSnapshot, .restoreSnapshot, .deleteSnapshot:
            return try await Snapshots.handle(method, params: params, machine: self)
        }
    }
}

extension Machine: VZVirtualMachineDelegate {
    nonisolated func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        MainActor.assumeIsolated {
            saveThumbnail()
            stopped()
        }
    }

    nonisolated func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) {
        MainActor.assumeIsolated {
            stopped()
            fail(error)
        }
    }
}

extension NSImage {
    func pngData(maxWidth: CGFloat? = nil) -> Data? {
        var size = self.size
        if let maxWidth, size.width > maxWidth { size = CGSize(width: maxWidth, height: (size.height * maxWidth / size.width).rounded()) }
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height), bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        draw(in: CGRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }
}
