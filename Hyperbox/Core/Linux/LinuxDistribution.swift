import Foundation

/// How Hyperbox installs each Linux in the catalog: which cloud image to start from, and what to add
/// to it on first boot to make a desktop.
///
/// Every distribution publishes arm64 cloud images, small disks with cloud-init that boot straight
/// into the system, so an install is a download and one boot rather than an installer to click through.
nonisolated struct LinuxDistribution: Sendable {
    enum Family: Sendable { case debian, fedora }

    let id: String
    let family: Family
    /// Finds the current cloud image, a qcow2 file. Some names carry a build number, so it can't be fixed.
    let image: @Sendable () async throws -> URL
    /// The desktop, with spice-vdagent for the clipboard.
    let packages: [String]
    /// Where GDM reads its autologin settings.
    let gdmConfig: String
    /// The group that may use sudo.
    let adminGroup: String

    static func named(_ id: String) -> LinuxDistribution? { all.first { $0.id == id } }

    static let all: [LinuxDistribution] = [
        LinuxDistribution(
            id: "ubuntu", family: .debian,
            image: { URL(string: "https://cloud-images.ubuntu.com/releases/noble/release/ubuntu-24.04-server-cloudimg-arm64.img")! },
            packages: ["ubuntu-desktop-minimal", "spice-vdagent"],
            gdmConfig: "/etc/gdm3/custom.conf", adminGroup: "sudo"),
        LinuxDistribution(
            id: "fedora", family: .fedora,
            image: { try await fedoraImage(release: "44") },
            packages: ["@workstation-product-environment", "spice-vdagent"],
            gdmConfig: "/etc/gdm/custom.conf", adminGroup: "wheel"),
        LinuxDistribution(
            id: "debian", family: .debian,
            image: { URL(string: "https://cloud.debian.org/images/cloud/trixie/latest/debian-13-generic-arm64.qcow2")! },
            packages: ["task-gnome-desktop", "spice-vdagent"],
            gdmConfig: "/etc/gdm3/daemon.conf", adminGroup: "sudo"),
    ]

    /// Fedora's Generic cloud image, whose name has the compose number in it ("44-1.7").
    private static func fedoraImage(release: String) async throws -> URL {
        let folder = URL(string: "https://dl.fedoraproject.org/pub/fedora/linux/releases/\(release)/Cloud/aarch64/images/")!
        let (data, _) = try await URLSession.shared.data(from: folder)
        let listing = String(decoding: data, as: UTF8.self)
        guard let match = listing.firstMatch(of: /Fedora-Cloud-Base-Generic-[0-9.-]+\.aarch64\.qcow2/) else {
            throw ControlError("Couldn't find Fedora \(release)'s cloud image at \(folder.absoluteString).")
        }
        return folder.appending(path: String(match.output))
    }
}
