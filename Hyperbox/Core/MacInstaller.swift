import Virtualization

/// Installs macOS from the IPSW in `config.install.source` onto a fresh bundle.
enum MacInstaller {
    static func install(_ machine: Machine) async throws {
        throw ControlError("Installing macOS isn't built yet.")
    }
}
