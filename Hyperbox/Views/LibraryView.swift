import SwiftUI

struct LibraryView: View {
    @Environment(Library.self) private var library

    var body: some View {
        @Bindable var library = library
        NavigationSplitView {
            List(selection: $library.selection) {
                Section("Machines") {
                    ForEach(library.machines) { entry in
                        MachineRow(entry: entry)
                            .tag(entry.id)
                            .contextMenu { MachineMenu(id: entry.id) }
                    }
                }
                Section("Containers") {
                    ContainersRow()
                        .tag(Library.containersPage)
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 320)
            .overlay {
                if library.machines.isEmpty, library.selection != Library.containersPage {
                    ContentUnavailableView {
                        Label("No Machines", systemImage: "shippingbox")
                    } description: {
                        Text("Install macOS or Linux in one click.")
                    } actions: {
                        Button("New Machine…") { library.showingNewMachine = true }
                    }
                }
            }
        } detail: {
            if library.selection == Library.containersPage {
                ContainersView()
            } else if let entry = library.entry(library.selection) {
                MachineDetail(entry: entry)
                    .id(entry.id)
            } else {
                Color.clear
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("New Machine", systemImage: "plus") { library.showingNewMachine = true }
            }
        }
        .sheet(isPresented: $library.showingNewMachine) {
            NewMachineSheet()
        }
        .modifier(StorageActivitySheet())
    }
}

private struct MachineRow: View {
    @Environment(Library.self) private var library
    let entry: Library.Entry

    var body: some View {
        let state = library.state(of: entry.id)
        HStack(spacing: 10) {
            OSBadge(config: entry.config, size: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.config.name)
                    .lineLimit(1)
                Text([state == .stopped && FileManager.default.fileExists(atPath: entry.bundle.savedState.path) ? "Suspended" : state.label,
                      library.statuses[entry.id]?.ipAddress].compactMap(\.self).joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if state == .running {
                Circle().fill(.green).frame(width: 7, height: 7)
            }
        }
        .padding(.vertical, 2)
    }
}

/// Start, stop and the rest, for a machine's context menu and its detail toolbar.
struct MachineMenu: View {
    @Environment(Library.self) private var library
    let id: UUID

    var body: some View {
        let running = library.isRunning(id)
        if running {
            Button("Show") { library.start(id) }
            Button("Shut Down") { library.send(.stop, to: id) }
            Button("Force Stop") { library.send(.forceStop, to: id) }
        } else {
            Button("Start") { library.start(id) }
        }
        Divider()
        Button("Show in Finder") { library.reveal(id) }
        Button("Duplicate") { Cloner.duplicate(id) }
            .disabled(running)
        Button("Export…") { Exporter.export(id) }
            .disabled(running)
        Divider()
        Button("Move to Trash", role: .destructive) { library.delete(id) }
            .disabled(running)
    }
}

/// The OS's mark on a rounded square, for lists and the Dock.
struct OSBadge: View {
    let config: MachineConfig
    var size: CGFloat

    var body: some View {
        let style = OSStyle(config)
        RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
            .fill(style.gradient)
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: style.symbol)
                    .font(.system(size: size * 0.5, weight: .semibold))
                    .foregroundStyle(.white)
            }
    }
}

struct OSStyle {
    let symbol: String
    let colors: [Color]

    init(_ config: MachineConfig) {
        switch config.distribution {
        case "ubuntu": symbol = "circle.circle"; colors = [Color(red: 0.95, green: 0.42, blue: 0.2), Color(red: 0.8, green: 0.25, blue: 0.1)]
        case "fedora": symbol = "f.circle"; colors = [Color(red: 0.25, green: 0.48, blue: 0.85), Color(red: 0.12, green: 0.27, blue: 0.62)]
        case "debian": symbol = "d.circle"; colors = [Color(red: 0.84, green: 0.1, blue: 0.33), Color(red: 0.6, green: 0.03, blue: 0.2)]
        default:
            if config.os == .macOS {
                symbol = "apple.logo"; colors = [Color(white: 0.42), Color(white: 0.18)]
            } else {
                symbol = "terminal"; colors = [Color(red: 0.3, green: 0.3, blue: 0.36), Color(red: 0.14, green: 0.14, blue: 0.18)]
            }
        }
    }

    var gradient: LinearGradient { LinearGradient(colors: colors, startPoint: .top, endPoint: .bottom) }
}

private struct MachineDetail: View {
    @Environment(Library.self) private var library
    let entry: Library.Entry

    var body: some View {
        let status = library.statuses[entry.id]
        let state = status?.state ?? .stopped
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                ThumbnailCard(entry: entry, state: state)
                    .frame(maxWidth: .infinity)
                if state == .error, let message = status?.message {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }
                if state == .installing, let progress = status?.progress {
                    ProgressView(value: progress) {
                        Text("Installing \(entry.config.os.label)… \(Int(progress * 100))%").monospacedDigit()
                    }
                }
                StorageSection(entry: entry)
                MachineSettingsForm(config: Binding(
                    get: { entry.config },
                    set: { new in library.update(entry.id) { $0 = new } }
                ), running: state != .stopped, portForwardErrors: Dictionary(uniqueKeysWithValues:
                    (status?.portForwardErrors ?? [:]).compactMap { key, value in UUID(uuidString: key).map { ($0, value) } }))
            }
            .padding(24)
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle(entry.config.name)
        .navigationSubtitle(subtitle(status))
        .toolbar {
            ToolbarItemGroup {
                if library.isRunning(entry.id) {
                    Button("Shut Down", systemImage: "power") { library.send(.stop, to: entry.id) }
                    Button("Show", systemImage: "macwindow") { library.start(entry.id) }
                } else {
                    Button("Start", systemImage: "play.fill") { library.start(entry.id) }
                }
                Menu("More", systemImage: "ellipsis.circle") { MachineMenu(id: entry.id) }
            }
        }
    }

    private func subtitle(_ status: MachineStatus?) -> String {
        var parts = [entry.config.os.label, status?.state.label ?? "Stopped"]
        if let ip = status?.ipAddress { parts.append(ip) }
        return parts.joined(separator: " · ")
    }
}

private struct ThumbnailCard: View {
    @Environment(Library.self) private var library
    let entry: Library.Entry
    let state: MachineState

    var body: some View {
        let _ = library.thumbnailGeneration
        ZStack {
            if let image = NSImage(contentsOf: entry.bundle.thumbnail) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Rectangle().fill(OSStyle(entry.config).gradient.opacity(0.35))
                    .aspectRatio(CGFloat(entry.config.display.width) / CGFloat(entry.config.display.height), contentMode: .fit)
                    .overlay { OSBadge(config: entry.config, size: 72) }
            }
            if state == .stopped || state == .error {
                Button {
                    library.start(entry.id)
                } label: {
                    Image(systemName: "play.fill")
                        .font(.system(size: 28))
                        .frame(width: 64, height: 64)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
            }
        }
        .frame(maxHeight: 360)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
        .onTapGesture(count: 2) { library.start(entry.id) }
    }
}
