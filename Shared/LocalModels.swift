import Foundation

/// Liquid's LFM3 models, run on this Mac, so scripts, recipes and agents can ask about a guest's screen
/// without a cloud model or sending the screen anywhere. d1-2B answers typed questions (yes or no, one of
/// some options, a level) with calibrated probabilities, in one pass and no generated text; LFM3-VL-2B
/// describes and reads a screen.
///
/// They run in llama.cpp's `llama-server`, the only runtime with LFM3 support a Swift app can use today.
/// Hyperbox downloads llama.cpp's release build and the weights on first use (the weights are under the
/// LFM Open License, so they're never bundled), and `hyperbox` runs one server per model, which stops
/// itself once it's been idle for `ModelServer.idleTimeout`.
nonisolated enum LocalModel: String, CaseIterable, Identifiable, Sendable {
    case decision = "d1-2B"
    case vision = "LFM3-VL-2B"

    var id: String { rawValue }

    var summary: String {
        switch self {
        case .decision: "Answers questions about a screen with a probability: hyperbox check and wait"
        case .vision: "Describes and reads a screen: hyperbox describe"
        }
    }

    var repo: String { "LiquidAI/\(rawValue)-GGUF" }
    var weights: String { self == .decision ? "d1-2B-Q8_0.gguf" : "LFM3-VL-2B-Q4_K_M.gguf" }
    /// The vision encoder.
    var projector: String { "mmproj-\(rawValue)-Q8_0.gguf" }
    var files: [String] { [weights, projector] }

    /// The model's card, where its licence is.
    var page: URL { URL(string: "https://huggingface.co/LiquidAI/\(rawValue)")! }
    static let license = "LFM Open License v1.0"
    static let licenseURL = URL(string: "https://huggingface.co/LiquidAI/d1-2B/blob/main/LICENSE")!
    static let licenseNote = "Liquid AI's LFM3 models are under the \(license): free to use, unless your company makes over $10M a year. Hyperbox downloads them from Hugging Face; they're not part of Hyperbox."

    static var folder: URL { Paths.support.appending(path: "Models") }
    func path(_ file: String) -> URL { Self.folder.appending(path: file) }
    func url(_ file: String) -> URL { URL(string: "https://huggingface.co/\(repo)/resolve/main/\(file)")! }

    var isDownloaded: Bool { files.allSatisfy { FileManager.default.fileExists(atPath: path($0).path) } }

    /// Bytes on disk, partial downloads included.
    var size: Int64 {
        files.flatMap { [path($0), ResumableDownload.partial(path($0))] }
            .reduce(0) { $0 + ((try? FileManager.default.attributesOfItem(atPath: $1.path)[.size] as? Int64) ?? 0) }
    }

    /// llama-server's arguments for this model, after the files and the port.
    var serverArguments: [String] {
        switch self {
        // d1 reads a question with its state and pictures in one batch, so the batch holds them all; at 8192 a
        // picture keeps its full budget of 4096 tokens.
        case .decision: ["-b", "8192", "-ub", "8192"]
        // The model card's sampling. Describing a screen doesn't need it to think first, which takes far longer.
        case .vision: ["--temp", "0.1", "--top-p", "1.0", "--top-k", "50", "--min-p", "0.0", "--repeat-penalty", "1.1",
                       "--reasoning", "off", "--no-reasoning-preserve"]
        }
    }

    /// Downloads llama.cpp and the model's files that aren't here yet, resuming partial ones.
    /// `progress` gets what's happening and how far along it is, when that's known.
    func download(progress: @escaping @Sendable (String, Double?) -> Void) async throws {
        if !LlamaCpp.isInstalled { try await LlamaCpp.install(progress: progress) }
        for file in files where !FileManager.default.fileExists(atPath: path(file).path) {
            let title = "Downloading \(file)"
            progress(title, nil)
            try await ResumableDownload.fetch(url(file), to: path(file)) { received, total in
                guard let total, total > 0 else { return progress("\(title): \(Self.bytes(received))", nil) }
                progress("\(title): \(Self.bytes(received)) of \(Self.bytes(total))", Double(received) / Double(total))
            }
        }
    }

    func delete() {
        ModelServer.stop(self)
        for file in files {
            try? FileManager.default.removeItem(at: path(file))
            try? FileManager.default.removeItem(at: ResumableDownload.partial(path(file)))
        }
    }

    static func bytes(_ count: Int64) -> String { ByteCountFormatter.string(fromByteCount: count, countStyle: .file) }
}

/// llama.cpp's own macOS build, from its GitHub release: Homebrew's is too old for LFM3.
nonisolated enum LlamaCpp {
    /// The first release that runs every LFM3 model.
    static let build = "b11960"
    static var url: URL {
        URL(string: "https://github.com/ggml-org/llama.cpp/releases/download/\(build)/llama-\(build)-bin-macos-arm64.tar.gz")!
    }

    static var folder: URL { Paths.support.appending(path: "llama.cpp") }
    /// The tarball unpacks to llama-<build>/, with the dylibs beside the tools.
    static var server: URL { folder.appending(path: "llama-\(build)/llama-server") }
    static var isInstalled: Bool { FileManager.default.isExecutableFile(atPath: server.path) }

    static func install(progress: @escaping @Sendable (String, Double?) -> Void) async throws {
        Paths.ensure(Paths.downloads)
        let archive = Paths.downloads.appending(path: url.lastPathComponent)
        if !FileManager.default.fileExists(atPath: archive.path) {
            let title = "Downloading llama.cpp \(build)"
            progress(title, nil)
            try await ResumableDownload.fetch(url, to: archive) { received, total in
                guard let total, total > 0 else { return progress("\(title): \(LocalModel.bytes(received))", nil) }
                progress("\(title): \(LocalModel.bytes(received)) of \(LocalModel.bytes(total))", Double(received) / Double(total))
            }
        }
        progress("Unpacking llama.cpp", nil)
        Paths.ensure(folder)
        try run("/usr/bin/tar", ["-xzf", archive.path, "-C", folder.path])
        // Downloaded files may carry quarantine, which would stop the server and its dylibs from loading.
        try? run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", folder.path])
        guard isInstalled else {
            try? FileManager.default.removeItem(at: archive)
            throw ControlError("llama.cpp's download has no llama-server in it. Try again.")
        }
    }

    private static func run(_ tool: String, _ arguments: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = arguments
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw ControlError("\(URL(fileURLWithPath: tool).lastPathComponent) failed unpacking llama.cpp.") }
    }
}

/// The servers `hyperbox` starts, one per model. Each is watched by a `hyperbox model-server` process,
/// which writes `state(for:)` once it's up, and stops the server after `idleTimeout` without a question.
nonisolated enum ModelServer {
    static let idleTimeout: TimeInterval = 10 * 60

    struct State: Codable, Sendable {
        /// The `hyperbox model-server` process, which stops llama-server when it's told to stop.
        var pid: Int32
        var serverPid: Int32
        var port: Int
        var model: String
    }

    static func state(for model: LocalModel) -> URL { Paths.run.appending(path: "model-\(model.rawValue).json") }
    static func log(for model: LocalModel) -> URL { Paths.run.appending(path: "model-\(model.rawValue).log") }

    /// The model's server, when one is running.
    static func running(_ model: LocalModel) -> State? {
        guard let data = try? Data(contentsOf: state(for: model)),
              let state = try? JSONDecoder().decode(State.self, from: data),
              kill(state.pid, 0) == 0 || errno == EPERM else { return nil }
        return state
    }

    /// Resets the idle clock: the state file's date is when the model was last asked something.
    static func touch(_ model: LocalModel) {
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: state(for: model).path)
    }

    static func lastUsed(_ model: LocalModel) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: state(for: model).path))?[.modificationDate] as? Date
    }

    static func stop(_ model: LocalModel) {
        guard let state = running(model) else { return }
        kill(state.pid, SIGTERM)
    }
}

/// Settings › Models, which `hyperbox` reads too.
nonisolated enum ModelSettings {
    static let enabledKey = "models.enabled"

    /// On unless turned off: asking a question is what downloads a model.
    static var enabled: Bool {
        UserDefaults(suiteName: "dev.alexis.Hyperbox")?.object(forKey: enabledKey) as? Bool ?? true
    }
}
