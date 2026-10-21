import SwiftUI

/// Hyperbox runs as the library, or, launched with `--machine <bundle>`, as one machine, or, launched by
/// launchd with `--engine`, as the container engine.
@main
enum Main {
    static func main() {
        if MachineApp.bundlePath != nil {
            MachineApp.main()
        } else if CommandLine.arguments.contains(EngineAgent.argument) {
            EngineHost.main()
        } else {
            HyperboxApp.main()
        }
    }
}
