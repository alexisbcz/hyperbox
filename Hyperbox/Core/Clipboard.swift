import AppKit

/// Shares copied text between the Mac and a macOS guest, through Hyperbox Tools in the guest.
/// Linux guests share the clipboard through SPICE instead (see `VirtualMachineBuilder`).
///
/// Both sides are polled, since neither pasteboard says when it changes. Text that came from the other
/// side is remembered, so it isn't sent straight back.
final class ClipboardSync {
    /// Longer text stays where it was copied; it'd make for very long agent messages.
    static let limit = 4 << 20

    private weak var machine: Machine?
    private var task: Task<Void, Never>?
    /// -1 until the guest's agent first answers, so the Mac's clipboard goes over then.
    private var hostCount = -1
    private var guestCount: Int?
    /// The text both sides last agreed on.
    private var shared: String?

    init(_ machine: Machine) {
        self.machine = machine
        guard machine.config.os == .macOS else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let wait = await self?.sync() else { return }
                try? await Task.sleep(for: wait)
            }
        }
    }

    deinit { task?.cancel() }

    /// One round each way; returns how long to wait before the next.
    private func sync() async -> Duration {
        guard let machine, machine.state == .running, machine.virtualMachine != nil else {
            // Start over on the next boot.
            hostCount = -1
            guestCount = nil
            return .seconds(1)
        }
        let pasteboard = NSPasteboard.general

        if pasteboard.changeCount != hostCount {
            let count = pasteboard.changeCount
            if let text = pasteboard.string(forType: .string), text != shared, text.utf8.count <= Self.limit {
                // Not installed, or not logged in yet: try again in a while, without marking this copy as sent.
                guard (try? await GuestAgent.request(["op": "setClipboard", "text": .string(text)], machine: machine, timeout: 5)) != nil else {
                    return .seconds(5)
                }
                shared = text
            }
            hostCount = count
        }

        guard let reply = try? await GuestAgent.request(["op": "getClipboard"], machine: machine, timeout: 5) else { return .seconds(5) }
        let count = reply["changeCount"]?.int
        if count != guestCount {
            // The first answer only says where the guest is; what it held before isn't news.
            if guestCount != nil, let text = reply["text"]?.string, text != shared, text.utf8.count <= Self.limit {
                pasteboard.clearContents()
                pasteboard.setString(text, forType: .string)
                hostCount = pasteboard.changeCount
                shared = text
            }
            guestCount = count
        }
        return .milliseconds(500)
    }
}
