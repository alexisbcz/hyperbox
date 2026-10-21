import SwiftUI

/// The Containers page: the engine, its containers, and official images to install in one click.
struct ContainersView: View {
    @State private var model = Containers.shared
    @State private var installing: GalleryImage?
    @State private var logs: ContainerSummary?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                EngineCard(model: model)
                if let error = model.error {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                        .onTapGesture { model.clearError() }
                }
                if !model.containers.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Containers").font(.headline)
                        ContainerList(model: model, logs: $logs)
                    }
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("Install").font(.headline)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 12)], spacing: 12) {
                        ForEach(GalleryImage.all) { image in
                            GalleryCard(image: image) { installing = image }
                        }
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 860)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Containers")
        .navigationSubtitle(subtitle)
        .toolbar {
            ToolbarItemGroup {
                if model.isRunning {
                    Button("Stop Engine", systemImage: "stop.fill") { model.stopEngine() }
                } else {
                    Button("Start Engine", systemImage: "play.fill") { model.startEngine() }
                        .disabled(model.state == .starting || model.state == .settingUp || model.activity != nil)
                }
            }
        }
        .sheet(item: $installing) { InstallSheet(image: $0, model: model) }
        .sheet(item: $logs) { LogsSheet(container: $0) }
        .onAppear { model.watch(containers: true) }
        .onDisappear { model.unwatch(containers: true) }
    }

    private var subtitle: String {
        var parts = ["Engine " + model.state.label.lowercased()]
        let running = model.containers.filter(\.isRunning).count
        if running > 0 { parts.append("\(running) running") }
        return parts.joined(separator: " · ")
    }
}

private struct EngineCard: View {
    let model: Containers

    var body: some View {
        let status = model.status
        HStack(alignment: .top, spacing: 16) {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(LinearGradient(colors: [Color(red: 0.16, green: 0.55, blue: 0.95), Color(red: 0.05, green: 0.33, blue: 0.75)],
                                     startPoint: .top, endPoint: .bottom))
                .frame(width: 52, height: 52)
                .overlay { Image(systemName: "shippingbox.fill").font(.system(size: 24, weight: .semibold)).foregroundStyle(.white) }
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Circle().fill(color).frame(width: 8, height: 8)
                    Text("Engine " + model.state.label.lowercased()).font(.title3.weight(.semibold))
                }
                Text(detail(status))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if model.state == .settingUp || model.state == .starting || model.activity != nil {
                    if let progress = status?.progress {
                        ProgressView(value: progress).frame(maxWidth: 320)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                }
                if !model.usesHyperbox {
                    HStack {
                        Text("docker uses ‘\(DockerContext.current)’.").foregroundStyle(.secondary)
                        Button("Use Hyperbox") { model.setUsesHyperbox(true) }
                            .buttonStyle(.link)
                    }
                    .font(.callout)
                }
            }
            Spacer()
        }
        .padding(16)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var color: Color {
        switch model.state {
        case .running: .green
        case .starting, .settingUp, .stopping: .orange
        case .error: .red
        case .stopped: .secondary
        }
    }

    private func detail(_ status: EngineStatus?) -> String {
        if let activity = model.activity { return activity + "…" }
        guard let status else {
            return "Starts on its own when you run a docker command, and stops when no containers have run for a while."
        }
        if let message = status.message { return message }
        var parts: [String] = []
        if let used = status.memoryUsed {
            let memory = ByteCountFormatter.string(fromByteCount: Int64(used), countStyle: .memory)
            parts.append("\(memory) memory in use" + (status.memoryLimit.map { " of \(ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .memory))" } ?? ""))
        }
        if let boot = status.bootSeconds { parts.append(String(format: "booted in %.1f s", boot)) }
        if !status.blockedPorts.isEmpty { parts.append("ports in use on this Mac: \(status.blockedPorts.joined(separator: ", "))") }
        return parts.isEmpty ? status.state.label : parts.joined(separator: " · ")
    }
}

private struct ContainerList: View {
    let model: Containers
    @Binding var logs: ContainerSummary?

    var body: some View {
        VStack(spacing: 0) {
            ForEach(model.containers) { container in
                ContainerRow(container: container, model: model, logs: $logs)
                if container.id != model.containers.last?.id { Divider().padding(.leading, 40) }
            }
        }
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct ContainerRow: View {
    let container: ContainerSummary
    let model: Containers
    @Binding var logs: ContainerSummary?
    @State private var password: String?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: GalleryImage.matching(container)?.symbol ?? "shippingbox")
                .font(.system(size: 16))
                .foregroundStyle(container.isRunning ? Color.accentColor : .secondary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(container.name).fontWeight(.medium)
                Text("\(container.image) · \(container.status)")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            ForEach(container.publishedPorts, id: \.self) { port in
                if let url = URL(string: "http://localhost:\(port.publicPort!)"), port.type == "tcp", [80, 8080, 3000, 15672, 8000].contains(port.privatePort) {
                    Link("\(port.publicPort!)", destination: url).font(.callout.monospacedDigit())
                } else {
                    Text(port.type == "udp" ? "\(port.publicPort!)/udp" : "\(port.publicPort!)")
                        .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            if let password {
                CopyButton(text: password, label: "Password")
            }
            if container.isRunning {
                Button("Stop", systemImage: "stop.fill") { model.stop(container) }
                    .labelStyle(.iconOnly).buttonStyle(.borderless).help("Stop")
            } else {
                Button("Start", systemImage: "play.fill") { model.start(container) }
                    .labelStyle(.iconOnly).buttonStyle(.borderless).help("Start")
            }
            Menu("More", systemImage: "ellipsis") {
                Button("Logs") { logs = container }
                Button("Restart") { model.restart(container) }
                Button("Copy ID") { copy(container.id) }
                Divider()
                Button("Remove", role: .destructive) { model.remove(container) }
            }
            .labelStyle(.iconOnly)
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .contextMenu {
            Button("Logs") { logs = container }
            Button(container.isRunning ? "Stop" : "Start") { container.isRunning ? model.stop(container) : model.start(container) }
            Button("Remove", role: .destructive) { model.remove(container) }
        }
        .task(id: container.id) {
            // Gallery installs keep their generated password in the container's environment; show it again.
            guard container.labels?[ContainerEngine.label] != nil, GalleryImage.matching(container)?.needsPassword == true else { return }
            let id = container.id
            let env = await Task.detached { try? ContainerEngine.environment(id) }.value ?? [:]
            password = env.first { $0.key.hasSuffix("PASSWORD") || $0.key.hasSuffix("_PASS") }?.value
        }
    }
}

private struct GalleryCard: View {
    let image: GalleryImage
    let install: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: image.symbol)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .background(Color.accentColor.gradient, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(image.name).fontWeight(.medium)
                Text(image.summary).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 4)
            Button("Install", action: install)
                .controlSize(.small)
        }
        .padding(12)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/// Confirms the name, port and password, then installs and shows how to connect.
private struct InstallSheet: View {
    let image: GalleryImage
    let model: Containers
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var port = 0
    @State private var password = GalleryImage.password()
    @State private var progress: String?
    @State private var error: String?
    @State private var done = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: image.symbol)
                    .font(.system(size: 20, weight: .medium)).foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(Color.accentColor.gradient, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading) {
                    Text(done ? "\(image.name) is running" : "Install \(image.name)").font(.title3.weight(.semibold))
                    Text(image.image).font(.caption.monospaced()).foregroundStyle(.secondary)
                }
            }
            Form {
                TextField("Name", text: $name)
                TextField("Port on this Mac", value: $port, format: .number.grouping(.never))
                if image.needsPassword {
                    LabeledContent("Password") {
                        HStack {
                            Text(password).font(.body.monospaced()).textSelection(.enabled)
                            CopyButton(text: password, label: "Copy")
                        }
                    }
                }
                if let connect = image.connect {
                    LabeledContent("Connect") {
                        HStack {
                            Text(image.filled(connect, port: port, password: password))
                                .font(.callout.monospaced()).textSelection(.enabled).lineLimit(2)
                            CopyButton(text: image.filled(connect, port: port, password: password), label: "Copy")
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .disabled(progress != nil || done)
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).textSelection(.enabled)
            } else if let progress {
                HStack {
                    ProgressView().controlSize(.small)
                    Text(progress).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            } else if !done, !Sockets.isFree(port: port) {
                Text("Something on this Mac already uses port \(port).").font(.caption).foregroundStyle(.orange)
            }
            HStack {
                Spacer()
                if done {
                    Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
                } else {
                    Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                    Button("Install") { install() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(progress != nil || name.isEmpty || !(1...65535).contains(port))
                }
            }
        }
        .padding(20)
        .frame(width: 520)
        .onAppear {
            name = uniqueName()
            port = freePort(from: image.port)
        }
    }

    private func install() {
        error = nil
        progress = "Starting the engine…"
        let image = image, name = name, port = port, password = password
        Task.detached {
            let result = Result {
                try ContainerEngine.ping()
                return try image.install(name: name, port: port, password: password) { line in
                    Task { @MainActor in progress = line }
                }
            }
            await MainActor.run {
                progress = nil
                switch result {
                case .success: done = true
                case .failure(let failure): error = failure.localizedDescription
                }
                model.refresh()
            }
        }
    }

    private func uniqueName() -> String {
        let names = Set(model.containers.map(\.name))
        var candidate = image.id
        var n = 2
        while names.contains(candidate) { candidate = "\(image.id)-\(n)"; n += 1 }
        return candidate
    }

    /// The image's usual port when nothing on the Mac uses it, else the next free one.
    private func freePort(from start: Int) -> Int {
        let taken = Set(model.containers.flatMap { $0.ports.compactMap(\.publicPort) })
        var port = start
        while port < start + 100, taken.contains(port) || !Sockets.isFree(port: port) { port += 1 }
        return port
    }
}

private struct LogsSheet: View {
    let container: ContainerSummary
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    Text(text.isEmpty ? "No output yet." : text)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                    Color.clear.frame(height: 1).id("end")
                }
                .onChange(of: text) { proxy.scrollTo("end") }
            }
            Divider()
            HStack {
                Text(container.name).font(.headline)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 720, height: 480)
        .task {
            // Rereads every two seconds while open: simple, and enough to follow a server starting up.
            let id = container.id
            while !Task.isCancelled {
                if let new = await Task.detached(operation: { try? ContainerEngine.logs(id) }).value, new != text { text = new }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }
}

struct CopyButton: View {
    let text: String
    let label: String
    @State private var copied = false

    var body: some View {
        Button(copied ? "Copied" : label, systemImage: copied ? "checkmark" : "doc.on.doc") {
            copy(text)
            copied = true
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                copied = false
            }
        }
        .controlSize(.small)
        .help("Copy to the clipboard")
    }
}

private func copy(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
}

/// The sidebar row that opens the Containers page.
struct ContainersRow: View {
    @State private var model = Containers.shared

    var body: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 28 * 0.24, style: .continuous)
                .fill(LinearGradient(colors: [Color(red: 0.16, green: 0.55, blue: 0.95), Color(red: 0.05, green: 0.33, blue: 0.75)],
                                     startPoint: .top, endPoint: .bottom))
                .frame(width: 28, height: 28)
                .overlay { Image(systemName: "shippingbox.fill").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white) }
            VStack(alignment: .leading, spacing: 1) {
                Text("Docker")
                Text(model.state.label + (model.status?.runningContainers.map { $0 > 0 ? " · \($0) running" : "" } ?? ""))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if model.isRunning { Circle().fill(.green).frame(width: 7, height: 7) }
        }
        .padding(.vertical, 2)
        .onAppear { model.watch() }
        .onDisappear { model.unwatch() }
    }
}
