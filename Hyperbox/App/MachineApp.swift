import SwiftUI

/// One machine in its own process: its screen in a window, and its own Dock icon.
struct MachineApp: App {
    static let argument = "--machine"

    /// The bundle this process runs, from `--machine <path>`.
    static var bundlePath: String? {
        let arguments = CommandLine.arguments
        guard let i = arguments.firstIndex(of: argument), i + 1 < arguments.count else { return nil }
        return arguments[i + 1]
    }

    @NSApplicationDelegateAdaptor private var delegate: MachineDelegate

    var body: some Scene {
        Window(delegate.machine?.config.name ?? "Hyperbox", id: "machine") {
            Group {
                if let machine = delegate.machine {
                    MachineWindow(machine: machine)
                } else {
                    ContentUnavailableView("Couldn't open the machine", systemImage: "exclamationmark.triangle", description: Text(delegate.error ?? ""))
                }
            }
            .frame(minWidth: 640, minHeight: 400)
        }
        .defaultSize(delegate.machine?.config.display.sizeInPoints ?? CGSize(width: 1280, height: 800))
        .windowToolbarStyle(.unified(showsTitle: true))
        .commands {
            CommandGroup(replacing: .newItem) {}
            MachineCommands(machine: delegate.machine)
        }
    }
}

final class MachineDelegate: NSObject, NSApplicationDelegate {
    let machine: Machine?
    let error: String?
    private var clipboard: ClipboardSync?

    override init() {
        do {
            let machine = try Machine(bundle: URL(fileURLWithPath: MachineApp.bundlePath ?? ""))
            self.machine = machine
            error = nil
        } catch {
            machine = nil
            self.error = error.localizedDescription
        }
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let machine else { return }
        NSApp.applicationIconImage = DockIcon.image(for: machine.config)
        machine.listen()
        clipboard = ClipboardSync(machine)
        Task { await machine.start() }
    }

    /// Closing the window leaves the machine running; the Dock icon brings it back.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        machine?.virtualMachine == nil
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool { true }

    /// Quitting shuts the guest down first, and pulls the plug if it doesn't stop in time.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let machine, machine.virtualMachine != nil else { return .terminateNow }
        Task {
            machine.saveThumbnail()
            try? machine.stop()
            for _ in 0..<150 where machine.virtualMachine != nil { try? await Task.sleep(for: .milliseconds(100)) }
            await machine.forceStop()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        machine?.shutdown()
    }
}
