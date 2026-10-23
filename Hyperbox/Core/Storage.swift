import AppKit
import AppleArchive
import System
import SwiftUI
import UniformTypeIdentifiers
import Virtualization

/// Copies of a machine that share the original's blocks until they change; see `MachineCopy`.
enum Cloner {
    static func duplicate(_ id: UUID) {
        guard let entry = Library.shared.entry(id) else { return }
        let name = Library.shared.uniqueName("\(entry.config.name) copy")
        let destination = Library.newBundleURL(named: name)
        StorageActivity.shared.run("Duplicating \(entry.config.name)") { report in
            try StorageCopy.copy(entry.url, to: destination, report: report)
            try MachineCopy.renew(MachineBundle(url: destination), name: name)
            await MainActor.run { Library.shared.add(destination) }
        }
    }
}

/// A machine as one file, to move it to another Mac: the bundle itself (cloned when it stays on the
/// same disk, else copied keeping its holes), or a compressed Apple Archive.
///
/// Sparse files are why there are two: the bundle copies at the size of what's in the disk, but only to
/// APFS disks; anything else (exFAT drives, most file sharing) writes out the empty space too. An archive
/// is small anywhere, and Hyperbox (or `aa extract -enable-holes`) unpacks it sparse again. A zip made with
/// `ditto -c -k` compresses as well, but unpacks with every zero written, so Hyperbox doesn't make them.
enum Exporter {
    static func export(_ id: UUID) {
        guard let entry = Library.shared.entry(id) else { return }
        let panel = NSSavePanel()
        panel.title = "Export \(entry.config.name)"
        panel.nameFieldStringValue = "\(entry.config.name).\(Paths.bundleExtension)"
        let options = ExportOptions(panel: panel, name: entry.config.name, hasSnapshots: !SnapshotFiles.list(entry.bundle).isEmpty)
        panel.accessoryView = options.view
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        export(entry, to: destination, archive: options.archive, snapshots: options.includeSnapshots)
    }

    static func export(_ entry: Library.Entry, to destination: URL, archive: Bool, snapshots: Bool, reveal: Bool = true) {
        StorageActivity.shared.run("Exporting \(entry.config.name)") { report in
            if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
            if archive {
                try StorageArchive.archive(entry.url, to: destination, skipping: snapshots ? [] : ["snapshots"], report: report)
            } else {
                try StorageCopy.copy(entry.url, to: destination, skipping: snapshots ? [] : ["snapshots"], report: report)
            }
            if reveal { await MainActor.run { NSWorkspace.shared.activateFileViewerSelecting([destination]) } }
        }
    }

    /// The save panel's format and snapshot choices.
    private final class ExportOptions: NSObject {
        let view: NSView
        private let panel: NSSavePanel
        private let name: String
        private let format = NSPopUpButton()
        private let snapshots = NSButton(checkboxWithTitle: "Include snapshots", target: nil, action: nil)
        private let note = NSTextField(wrappingLabelWithString: "")

        var archive: Bool { format.indexOfSelectedItem == 1 }
        var includeSnapshots: Bool { snapshots.state == .on }

        init(panel: NSSavePanel, name: String, hasSnapshots: Bool) {
            self.panel = panel
            self.name = name
            format.addItems(withTitles: ["Hyperbox Machine", "Apple Archive (compressed)"])
            snapshots.isEnabled = hasSnapshots
            note.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            note.textColor = .secondaryLabelColor
            note.preferredMaxLayoutWidth = 420
            let label = NSTextField(labelWithString: "Format:")
            let row = NSStackView(views: [label, format])
            let stack = NSStackView(views: [row, snapshots, note])
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.edgeInsets = NSEdgeInsets(top: 12, left: 20, bottom: 12, right: 20)
            stack.widthAnchor.constraint(equalToConstant: 460).isActive = true
            view = stack
            super.init()
            format.target = self
            format.action = #selector(formatChanged)
            formatChanged()
        }

        @objc private func formatChanged() {
            if archive {
                panel.allowedContentTypes = [UTType(filenameExtension: "aar") ?? .data]
                panel.nameFieldStringValue = "\(name).aar"
                note.stringValue = "Small anywhere: on a USB drive, in the cloud, sent over a network. Takes a while to make, and to open on the other Mac."
            } else {
                panel.allowedContentTypes = [UTType(filenameExtension: Paths.bundleExtension) ?? .package]
                panel.nameFieldStringValue = "\(name).\(Paths.bundleExtension)"
                note.stringValue = "Ready to run. Takes only the space the disk uses on Mac disks (APFS); on other drives, the disk's full size."
            }
            panel.isExtensionHidden = false
        }
    }
}

/// Copying bundles, with the bytes copied reported as they go.
nonisolated enum StorageCopy {
    /// Clones on the same disk, which is instant; copies keeping holes elsewhere. Top-level items named in
    /// `skipping` are left out.
    static func copy(_ source: URL, to destination: URL, skipping: Set<String> = [], report: StorageActivity.Reporter) throws {
        let fm = FileManager.default
        let items = try fm.contentsOfDirectory(at: source, includingPropertiesForKeys: nil).filter { !skipping.contains($0.lastPathComponent) }
        let total = items.reduce(UInt64(0)) { $0 + DiskUsage.allocated($1) }
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        do {
            var done: UInt64 = 0
            for item in items {
                if Task.isCancelled { throw CancellationError() }
                let target = destination.appending(path: item.lastPathComponent)
                if clonefile(item.path, target.path, 0) != 0 {
                    let base = done
                    try FileClone.copy(item, to: target) { copied in report.progress(Double(base + copied) / Double(max(total, 1))) }
                }
                done += DiskUsage.allocated(item)
                report.progress(Double(done) / Double(max(total, 1)))
            }
        } catch {
            try? fm.removeItem(at: destination)
            throw error
        }
    }
}

/// Apple Archive, compressed with LZFSE. Unpacking makes zero blocks holes again, so disks stay sparse.
nonisolated enum StorageArchive {
    /// Archives the bundle's contents (not the folder itself), so it unpacks under any name.
    static func archive(_ bundle: URL, to destination: URL, skipping: Set<String>, report: StorageActivity.Reporter) throws {
        let fm = FileManager.default
        let items = try fm.contentsOfDirectory(at: bundle, includingPropertiesForKeys: nil).filter { !skipping.contains($0.lastPathComponent) }
        // The archive reads every byte, holes too, so progress counts the files' full sizes.
        let total = items.reduce(UInt64(0)) { total, item in
            let files = item.hasDirectoryPath ? (fm.enumerator(at: item, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? []) : [item]
            return total + files.reduce(0) { $0 + DiskUsage.size($1) }
        }

        guard let file = ArchiveByteStream.fileStream(path: FilePath(destination.path), mode: .writeOnly,
                                                      options: [.create, .truncate], permissions: FilePermissions(rawValue: 0o644)),
              let compressed = ArchiveByteStream.compressionStream(using: .lzfse, writingTo: file),
              let counted = ArchiveByteStream.customStream(instance: CountingStream(compressed, total: total, report: report)),
              let encoder = ArchiveStream.encodeStream(writingTo: counted)
        else { throw ControlError("Couldn't start the archive at \(destination.path).") }
        do {
            defer {
                try? encoder.close()
                try? counted.close()
                try? compressed.close()
                try? file.close()
            }
            try encoder.writeDirectoryContents(
                archiveFrom: FilePath(bundle.path),
                keySet: ArchiveHeader.FieldKeySet("TYP,PAT,LNK,DEV,DAT,MOD,FLG,MTM,BTM,CTM,XAT")!,
                selectUsing: { message, path, _ in
                    if Task.isCancelled { return .cancel }
                    if message == .searchPruneDirectory || message == .searchExclude, skipping.contains(path.string) { return .skip }
                    return .ok
                })
        } catch {
            try? fm.removeItem(at: destination)
            throw Task.isCancelled ? CancellationError() : error
        }
        if Task.isCancelled {
            try? fm.removeItem(at: destination)
            throw CancellationError()
        }
    }

    /// Unpacks into `folder`, which must exist.
    static func extract(_ archive: URL, into folder: URL, report: StorageActivity.Reporter) throws {
        guard let file = ArchiveByteStream.fileStream(path: FilePath(archive.path), mode: .readOnly, options: [], permissions: FilePermissions(rawValue: 0o644)),
              let counted = ArchiveByteStream.customStream(instance: CountingStream(file, total: DiskUsage.size(archive), report: report)),
              let decompressed = ArchiveByteStream.decompressionStream(readingFrom: counted),
              let decoder = ArchiveStream.decodeStream(readingFrom: decompressed),
              let extractor = ArchiveStream.extractStream(extractingTo: FilePath(folder.path), flags: [.ignoreOperationNotPermitted])
        else { throw ControlError("\(archive.lastPathComponent) isn't an Apple Archive.") }
        defer {
            try? extractor.close()
            try? decoder.close()
            try? decompressed.close()
            try? counted.close()
            try? file.close()
        }
        _ = try ArchiveStream.process(readingFrom: decoder, writingTo: extractor, selectUsing: { _, _, _ in
            Task.isCancelled ? .cancel : .ok
        })
        if Task.isCancelled { throw CancellationError() }
    }

    /// Passes bytes through, reporting how many went by.
    private final class CountingStream: ArchiveByteStreamProtocol {
        let stream: ArchiveByteStream
        let total: UInt64
        let report: StorageActivity.Reporter
        var count: UInt64 = 0

        init(_ stream: ArchiveByteStream, total: UInt64, report: StorageActivity.Reporter) {
            self.stream = stream
            self.total = total
            self.report = report
        }

        private func add(_ n: Int) -> Int {
            if n > 0 {
                let before = count * 1000 / max(total, 1)
                count += UInt64(n)
                if count * 1000 / max(total, 1) != before { report.progress(min(Double(count) / Double(max(total, 1)), 1)) }
            }
            return n
        }

        func read(into buffer: UnsafeMutableRawBufferPointer) throws -> Int { add(try stream.read(into: buffer)) }
        func read(into buffer: UnsafeMutableRawBufferPointer, atOffset offset: Int64) throws -> Int { try stream.read(into: buffer, atOffset: offset) }
        func write(from buffer: UnsafeRawBufferPointer) throws -> Int { add(try stream.write(from: buffer)) }
        func write(from buffer: UnsafeRawBufferPointer, atOffset offset: Int64) throws -> Int { try stream.write(from: buffer, atOffset: offset) }
        func seek(toOffset offset: Int64, relativeTo origin: FileDescriptor.SeekOrigin) throws -> Int64 { try stream.seek(toOffset: offset, relativeTo: origin) }
        func cancel() { stream.cancel() }
        func close() throws {}
    }
}

/// The one long storage job running (an import, an export, a copy), shown over the library with its
/// progress and a Cancel button.
@Observable
final class StorageActivity {
    static let shared = StorageActivity()

    /// Hands progress from the job's thread to the library. 0 to 1, or nil when there's no telling.
    struct Reporter: Sendable {
        let progress: @Sendable (Double?) -> Void
        let status: @Sendable (String) -> Void
    }

    private(set) var title: String?
    private(set) var status: String?
    private(set) var progress: Double?
    @ObservationIgnored private var task: Task<Void, Never>?

    var isRunning: Bool { title != nil }

    /// Jobs asked for while one runs (importing several files at once), started in turn.
    @ObservationIgnored private var queue: [(String, @Sendable (Reporter) async throws -> Void)] = []

    func run(_ title: String, _ work: @escaping @Sendable (Reporter) async throws -> Void) {
        guard task == nil else {
            queue.append((title, work))
            return
        }
        self.title = title
        status = nil
        progress = nil
        let reporter = Reporter(
            progress: { value in Task { @MainActor in StorageActivity.shared.progress = value } },
            status: { text in Task { @MainActor in StorageActivity.shared.status = text } })
        task = Task.detached {
            var failure: Error?
            do { try await work(reporter) } catch { failure = error }
            await MainActor.run {
                let activity = StorageActivity.shared
                activity.task = nil
                activity.title = nil
                if let failure, !(failure is CancellationError) { NSAlert(error: failure).runModal() }
                if !activity.queue.isEmpty {
                    let (title, work) = activity.queue.removeFirst()
                    activity.run(title, work)
                }
            }
        }
    }

    /// Cancels the running job and the ones waiting.
    func cancel() {
        queue.removeAll()
        task?.cancel()
        status = "Cancelling…"
    }
}

/// Shows `StorageActivity`'s job as a sheet.
struct StorageActivitySheet: ViewModifier {
    @State private var activity = StorageActivity.shared

    func body(content: Content) -> some View {
        content.sheet(isPresented: .constant(activity.isRunning)) {
            VStack(alignment: .leading, spacing: 12) {
                Text(activity.title ?? "").font(.headline)
                if let progress = activity.progress {
                    ProgressView(value: progress)
                } else {
                    ProgressView().progressViewStyle(.linear)
                }
                HStack {
                    Text(activity.status ?? activity.progress.map { $0.formatted(.percent.precision(.fractionLength(0))) } ?? "")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    Spacer()
                    Button("Cancel") { activity.cancel() }
                        .keyboardShortcut(.cancelAction)
                }
            }
            .padding(20)
            .frame(width: 400)
            .interactiveDismissDisabled()
        }
    }
}

#if DEBUG
/// Runs a storage job from the environment, for checking them without clicking through panels:
/// `HYPERBOX_STORAGE_TEST="duplicate <machine>"`, `"export <machine> <path> [archive] [snapshots]"`, `"import <path>"`.
enum StorageTest {
    static func runIfRequested() {
        guard let request = ProcessInfo.processInfo.environment["HYPERBOX_STORAGE_TEST"] else { return }
        let words = request.split(separator: " ").map(String.init)
        guard let command = words.first else { return }
        let entry = words.count > 1 ? Library.shared.machines.first { $0.config.name == words[1] || $0.id.uuidString.lowercased().hasPrefix(words[1].lowercased()) } : nil
        switch command {
        case "duplicate": if let entry { Cloner.duplicate(entry.id) }
        case "export":
            if let entry, words.count > 2 {
                Exporter.export(entry, to: URL(fileURLWithPath: words[2]), archive: words.contains("archive"), snapshots: words.contains("snapshots"), reveal: false)
            }
        case "import":
            for url in words.dropFirst().map({ URL(fileURLWithPath: $0) }) {
                if url.pathExtension == Paths.bundleExtension { Importer.copyIntoLibrary(url) } else { Importer.importFile(url) }
            }
        default: NSLog("Hyperbox: unknown storage test \(command)")
        }
    }
}
#endif
