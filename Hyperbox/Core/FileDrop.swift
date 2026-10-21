import AppKit
import UniformTypeIdentifiers

/// Files dropped on a machine's window, copied to the guest's desktop through its agent.
///
/// Files go over in pieces, so a big one doesn't become one enormous message; folders go as a tar
/// archive, unpacked in the guest. It works the same for Linux, whose agent speaks the same protocol.
/// Dragging out of a machine isn't possible: the guest never tells the Mac a drag started. Shared
/// folders are the way to get files out.
@Observable
final class FileDrop {
    static let shared = FileDrop()

    /// What the window's toast shows.
    struct Transfer: Equatable {
        var title: String
        var fraction: Double?
        var failed = false
        var done = false
    }

    private(set) var transfer: Transfer?
    @ObservationIgnored private var busy = false

    static let chunkSize = 4 << 20
    /// Agents before version 2 can't append, so they take a file in one piece, up to this.
    static let singlePieceLimit = 64 << 20

    static func drop(_ providers: [NSItemProvider], on machine: Machine) -> Bool {
        guard machine.virtualMachine != nil, machine.state == .running, !shared.busy else { return false }
        let files = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        guard !files.isEmpty else { return false }
        shared.busy = true
        Task {
            var urls: [URL] = []
            for provider in files {
                if let url = await provider.loadFileURL() { urls.append(url) }
            }
            await shared.copy(urls, to: machine)
            shared.busy = false
        }
        return true
    }

    private func copy(_ urls: [URL], to machine: Machine) async {
        guard !urls.isEmpty else { return }
        do {
            guard let ping = await GuestAgent.ping(machine) else {
                throw ControlError(machine.config.os == .macOS
                    ? "Install Hyperbox Tools in \(machine.config.name) to drop files on it."
                    : "\(machine.config.name) isn't ready for files yet.")
            }
            let version = ping["version"]?.int ?? 1
            for (i, url) in urls.enumerated() {
                let title = "Copying \(url.lastPathComponent)" + (urls.count > 1 ? " (\(i + 1) of \(urls.count))" : "") + "…"
                transfer = Transfer(title: title, fraction: 0)
                if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                    try await sendFolder(url, to: machine, agentVersion: version, title: title)
                } else {
                    _ = try await send(url, as: "~/Desktop/\(url.lastPathComponent)", to: machine, agentVersion: version, title: title)
                }
            }
            let what = urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) items"
            await show(Transfer(title: "Copied \(what) to the desktop", fraction: 1, done: true), for: .seconds(2.5))
        } catch {
            await show(Transfer(title: error.localizedDescription, failed: true), for: .seconds(5))
        }
    }

    private func show(_ final: Transfer, for duration: Duration) async {
        transfer = final
        try? await Task.sleep(for: duration)
        if transfer == final { transfer = nil }
    }

    /// Writes a file in the guest a piece at a time; returns where it landed, which is a new name if
    /// `path` was taken.
    private func send(_ file: URL, as path: String, to machine: Machine, agentVersion: Int, title: String) async throws -> String {
        let size = (try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int) ?? 0
        let piece = agentVersion >= 2 ? Self.chunkSize : Self.singlePieceLimit
        if agentVersion < 2, size > piece {
            throw ControlError("\(file.lastPathComponent) is too big for the agent in \(machine.config.name). Update it, or use a shared folder.")
        }
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var path = path
        var sent = 0
        repeat {
            let chunk = try handle.read(upToCount: piece) ?? Data()
            var request: [String: JSONValue] = ["op": "writeFile", "path": .string(path), "data": .string(chunk.base64EncodedString())]
            request[sent == 0 ? "unique" : "append"] = true
            let reply = try await GuestAgent.request(request, machine: machine, timeout: 60)
            if sent == 0, let landed = reply["path"]?.string { path = landed }
            sent += chunk.count
            transfer = Transfer(title: title, fraction: size > 0 ? Double(sent) / Double(size) : 1)
            if chunk.isEmpty { break }
        } while sent < size
        return path
    }

    private func sendFolder(_ folder: URL, to machine: Machine, agentVersion: Int, title: String) async throws {
        let archive = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).tar.gz")
        defer { try? FileManager.default.removeItem(at: archive) }
        transfer = Transfer(title: title, fraction: nil)
        // Finder's metadata travels as ._ files, which only a Mac turns back into what they were.
        var options = ["-czf", archive.path]
        if machine.config.os == .linux { options.append("--no-mac-metadata") }
        try await Shell.run("/usr/bin/tar", options + ["-C", folder.deletingLastPathComponent().path, folder.lastPathComponent])

        let name = folder.lastPathComponent
        let landed = try await send(archive, as: "~/Desktop/.\(name).hyperbox.tar.gz", to: machine, agentVersion: agentVersion, title: title)
        // Unpacked into a fresh folder, "Name 2" if "Name" is taken, as Finder would.
        let script = """
            d="$HOME/Desktop"; n=\(quote(name)); t="$d/$n"; i=2
            while [ -e "$t" ]; do t="$d/$n $i"; i=$((i+1)); done
            mkdir -p "$t" && tar -xzf \(quote(landed)) -C "$t" --strip-components=1; s=$?; rm -f \(quote(landed)); exit $s
            """
        let result = try await GuestAgent.request(["op": "exec", "command": .string(script), "admin": false, "timeout": 600], machine: machine, timeout: 605)
        guard result["exitCode"]?.int == 0 else {
            throw ControlError("Couldn't unpack \(name) in \(machine.config.name): \(result["stderr"]?.string ?? "")")
        }
    }

    private func quote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}

private extension NSItemProvider {
    func loadFileURL() async -> URL? {
        await withCheckedContinuation { continuation in
            _ = loadObject(ofClass: URL.self) { url, _ in continuation.resume(returning: url) }
        }
    }
}
