import Virtualization

/// Installs macOS from the IPSW in `config.install.source` onto a fresh bundle.
enum MacInstaller {
    static func install(_ machine: Machine) async throws {
        guard let source = machine.config.install?.source else { throw ControlError("There's no restore image to install from.") }
        let ipsw = URL(fileURLWithPath: source)
        guard FileManager.default.fileExists(atPath: ipsw.path) else {
            throw ControlError("The restore image at \(ipsw.path) is gone. Put it back, or make a new machine.")
        }
        // The installer runs its own, never-started machine; Machine.start boots a fresh one afterwards.
        let vm = VZVirtualMachine(configuration: try VirtualMachineBuilder.make(machine.config, bundle: machine.bundle))
        let installer = VZMacOSInstaller(virtualMachine: vm, restoringFromImageAt: ipsw)
        machine.progress = 0
        defer { machine.progress = nil }

        // Polled rather than observed: KVO would call back off the main actor, and twice a second is plenty.
        let watcher = Task {
            while !Task.isCancelled {
                let fraction = installer.progress.fractionCompleted
                if fraction > (machine.progress ?? 0) { machine.progress = fraction }
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
        defer { watcher.cancel() }
        do {
            try await installer.install()
        } catch {
            throw ControlError("Installing macOS failed: \(error.localizedDescription)")
        }
    }
}
