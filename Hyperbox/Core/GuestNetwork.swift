import Foundation

/// A running machine's side of the NAT network: finds the guest's address, and runs its port forwards.
///
/// The address comes from the DHCP lease for the machine's MAC address, or else from the guest agent,
/// rechecked every few seconds while it runs, so a reboot or a renewed lease shows up too. Forwards listen
/// whenever the machine runs with its network connected, even before the guest has an address, so a port
/// that's taken shows up right away.
final class GuestNetwork {
    private unowned let machine: Machine
    private var timer: Timer?
    private var forwarders: [UUID: PortForwarder] = [:]
    /// What the forwarders connect to; they read it on their own queues.
    private let address = Locked<String?>(nil)
    private var refreshing = false

    init(machine: Machine) {
        self.machine = machine
    }

    /// Whether the guest is up with a network: on while running or paused, off once stopped or disconnected.
    private var active: Bool {
        guard machine.virtualMachine != nil, machine.config.network.enabled else { return false }
        return [.starting, .running, .paused, .installing, .saving, .restoring].contains(machine.state)
    }

    /// Call when the machine's state or config changes.
    func update() {
        if active {
            if timer == nil {
                timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.refreshAddress()
                        self?.retryFailedForwards()
                    }
                }
                refreshAddress()
            }
        } else {
            timer?.invalidate()
            timer = nil
            setAddress(nil)
        }
        updateForwards()
    }

    private func refreshAddress() {
        guard !refreshing else { return }
        refreshing = true
        let mac = machine.config.network.macAddress
        Task {
            defer { refreshing = false }
            var ip = await Task.detached { DHCPLeases.address(for: mac) }.value
            if ip == nil, machine.config.os == .linux { ip = await addressFromAgent() }
            guard active else { return }
            setAddress(ip)
        }
    }

    /// The source address of the guest's default route, from Hyperbox's agent in the guest, for guests
    /// whose lease doesn't name their MAC.
    private func addressFromAgent() async -> String? {
        let command = "ip -4 -o route get 1.1.1.1 2>/dev/null | sed -n 's/.* src \\([0-9.]*\\).*/\\1/p'"
        guard let reply = try? await GuestAgent.exec(["command": .string(command), "timeout": 5], machine: machine),
              let ip = reply["stdout"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        var parsed = in_addr()
        return inet_pton(AF_INET, ip, &parsed) == 1 ? ip : nil
    }

    private func setAddress(_ ip: String?) {
        address.value = ip
        if machine.ipAddress != ip { machine.ipAddress = ip }
    }

    /// Starts and stops listeners to match the config. A changed forward is a new listener.
    private func updateForwards() {
        let wanted = active ? machine.config.network.portForwards : []
        for (id, forwarder) in forwarders where !wanted.contains(forwarder.forward) {
            forwarder.stop()
            forwarders[id] = nil
            machine.portForwardErrors[id] = nil
        }
        for forward in wanted where forwarders[forward.id] == nil {
            let address = address
            let forwarder = PortForwarder(forward, guestAddress: { address.value })
            forwarders[forward.id] = forwarder
            forwarder.start { [weak self, weak forwarder] error in
                guard let self, let forwarder, self.forwarders[forward.id] === forwarder else { return }
                if self.machine.portForwardErrors[forward.id] != error { self.machine.portForwardErrors[forward.id] = error }
            }
        }
    }

    /// A port another app held may be free now. The error stays up until the new listener says otherwise.
    private func retryFailedForwards() {
        for id in machine.portForwardErrors.keys {
            forwarders[id]?.stop()
            forwarders[id] = nil
        }
        updateForwards()
    }
}
