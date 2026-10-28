import SwiftUI

/// Settings › Models: Liquid's LFM3 models, which answer questions about a machine's screen on this Mac
/// for `hyperbox check`, `wait` and `describe`, and the MCP server's check_screen, wait_for_screen and
/// describe_screen.
struct ModelsSettings: View {
    @AppStorage(ModelSettings.enabledKey) private var enabled = true
    @State private var downloaded: [LocalModel: Int64] = [:]
    @State private var running: [LocalModel: Int] = [:]
    @State private var progress: [LocalModel: (status: String, fraction: Double?)] = [:]
    @State private var tasks: [LocalModel: Task<Void, Never>] = [:]
    @State private var error: String?

    var body: some View {
        Form {
            Section {
                Toggle("Answer questions about screens on this Mac", isOn: $enabled)
            } footer: {
                Text("Scripts, recipes and agents can wait for a screen (`hyperbox wait`), ask about it (`hyperbox check`) or have it described (`hyperbox describe`), without a cloud model and without the screen leaving this Mac. Each model downloads the first time it's needed, and runs in llama.cpp \(LlamaCpp.build) until it's been idle for \(Int(ModelServer.idleTimeout / 60)) minutes.")
                    .foregroundStyle(.secondary)
            }
            Section {
                ForEach(LocalModel.allCases) { row($0) }
            } header: {
                Text("Models")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(LocalModel.licenseNote)
                    Link("Read the \(LocalModel.license)", destination: LocalModel.licenseURL)
                }
                .foregroundStyle(.secondary)
            }
            .disabled(!enabled)
        }
        .formStyle(.grouped)
        .task {
            while !Task.isCancelled {
                refresh()
                try? await Task.sleep(for: .seconds(2))
            }
        }
        .onChange(of: enabled) { if !enabled { LocalModel.allCases.forEach(ModelServer.stop) } }
        .alert("Couldn't download the model", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") {}
        } message: {
            Text(error ?? "")
        }
    }

    @ViewBuilder
    private func row(_ model: LocalModel) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            LabeledContent {
                if tasks[model] != nil {
                    Button("Cancel") { tasks[model]?.cancel() }
                } else if downloaded[model] != nil {
                    HStack {
                        if running[model] != nil { Button("Stop") { ModelServer.stop(model); refresh() } }
                        Button("Delete") { model.delete(); refresh() }
                    }
                } else {
                    Button("Download") { download(model) }
                }
            } label: {
                Text(model.rawValue)
                Text(model.summary)
                if let port = running[model] {
                    Label("Running on port \(port)", systemImage: "circle.fill").foregroundStyle(.green)
                } else if let size = downloaded[model] {
                    Text("Downloaded, \(LocalModel.bytes(size))")
                }
            }
            if let progress = progress[model] {
                ProgressView(value: progress.fraction) { Text(progress.status).font(.caption) }
            }
        }
        .help(model.page.absoluteString)
    }

    private func download(_ model: LocalModel) {
        progress[model] = ("Starting…", nil)
        tasks[model] = Task {
            do {
                try await model.download { status, fraction in
                    Task { @MainActor in if tasks[model] != nil { progress[model] = (status, fraction) } }
                }
            } catch is CancellationError {
            } catch {
                self.error = error.localizedDescription
            }
            tasks[model] = nil
            progress[model] = nil
            refresh()
        }
    }

    private func refresh() {
        downloaded = Dictionary(uniqueKeysWithValues: LocalModel.allCases.filter(\.isDownloaded).map { ($0, $0.size) })
        running = Dictionary(uniqueKeysWithValues: LocalModel.allCases.compactMap { m in ModelServer.running(m).map { (m, $0.port) } })
    }
}
