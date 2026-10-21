import Foundation

/// The systems the New Machine sheet offers to install in one click.
struct CatalogEntry: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let version: String
    let os: GuestOS
    /// An SF Symbol, or the name of an image in the asset catalog.
    let symbol: String
    let summary: String
    var defaultCPUs: Int = 4
    var defaultMemoryGB: Int = 8
    var defaultDiskGB: Int = 64
}

enum Catalog {
    static let entries: [CatalogEntry] = [
        CatalogEntry(id: "macos", name: "macOS", version: "Latest", os: .macOS, symbol: "apple.logo",
                     summary: "Downloaded from Apple, with Metal graphics.", defaultDiskGB: 80),
        CatalogEntry(id: "ubuntu", name: "Ubuntu", version: "24.04 LTS", os: .linux, symbol: "circle.circle",
                     summary: "Desktop, installed on its own."),
        CatalogEntry(id: "fedora", name: "Fedora", version: "44", os: .linux, symbol: "f.circle",
                     summary: "Workstation, installed on its own."),
        CatalogEntry(id: "debian", name: "Debian", version: "13", os: .linux, symbol: "d.circle",
                     summary: "Desktop, installed on its own."),
    ]

    static func entry(_ id: String?) -> CatalogEntry? { entries.first { $0.id == id } }
}
