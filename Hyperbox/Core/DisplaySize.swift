import AppKit
import Virtualization

/// The guest's screen follows the window, so asking for an exact screen size, for a recording that has to be
/// 16:9 say, means sizing the window so the screen view is that many pixels, then waiting for the guest to
/// take the new size.
enum DisplaySize {
    static func handle(_ params: JSONValue, machine: Machine) async throws -> JSONValue {
        guard machine.virtualMachine != nil else { throw ControlError("\(machine.config.name) isn't running. Start it first.") }
        guard let view = machine.screenView, let window = view.window else {
            throw ControlError("\(machine.config.name)'s window is closed. Run `hyperbox start` or click its Dock icon to open it again.")
        }
        guard let width = params["width"]?.int, let height = params["height"]?.int else { return current(view) }
        guard width >= 640, height >= 480 else { throw ControlError("The screen needs to be at least 640 × 480.") }
        let scale = window.backingScaleFactor
        let wanted = CGSize(width: CGFloat(width) / scale, height: CGFloat(height) / scale)
        if window.styleMask.contains(.fullScreen) { throw ControlError("Leave full screen first: a full-screen window can't change size.") }
        // Whatever the window has around the screen (the toolbar) stays as it is.
        var frame = window.frame
        frame.size.width += wanted.width - view.bounds.width
        frame.size.height += wanted.height - view.bounds.height
        if let visible = window.screen?.visibleFrame {
            guard frame.width <= visible.width, frame.height <= visible.height else {
                throw ControlError("\(width) × \(height) doesn't fit on this Mac's screen at \(Int(scale))×; the most is about \(Int((visible.width - (frame.width - wanted.width)) * scale)) × \(Int((visible.height - (frame.height - wanted.height)) * scale)).")
            }
            // Keep the top left where it was, and the whole window on the screen.
            frame.origin.y = window.frame.maxY - frame.height
            frame.origin.x = min(max(frame.origin.x, visible.minX), visible.maxX - frame.width)
            frame.origin.y = min(max(frame.origin.y, visible.minY), visible.maxY - frame.height)
        }
        window.setFrame(frame, display: true, animate: false)
        // The guest asks for the new mode on its own, within a second or two.
        let deadline = Date.now.addingTimeInterval(10)
        while Date.now < deadline {
            if ScreenCapture.size(of: view) == CGSize(width: width, height: height) { break }
            try await Task.sleep(for: .milliseconds(200))
        }
        return current(view)
    }

    private static func current(_ view: VZVirtualMachineView) -> JSONValue {
        let size = ScreenCapture.size(of: view) ?? .zero
        return ["width": .number(size.width), "height": .number(size.height)]
    }
}
