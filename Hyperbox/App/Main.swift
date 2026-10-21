import SwiftUI

/// Hyperbox runs as the library, or, launched with `--machine <bundle>`, as one machine, or, launched by
/// launchd with `--engine`, as the container engine.
@main
enum Main {
    static func main() {
        // A client that hangs up mid-reply (a Ctrl-C'd `hyperbox exec`) must not take the machine down with it.
        signal(SIGPIPE, SIG_IGN)
        if MachineApp.bundlePath != nil {
            MachineApp.main()
        } else if CommandLine.arguments.contains(EngineAgent.argument) {
            EngineHost.main()
        } else {
            HyperboxApp.main()
        }
    }
}
