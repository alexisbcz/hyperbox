import SwiftUI

/// Settings › Agents: adds Hyperbox's MCP server to the AI agents on this Mac, in one click each.
struct AgentsSettings: View {
    @AppStorage("agents.snapshotBeforeSession") private var snapshotBeforeSession = false
    @State private var states: [String: AgentIntegrations.State] = [:]
    @State private var working: String?
    @State private var error: String?
    @State private var copied = false

    var body: some View {
        Form {
            Section {
                ForEach(AgentIntegrations.agents) { agent in
                    row(agent)
                }
            } header: {
                Text("MCP Server")
            } footer: {
                Text("Agents see a machine's screen and use its own keyboard and mouse, so Hyperbox needs no Accessibility or Screen Recording permission. Turn Agent Control off in a machine's settings to keep agents out of it. Restart an agent after adding Hyperbox.")
                    .foregroundStyle(.secondary)
            }
            Section("Safety") {
                Toggle("Take a snapshot before each agent session", isOn: $snapshotBeforeSession)
                Text("The first time an agent changes a machine, Hyperbox snapshots it, so you can undo everything the agent did.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Section {
                Text(AgentIntegrations.snippet)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button(copied ? "Copied" : "Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(AgentIntegrations.snippet, forType: .string)
                    copied = true
                }
            } header: {
                Text("Other Agents")
            } footer: {
                Text("Most agents read this shape of config. Agents inside a machine can't reach this server; run them on your Mac and they can drive the machine, or use run_command for the guest's own tools.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: refresh)
        .alert("Couldn't change the agent's settings", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") {}
        } message: {
            Text(error ?? "")
        }
    }

    @ViewBuilder
    private func row(_ agent: AgentIntegrations.Agent) -> some View {
        let state = states[agent.id] ?? .notFound
        LabeledContent {
            if working == agent.id {
                ProgressView().controlSize(.small)
            } else {
                switch state {
                case .notFound, .notAdded:
                    Button("Add") { change(agent, add: true) }
                case .added:
                    Button("Remove") { change(agent, add: false) }
                case .elsewhere:
                    HStack {
                        Button("Update") { change(agent, add: true) }
                        Button("Remove") { change(agent, add: false) }
                    }
                }
            }
        } label: {
            Text(agent.name)
            switch state {
            case .notFound: Text("Not found on this Mac")
            case .notAdded: Text("Not added")
            case .added: Label("Added", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            case .elsewhere(let path): Text("Uses another copy of Hyperbox: \(path)")
            }
        }
        .help(agent.file.path)
    }

    private func change(_ agent: AgentIntegrations.Agent, add: Bool) {
        working = agent.id
        Task {
            do {
                if add { try await AgentIntegrations.add(agent) } else { try await AgentIntegrations.remove(agent) }
            } catch {
                self.error = error.localizedDescription
            }
            working = nil
            refresh()
        }
    }

    private func refresh() {
        states = Dictionary(uniqueKeysWithValues: AgentIntegrations.agents.map { ($0.id, AgentIntegrations.state(of: $0)) })
    }
}
