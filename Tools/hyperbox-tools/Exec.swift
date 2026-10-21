import Foundation

/// Runs a command to completion and collects what it printed.
enum Exec {
    /// Enough for any sensible command; more would make a reply line too big to pass around.
    static let outputLimit = 16 << 20

    static func run(_ arguments: [String], timeout: Double, directory: URL = FileManager.default.homeDirectoryForCurrentUser) -> Message {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: arguments[0])
        process.arguments = Array(arguments.dropFirst())
        process.currentDirectoryURL = directory
        var environment = ProcessInfo.processInfo.environment
        // launchd starts agents with a bare PATH; add Homebrew's, as a Terminal would.
        environment["PATH"] = "/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        environment["LANG"] = environment["LANG"] ?? "en_US.UTF-8"
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err

        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do { try process.run() } catch {
            return ["ok": true, "exitCode": 127, "stdout": "", "stderr": "\(error.localizedDescription)\n"]
        }
        // Read while it runs, so a full pipe can't stall it.
        let stdout = Collector(out.fileHandleForReading), stderr = Collector(err.fileHandleForReading)

        var timedOut = false
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            process.terminate()
            if exited.wait(timeout: .now() + 3) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                exited.wait()
            }
        }
        // Something it started in the background may hold the pipes open; don't wait on that forever.
        let output = stdout.finish(within: 2), errors = stderr.finish(within: 2)
        var errorText = String(decoding: errors, as: UTF8.self)
        if timedOut { errorText += "Timed out after \(Int(timeout)) seconds.\n" }
        return [
            "ok": true,
            "exitCode": timedOut ? 124 : Int(process.terminationStatus),
            "stdout": String(decoding: output, as: UTF8.self),
            "stderr": errorText,
        ]
    }

    /// Drains a pipe on its own thread.
    private final class Collector: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        private let done = DispatchSemaphore(value: 0)

        init(_ handle: FileHandle) {
            Thread.detachNewThread { [self] in
                while let chunk = try? handle.read(upToCount: 65536), !chunk.isEmpty {
                    lock.withLock { if data.count < Exec.outputLimit { data.append(chunk.prefix(Exec.outputLimit - data.count)) } }
                }
                done.signal()
            }
        }

        func finish(within seconds: Double) -> Data {
            _ = done.wait(timeout: .now() + seconds)
            return lock.withLock { data }
        }
    }
}
