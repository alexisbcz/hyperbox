import Foundation
import Network
import Synchronization

/// Listens on a port on the Mac and passes each connection on to the same, or another, port in the guest,
/// so a web server or SSH in the machine is reachable at 127.0.0.1:<hostPort>.
///
/// Virtualization's NAT lets the Mac reach the guest's address directly, so this is a plain proxy: TCP
/// streams are copied both ways, closing each half as its side does; UDP datagrams are relayed per sender,
/// and a sender's flow is dropped after a minute of quiet. It runs on its own queue, off the main thread.
nonisolated final class PortForwarder: @unchecked Sendable {
    let forward: MachineConfig.PortForward
    /// Read when each connection arrives, so a guest that changes address after a reboot is still reached.
    private let guestAddress: @Sendable () -> String?
    /// Called on the main actor with nil once listening, or why it couldn't listen.
    private let onError: @MainActor @Sendable (String?) -> Void

    private let queue: DispatchQueue
    private var listener: NWListener?
    private var sessions: [ObjectIdentifier: Session] = [:]

    init(_ forward: MachineConfig.PortForward, guestAddress: @escaping @Sendable () -> String?,
         onError: @escaping @MainActor @Sendable (String?) -> Void) {
        self.forward = forward
        self.guestAddress = guestAddress
        self.onError = onError
        queue = DispatchQueue(label: "dev.alexis.Hyperbox.forward.\(forward.hostPort)")
    }

    func start() {
        let report = onError
        guard forward.hostPort > 0, forward.guestPort > 0, let port = NWEndpoint.Port(rawValue: forward.hostPort) else {
            Task { @MainActor in report("Pick ports from 1 to 65535.") }
            return
        }
        let parameters: NWParameters = forward.udp ? .udp : .tcp
        do {
            let listener: NWListener
            if forward.allInterfaces {
                listener = try NWListener(using: parameters, on: port)
            } else {
                parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: port)
                listener = try NWListener(using: parameters)
            }
            let hostPort = forward.hostPort
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    Task { @MainActor in report(nil) }
                case .failed(let error), .waiting(let error):
                    let message = Self.describe(error, port: hostPort)
                    Task { @MainActor in report(message) }
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
            self.listener = listener
            listener.start(queue: queue)
        } catch {
            let message = Self.describe(error, port: forward.hostPort)
            Task { @MainActor in report(message) }
        }
    }

    func stop() {
        queue.async { [self] in
            listener?.cancel()
            listener = nil
            for session in sessions.values { session.close() }
            sessions = [:]
        }
    }

    private static func describe(_ error: Error, port: UInt16) -> String {
        if case NWError.posix(let code) = error {
            switch code {
            case .EADDRINUSE: return "Port \(port) is already in use on this Mac."
            case .EACCES: return "Hyperbox isn't allowed to listen on port \(port)."
            default: break
            }
        }
        return "Couldn't listen on port \(port): \(error.localizedDescription)"
    }

    private func accept(_ client: NWConnection) {
        guard let address = guestAddress(), let port = NWEndpoint.Port(rawValue: forward.guestPort) else {
            // The guest has no address yet: refuse, as a closed port would.
            client.cancel()
            return
        }
        let guest = NWConnection(host: NWEndpoint.Host(address), port: port, using: forward.udp ? .udp : .tcp)
        let session = Session(client: client, guest: guest, udp: forward.udp, queue: queue)
        let key = ObjectIdentifier(session)
        sessions[key] = session
        session.onClose = { [weak self] in self?.sessions[key] = nil }
        session.start()
    }

    /// One proxied connection, or one UDP sender's flow.
    /// Touched only on the forwarder's queue.
    private final class Session: @unchecked Sendable {
        let client: NWConnection
        let guest: NWConnection
        let udp: Bool
        let queue: DispatchQueue
        var onClose: (() -> Void)?
        /// TCP directions that have finished, so the session closes once both have.
        private var finished = 0
        private var closed = false
        private var idle: DispatchWorkItem?

        init(client: NWConnection, guest: NWConnection, udp: Bool, queue: DispatchQueue) {
            self.client = client
            self.guest = guest
            self.udp = udp
            self.queue = queue
        }

        func start() {
            guest.stateUpdateHandler = { [self] state in
                switch state {
                case .ready:
                    pump(from: client, to: guest)
                    pump(from: guest, to: client)
                // A closed port in the guest shows up as waiting, retrying forever; give up instead.
                case .failed, .waiting: close()
                default: break
                }
            }
            client.stateUpdateHandler = { [self] state in
                if case .failed = state { close() }
            }
            guest.start(queue: queue)
            client.start(queue: queue)
            touch()
        }

        private func pump(from source: NWConnection, to destination: NWConnection) {
            if udp {
                source.receiveMessage { [self] data, _, _, error in
                    guard !closed else { return }
                    if error != nil { return close() }
                    if let data, !data.isEmpty {
                        touch()
                        destination.send(content: data, completion: .contentProcessed { _ in })
                    }
                    pump(from: source, to: destination)
                }
                return
            }
            source.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [self] data, _, isComplete, error in
                guard !closed else { return }
                if let data, !data.isEmpty {
                    destination.send(content: data, completion: .contentProcessed { [self] sendError in
                        if sendError != nil { return close() }
                        if isComplete { finish(destination) } else if error == nil { pump(from: source, to: destination) }
                    })
                    if error != nil { close() }
                } else if isComplete {
                    finish(destination)
                } else if error != nil {
                    close()
                }
            }
        }

        /// One side closed its half: pass the close on, and end the session when both have.
        private func finish(_ destination: NWConnection) {
            destination.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in })
            finished += 1
            if finished == 2 { close() }
        }

        /// UDP has no close, so a flow ends after a minute without datagrams.
        private func touch() {
            guard udp else { return }
            idle?.cancel()
            let item = DispatchWorkItem { [weak self] in self?.close() }
            idle = item
            queue.asyncAfter(deadline: .now() + 60, execute: item)
        }

        func close() {
            guard !closed else { return }
            closed = true
            idle?.cancel()
            client.stateUpdateHandler = nil
            guest.stateUpdateHandler = nil
            client.cancel()
            guest.cancel()
            onClose?()
            onClose = nil
        }
    }
}

/// A value read from any thread, for the guest's address the forwarders read as connections arrive.
nonisolated final class Locked<Value: Sendable>: Sendable {
    private let storage: Mutex<Value>
    init(_ value: Value) { storage = Mutex(value) }
    var value: Value {
        get { storage.withLock { $0 } }
        set { storage.withLock { $0 = newValue } }
    }
}
