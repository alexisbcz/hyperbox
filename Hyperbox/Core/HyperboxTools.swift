import Foundation

/// Hyperbox Tools, the agent for macOS guests (Tools/hyperbox-tools). The app carries it in
/// Contents/Resources/guest/ and shares that folder read-only with every macOS machine, so it shows up
/// in the guest at /Volumes/My Shared Files/Hyperbox Tools, next to `Install Hyperbox Tools.command`.
enum HyperboxTools {
    static let shareName = "Hyperbox Tools"
    /// Where the shared folder appears inside a macOS guest.
    static let guestPath = "/Volumes/My Shared Files/\(shareName)"
    static let installer = "Install Hyperbox Tools.command"

    static var folder: URL? {
        guard let url = Bundle.main.resourceURL?.appending(path: "guest"),
              FileManager.default.fileExists(atPath: url.appending(path: "hyperbox-tools").path) else { return nil }
        return url
    }
}
