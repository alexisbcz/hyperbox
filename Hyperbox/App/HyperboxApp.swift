import SwiftUI

/// The library: every machine, and the place to make new ones.
struct HyperboxApp: App {
    @NSApplicationDelegateAdaptor private var delegate: LibraryDelegate
    @State private var library = Library.shared

    var body: some Scene {
        Window("Hyperbox", id: "main") {
            LibraryView()
                .environment(library)
                .frame(minWidth: 820, minHeight: 520)
        }
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { Updater.shared.checkForUpdates() }
                    .disabled(!Updater.shared.canCheck)
            }
            CommandGroup(replacing: .newItem) {
                Button("New Machine…") { library.showingNewMachine = true }
                    .keyboardShortcut("n")
                Button("Import…") { Importer.chooseAndImport() }
                    .keyboardShortcut("o")
            }
            CommandGroup(after: .appSettings) {
                Button("Install ‘hyperbox’ Command in PATH") { CommandLineTool.installShowingResult() }
            }
        }

        Settings {
            SettingsView()
                .environment(library)
        }
    }
}

/// Opens machine bundles handed to the app, from Finder or `open`.
final class LibraryDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        _ = Updater.shared
        // Read the login shell's PATH now, off the main thread, before a menu item needs it.
        Task.detached { _ = Shell.environment }
        Task { await AgentIntegrations.repair() }
        Containers.registerAgent()
        #if DEBUG
        MacTestHook.runIfRequested()
        // `-showContainers YES`: open on the Containers page, for screenshots.
        if UserDefaults.standard.bool(forKey: "showContainers") { Library.shared.selection = Library.containersPage }
        StorageTest.runIfRequested()
        DebugCreate.runIfRequested()
        #endif
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.pathExtension == Paths.bundleExtension {
            Library.shared.add(url)
            if let config = try? MachineConfig.load(from: url) { Library.shared.start(config.id) }
        }
        // Anything else is something to import: a Parallels or UTM machine, an archive, a disk image.
        Importer.importFiles(urls.filter { $0.pathExtension != Paths.bundleExtension })
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
