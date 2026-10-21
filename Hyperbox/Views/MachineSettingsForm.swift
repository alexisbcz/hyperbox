import SwiftUI
import Virtualization

/// A machine's settings. The name, shared folders, network and agent access change while it runs;
/// the hardware waits for the next boot.
struct MachineSettingsForm: View {
    @Binding var config: MachineConfig
    var running: Bool

    private var maxCPUs: Int { ProcessInfo.processInfo.processorCount }
    private var maxMemoryGB: Int { Int(ProcessInfo.processInfo.physicalMemory >> 30) }

    var body: some View {
        Form {
            Section("General") {
                TextField("Name", text: $config.name)
            }

            if let user = config.guestUser {
                Section {
                    LabeledContent("User", value: user.name)
                    LabeledContent("Password") { Text(user.password).monospaced().textSelection(.enabled) }
                } header: {
                    Text("Account")
                } footer: {
                    Text("Hyperbox made this account when it set up \(config.os.label).").foregroundStyle(.secondary)
                }
            }

            Section {
                Stepper("Processors: \(config.cpuCount)", value: $config.cpuCount, in: 1...maxCPUs)
                Stepper("Memory: \(config.memorySize >> 30) GB", value: Binding(
                    get: { Int(config.memorySize >> 30) },
                    set: { config.memorySize = UInt64($0) << 30 }
                ), in: 2...max(2, maxMemoryGB - 2))
                Picker("Display", selection: Binding(
                    get: { DisplayPreset.matching(config.display) },
                    set: { config.display = $0.display }
                )) {
                    ForEach(DisplayPreset.allCases) { Text($0.label).tag($0) }
                }
                LabeledContent("Disk", value: ByteCountFormatter.string(fromByteCount: Int64(config.diskSize), countStyle: .file))
            } header: {
                Text("Hardware")
            } footer: {
                if running { Text("Hardware changes apply the next time the machine starts.").foregroundStyle(.secondary) }
            }
            .disabled(running)

            Section {
                SharedFoldersList(folders: $config.sharedFolders)
            } header: {
                Text("Shared Folders")
            } footer: {
                Text(config.os == .macOS ? "They appear in Finder under My Shared Files." : "They appear in the Files app under /mnt/hyperbox.")
                    .foregroundStyle(.secondary)
            }

            Section("Network") {
                Toggle("Connected", isOn: $config.network.enabled)
                PortForwardsList(forwards: $config.network.portForwards)
            }

            Section {
                Toggle("Sound", isOn: $config.sound)
                Toggle("Microphone", isOn: $config.microphone)
                    .disabled(!config.sound)
            } header: {
                Text("Sound")
            }
            .disabled(running)

            if config.os == .linux {
                Section("Linux") {
                    Toggle("Run Intel apps with Rosetta", isOn: $config.rosetta)
                    Toggle("Nested virtualization", isOn: $config.nestedVirtualization)
                        .disabled(!VZGenericPlatformConfiguration.isNestedVirtualizationSupported)
                }
                .disabled(running)
            }

            Section {
                Toggle("Let AI agents use this machine", isOn: $config.agentControl)
            } header: {
                Text("Agents")
            } footer: {
                Text("Agents see the screen and use the machine's own keyboard and mouse. They never see your Mac's screen or files.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .scrollContentBackground(.hidden)
    }
}

enum DisplayPreset: String, CaseIterable, Identifiable {
    case screen, hd, wuxga, qhd, retina5k
    var id: String { rawValue }

    var display: MachineConfig.Display {
        switch self {
        case .screen: .matchingMainScreen()
        case .hd: .init(width: 1920, height: 1080, pixelsPerInch: 110)
        case .wuxga: .init(width: 1920, height: 1200, pixelsPerInch: 144)
        case .qhd: .init(width: 2560, height: 1600, pixelsPerInch: 220)
        case .retina5k: .init(width: 5120, height: 2880, pixelsPerInch: 218)
        }
    }

    var label: String { self == .screen ? "Sharp as This Mac" : "\(display.width) × \(display.height)" }

    /// A size none of the presets has came from `matchingMainScreen`.
    static func matching(_ display: MachineConfig.Display) -> DisplayPreset {
        allCases.first { $0 != .screen && $0.display.width == display.width && $0.display.height == display.height } ?? .screen
    }
}

private struct SharedFoldersList: View {
    @Binding var folders: [MachineConfig.SharedFolder]

    var body: some View {
        ForEach($folders) { $folder in
            HStack {
                Image(systemName: "folder.fill").foregroundStyle(.tint)
                Text(folder.name)
                Text(folder.path).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                Spacer()
                Toggle("Read only", isOn: $folder.readOnly).toggleStyle(.checkbox)
                Button("Remove", systemImage: "minus.circle.fill") { folders.removeAll { $0.id == folder.id } }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
            }
        }
        Button("Add Folder…") {
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.allowsMultipleSelection = true
            guard panel.runModal() == .OK else { return }
            for url in panel.urls where !folders.contains(where: { $0.path == url.path }) {
                folders.append(.init(path: url.path))
            }
        }
    }
}

private struct PortForwardsList: View {
    @Binding var forwards: [MachineConfig.PortForward]

    var body: some View {
        ForEach($forwards) { $forward in
            HStack {
                TextField("Mac port", value: $forward.hostPort, format: .number.grouping(.never))
                    .frame(width: 90)
                Image(systemName: "arrow.right").foregroundStyle(.secondary)
                TextField("Guest port", value: $forward.guestPort, format: .number.grouping(.never))
                    .frame(width: 90)
                Picker("", selection: $forward.udp) {
                    Text("TCP").tag(false)
                    Text("UDP").tag(true)
                }
                .labelsHidden()
                .frame(width: 80)
                Spacer()
                Button("Remove", systemImage: "minus.circle.fill") { forwards.removeAll { $0.id == forward.id } }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
            }
            .textFieldStyle(.roundedBorder)
        }
        Button("Forward a Port…") {
            let used = Set(forwards.map(\.hostPort))
            var port: UInt16 = 8080
            while used.contains(port) { port += 1 }
            forwards.append(.init(hostPort: port, guestPort: 80))
        }
    }
}
