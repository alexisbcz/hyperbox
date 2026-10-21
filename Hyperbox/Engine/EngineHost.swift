import Foundation
import Virtualization

/// The container engine's process: `Hyperbox --engine`, started by launchd when something connects to
/// `~/.hyperbox/docker.sock` (see `EngineAgent`). No windows and no Dock icon.
///
/// Each connection to the socket boots the machine if it isn't running, then is piped to Docker's socket
/// in the guest over vsock. While running it forwards published ports, and after
/// `EngineSettings.idleMinutes` with no containers running and no connections open, shuts the guest
/// down and exits.
final class EngineHost: NSObject {
    static func main() {
        signal(SIGPIPE, SIG_IGN)
        let host = EngineHost()
        host.run()
        RunLoop.main.run()
    }

    private let settings = EngineSettings.load()
    private var virtualMachine: VZVirtualMachine?
    private var boot: Task<Void, Error>?
    private var fetchingKernel = false
    private var state: EngineState = .stopped { didSet { writeStatus() } }
    private var message: String?
    private var progress: Double?
    private var bootSeconds: Double?
    private var memoryUsed: UInt64?
    private var memoryLimit: UInt64?
    private var runningContainers: Int?
    private var lastBusy = Date()
    private var failedPings = 0
    private var listener: DispatchSourceRead?
    private var events: Task<Void, Never>?
    private var signals: [DispatchSourceSignal] = []
    private var network: UserNetwork?
    private var ports: ContainerPorts?
    private let connections = Counter()

    private func run() {
        log("Engine starting (pid \(getpid())).")
        writeStatus()
        do {
            let fd = try Self.inheritedSocket() ?? Sockets.listenUnix(EnginePaths.socket.path)
            listener = Sockets.accept(on: fd) { [weak self, connections] client in
                connections.add(1)
                Task { @MainActor in await self?.serve(client) }
            }
        } catch {
            fail(error)
            exit(1)
        }
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { [weak self] in
                MainActor.assumeIsolated { self?.quit(reason: "Asked to stop.") }
            }
            source.resume()
            signals.append(source)
        }
        Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    /// The socket launchd listened on for us, when launchd started us.
    private static func inheritedSocket() -> Int32? {
        typealias Activate = @convention(c) (UnsafePointer<CChar>, UnsafeMutablePointer<UnsafeMutablePointer<Int32>?>, UnsafeMutablePointer<Int>) -> Int32
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "launch_activate_socket") else { return nil }
        let activate = unsafeBitCast(symbol, to: Activate.self)
        var fds: UnsafeMutablePointer<Int32>?
        var count = 0
        guard activate(EngineAgent.socketName, &fds, &count) == 0, let fds, count > 0 else { return nil }
        defer { free(fds) }
        return fds[0]
    }

    // MARK: - Connections

    /// Boots the guest if needed, then pipes the client to Docker in it. The client waits meanwhile:
    /// Docker's client sends its request and waits for an answer, however long the boot takes.
    private func serve(_ client: Int32) async {
        do {
            try await ensureRunning()
            let upstream = try await connect(port: EngineSetup.dockerPort)
            lastBusy = Date()
            Sockets.pipe(client, upstream) { [connections] in connections.add(-1) }
        } catch {
            log("Couldn't serve a connection: \(error.localizedDescription)")
            // Answer in HTTP, so `docker` shows why rather than a bare EOF.
            let body = "{\"message\":\"Hyperbox's container engine couldn't start: \(error.localizedDescription.replacingOccurrences(of: "\"", with: "'"))\"}"
            let response = "HTTP/1.1 503 Service Unavailable\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
            try? DockerHTTP.writeAll(client, Data(response.utf8))
            close(client)
            connections.add(-1)
        }
    }

    private func ensureRunning() async throws {
        if state == .running, virtualMachine != nil { return }
        if state == .stopping { throw ControlError("The engine is shutting down; try again in a moment.") }
        if boot == nil {
            boot = Task { try await start() }
        }
        do {
            try await boot!.value
        } catch {
            boot = nil
            throw error
        }
    }

    private func connect(port: UInt32) async throws -> Int32 {
        guard let device = virtualMachine?.socketDevices.first as? VZVirtioSocketDevice else {
            throw ControlError("The engine isn't running.")
        }
        let connection = try await device.connect(toPort: port)
        let fd = dup(connection.fileDescriptor)
        connection.close()
        Sockets.noSigPipe(fd)
        return fd
    }

    /// A connection to a published port in the guest: the agent connects to it there.
    private func connectPublished(_ port: Int) async -> Int32? {
        guard let fd = try? await connect(port: EngineSetup.forwardPort) else { return nil }
        guard (try? DockerHTTP.writeAll(fd, Data("\(port)\n".utf8))) != nil else {
            close(fd)
            return nil
        }
        return fd
    }

    /// The guest's outgoing TCP: the agent sends each connection here, and it leaves from the Mac.
    private func listenForProxy(_ vm: VZVirtualMachine) {
        guard let device = vm.socketDevices.first as? VZVirtioSocketDevice else { return }
        let listener = VZVirtioSocketListener()
        listener.delegate = self
        device.setSocketListener(listener, forPort: EngineSetup.proxyPort)
    }

    // MARK: - Lifecycle

    private func start() async throws {
        message = nil
        progress = nil
        do {
            let ready = EngineSetup.isSetUp
            if !ready {
                state = .settingUp
                try await EngineSetup.prepare(settings: settings) { [weak self] text, fraction in
                    self?.message = text
                    self?.progress = fraction
                    self?.writeStatus()
                }
                message = "Installing Docker"
                progress = nil
            } else {
                state = .starting
            }
            try EngineSetup.installAgent()
            if !directBoot { try await fetchKernel(ready: ready) }
            let started = Date()
            let vm = VZVirtualMachine(configuration: try configuration(ready: ready, firmware: false))
            vm.delegate = self
            virtualMachine = vm
            try await vm.start()
            listenForProxy(vm)
            ports = ContainerPorts(network: network) { [weak self] port in await self?.connectPublished(port) }
            log("Booted\(ready ? "" : " for setup").")
            try await waitForDocker(timeout: ready ? 120 : 1200)
            bootSeconds = Date().timeIntervalSince(started)
            log(String(format: "Docker answered %.1f s after power on.", bootSeconds!))
            if !ready { FileManager.default.createFile(atPath: EnginePaths.ready.path, contents: nil) }
            message = nil
            progress = nil
            lastBusy = Date()
            state = .running
            await refreshGuest()
            watchEvents()
            await syncPorts()
        } catch {
            if let vm = virtualMachine, vm.canStop { try? await vm.stop() }
            virtualMachine = nil
            fail(error)
            throw error
        }
    }

    /// Boots the disk's own firmware and GRUB just long enough for the guest to copy its kernel into the
    /// boot share, then stops it. Every later boot loads that kernel directly: faster, and on macOS 27
    /// guests booted through the firmware corrupted their memory after a couple of minutes, which booting
    /// directly doesn't. The guest copies it from cloud-init's bootcmd while setting up, or from the agent.
    private func fetchKernel(ready: Bool) async throws {
        log("Fetching the guest's kernel.")
        let vm = VZVirtualMachine(configuration: try configuration(ready: ready, firmware: true))
        vm.delegate = self
        fetchingKernel = true
        defer { fetchingKernel = false }
        virtualMachine = vm
        try await vm.start()
        listenForProxy(vm)
        let deadline = Date().addingTimeInterval(180)
        while !directBoot, virtualMachine != nil, Date() < deadline { try await Task.sleep(for: .milliseconds(200)) }
        if let vm = virtualMachine {
            if vm.canRequestStop { try? vm.requestStop() }
            for _ in 0..<100 where virtualMachine != nil { try await Task.sleep(for: .milliseconds(100)) }
            if let vm = virtualMachine, vm.canStop { try? await vm.stop() }
        }
        virtualMachine = nil
        network?.stop()
        network = nil
        guard directBoot else { throw ControlError("The engine didn't hand over its kernel; see \(EnginePaths.console.path).") }
    }

    /// Docker answers `/_ping` once it and the vsock relay are both up.
    private func waitForDocker(timeout: TimeInterval) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            guard virtualMachine != nil else { throw ControlError(message ?? "The engine stopped while starting.") }
            if let fd = try? await connect(port: EngineSetup.dockerPort) {
                let ok = await Task.detached {
                    DockerHTTP.setTimeout(fd, 3)
                    return (try? DockerHTTP.exchange(fd: fd, method: "GET", path: "/_ping"))?.ok == true
                }.value
                if ok { return }
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw ControlError("Docker didn't start in the engine; see \(EnginePaths.console.path).")
    }

    /// Shuts the guest down cleanly, pulling the plug if it takes too long, then exits.
    private func quit(reason: String) {
        guard state != .stopping else { return }
        log("Stopping: \(reason)")
        state = .stopping
        listener?.cancel()
        events?.cancel()
        ports?.removeAll()
        Task {
            if let vm = virtualMachine {
                if vm.canRequestStop { try? vm.requestStop() }
                for _ in 0..<150 where virtualMachine != nil { try? await Task.sleep(for: .milliseconds(100)) }
                if let vm = virtualMachine, vm.canStop { try? await vm.stop() }
            }
            try? FileManager.default.removeItem(at: EnginePaths.status)
            log("Stopped.")
            exit(0)
        }
    }

    private func stopped() {
        virtualMachine = nil
        if fetchingKernel { return }
        events?.cancel()
        ports?.removeAll()
        ports = nil
        network?.stop()
        network = nil
        boot = nil
        lastBusy = Date()
        if state == .running || state == .starting {
            // The guest shut itself down (or crashed): the next connection boots it again.
            log("The guest stopped.")
            state = .stopped
        }
    }

    private func fail(_ error: Error) {
        lastBusy = Date()
        log("Error: \(error.localizedDescription)")
        message = error.localizedDescription
        state = .error
    }

    // MARK: - While running

    /// Every 5 seconds: memory, the idle timer, and a port resync in case an event was missed.
    private func tick() {
        guard state == .running, virtualMachine != nil else {
            // Stopped on its own or failed: leave the error up a while, then make way for a fresh start.
            if boot == nil, state != .stopping, connections.value == 0, Date().timeIntervalSince(lastBusy) > 300 {
                quit(reason: "Not running.")
            }
            writeStatus()
            return
        }
        Task {
            // A guest that panicked keeps "running" but answers nothing, and the connections stuck on it
            // would keep it from ever idling out. Quitting closes them; the next docker command boots fresh.
            let alive = await Task.detached { (try? ContainerEngine.ping(timeout: 5)) != nil }.value
            failedPings = alive ? 0 : failedPings + 1
            if failedPings >= 3 {
                quit(reason: "Docker stopped answering.")
                return
            }
            await refreshGuest()
            await syncPorts()
            if (runningContainers ?? 0) > 0 || connections.value > 0 || (ports?.openConnections ?? 0) > 0 {
                lastBusy = Date()
            } else if settings.idleMinutes > 0, Date().timeIntervalSince(lastBusy) > Double(settings.idleMinutes) * 60 {
                quit(reason: "No containers for \(settings.idleMinutes) min.")
                return
            }
            writeStatus()
        }
    }

    /// Asks the guest how much memory it uses, for the status.
    ///
    /// The balloon device is there, but Hyperbox doesn't inflate it: measured on macOS 27, inflating it to
    /// give 1 GB back made the VM process's footprint grow by 850 MB instead (the guest touches each page
    /// it hands over, and Virtualization keeps them). What keeps memory low is stopping the engine when
    /// it's idle, and booting fresh, which takes 4 seconds.
    private func refreshGuest() async {
        guard let fd = try? await connect(port: EngineSetup.infoPort) else { return }
        let reply = await Task.detached { () -> Data? in
            defer { close(fd) }
            DockerHTTP.setTimeout(fd, 3)
            var reader = DockerHTTP.Reader(fd: fd)
            return (try? reader.line()).map { Data($0.utf8) }
        }.value
        guard let reply, let info = try? JSONDecoder().decode(JSONValue.self, from: reply),
              let total = info["memTotal"]?.double, let available = info["memAvailable"]?.double else { return }
        memoryUsed = UInt64(max(0, total - available))
        memoryLimit = UInt64(total)
    }

    /// Lists containers in the guest and forwards their published ports.
    private func syncPorts() async {
        guard let ports, let fd = try? await connect(port: EngineSetup.dockerPort) else { return }
        let containers = await Task.detached {
            DockerHTTP.setTimeout(fd, 10)
            return try? DockerHTTP.exchange(fd: fd, method: "GET", path: "/containers/json").decode([ContainerSummary].self)
        }.value
        guard let containers else { return }
        runningContainers = containers.count
        var wanted = Set<ContainerPorts.Key>()
        for container in containers {
            for port in container.ports {
                guard let published = port.publicPort else { continue }
                wanted.insert(.init(port: published, udp: port.type == "udp"))
            }
        }
        await Task.detached { ports.update(wanted) }.value
        writeStatus()
    }

    /// Resyncs ports as soon as a container starts or stops, so `docker run -d -p …` is reachable at once.
    private func watchEvents() {
        events?.cancel()
        events = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, let fd = try? await connect(port: EngineSetup.dockerPort) else { return }
                let filters = ContainerEngine.escape(#"{"type":["container"],"event":["start","die","stop","kill","destroy","pause","unpause"]}"#)
                let changes = AsyncStream<Void> { continuation in
                    Thread.detachNewThread {
                        DockerHTTP.setTimeout(fd, 0)
                        _ = try? DockerHTTP.exchange(fd: fd, method: "GET", path: "/events?filters=\(filters)") { _ in
                            continuation.yield()
                            return true
                        }
                        continuation.finish()
                    }
                    continuation.onTermination = { _ in shutdown(fd, SHUT_RDWR) }
                }
                for await _ in changes { await self.syncPorts() }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    // MARK: - The machine

    /// Booting the kernel directly saves the firmware and GRUB, a second or two; the guest hands its kernel
    /// over on every boot (hyperbox-boot-sync), so it follows kernel updates.
    private var directBoot: Bool {
        ["Image", "initrd", "cmdline"].allSatisfy { FileManager.default.fileExists(atPath: EnginePaths.boot.appending(path: $0).path) }
    }

    private func configuration(ready: Bool, firmware: Bool) throws -> VZVirtualMachineConfiguration {
        let vm = VZVirtualMachineConfiguration()
        vm.cpuCount = min(max(settings.cpuCount, VZVirtualMachineConfiguration.minimumAllowedCPUCount), VZVirtualMachineConfiguration.maximumAllowedCPUCount)
        vm.memorySize = min(max(settings.memorySize, 1 << 30), VZVirtualMachineConfiguration.maximumAllowedMemorySize)

        let platform = VZGenericPlatformConfiguration()
        if let data = try? Data(contentsOf: EnginePaths.machineIdentifier), let identifier = VZGenericMachineIdentifier(dataRepresentation: data) {
            platform.machineIdentifier = identifier
        } else {
            try platform.machineIdentifier.dataRepresentation.write(to: EnginePaths.machineIdentifier)
        }
        vm.platform = platform

        if !firmware, let cmdline = try? String(contentsOf: EnginePaths.boot.appending(path: "cmdline"), encoding: .utf8) {
            let loader = VZLinuxBootLoader(kernelURL: EnginePaths.boot.appending(path: "Image"))
            loader.initialRamdiskURL = EnginePaths.boot.appending(path: "initrd")
            loader.commandLine = "\(cmdline.trimmingCharacters(in: .whitespacesAndNewlines)) ro console=hvc0 quiet"
            vm.bootLoader = loader
        } else {
            let loader = VZEFIBootLoader()
            if FileManager.default.fileExists(atPath: EnginePaths.efiVariables.path) {
                loader.variableStore = VZEFIVariableStore(url: EnginePaths.efiVariables)
            } else {
                loader.variableStore = try VZEFIVariableStore(creatingVariableStoreAt: EnginePaths.efiVariables)
            }
            vm.bootLoader = loader
        }

        var storage: [VZStorageDeviceConfiguration] = [
            VZVirtioBlockDeviceConfiguration(attachment: try VZDiskImageStorageDeviceAttachment(
                url: EnginePaths.disk, readOnly: false, cachingMode: .cached, synchronizationMode: .fsync)),
        ]
        if !ready {
            storage.append(VZVirtioBlockDeviceConfiguration(attachment: try VZDiskImageStorageDeviceAttachment(url: EnginePaths.seed, readOnly: true)))
        }
        vm.storageDevices = storage

        // Our own network rather than macOS's NAT; see `UserNetwork`.
        let network = try UserNetwork()
        self.network = network
        let card = VZVirtioNetworkDeviceConfiguration()
        card.attachment = VZFileHandleNetworkDeviceAttachment(fileHandle: network.guestHandle)
        if let mac = VZMACAddress(string: settings.macAddress) { card.macAddress = mac }
        vm.networkDevices = [card]

        // Your home folder at the same path, so `-v ~/code:/code` works as with Docker Desktop, and
        // /var/folders, where tools like Testcontainers put files they mount.
        func share(_ tag: String, _ path: String) -> VZVirtioFileSystemDeviceConfiguration {
            let device = VZVirtioFileSystemDeviceConfiguration(tag: tag)
            device.share = VZSingleDirectoryShare(directory: VZSharedDirectory(url: URL(fileURLWithPath: path), readOnly: false))
            return device
        }
        var shares = [
            share(EngineSetup.homeTag, FileManager.default.homeDirectoryForCurrentUser.path),
            share(EngineSetup.foldersTag, "/private/var/folders"),
            share(EngineSetup.bootTag, EnginePaths.boot.path),
        ]
        if VZLinuxRosettaDirectoryShare.availability == .installed, let rosetta = try? VZLinuxRosettaDirectoryShare() {
            let device = VZVirtioFileSystemDeviceConfiguration(tag: EngineSetup.rosettaTag)
            device.share = rosetta
            shares.append(device)
        }
        vm.directorySharingDevices = shares

        vm.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
        vm.memoryBalloonDevices = [VZVirtioTraditionalMemoryBalloonDeviceConfiguration()]
        vm.socketDevices = [VZVirtioSocketDeviceConfiguration()]
        FileManager.default.createFile(atPath: EnginePaths.console.path, contents: nil)
        if let attachment = try? VZFileSerialPortAttachment(url: EnginePaths.console, append: false) {
            let port = VZVirtioConsoleDeviceSerialPortConfiguration()
            port.attachment = attachment
            vm.serialPorts = [port]
        }
        try vm.validate()
        return vm
    }

    // MARK: - Status

    private func writeStatus() {
        EngineStatus(pid: getpid(), state: state, message: message, progress: progress, bootSeconds: bootSeconds,
                     memoryUsed: state == .running ? memoryUsed : nil, memoryLimit: state == .running ? memoryLimit : nil,
                     runningContainers: state == .running ? runningContainers : nil,
                     forwardedPorts: ports?.forwarded ?? [], blockedPorts: ports?.unavailable ?? []).write()
    }

    private func log(_ text: String) {
        let line = "\(Date().formatted(.iso8601)) \(text)\n"
        FileHandle.standardError.write(Data(line.utf8))
    }
}

extension EngineHost: VZVirtioSocketListenerDelegate {
    nonisolated func listener(_ listener: VZVirtioSocketListener, shouldAcceptNewConnection connection: VZVirtioSocketConnection,
                              from socketDevice: VZVirtioSocketDevice) -> Bool {
        let fd = dup(connection.fileDescriptor)
        connection.close()
        guard fd >= 0 else { return false }
        Sockets.noSigPipe(fd)
        Thread.detachNewThread { Self.proxy(fd) }
        return true
    }

    /// Reads "ip port\n" and connects there from the Mac. The gateway and 192.168.127.254 mean the Mac itself.
    private nonisolated static func proxy(_ fd: Int32) {
        DockerHTTP.setTimeout(fd, 10)
        var reader = DockerHTTP.Reader(fd: fd)
        guard let header = try? reader.line() else { close(fd); return }
        let parts = header.split(separator: " ")
        guard parts.count == 2, let port = Int(parts[1]) else { close(fd); return }
        var host = String(parts[0])
        if host == "192.168.127.254" || host == "192.168.127.1" { host = "127.0.0.1" }
        DockerHTTP.setTimeout(fd, 0)
        guard let upstream = Sockets.connectTCP(host: host, port: port) else { close(fd); return }
        // Whatever the guest sent after the header is already read; pass it on first.
        if let early = try? reader.leftover(), !early.isEmpty, (try? DockerHTTP.writeAll(upstream, early)) == nil {
            close(fd)
            close(upstream)
            return
        }
        Sockets.pipe(fd, upstream)
    }
}

extension EngineHost: VZVirtualMachineDelegate {
    nonisolated func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        MainActor.assumeIsolated { stopped() }
    }

    nonisolated func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) {
        MainActor.assumeIsolated {
            stopped()
            fail(error)
        }
    }
}

/// A thread-safe count of open connections.
nonisolated final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func add(_ n: Int) { lock.withLock { count += n } }
}
