import Virtualization

/// Saved copies of a machine, running or stopped.
enum Snapshots {
    static func handle(_ method: ControlMethod, params: JSONValue, machine: Machine) async throws -> JSONValue {
        throw ControlError("Snapshots aren't built yet.")
    }
}

import SwiftUI

/// Take, restore and delete snapshots, for the toolbar and the Machine menu.
struct SnapshotMenuItems: View {
    let machine: Machine

    var body: some View {
        Button("Take Snapshot") {}
            .disabled(true)
    }
}
