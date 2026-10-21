import AppKit

/// Copies of a machine that share the original's blocks until they change.
enum Cloner {
    static func duplicate(_ id: UUID) {}
}

/// A machine as one file, to move it to another Mac.
enum Exporter {
    static func export(_ id: UUID) {}
}

/// Machines from elsewhere: Hyperbox bundles, Parallels machines, disk images.
enum Importer {
    static func chooseAndImport() {}
}
