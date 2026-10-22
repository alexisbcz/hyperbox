import AVFoundation
import AppKit
import Virtualization

/// Films a machine's screen for demos and bug reports: the guest's framebuffer thirty times a second, as H.264.
/// The Mac draws the guest's pointer over the view, so it isn't in the framebuffer: the recording draws an arrow
/// where agents last put it, pressed in while the button is down.
final class ScreenRecording {
    private static var active: [UUID: ScreenRecording] = [:]

    static func start(_ machine: Machine, to url: URL) throws {
        guard active[machine.id] == nil else { throw ControlError("\(machine.config.name) is already recording.") }
        guard let view = machine.screenView, view.window != nil, let first = ScreenCapture.cgImage(of: view) else {
            throw ControlError("Couldn't read \(machine.config.name)'s screen. Is its window open?")
        }
        let recording = try ScreenRecording(url: url, view: view, size: CGSize(width: first.width, height: first.height))
        active[machine.id] = recording
        recording.begin()
    }

    static func stop(_ machine: Machine) async throws -> JSONValue {
        guard let recording = active.removeValue(forKey: machine.id) else { throw ControlError("\(machine.config.name) isn't recording.") }
        let seconds = await recording.finish()
        return ["path": .string(recording.url.path), "seconds": .number(seconds)]
    }

    let url: URL
    private weak var view: VZVirtualMachineView?
    private let size: CGSize
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private var timer: Timer?
    private var origin = CACurrentMediaTime()
    private var last: CMTime = .invalid

    private init(url: URL, view: VZVirtualMachineView, size: CGSize) throws {
        self.url = url
        self.view = view
        self.size = size
        try? FileManager.default.removeItem(at: url)
        writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height),
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 40_000_000, AVVideoExpectedSourceFrameRateKey: 30],
        ])
        input.expectsMediaDataInRealTime = true
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(size.width),
            kCVPixelBufferHeightKey as String: Int(size.height),
        ])
        writer.add(input)
    }

    private func begin() {
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        origin = CACurrentMediaTime()
        frame()
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { _ in
            MainActor.assumeIsolated { self.frame() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func finish() async -> Double {
        timer?.invalidate()
        frame()
        input.markAsFinished()
        await writer.finishWriting()
        return CACurrentMediaTime() - origin
    }

    private func frame() {
        let time = CMTime(seconds: CACurrentMediaTime() - origin, preferredTimescale: 600)
        guard time > last || !last.isValid, input.isReadyForMoreMediaData, let view, let image = ScreenCapture.cgImage(of: view),
              image.width == Int(size.width), image.height == Int(size.height), let pool = adaptor.pixelBufferPool
        else { return }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        guard let buffer else { return }
        CVPixelBufferLockBaseAddress(buffer, [])
        if let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer), width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) {
            context.draw(image, in: CGRect(origin: .zero, size: size))
            drawPointer(in: context, view: view)
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        if adaptor.append(buffer, withPresentationTime: time) { last = time }
    }

    /// The system arrow at the pointer's spot, at the guest's scale: Retina when the screen is wide in pixels.
    private func drawPointer(in context: CGContext, view: VZVirtualMachineView) {
        guard let pointer = AgentControl.pointer else { return }
        let spot = AgentControl.pixel(of: pointer, in: view, screen: size)
        let cursor = NSCursor.arrow
        var rect = CGRect(origin: .zero, size: cursor.image.size)
        guard let image = cursor.image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return }
        let scale: CGFloat = (size.width > 2000 ? 2 : 1) * (AgentControl.isPressed ? 0.9 : 1)
        let drawn = CGSize(width: cursor.image.size.width * scale, height: cursor.image.size.height * scale)
        let hotSpot = CGPoint(x: cursor.hotSpot.x * scale, y: cursor.hotSpot.y * scale)
        // The context's origin is at the bottom left; the pointer's spot and hot spot count from the top.
        context.draw(image, in: CGRect(x: spot.x - hotSpot.x, y: size.height - spot.y - drawn.height + hotSpot.y,
                                       width: drawn.width, height: drawn.height))
    }
}
