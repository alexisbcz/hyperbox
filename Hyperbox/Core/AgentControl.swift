import AppKit

/// Lets AI agents see a machine's screen and use its keyboard and mouse, by sending events to the
/// machine's own view: nothing touches your Mac's screen, so Hyperbox needs no Accessibility or
/// Screen Recording permission.
enum AgentControl {
    static func handle(_ method: ControlMethod, params: JSONValue, machine: Machine) async throws -> JSONValue {
        throw ControlError("\(method.rawValue) isn't built yet.")
    }
}
