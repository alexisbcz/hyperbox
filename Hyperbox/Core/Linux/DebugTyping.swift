#if DEBUG
import AppKit
import Virtualization

/// For testing installers without a person at the keyboard: text written to `debug-type.txt` in a
/// running machine's bundle is typed into its screen, as a US keyboard would, then the file is removed.
/// A `debug-eject` file does what "Eject Installer" does.
enum DebugTyping {
    static func watch(_ machine: Machine) {
        guard ProcessInfo.processInfo.environment["HYPERBOX_DEBUG_TYPING"] != nil else { return }
        let file = machine.bundle.url.appending(path: "debug-type.txt")
        Task {
            while machine.virtualMachine != nil {
                if let text = try? String(contentsOf: file, encoding: .utf8) {
                    try? FileManager.default.removeItem(at: file)
                    await type(text, into: machine)
                }
                let eject = machine.bundle.url.appending(path: "debug-eject")
                if FileManager.default.fileExists(atPath: eject.path) {
                    try? FileManager.default.removeItem(at: eject)
                    await LinuxGuest.ejectInstaller(machine)
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private static func type(_ text: String, into machine: Machine) async {
        guard let view = machine.screenView else { return }
        // Shift plus the left Shift key's device bit, which the screen view reads to press it in the guest.
        let shiftFlags = NSEvent.ModifierFlags(rawValue: NSEvent.ModifierFlags.shift.rawValue | 0x2)
        for character in text {
            guard let (code, shift) = keys[character] else { continue }
            if shift { view.flagsChanged(with: event(.flagsChanged, code: 56, flags: shiftFlags, view: view)) }
            view.keyDown(with: event(.keyDown, code: code, flags: shift ? shiftFlags : [], view: view, characters: String(character)))
            view.keyUp(with: event(.keyUp, code: code, flags: shift ? shiftFlags : [], view: view, characters: String(character)))
            if shift { view.flagsChanged(with: event(.flagsChanged, code: 56, flags: [], view: view)) }
            try? await Task.sleep(for: .milliseconds(15))
        }
    }

    private static func event(_ type: NSEvent.EventType, code: UInt16, flags: NSEvent.ModifierFlags, view: NSView, characters: String = "") -> NSEvent {
        if type == .flagsChanged {
            return NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                    windowNumber: view.window?.windowNumber ?? 0, context: nil, characters: "", charactersIgnoringModifiers: "",
                                    isARepeat: false, keyCode: code)!
        }
        return NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                windowNumber: view.window?.windowNumber ?? 0, context: nil, characters: characters,
                                charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!
    }

    /// US key codes, and whether the character needs Shift.
    private static let keys: [Character: (UInt16, Bool)] = {
        var keys: [Character: (UInt16, Bool)] = [:]
        for (code, character) in "asdfhgzxcv\u{0}bqweryt123465=97-80]ou[ip\u{0}lj'k;\\,/nm.".enumerated() where character != "\u{0}" {
            keys[character] = (UInt16(code), false)
        }
        keys["`"] = (50, false); keys[" "] = (49, false); keys["\n"] = (36, false)
        let shifted: [Character: Character] = ["!": "1", "@": "2", "#": "3", "$": "4", "%": "5", "^": "6", "&": "7", "*": "8", "(": "9",
            ")": "0", "_": "-", "+": "=", "{": "[", "}": "]", "|": "\\", ":": ";", "\"": "'", "<": ",", ">": ".", "?": "/", "~": "`"]
        for (character, base) in shifted { keys[character] = (keys[base]!.0, true) }
        for character in "abcdefghijklmnopqrstuvwxyz" { keys[Character(character.uppercased())] = (keys[character]!.0, true) }
        return keys
    }()
}
#endif
