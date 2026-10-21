import Virtualization

/// Saved copies of a machine, running or stopped. The files are `SnapshotFiles`'s business; this is the
/// part that needs the running machine: saving its memory and devices, and resuming from them.
///
/// Virtualization restores a saved state only into a machine configured the same way, so changing the
/// processors, memory or devices after a snapshot means restoring it boots the restored disk cold instead.
enum Snapshots {
    static func handle(_ method: ControlMethod, params: JSONValue, machine: Machine) async throws -> JSONValue {
        switch method {
        case .listSnapshots:
            return try JSONValue(encoding: SnapshotFiles.list(machine.bundle))
        case .takeSnapshot:
            let name = params["name"]?.string.flatMap { $0.isEmpty ? nil : $0 } ?? SnapshotFiles.defaultName()
            return try JSONValue(encoding: await machine.takeSnapshot(named: name))
        case .restoreSnapshot:
            try await machine.restoreSnapshot(try snapshot(params, machine).id)
            return .null
        case .deleteSnapshot:
            try machine.deleteSnapshot(try snapshot(params, machine).id)
            return .null
        default:
            throw ControlError("\(method.rawValue) isn't a snapshot method.")
        }
    }

    /// `id` is the snapshot's id, the start of it, or its name.
    private static func snapshot(_ params: JSONValue, _ machine: Machine) throws -> SnapshotInfo {
        guard let query = params["id"]?.string ?? params["name"]?.string else { throw ControlError("Say which snapshot, with id.") }
        return try SnapshotFiles.find(machine.bundle, query)
    }
}

extension Machine {
    /// Running: pauses, saves the state, clones the disk, and carries on, all in a few seconds.
    /// Stopped: clones the disk files.
    func takeSnapshot(named name: String) async throws -> SnapshotInfo {
        defer { SnapshotList.of(bundle).reload() }
        guard let vm = virtualMachine, vm.state == .running || vm.state == .paused else {
            return try SnapshotFiles.create(bundle, os: config.os, name: name)
        }
        let previous = state
        let wasRunning = vm.state == .running
        let thumbnail = screenshot()?.pngData(maxWidth: 640)
        if wasRunning { try await vm.pause() }
        state = .saving
        let staging = SnapshotFiles.stagingState(bundle)
        do {
            // The disk is cloned while the guest is paused, so it matches the saved memory exactly.
            try await vm.saveMachineStateTo(url: staging)
            let info = try SnapshotFiles.create(bundle, os: config.os, name: name, state: staging, thumbnail: thumbnail)
            if wasRunning { try await vm.resume() }
            state = previous
            return info
        } catch {
            try? FileManager.default.removeItem(at: staging)
            if wasRunning, vm.canResume { try? await vm.resume() }
            state = previous
            throw error
        }
    }

    /// Pulls the plug if it's running (what's running is about to be replaced anyway), puts the snapshot's
    /// files back, and starts again: resuming the snapshot's state when it has one.
    func restoreSnapshot(_ id: UUID) async throws {
        _ = try SnapshotFiles.info(bundle, id)
        let wasRunning = virtualMachine != nil
        if wasRunning {
            state = .restoring
            await forceStop()
        }
        let info = try SnapshotFiles.restore(bundle, id)
        let size = DiskUsage.size(bundle.disk)
        if size != config.diskSize { updateConfig { $0.diskSize = size } }
        SnapshotList.of(bundle).reload()
        if wasRunning || info.hasState { await start() }
    }

    func deleteSnapshot(_ id: UUID) throws {
        try SnapshotFiles.delete(bundle, id)
        SnapshotList.of(bundle).reload()
    }

    /// Saves the state so the next start resumes it, then stops: quitting picks up where it left off.
    /// Returns false when it didn't (it's off, the machine is installing, or saving failed), to shut down instead.
    func suspend() async -> Bool {
        guard config.suspendOnQuit, config.install == nil, let vm = virtualMachine, vm.state == .running || vm.state == .paused
        else { return false }
        let previous = state
        let wasRunning = vm.state == .running
        let partial = bundle.url.appending(path: ".saved-state-partial.vzsave")
        do {
            if wasRunning { try await vm.pause() }
            state = .saving
            try? FileManager.default.removeItem(at: partial)
            try await vm.saveMachineStateTo(url: partial)
            guard rename(partial.path, bundle.savedState.path) == 0 else { throw FileClone.posixError(errno, "Couldn't keep the saved state") }
            await forceStop()
            return true
        } catch {
            NSLog("Hyperbox: couldn't suspend \(config.name), shutting it down instead: \(error.localizedDescription)")
            try? FileManager.default.removeItem(at: partial)
            if wasRunning, vm.canResume { try? await vm.resume() }
            state = previous
            return false
        }
    }

    /// Boots the machine, or resumes it from a saved state: a suspended machine, or a restored snapshot.
    /// The saved state is used up either way, since the disk moves on from here.
    func bootOrResume(_ vm: VZVirtualMachine) async throws {
        let saved = bundle.savedState
        guard FileManager.default.fileExists(atPath: saved.path) else {
            if let options = MacSetup.startOptions(for: config) { try await vm.start(options: options) } else { try await vm.start() }
            return
        }
        defer { try? FileManager.default.removeItem(at: saved) }
        state = .restoring
        do {
            try await vm.restoreMachineStateFrom(url: saved)
            try await vm.resume()
        } catch {
            // Usually the configuration changed since the state was saved. The disk is still good: boot it.
            NSLog("Hyperbox: couldn't resume \(config.name), starting it fresh: \(error.localizedDescription)")
            state = .starting
            try await vm.start()
        }
    }

    /// Grows the disk to the size in the settings (it never shrinks). The guest's partition stays the
    /// same size until the guest grows it, which cloud images do on boot.
    func growDisk() throws {
        guard config.diskSize > DiskUsage.size(bundle.disk) else { return }
        try MachineFactory.grow(bundle.disk, to: config.diskSize)
        // A saved state remembers the old disk size; resuming onto a bigger disk would confuse the guest.
        try? FileManager.default.removeItem(at: bundle.savedState)
    }
}

/// A machine's snapshots, observed by menus and the library, and reread after anything changes them.
@Observable
final class SnapshotList {
    let bundle: MachineBundle
    private(set) var items: [SnapshotInfo] = []

    private static var lists: [URL: SnapshotList] = [:]

    static func of(_ bundle: MachineBundle) -> SnapshotList {
        if let list = lists[bundle.url] { return list }
        let list = SnapshotList(bundle: bundle)
        lists[bundle.url] = list
        return list
    }

    private init(bundle: MachineBundle) {
        self.bundle = bundle
        reload()
    }

    func reload() {
        let new = SnapshotFiles.list(bundle)
        if new != items { items = new }
    }
}

/// The questions snapshots ask, shared by the machine's window and the library.
enum SnapshotPrompt {
    static func name() -> String? {
        let alert = NSAlert()
        alert.messageText = "Take a Snapshot"
        alert.informativeText = "A snapshot takes space only as the machine changes after it. If the machine is running, it's saved as it is, open apps and all."
        let field = NSTextField(string: SnapshotFiles.defaultName())
        field.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Take Snapshot")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? SnapshotFiles.defaultName() : name
    }

    static func confirmRestore(_ info: SnapshotInfo, machine: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Restore “\(info.name)”?"
        alert.informativeText = "\(machine) goes back to how it was on \(info.created.formatted(date: .long, time: .shortened))"
            + (info.hasState ? ", running." : ".") + " Anything since then is lost, unless you take a snapshot first."
        alert.addButton(withTitle: "Restore")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    static func confirmDelete(_ info: SnapshotInfo) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Delete “\(info.name)”?"
        alert.informativeText = "The machine stays as it is; you just can't go back to this snapshot."
        alert.addButton(withTitle: "Delete").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    static func show(_ error: Error) {
        NSAlert(error: error).runModal()
    }
}

import SwiftUI

/// Take, restore and delete snapshots, for the toolbar and the Machine menu.
struct SnapshotMenuItems: View {
    let machine: Machine

    var body: some View {
        let snapshots = SnapshotList.of(machine.bundle).items
        let busy = [.saving, .restoring, .starting, .stopping].contains(machine.state)
        Button("Take Snapshot…") {
            guard let name = SnapshotPrompt.name() else { return }
            Task {
                do { _ = try await machine.takeSnapshot(named: name) } catch { SnapshotPrompt.show(error) }
            }
        }
        .disabled(busy)
        if !snapshots.isEmpty {
            Menu("Restore Snapshot") {
                ForEach(snapshots.reversed()) { info in
                    Button(label(info)) {
                        guard SnapshotPrompt.confirmRestore(info, machine: machine.config.name) else { return }
                        Task {
                            do { try await machine.restoreSnapshot(info.id) } catch { SnapshotPrompt.show(error) }
                        }
                    }
                }
            }
            .disabled(busy)
            Menu("Delete Snapshot") {
                ForEach(snapshots.reversed()) { info in
                    Button(label(info)) {
                        guard SnapshotPrompt.confirmDelete(info) else { return }
                        do { try machine.deleteSnapshot(info.id) } catch { SnapshotPrompt.show(error) }
                    }
                }
            }
        }
    }

    private func label(_ info: SnapshotInfo) -> String {
        info.hasState ? "\(info.name) (running)" : info.name
    }
}
