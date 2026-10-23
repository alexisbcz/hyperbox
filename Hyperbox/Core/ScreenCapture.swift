import AppKit
import CoreImage
import IOSurface
import Virtualization

/// Pictures of a machine's screen, for thumbnails and agents.
///
/// `VZVirtualMachineView` shows the guest's framebuffer as the contents of one sublayer, an IOSurface
/// that Virtualization updates in place. Reading that surface gives the guest's own pixels, at the guest's
/// resolution, from inside our process: no Screen Recording permission, no need for the window to be in
/// front, and nothing of the Mac's desktop gets in. (`cacheDisplay` draws black, `CALayer.render(in:)`
/// only at the window's resolution, and ScreenCaptureKit would need permission.)
enum ScreenCapture {
    static func image(of view: VZVirtualMachineView) -> NSImage? {
        cgImage(of: view).map { NSImage(cgImage: $0, size: CGSize(width: $0.width, height: $0.height)) }
    }

    static func cgImage(of view: VZVirtualMachineView) -> CGImage? {
        guard let layer = view.layer, let surface = surface(in: layer) else { return nil }
        return image(of: surface)
    }

    /// The guest's screen in pixels, without copying it.
    static func size(of view: VZVirtualMachineView) -> CGSize? {
        guard let layer = view.layer, let surface = surface(in: layer) else { return nil }
        return CGSize(width: IOSurfaceGetWidth(surface), height: IOSurfaceGetHeight(surface))
    }

    private static func surface(in layer: CALayer) -> IOSurfaceRef? {
        if let contents = layer.contents, CFGetTypeID(contents as CFTypeRef) == IOSurfaceGetTypeID() {
            return (contents as! IOSurfaceRef)
        }
        for sub in layer.sublayers ?? [] {
            if let found = surface(in: sub) { return found }
        }
        return nil
    }

    private static func image(of surface: IOSurfaceRef) -> CGImage? {
        let width = IOSurfaceGetWidth(surface), height = IOSurfaceGetHeight(surface)
        guard width > 0, height > 0 else { return nil }
        // The guest's framebuffer is BGRA with an alpha byte that's always 0, so read it as BGRX
        // ourselves: Core Image would take that alpha at its word and hand back a transparent picture.
        guard IOSurfaceGetPixelFormat(surface) == kCVPixelFormatType_32BGRA else {
            return CIContext.shared.createCGImage(CIImage(ioSurface: surface), from: CGRect(x: 0, y: 0, width: width, height: height))
        }
        guard IOSurfaceLock(surface, .readOnly, nil) == kIOReturnSuccess else { return nil }
        let bytesPerRow = IOSurfaceGetBytesPerRow(surface)
        // Copied, because Virtualization keeps drawing into the surface once it's unlocked.
        let data = Data(bytes: IOSurfaceGetBaseAddress(surface), count: bytesPerRow * height)
        IOSurfaceUnlock(surface, .readOnly, nil)
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bytesPerRow,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}

private extension CIContext {
    static let shared = CIContext(options: [.cacheIntermediates: false])
}
