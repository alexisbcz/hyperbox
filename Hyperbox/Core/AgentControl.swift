import AppKit
import Virtualization

/// Lets AI agents see a machine's screen and use its keyboard and mouse, by sending events to the
/// machine's own view: nothing touches your Mac's screen, so Hyperbox needs no Accessibility or
/// Screen Recording permission.
///
/// Coordinates are pixels of the last screenshot an agent took, (0, 0) at the top left, so an agent
/// can click what it sees without knowing the guest's real resolution or the window's size.
enum AgentControl {
    /// The size of the last screenshot handed out, per machine; clicks are in its pixels.
    private static var spaces: [UUID: CGSize] = [:]

    static func handle(_ method: ControlMethod, params: JSONValue, machine: Machine) async throws -> JSONValue {
        switch method {
        case .screenshot:
            return try screenshot(machine, maxWidth: params["maxWidth"]?.double)
        case .type:
            guard let text = params["text"]?.string else { throw ControlError("type needs text.") }
            try await type(text, into: view(of: machine))
        case .key:
            guard let key = params["key"]?.string else { throw ControlError("key needs a key, such as \"return\" or \"c\".") }
            let modifiers = params["modifiers"]?.array?.compactMap(\.string) ?? []
            try await press(key, modifiers: modifiers, in: view(of: machine))
        case .click:
            let view = try view(of: machine)
            let point = try point(params, machine: machine, view: view)
            let count = max(1, params["count"]?.int ?? 1)
            let button = params["button"]?.string ?? "left"
            guard ["left", "right", "middle"].contains(button) else { throw ControlError("button is left, right or middle.") }
            let modifiers = try flags(params["modifiers"]?.array?.compactMap(\.string) ?? [])
            try await click(at: point, button: button, count: count, modifiers: modifiers, in: view)
        case .moveMouse:
            let view = try view(of: machine)
            try await move(to: point(params, machine: machine, view: view), in: view)
        case .scroll:
            let view = try view(of: machine)
            if params["x"] != nil { try await move(to: point(params, machine: machine, view: view), in: view) }
            scroll(deltaX: params["deltaX"]?.double ?? 0, deltaY: params["deltaY"]?.double ?? 0, in: view)
        case .drag:
            let view = try view(of: machine)
            let from = try point(params, machine: machine, view: view)
            var to = params
            if case .object(var o) = params { o["x"] = params["toX"]; o["y"] = params["toY"]; to = .object(o) }
            try await drag(from: from, to: point(to, machine: machine, view: view), in: view)
        default:
            throw ControlError("\(method.rawValue) isn't an agent method.")
        }
        return .null
    }

    // MARK: - Screen

    private static func screenshot(_ machine: Machine, maxWidth: Double?) throws -> JSONValue {
        let view = try view(of: machine)
        guard let image = ScreenCapture.cgImage(of: view) else {
            throw ControlError("Couldn't read \(machine.config.name)'s screen. Is its window open?")
        }
        let scaled = image.scaled(maxWidth: maxWidth.map { Int($0) })
        guard let png = scaled.pngData() else { throw ControlError("Couldn't encode the screenshot.") }
        spaces[machine.id] = CGSize(width: scaled.width, height: scaled.height)
        return [
            "png": .string(png.base64EncodedString()),
            "width": .number(Double(scaled.width)), "height": .number(Double(scaled.height)),
            "screenWidth": .number(Double(image.width)), "screenHeight": .number(Double(image.height)),
        ]
    }

    private static func view(of machine: Machine) throws -> VZVirtualMachineView {
        guard machine.virtualMachine != nil else { throw ControlError("\(machine.config.name) isn't running. Start it first.") }
        guard let view = machine.screenView, view.window != nil else {
            throw ControlError("\(machine.config.name)'s window is closed. Run `hyperbox start` or click its Dock icon to open it again.")
        }
        return view
    }

    /// Turns screenshot pixels into a point in the view's coordinates, where the guest's screen fills the
    /// view but keeps its shape.
    private static func point(_ params: JSONValue, machine: Machine, view: VZVirtualMachineView) throws -> CGPoint {
        guard let x = params["x"]?.double, let y = params["y"]?.double else { throw ControlError("Needs x and y, in screenshot pixels.") }
        // Without a screenshot yet, the coordinates are the guest's own pixels.
        let space: CGSize
        if let w = params["width"]?.double, let h = params["height"]?.double { space = CGSize(width: w, height: h) }
        else if let known = spaces[machine.id] { space = known }
        else if let image = ScreenCapture.cgImage(of: view) { space = CGSize(width: image.width, height: image.height) }
        else { throw ControlError("Take a screenshot first, so Hyperbox knows the screen's size.") }
        guard (0...space.width).contains(x), (0...space.height).contains(y) else {
            throw ControlError("(\(Int(x)), \(Int(y))) is off the screen, which is \(Int(space.width))×\(Int(space.height)).")
        }
        let bounds = view.bounds
        let scale = min(bounds.width / space.width, bounds.height / space.height)
        let shown = CGSize(width: space.width * scale, height: space.height * scale)
        let origin = CGPoint(x: bounds.midX - shown.width / 2, y: bounds.midY - shown.height / 2)
        let local = CGPoint(x: origin.x + x * scale, y: view.isFlipped ? origin.y + y * scale : origin.y + shown.height - y * scale)
        return view.convert(local, to: nil)
    }

    // MARK: - Mouse

    /// Where the guest's pointer was last put, in window coordinates, so drags and scrolls start there.
    private(set) static var pointer: CGPoint?
    /// Whether the left button is held, for recordings to show the press.
    private(set) static var isPressed = false
    /// True while an event of ours is on its way into the view, which takes only these while it's being filmed.
    private(set) static var delivering = false

    /// A point in window coordinates as pixels of the guest's screen, `size` big, (0, 0) at the top left.
    static func pixel(of point: CGPoint, in view: VZVirtualMachineView, screen size: CGSize) -> CGPoint {
        let local = view.convert(point, from: nil)
        let bounds = view.bounds
        let scale = min(bounds.width / size.width, bounds.height / size.height)
        let shown = CGSize(width: size.width * scale, height: size.height * scale)
        let origin = CGPoint(x: bounds.midX - shown.width / 2, y: bounds.midY - shown.height / 2)
        let x = (local.x - origin.x) / scale
        let y = view.isFlipped ? (local.y - origin.y) / scale : (origin.y + shown.height - local.y) / scale
        return CGPoint(x: x, y: y)
    }

    private static func move(to point: CGPoint, in view: VZVirtualMachineView) async throws {
        send(mouse: .mouseMoved, at: point, in: view)
        pointer = point
        try await pause()
    }

    private static func click(at point: CGPoint, button: String, count: Int, modifiers: NSEvent.ModifierFlags, in view: VZVirtualMachineView) async throws {
        try await move(to: point, in: view)
        let (down, up): (NSEvent.EventType, NSEvent.EventType) = switch button {
        case "right": (.rightMouseDown, .rightMouseUp)
        case "middle": (.otherMouseDown, .otherMouseUp)
        default: (.leftMouseDown, .leftMouseUp)
        }
        for n in 1...count {
            send(mouse: down, at: point, clickCount: n, modifiers: modifiers, in: view)
            try await pause()
            send(mouse: up, at: point, clickCount: n, modifiers: modifiers, in: view)
            try await pause()
        }
    }

    /// In steps, so the guest sees the pointer travel, as apps that track dragging expect.
    private static func drag(from: CGPoint, to: CGPoint, in view: VZVirtualMachineView) async throws {
        try await move(to: from, in: view)
        send(mouse: .leftMouseDown, at: from, clickCount: 1, in: view)
        try await pause()
        let steps = 12
        for i in 1...steps {
            let t = CGFloat(i) / CGFloat(steps)
            let point = CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t)
            send(mouse: .leftMouseDragged, at: point, in: view)
            try await pause()
        }
        send(mouse: .leftMouseUp, at: to, clickCount: 1, in: view)
        pointer = to
        try await pause()
    }

    private static func send(mouse type: NSEvent.EventType, at point: CGPoint, clickCount: Int = 0, modifiers: NSEvent.ModifierFlags = [], in view: VZVirtualMachineView) {
        guard let window = view.window, let event = NSEvent.mouseEvent(
            with: type, location: point, modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: clickCount, pressure: type == .leftMouseDown ? 1 : 0)
        else { return }
        if type == .leftMouseDown { isPressed = true } else if type == .leftMouseUp { isPressed = false }
        delivering = true
        defer { delivering = false }
        switch type {
        case .mouseMoved: view.mouseMoved(with: event)
        case .leftMouseDown: view.mouseDown(with: event)
        case .leftMouseUp: view.mouseUp(with: event)
        case .rightMouseDown: view.rightMouseDown(with: event)
        case .rightMouseUp: view.rightMouseUp(with: event)
        case .otherMouseDown: view.otherMouseDown(with: event)
        case .otherMouseUp: view.otherMouseUp(with: event)
        case .leftMouseDragged: view.mouseDragged(with: event)
        default: break
        }
    }

    /// Notches of a mouse wheel: positive deltaY scrolls the content down, as an agent reading a page expects.
    private static func scroll(deltaX: Double, deltaY: Double, in view: VZVirtualMachineView) {
        // Virtualization turns each line into a tenth of a wheel notch (10 of the 120 high-resolution units
        // Linux counts per notch), so a notch is 12 lines. Its horizontal wheel runs the other way round.
        let lines = 12.0
        guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 2,
                               wheel1: Int32((-deltaY * lines).rounded()), wheel2: Int32((deltaX * lines).rounded()), wheel3: 0)
        else { return }
        if let pointer, let window = view.window {
            // CGEvent locations are in global coordinates with the origin at the top left of the main screen.
            let screen = window.convertPoint(toScreen: pointer)
            cg.location = CGPoint(x: screen.x, y: (NSScreen.screens.first?.frame.height ?? 0) - screen.y)
        }
        guard let event = NSEvent(cgEvent: cg) else { return }
        delivering = true
        defer { delivering = false }
        view.scrollWheel(with: event)
    }

    // MARK: - Keyboard

    private static func type(_ text: String, into view: VZVirtualMachineView) async throws {
        var strokes: [(code: UInt16, shift: Bool)] = []
        for character in text {
            guard let stroke = Keys.stroke(for: character) else {
                throw ControlError("Can't type “\(character)”: Hyperbox types with a US keyboard, which has no key for it. Nothing was typed. For other text, put it on the clipboard or in a file with run_command.")
            }
            strokes.append(stroke)
        }
        for stroke in strokes {
            try await tap(stroke.code, modifiers: stroke.shift ? [.shift] : [], in: view)
        }
    }

    private static func press(_ key: String, modifiers names: [String], in view: VZVirtualMachineView) async throws {
        // "ctrl+alt+delete" works as well as key "delete" with modifiers ["control", "option"].
        var parts = key.split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        if key.hasSuffix("++") || key == "+" { parts = parts.filter { !$0.isEmpty } + ["+"] }
        let name = parts.removeLast()
        var modifiers = try flags(names + parts)
        let code: UInt16
        if let named = Keys.named[name.lowercased()] {
            code = named
        } else if name.count == 1, let stroke = Keys.stroke(for: Character(name)) {
            code = stroke.code
            if stroke.shift { modifiers.insert(.shift) }
        } else {
            throw ControlError("Unknown key “\(name)”. Use a character, or one of: \(Keys.named.keys.sorted().joined(separator: ", ")).")
        }
        try await tap(code, modifiers: modifiers, in: view)
    }

    private static func flags(_ names: [String]) throws -> NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        for name in names {
            guard let flag = Keys.modifiers[name.lowercased()] else {
                throw ControlError("Unknown modifier “\(name)”. Use command, shift, option or control.")
            }
            flags.insert(flag.flag)
        }
        return flags
    }

    /// Holds the modifiers, presses and releases the key, then lets the modifiers go.
    private static func tap(_ code: UInt16, modifiers: NSEvent.ModifierFlags, in view: VZVirtualMachineView) async throws {
        let held = Keys.order.filter { modifiers.contains($0.flag) }
        var flags: NSEvent.ModifierFlags = []
        for modifier in held {
            flags.insert(modifier.flag)
            send(key: modifier.code, type: .flagsChanged, flags: flags, to: view)
            try await pause()
        }
        send(key: code, type: .keyDown, flags: flags, to: view)
        try await pause()
        send(key: code, type: .keyUp, flags: flags, to: view)
        try await pause()
        for modifier in held.reversed() {
            flags.remove(modifier.flag)
            send(key: modifier.code, type: .flagsChanged, flags: flags, to: view)
            try await pause()
        }
    }

    private static func send(key code: UInt16, type: NSEvent.EventType, flags: NSEvent.ModifierFlags, to view: VZVirtualMachineView) {
        // A CGEvent that's never posted: it's only the easiest way to make an NSEvent of any key type.
        guard let cg = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: type != .keyUp) else { return }
        if type == .flagsChanged { cg.type = .flagsChanged }
        cg.flags = CGEventFlags(rawValue: UInt64(flags.rawValue) | Keys.deviceBits(flags))
        guard let event = NSEvent(cgEvent: cg) else { return }
        delivering = true
        defer { delivering = false }
        switch type {
        case .keyDown: view.keyDown(with: event)
        case .keyUp: view.keyUp(with: event)
        default: view.flagsChanged(with: event)
        }
    }

    /// The guest reads its keyboard and mouse as USB devices that report every few milliseconds, so
    /// events sent faster than that can merge or arrive out of order.
    private static func pause() async throws {
        try await Task.sleep(for: .milliseconds(10))
    }
}

/// Key codes of a US keyboard, which is what the guest's virtual keyboard is.
private enum Keys {
    static let named: [String: UInt16] = [
        "return": 36, "enter": 36, "tab": 48, "space": 49, "delete": 51, "backspace": 51, "escape": 53, "esc": 53,
        "forwarddelete": 117, "home": 115, "end": 119, "pageup": 116, "pagedown": 121,
        "left": 123, "right": 124, "down": 125, "up": 126, "capslock": 57,
        "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97, "f7": 98, "f8": 100,
        "f9": 101, "f10": 109, "f11": 103, "f12": 111,
    ]

    static let modifiers: [String: (code: UInt16, flag: NSEvent.ModifierFlags)] = [
        "command": (55, .command), "cmd": (55, .command), "meta": (55, .command), "super": (55, .command), "win": (55, .command),
        "shift": (56, .shift), "option": (58, .option), "alt": (58, .option), "control": (59, .control), "ctrl": (59, .control),
    ]

    /// Which physical key is down (the left one, here), in the low bits of an event's flags, as IOKit's
    /// NX_DEVICEL*KEYMASK. Virtualization reads these to tell presses from releases; without them a
    /// modifier sticks until the next one.
    static func deviceBits(_ flags: NSEvent.ModifierFlags) -> UInt64 {
        var bits: UInt64 = 0x100 // NX_NONCOALSESCEDMASK, as on every real event
        if flags.contains(.control) { bits |= 0x1 }
        if flags.contains(.shift) { bits |= 0x2 }
        if flags.contains(.command) { bits |= 0x8 }
        if flags.contains(.option) { bits |= 0x20 }
        return bits
    }

    /// The order modifiers go down in, as a person would press them.
    static let order: [(code: UInt16, flag: NSEvent.ModifierFlags)] = [(59, .control), (58, .option), (56, .shift), (55, .command)]

    private static let plain: [Character: UInt16] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13,
        "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25,
        "7": 26, "-": 27, "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "l": 37, "j": 38,
        "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46, ".": 47, "`": 50,
        " ": 49, "\t": 48, "\n": 36, "\r": 36,
    ]

    private static let shifted: [Character: Character] = [
        "!": "1", "@": "2", "#": "3", "$": "4", "%": "5", "^": "6", "&": "7", "*": "8", "(": "9", ")": "0",
        "_": "-", "+": "=", "{": "[", "}": "]", "|": "\\", ":": ";", "\"": "'", "<": ",", ">": ".", "?": "/", "~": "`",
    ]

    static func stroke(for character: Character) -> (code: UInt16, shift: Bool)? {
        if let code = plain[character] { return (code, false) }
        if let base = shifted[character], let code = plain[base] { return (code, true) }
        if character.isUppercase, let lower = character.lowercased().first, lower.isASCII, let code = plain[lower] { return (code, true) }
        return nil
    }
}

private extension CGImage {
    func scaled(maxWidth: Int?) -> CGImage {
        guard let maxWidth, maxWidth > 0, width > maxWidth else { return self }
        let height = max(1, Int((Double(self.height) * Double(maxWidth) / Double(width)).rounded()))
        guard let context = CGContext(data: nil, width: maxWidth, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return self }
        context.interpolationQuality = .high
        context.draw(self, in: CGRect(x: 0, y: 0, width: maxWidth, height: height))
        return context.makeImage() ?? self
    }

    func pngData() -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, self, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }
}
