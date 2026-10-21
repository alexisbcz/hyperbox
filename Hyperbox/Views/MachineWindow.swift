import SwiftUI
import Virtualization

/// A machine's own window: its screen, and the controls around it.
struct MachineWindow: View {
    let machine: Machine
    @State private var showingSettings = false

    var body: some View {
        ZStack {
            Color.black
            if machine.virtualMachine != nil {
                MachineScreen(machine: machine)
            }
            if machine.state != .running && machine.state != .installing || machine.virtualMachine == nil {
                StatusOverlay(machine: machine)
            }
        }
        .ignoresSafeArea()
        .navigationTitle(machine.config.name)
        .navigationSubtitle(machine.ipAddress ?? machine.state.label)
        .toolbar {
            ToolbarItemGroup {
                PowerButtons(machine: machine)
            }
            ToolbarItemGroup {
                SnapshotMenu(machine: machine)
                Button("Settings", systemImage: "slider.horizontal.3") { showingSettings = true }
            }
        }
        .sheet(isPresented: $showingSettings) {
            VStack(spacing: 0) {
                ScrollView {
                    MachineSettingsForm(config: Binding(
                        get: { machine.config },
                        set: { new in machine.updateConfig { $0 = new } }
                    ), running: machine.virtualMachine != nil)
                    .padding(.vertical)
                }
                HStack {
                    Spacer()
                    Button("Done") { showingSettings = false }.keyboardShortcut(.defaultAction)
                }
                .padding()
            }
            .frame(width: 560, height: 620)
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            FileDrop.drop(providers, on: machine)
        }
        .overlay(alignment: .bottom) { FileDropToast() }
        .animation(.snappy, value: FileDrop.shared.transfer)
    }
}

struct PowerButtons: View {
    let machine: Machine

    var body: some View {
        if machine.virtualMachine == nil {
            Button("Start", systemImage: "play.fill") { Task { await machine.start() } }
        } else {
            if machine.state == .paused {
                Button("Resume", systemImage: "play.fill") { Task { try? await machine.resume() } }
            } else {
                Button("Pause", systemImage: "pause.fill") { Task { try? await machine.pause() } }
            }
            Button("Shut Down", systemImage: "power") { try? machine.stop() }
        }
    }
}

struct SnapshotMenu: View {
    let machine: Machine

    var body: some View {
        Menu("Snapshots", systemImage: "camera.on.rectangle") {
            SnapshotMenuItems(machine: machine)
        }
    }
}

private struct StatusOverlay: View {
    let machine: Machine

    var body: some View {
        VStack(spacing: 14) {
            OSBadge(config: machine.config, size: 64)
            switch machine.state {
            case .error:
                Text(machine.message ?? "Something went wrong.")
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
                Button("Try Again") { Task { await machine.start() } }
            case .stopped:
                Text("\(machine.config.name) is shut down.")
                Button("Start") { Task { await machine.start() } }
                    .buttonStyle(.glassProminent)
            case .installing:
                InstallProgress(os: machine.config.os, progress: machine.progress)
            default:
                ProgressView()
                Text(machine.state.label + "…")
            }
        }
        .foregroundStyle(.white)
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black.opacity(0.85))
    }
}

/// How far an install has got, for the machine's window and the library.
struct InstallProgress: View {
    let os: GuestOS
    let progress: Double?

    var body: some View {
        VStack(spacing: 8) {
            Text("Installing \(os.label)…").font(.headline)
            ProgressView(value: progress)
                .frame(width: 280)
            Group {
                if let progress, progress > 0 {
                    Text("\(Int(progress * 100))% · The machine starts on its own when it's done.")
                } else {
                    Text("Getting ready…")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .monospacedDigit()
        }
    }
}

/// The guest's screen. It takes the keyboard while focused, and resizes the guest's display to fit the window.
struct MachineScreen: NSViewRepresentable {
    let machine: Machine

    func makeNSView(context: Context) -> VZVirtualMachineView {
        let view = VZVirtualMachineView()
        view.capturesSystemKeys = true
        view.automaticallyReconfiguresDisplay = true
        view.virtualMachine = machine.virtualMachine
        machine.screenView = view
        DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
        return view
    }

    func updateNSView(_ view: VZVirtualMachineView, context: Context) {
        if view.virtualMachine !== machine.virtualMachine { view.virtualMachine = machine.virtualMachine }
        machine.screenView = view
    }
}

struct MachineCommands: Commands {
    let machine: Machine?

    var body: some Commands {
        CommandMenu("Machine") {
            if let machine {
                Button("Start") { Task { await machine.start() } }
                    .keyboardShortcut("r")
                    .disabled(machine.virtualMachine != nil)
                Button(machine.state == .paused ? "Resume" : "Pause") {
                    Task { machine.state == .paused ? try? await machine.resume() : try? await machine.pause() }
                }
                .disabled(machine.virtualMachine == nil)
                Button("Shut Down") { try? machine.stop() }
                    .disabled(machine.virtualMachine == nil)
                Button("Force Stop") { Task { await machine.forceStop() } }
                    .keyboardShortcut(".", modifiers: [.command, .option])
                    .disabled(machine.virtualMachine == nil)
                Divider()
                SnapshotMenuItems(machine: machine)
            }
        }
    }
}

/// The Dock icon of a machine's process: its OS badge, so each machine is easy to find.
enum DockIcon {
    static func image(for config: MachineConfig) -> NSImage {
        let renderer = ImageRenderer(content:
            OSBadge(config: config, size: 820)
                .padding(102)
                .frame(width: 1024, height: 1024)
        )
        renderer.scale = 1
        return renderer.nsImage ?? NSApp.applicationIconImage
    }
}
