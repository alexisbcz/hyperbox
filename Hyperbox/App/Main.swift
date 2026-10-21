import SwiftUI

/// Hyperbox runs as the library, or, launched with `--machine <bundle>`, as one machine.
@main
enum Main {
    static func main() {
        if MachineApp.bundlePath != nil {
            MachineApp.main()
        } else {
            HyperboxApp.main()
        }
    }
}
