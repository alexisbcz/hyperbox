import Foundation

/// A running machine's side of the NAT network: finds the guest's address, and runs its port forwards.
///
/// The address comes from the DHCP lease for the machine's MAC address, or the ARP table for a static one,
/// rechecked every few seconds while it runs, so a reboot or a renewed lease shows up too. Forwards listen
/// whenever the machine runs with its network connected, even before the guest has an address, so a port
/// that's taken shows up right away.
final class GuestNetwork {
    private unowned let machine: Machine
    private var timer: Timer?
    private var forwarders: [UUID: PortForwarder] = [:]
    /// What the forwarders connect to; they read it on their own queues.
    private let address = Locked<String?>(nil)

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
                    MainActor.assumeIsolated { self?.refreshAddress() }
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
        let mac = machine.config.network.macAddress
        Task.detached {
            let ip = DHCPLeases.address(for: mac) ?? DHCPLeases.addressFromARP(for: mac)
            await MainActor.run { [weak self] in
                guard let self, self.active else { return }
                self.setAddress(ip)
            }
        }
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
            let forwarder = PortForwarder(forward, guestAddress: { address.value }) { [weak self] error in
                guard let self, self.forwarders[forward.id]?.forward == forward else { return }
                if self.machine.portForwardErrors[forward.id] != error { self.machine.portForwardErrors[forward.id] = error }
            }
            forwarders[forward.id] = forwarder
            forwarder.start()
        }
    }
}
