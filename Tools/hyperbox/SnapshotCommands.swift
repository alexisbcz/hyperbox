import Foundation

/// Saved copies of a machine, through its control socket.
nonisolated extension Command {
    static let snapshot = Command(name: "snapshot", arguments: "<machine> [name]",
                                  summary: "save a copy of a machine, running or not, to go back to") { args in
        let target = try Target.find(try args.next("a machine"))
        let name = args.optionalNext()
        try args.done()
        var params: [String: JSONValue] = [:]
        if let name { params["name"] = .string(name) }
        let snapshot = try target.send(.takeSnapshot, params, timeout: 600).decode(SnapshotInfo.self)
        print("Took \(snapshot.name) (\(snapshot.id.uuidString.lowercased().prefix(8))).")
    }

    static let snapshots = Command(name: "snapshots", arguments: "<machine> [--json]", summary: "list a machine's snapshots") { args in
        let json = args.flag("--json")
        let target = try Target.find(try args.next("a machine"))
        try args.done()
        let list = try listSnapshots(target)
        if json { return try printJSON(list) }
        if list.isEmpty { return print("\(target.name) has no snapshots.") }
        printTable(["ID", "NAME", "TAKEN", "STATE"], list.map { snapshot in
            [String(snapshot.id.uuidString.lowercased().prefix(8)), snapshot.name,
             snapshot.created.formatted(date: .abbreviated, time: .shortened), snapshot.hasState ? "running" : "shut down"]
        })
    }

    static let restore = Command(name: "restore", arguments: "<machine> <snapshot>",
                                 summary: "go back to a snapshot, by name or id") { args in
        let target = try Target.find(try args.next("a machine"))
        let snapshot = try findSnapshot(try args.next("a snapshot"), in: target)
        try args.done()
        try target.send(.restoreSnapshot, ["id": .string(snapshot.id.uuidString)], timeout: 600)
    }

    static let deleteSnapshot = Command(name: "delete-snapshot", arguments: "<machine> <snapshot>",
                                        summary: "delete a snapshot, by name or id") { args in
        let target = try Target.find(try args.next("a machine"))
        let snapshot = try findSnapshot(try args.next("a snapshot"), in: target)
        try args.done()
        try target.send(.deleteSnapshot, ["id": .string(snapshot.id.uuidString)], timeout: 120)
    }

    private static func listSnapshots(_ target: Target) throws -> [SnapshotInfo] {
        try target.send(.listSnapshots).decode([SnapshotInfo].self)
    }

    private static func findSnapshot(_ name: String, in target: Target) throws -> SnapshotInfo {
        let list = try listSnapshots(target)
        if let match = list.last(where: { $0.name == name }) ?? list.first(where: { $0.id.uuidString.lowercased().hasPrefix(name.lowercased()) }) {
            return match
        }
        throw Failure("\(target.name) has no snapshot \(name). Try `hyperbox snapshots \(quoted(target.name))`.")
    }
}
