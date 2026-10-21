import SwiftUI

/// A machine's disk usage and snapshots, in the library. A stopped machine's snapshots change right
/// here, on its files; a running one's go through its process, which saves and restores its state.
struct StorageSection: View {
    @Environment(Library.self) private var library
    let entry: Library.Entry
    @State private var usage: Usage?

    struct Usage: Equatable, Sendable {
        var diskUsed: UInt64
        var snapshots: [UUID: UInt64]
        var savedState: UInt64
    }

    private var open: Bool { library.statuses[entry.id] != nil }

    var body: some View {
        let snapshots = SnapshotList.of(entry.bundle).items
        Form {
            Section("Storage") {
                LabeledContent("Disk") {
                    if let usage {
                        Text("\(format(usage.diskUsed)) used of \(format(entry.config.diskSize))")
                    } else {
                        Text(format(entry.config.diskSize))
                    }
                }
                if let usage, usage.savedState > 0, !open {
                    LabeledContent("Suspended", value: "\(format(usage.savedState)) of memory saved; starting picks up where it left off")
                }
            }

            Section {
                ForEach(snapshots.reversed()) { info in
                    SnapshotRow(info: info, bundle: entry.bundle, size: usage?.snapshots[info.id],
                                restore: { restore(info) }, delete: { delete(info) })
                }
                Button("Take Snapshot…") { take() }
                    .disabled(![MachineState.stopped, .running, .paused, .error].contains(library.state(of: entry.id)))
            } header: {
                Text("Snapshots")
            } footer: {
                Text("A snapshot costs space only as the machine changes after it. Taken while running, restoring it resumes the machine right where it was.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .scrollContentBackground(.hidden)
        .task(id: entry.id) {
            // Snapshots can come from the machine's window or the command line too: keep looking.
            while !Task.isCancelled {
                SnapshotList.of(entry.bundle).reload()
                let bundle = entry.bundle
                let ids = SnapshotList.of(bundle).items.map(\.id)
                let new = await Task.detached { Self.measure(bundle, snapshots: ids) }.value
                if new != usage { usage = new }
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    nonisolated private static func measure(_ bundle: MachineBundle, snapshots: [UUID]) -> Usage {
        var sizes: [UUID: UInt64] = [:]
        for id in snapshots {
            let folder = SnapshotFiles.directory(bundle, id)
            sizes[id] = DiskUsage.unshared(folder) ?? DiskUsage.allocated(folder)
        }
        return Usage(diskUsed: DiskUsage.allocated(bundle.disk), snapshots: sizes, savedState: DiskUsage.allocated(bundle.savedState))
    }

    private func format(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    // MARK: - Actions

    private func take() {
        guard let name = SnapshotPrompt.name() else { return }
        let (id, bundle, os, open) = (entry.id, entry.bundle, entry.config.os, open)
        perform {
            if open {
                _ = try ControlClient.send(.takeSnapshot, to: id, params: ["name": .string(name)], timeout: 600)
            } else {
                _ = try SnapshotFiles.create(bundle, os: os, name: name)
            }
        }
    }

    private func restore(_ info: SnapshotInfo) {
        guard SnapshotPrompt.confirmRestore(info, machine: entry.config.name) else { return }
        let (id, bundle, open) = (entry.id, entry.bundle, open)
        perform {
            if open {
                _ = try ControlClient.send(.restoreSnapshot, to: id, params: ["id": .string(info.id.uuidString)], timeout: 600)
            } else {
                try SnapshotFiles.restore(bundle, info.id)
                let size = DiskUsage.size(bundle.disk)
                await MainActor.run { Library.shared.update(id) { $0.diskSize = size } }
            }
        }
    }

    private func delete(_ info: SnapshotInfo) {
        guard SnapshotPrompt.confirmDelete(info) else { return }
        let (id, bundle, open) = (entry.id, entry.bundle, open)
        perform {
            if open {
                _ = try ControlClient.send(.deleteSnapshot, to: id, params: ["id": .string(info.id.uuidString)])
            } else {
                try SnapshotFiles.delete(bundle, info.id)
            }
        }
    }

    private func perform(_ work: @escaping @Sendable () async throws -> Void) {
        let bundle = entry.bundle
        Task.detached {
            do { try await work() } catch {
                await MainActor.run { SnapshotPrompt.show(error) }
            }
            await MainActor.run {
                SnapshotList.of(bundle).reload()
                Library.shared.bumpThumbnail()
            }
        }
    }
}

private struct SnapshotRow: View {
    let info: SnapshotInfo
    let bundle: MachineBundle
    let size: UInt64?
    let restore: () -> Void
    let delete: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if let image = NSImage(contentsOf: SnapshotFiles.directory(bundle, info.id).appending(path: SnapshotFiles.thumbnailName)) {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                } else {
                    Image(systemName: "camera").foregroundStyle(.secondary)
                }
            }
            .frame(width: 48, height: 30)
            .background(.quaternary)
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(info.name).lineLimit(1)
                Text(details)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Restore…", systemImage: "arrow.uturn.backward", action: restore)
                .labelStyle(.iconOnly)
                .help("Go back to this snapshot")
            Button("Delete…", systemImage: "trash", action: delete)
                .labelStyle(.iconOnly)
                .help("Delete this snapshot")
        }
        .buttonStyle(.borderless)
        .contextMenu {
            Button("Restore…", action: restore)
            Button("Delete…", role: .destructive, action: delete)
        }
    }

    private var details: String {
        var parts = [info.created.formatted(date: .abbreviated, time: .shortened)]
        parts.append(info.hasState ? "Running" : "Shut down")
        if let size { parts.append(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)) }
        return parts.joined(separator: " · ")
    }
}
