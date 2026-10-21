import AppKit

/// Files dropped on a machine's window, copied into the guest.
enum FileDrop {
    static func drop(_ providers: [NSItemProvider], on machine: Machine) -> Bool {
        false
    }
}
