import Foundation

enum Shell {
    /// GUI apps don't inherit the login shell's PATH, so borrow it once.
    static let environment: [String: String] = {
        var env = ProcessInfo.processInfo.environment
        let shell = env["SHELL"] ?? "/bin/zsh"
        let p = Process(), out = Pipe()
        p.executableURL = URL(fileURLWithPath: shell)
        p.arguments = ["-l", "-c", "printf %s \"$PATH\""]
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        if (try? p.run()) != nil {
            p.waitUntilExit()
            let path = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            if !path.isEmpty { env["PATH"] = path }
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
