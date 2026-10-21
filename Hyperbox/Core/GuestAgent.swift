import Virtualization

/// Talks to the agent inside the guest over vsock, to run commands.
enum GuestAgent {
    static func exec(_ params: JSONValue, machine: Machine) async throws -> JSONValue {
        throw ControlError("Running commands isn't built yet.")
    }
}
