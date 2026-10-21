import Foundation

enum Shell {
    /// GUI apps don't inherit the login shell's PATH, so borrow it once. A slow or chatty profile can't
    /// hang the app (it gives up after 3 seconds) or garble PATH (it's read between markers).
    nonisolated static let environment: [String: String] = {
        var env = ProcessInfo.processInfo.environment
        let shell = env["SHELL"] ?? "/bin/zsh"
        let p = Process(), out = Pipe()
        p.executableURL = URL(fileURLWithPath: shell)
        p.arguments = ["-l", "-c", "printf '\\n<<PATH>>%s<<END>>' \"$PATH\""]
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        if (try? p.run()) != nil {
            let deadline = Date().addingTimeInterval(3)
            while p.isRunning, Date() < deadline { usleep(20_000) }
            if p.isRunning { p.terminate() }
            let text = String(decoding: out.fileHandleForReading.availableData, as: UTF8.self)
            if let start = text.range(of: "<<PATH>>"), let end = text.range(of: "<<END>>", range: start.upperBound..<text.endIndex) {
                let path = String(text[start.upperBound..<end.lowerBound])
                if !path.isEmpty { env["PATH"] = path }
            }
        }
        return env
    }()

    /// Runs a tool and returns what it printed, throwing with its error output if it fails.
    @discardableResult
    nonisolated static func run(_ tool: String, _ arguments: [String], in directory: URL? = nil) async throws -> String {
        try await Task.detached {
            let p = Process(), out = Pipe(), err = Pipe()
            p.executableURL = URL(fileURLWithPath: tool)
            p.arguments = arguments
            p.standardOutput = out
            p.standardError = err
            if let directory { p.currentDirectoryURL = directory }
            try p.run()
            // Read before waiting, so a full pipe can't stall the tool.
            async let output = out.fileHandleForReading.readToEnd()
            async let errors = err.fileHandleForReading.readToEnd()
            let (o, e) = try await (output, errors)
            p.waitUntilExit()
            guard p.terminationStatus == 0 else {
                let message = String(decoding: e ?? Data(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                throw ControlError("\(URL(fileURLWithPath: tool).lastPathComponent) failed: \(message.isEmpty ? "exit \(p.terminationStatus)" : message)")
            }
            return String(decoding: o ?? Data(), as: UTF8.self)
        }.value
    }
}
