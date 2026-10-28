import SwiftUI

/// The Settings window (⌘,): native tabs and grouped forms, like System Settings.
struct SettingsView: View {
    /// Reopens on the tab you used last.
    @AppStorage("settings.tab") private var tab = "general"

    var body: some View {
        TabView(selection: $tab) {
            Tab("General", systemImage: "gearshape", value: "general") {
                GeneralSettings()
            }
            Tab("Agents", systemImage: "sparkles", value: "agents") {
                AgentsSettings()
            }
            Tab("Containers", systemImage: "shippingbox", value: "containers") {
                ContainersSettings()
            }
            Tab("Models", systemImage: "eye", value: "models") {
                ModelsSettings()
            }
        }
        .frame(width: 520)
    }
}

private struct GeneralSettings: View {
    @State private var updater = Updater.shared
    @State private var cli = CommandLineTool.status

    var body: some View {
        Form {
            Section("Updates") {
                Toggle("Check for updates automatically", isOn: $updater.checksAutomatically)
                Toggle("Download and install updates in the background", isOn: $updater.installsAutomatically)
                    .disabled(!updater.checksAutomatically)
                LabeledContent("Version", value: Updater.version)
                Button("Check Now") { updater.checkForUpdates() }
                    .disabled(!updater.canCheck)
            }
            Section("Command Line") {
                switch cli {
                case .installed(let link):
                    LabeledContent("hyperbox", value: link.path)
                    Button("Uninstall") { try? CommandLineTool.uninstall(); cli = CommandLineTool.status }
                default:
                    Button("Install ‘hyperbox’ Command in PATH") { CommandLineTool.installShowingResult(); cli = CommandLineTool.status }
                }
            }
        }
        .formStyle(.grouped)
    }
}
