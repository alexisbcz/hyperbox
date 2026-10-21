import SwiftUI

/// Settings › Containers: whether `docker` uses Hyperbox, and the engine's size.
struct ContainersSettings: View {
    @State private var model = Containers.shared
    @State private var settings = EngineSettings.load()
    @State private var resetting = false

    var body: some View {
        Form {
            Section {
                Toggle("Use Hyperbox for docker", isOn: Binding(get: { model.usesHyperbox }, set: { model.setUsesHyperbox($0) }))
                LabeledContent("Socket", value: EnginePaths.socket.path)
                    .textSelection(.enabled)
            } footer: {
                Text("Switches the Docker context to ‘hyperbox’; off goes back to ‘\(DockerContext.previous)’. Compose and Testcontainers can use DOCKER_HOST=\(DockerContext.host).")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Stepper("CPUs: \(settings.cpuCount)", value: $settings.cpuCount, in: 1...ProcessInfo.processInfo.processorCount)
                Picker("Memory", selection: $settings.memorySize) {
                    ForEach([1, 2, 3, 4, 6, 8, 12, 16].filter { UInt64($0) << 30 <= ProcessInfo.processInfo.physicalMemory / 2 }, id: \.self) {
                        Text("\($0) GB").tag(UInt64($0) << 30)
                    }
                }
                Picker("Stop when idle for", selection: $settings.idleMinutes) {
                    Text("1 minute").tag(1)
                    Text("5 minutes").tag(5)
                    Text("15 minutes").tag(15)
                    Text("1 hour").tag(60)
                    Text("Never").tag(0)
                }
            } header: {
                Text("Engine")
            } footer: {
                Text("Memory is the most the engine may use; it stops when idle, which frees it all. Changes apply the next time the engine starts.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                LabeledContent("State", value: model.state.label)
                HStack {
                    Button("Restart Engine") { model.restartEngine() }
                        .disabled(!model.isRunning)
                    Button("Show Engine Files") { NSWorkspace.shared.activateFileViewerSelecting([EnginePaths.root]) }
                    Spacer()
                    Button("Reset Engine…", role: .destructive) { resetting = true }
                }
            }
        }
        .formStyle(.grouped)
        .onChange(of: settings) {
            // Reread first, so a field the engine owns (the MAC address) is never overwritten with a stale copy.
            var current = EngineSettings.load()
            current.cpuCount = settings.cpuCount
            current.memorySize = settings.memorySize
            current.idleMinutes = settings.idleMinutes
            current.save()
        }
        .onAppear { model.watch() }
        .onDisappear { model.unwatch() }
        .confirmationDialog("Reset the container engine?", isPresented: $resetting) {
            Button("Delete All Images, Containers and Volumes", role: .destructive) { reset() }
        } message: {
            Text("The engine's disk is erased and set up again the next time it starts.")
        }
    }

    private func reset() {
        model.perform("Resetting the engine") {
            if let status = EngineStatus.read() {
                kill(status.pid, SIGTERM)
                for _ in 0..<300 where EngineStatus.read() != nil { try await Task.sleep(for: .milliseconds(100)) }
            }
            let fm = FileManager.default
            for url in [EnginePaths.disk, EnginePaths.efiVariables, EnginePaths.ready, EnginePaths.boot, EnginePaths.seed] {
                try? fm.removeItem(at: url)
            }
        }
    }
}
