import SwiftUI
import UniformTypeIdentifiers

/// Pick a system, size the machine, and Hyperbox downloads and installs it.
struct NewMachineSheet: View {
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss

    enum Source: Hashable {
        case catalog(CatalogEntry)
        case iso(URL)
        case ipsw(URL)
    }

    @State private var source: Source?
    @State private var name = ""
    @State private var cpus = 4
    @State private var memoryGB = 8
    @State private var diskGB = 64
    @State private var working = false
    @State private var status = ""
    @State private var progress: Double?
    @State private var error: String?
    @State private var task: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            if let source {
                configure(source)
            } else {
                gallery
            }
        }
        .frame(width: 620)
    }

    private var gallery: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New Machine").font(.title2.bold())
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 12)], spacing: 12) {
                ForEach(Catalog.entries) { entry in
                    Button { choose(.catalog(entry)) } label: { CatalogTile(entry: entry) }
                        .buttonStyle(.plain)
                }
            }
            Divider()
            HStack {
                Button("Install from ISO…") { pick([UTType(filenameExtension: "iso") ?? .diskImage, .diskImage]) { choose(.iso($0)) } }
                Button("Install from IPSW…") { pick([UTType(filenameExtension: "ipsw") ?? .data]) { choose(.ipsw($0)) } }
                Button("Import…") {
                    dismiss()
                    Importer.chooseAndImport()
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
    }

    private func configure(_ source: Source) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section {
                    TextField("Name", text: $name)
                    Stepper("Processors: \(cpus)", value: $cpus, in: 1...ProcessInfo.processInfo.processorCount)
                    Stepper("Memory: \(memoryGB) GB", value: $memoryGB, in: 2...max(2, Int(ProcessInfo.processInfo.physicalMemory >> 30) - 2))
                    Stepper("Disk: \(diskGB) GB", value: $diskGB, in: 16...2048, step: 16)
                } header: {
                    Text(title(source))
                } footer: {
                    Text("The disk takes only the space the system uses, not all \(diskGB) GB.").foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .disabled(working)

            if working || error != nil {
                VStack(alignment: .leading, spacing: 6) {
                    if let error {
                        Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
                    } else {
                        ProgressView(value: progress) { Text(status) }
                    }
                }
                .padding(.horizontal, 20)
            }

            HStack {
                Button("Back") { self.source = nil; error = nil }
                    .disabled(working)
                Spacer()
                Button("Cancel", role: .cancel) {
                    task?.cancel()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button("Create") { create(source) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(working || name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(20)
        }
    }

    private func title(_ source: Source) -> String {
        switch source {
        case .catalog(let entry): "\(entry.name) \(entry.version)"
        case .iso(let url), .ipsw(let url): url.lastPathComponent
        }
    }

    private func choose(_ source: Source) {
        switch source {
        case .catalog(let entry):
            name = library.uniqueName(entry.name)
            cpus = min(entry.defaultCPUs, ProcessInfo.processInfo.processorCount)
            memoryGB = entry.defaultMemoryGB
            diskGB = entry.defaultDiskGB
        case .iso(let url):
            name = library.uniqueName(url.deletingPathExtension().lastPathComponent)
        case .ipsw:
            name = library.uniqueName("macOS")
            diskGB = 80
        }
        self.source = source
    }

    private func pick(_ types: [UTType], then: @escaping (URL) -> Void) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = types
        if panel.runModal() == .OK, let url = panel.url { then(url) }
    }

    private func create(_ source: Source) {
        working = true
        error = nil
        let name = name.trimmingCharacters(in: .whitespaces)
        task = Task {
            do {
                let report: MachineFactory.Progress = { status = $0; progress = $1 }
                let url: URL
                switch source {
                case .catalog(let entry):
                    url = try await MachineFactory.create(from: entry, name: name, cpus: cpus, memoryGB: memoryGB, diskGB: diskGB, progress: report)
                case .iso(let iso):
                    url = try MachineFactory.createFromISO(iso, name: name, cpus: cpus, memoryGB: memoryGB, diskGB: diskGB)
                case .ipsw(let ipsw):
                    var config = MachineConfig(name: name, os: .macOS, cpuCount: cpus, memorySize: UInt64(memoryGB) << 30, diskSize: UInt64(diskGB) << 30)
                    url = try await MacProvisioner.create(&config, ipsw: ipsw, progress: report)
                }
                library.add(url)
                if let config = try? MachineConfig.load(from: url) { library.start(config.id) }
                dismiss()
            } catch is CancellationError {
            } catch {
                self.error = error.localizedDescription
                working = false
            }
        }
    }
}

private struct CatalogTile: View {
    let entry: CatalogEntry

    var body: some View {
        HStack(spacing: 12) {
            OSBadge(config: MachineConfig(name: "", os: entry.os, distribution: entry.id, cpuCount: 1, memorySize: 0, diskSize: 0), size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name).font(.headline)
                Text(entry.version).font(.caption).foregroundStyle(.secondary)
                Text(entry.summary).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 76, alignment: .leading)
        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .contentShape(Rectangle())
    }
}
