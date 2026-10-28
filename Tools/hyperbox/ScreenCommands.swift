import Foundation
import ImageIO

/// Questions about the guest's screen, answered on this Mac by Liquid's LFM3 models (see `LocalModel`), so
/// scripts and recipes can wait for a screen without an LLM, and agents without spending tokens on screenshots.
nonisolated extension Command {
    static let check = Command(name: "check", arguments: "<machine> <question> [--choice <name>[=<description>]]... [--levels <a,b,c>] [--threshold <p>] [--json]",
                               summary: "ask a question about the guest's screen, answered on this Mac",
                               details: """
                               Looks at the screen with Liquid's d1-2B and prints how likely the answer is yes, from 0 to 1: \
                               one pass of a 2B model, under a second, and the screen never leaves this Mac. With --choice, \
                               it picks one of the options, and with --levels, one of the levels (lowest first); each line \
                               is an option and its probability, the answer first. With --threshold, it exits with 1 when \
                               the answer's probability is below it, for scripts. In place of a machine, it takes a PNG or JPEG \
                               file, such as one `hyperbox screenshot` saved. The first question downloads llama.cpp \
                               and the model (about 1.7 GB), under the LFM Open License v1.0.

                               Examples:
                                 hyperbox check ubuntu "Is the installer finished?"
                                 hyperbox check macos "Which screen is showing?" --choice desktop --choice login="The login window" --choice setup="Setup Assistant"
                                 hyperbox check macos "Is an alert asking for a password?" --threshold 0.9 && echo yes
                               """) { args in
        let json = args.flag("--json")
        let threshold = try args.option("--threshold").map(Screen.probability)
        let maxWidth = try Screen.maxWidth(&args)
        let kind = try Screen.kind(&args)
        let machine = try args.next("a machine")
        let question = try args.next("a question")
        try args.done()
        let started = Date()
        let answer = try Screen.ask(question, kind, image: Screen.capture(machine, maxWidth: maxWidth))
        if json {
            var object = answer.json
            object["seconds"] = .number((Date().timeIntervalSince(started) * 100).rounded() / 100)
            try printJSON(JSONValue.object(object))
        } else {
            print(answer.lines.joined(separator: "\n"))
        }
        if let threshold, answer.probability < threshold { throw Failure("", status: 1) }
    }

    static let wait = Command(name: "wait", arguments: "<machine> --until <question> [--timeout <seconds>] [--threshold <p>] [--interval <seconds>] [--json]",
                              summary: "wait until the guest's screen matches a yes or no question",
                              details: """
                              Asks the question about the screen every --interval seconds (1 unless you say), as `hyperbox check` \
                              does, until the answer is yes with at least --threshold probability (0.9 unless you say). Exits \
                              with 1 after --timeout seconds (300 unless you say). Prints the last probability.

                              Example: hyperbox wait ubuntu --until "Is the desktop showing, with no installer window?" --timeout 1800
                              """) { args in
        let json = args.flag("--json")
        guard let question = try args.option("--until") else { throw Failure("say what to wait for with --until \"<question>\".") }
        let threshold = try args.option("--threshold").map(Screen.probability) ?? 0.9
        let timeout = try args.option("--timeout").map(Screen.seconds) ?? 300
        let interval = try args.option("--interval").map(Screen.seconds) ?? 1
        let maxWidth = try Screen.maxWidth(&args)
        let machine = try args.next("a machine")
        try args.done()
        let result = try Screen.wait(until: question, threshold: threshold, timeout: timeout, interval: interval) {
            try Screen.capture(machine, maxWidth: maxWidth)
        }
        if json {
            try printJSON(JSONValue.object(["met": .bool(result.met), "noul": .number(result.probability), "seconds": .number(result.seconds.rounded())]))
        } else {
            print(String(format: "%.3f", result.probability))
        }
        if !result.met {
            throw Failure(json ? "" : "after \(Int(timeout)) s, the answer was still no (\(String(format: "%.2f", result.probability)) < \(threshold)).")
        }
    }

    static let describe = Command(name: "describe", arguments: "<machine> [<what to ask>] [--max-width <pixels>]",
                                  summary: "describe or read the guest's screen, on this Mac",
                                  details: """
                                  Asks Liquid's LFM3-VL-2B about the screen and prints its answer: what's showing, by default, \
                                  or anything else you ask, such as \"Read the error message.\" It runs on this Mac, and takes a PNG \
                                  or JPEG file in place of a machine too. The first \
                                  time downloads the model (about 1.3 GB), under the LFM Open License v1.0.
                                  """) { args in
        let maxWidth = try Screen.maxWidth(&args)
        let machine = try args.next("a machine")
        let prompt = args.optionalNext()
        try args.done()
        print(try Screen.describe(image: Screen.capture(machine, maxWidth: maxWidth), prompt: prompt))
    }

    static let models = Command(name: "models", arguments: "[download <model> | stop]",
                                summary: "list the local models for check, wait and describe, download or stop them",
                                details: """
                                Downloads ahead of time, for CI, say: `hyperbox models download d1-2B`. Servers stop by themselves \
                                after \(Int(ModelServer.idleTimeout / 60)) minutes without a question; `stop` stops them now.
                                """) { args in
        switch args.optionalNext() {
        case nil:
            try args.done()
            printTable(["MODEL", "STATE", "SIZE", "WHAT IT DOES"], LocalModel.allCases.map { model in
                let state = ModelServer.running(model).map { "running on port \($0.port)" } ?? (model.isDownloaded ? "downloaded" : "not downloaded")
                return [model.rawValue, state, model.size > 0 ? LocalModel.bytes(model.size) : "-", model.summary]
            })
            print("\n\(LocalModel.licenseNote)")
        case "download":
            let name = try args.next("a model")
            try args.done()
            guard let model = LocalModel.allCases.first(where: { $0.rawValue.lowercased() == name.lowercased() }) else {
                throw Failure("no model \(name). Models: \(LocalModel.allCases.map(\.rawValue).joined(separator: ", ")).")
            }
            try Screen.download(model)
            print("\(model.rawValue) is ready.")
        case "stop":
            try args.done()
            LocalModel.allCases.forEach(ModelServer.stop)
        case let other?:
            throw Failure("models takes download or stop, not \(other).")
        }
    }

    /// Started by `Screen.server(for:)`: runs llama-server and stops it once idle. Not in `hyperbox --help`.
    static let modelServer = Command(name: "model-server", arguments: "<model>", summary: "", hidden: true) { args in
        let name = try args.next("a model")
        try args.done()
        guard let model = LocalModel(rawValue: name) else { throw Failure("no model \(name).") }
        Screen.serve(model)
    }
}

/// A question for d1, in the `/v1/systemone` types llama.cpp answers.
nonisolated enum QuestionKind: Sendable {
    case noul
    /// Option names and what each means.
    case choice([String: String])
    /// Levels, lowest first.
    case score([String])
}

/// d1's answer to one question.
nonisolated struct ScreenAnswer: Sendable {
    let json: [String: JSONValue]

    /// P(yes), or the picked option's probability.
    var probability: Double { json["noul"]?.double ?? json["confidence"]?.double ?? 0 }

    /// The answer, then the other options, each with its probability.
    var lines: [String] {
        if let p = json["noul"]?.double { return [String(format: "%.3f", p)] }
        guard case .object(let probabilities)? = json["probabilities"] else { return [] }
        let legend = json["legend"]
        let ranked = probabilities.compactMap { key, value in value.double.map { (legend?[key]?.string ?? key, $0) } }.sorted { $0.1 > $1.1 }
        let width = ranked.map(\.0.count).max() ?? 0
        return ranked.map { "\($0.0.padding(toLength: width, withPad: " ", startingAt: 0))  \(String(format: "%.3f", $0.1))" }
    }

    /// One line for an agent.
    var summary: String {
        if let p = json["noul"]?.double { return "P(yes) = \(String(format: "%.3f", p))" }
        var answer = json["choice"]?.string ?? ""
        if let score = json["score"]?.double { answer = json["legend"]?[String(Int(score))]?.string ?? String(Int(score)) }
        return "\(answer) (\(String(format: "%.3f", probability)))\n" + lines.joined(separator: "\n")
    }
}

/// Talking to the local models' servers, shared by the commands above and the MCP tools.
nonisolated enum Screen {
    /// Wide enough to read a screen's text; wider costs seconds and memory for little more.
    static let defaultWidth = 1280

    // MARK: Questions

    /// The screen as a data URL, for the models.
    static func capture(_ target: Target, maxWidth: Int) throws -> String {
        let result = try target.send(.screenshot, ["maxWidth": .number(Double(maxWidth))])
        guard let png = result["png"]?.string else { throw Failure("\(target.name) sent no screenshot.") }
        return "data:image/png;base64,\(png)"
    }

    static func capture(_ id: UUID, maxWidth: Int = defaultWidth) throws -> String {
        let result = try ControlClient.send(.screenshot, to: id, params: ["maxWidth": .number(Double(maxWidth))])
        guard let png = result["png"]?.string else { throw Failure("the machine sent no screenshot.") }
        return "data:image/png;base64,\(png)"
    }

    /// A machine's screen, or a picture saved earlier (by `hyperbox screenshot`, say), so a script can check those too.
    static func capture(_ argument: String, maxWidth: Int) throws -> String {
        let file = URL(fileURLWithPath: (argument as NSString).expandingTildeInPath)
        guard ["png", "jpg", "jpeg"].contains(file.pathExtension.lowercased()), FileManager.default.fileExists(atPath: file.path) else {
            return try capture(Target.find(argument), maxWidth: maxWidth)
        }
        // Scaled as screenshots are.
        guard let source = CGImageSourceCreateWithURL(file as CFURL, nil),
              let size = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = size[kCGImagePropertyPixelWidth] as? Int, let height = size[kCGImagePropertyPixelHeight] as? Int,
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: max(width, height) * min(maxWidth, width) / width,
              ] as CFDictionary)
        else { throw Failure("can't read \(argument) as a picture.") }
        let png = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(png, "public.png" as CFString, 1, nil) else { throw Failure("can't encode \(argument).") }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw Failure("can't encode \(argument).") }
        return "data:image/png;base64,\((png as Data).base64EncodedString())"
    }

    /// Asks d1 one question about a screenshot, a data URL.
    static func ask(_ question: String, _ kind: QuestionKind, image: String, state: String? = nil) throws -> ScreenAnswer {
        var item: [String: JSONValue] = ["instructions": .string(question)]
        switch kind {
        case .noul:
            item["type"] = "noul"
        case .choice(let options):
            item["type"] = "choice"
            item["criteria"] = .object(options.mapValues { .string($0) })
        case .score(let levels):
            item["type"] = "score"
            item["criteria"] = .array(levels.map { .string($0) })
        }
        let body: JSONValue = [
            "state": state.map { .string($0) } ?? .null,
            "images": [.string(image)],
            "questions": ["answer": .object(item)],
        ]
        let reply = try post("/v1/systemone", body, to: .decision)
        guard case .object(let answer)? = reply["answers"]?["answer"] else { throw Failure("d1 sent no answer.") }
        return ScreenAnswer(json: answer)
    }

    /// Asks until the answer is yes with `threshold` probability, or `timeout` passes.
    static func wait(until question: String, threshold: Double, timeout: TimeInterval, interval: TimeInterval,
                     capture: () throws -> String) throws -> (met: Bool, probability: Double, seconds: TimeInterval) {
        let started = Date()
        var probability = 0.0
        while true {
            let asked = Date()
            probability = try ask(question, .noul, image: capture()).probability
            let elapsed = Date().timeIntervalSince(started)
            if probability >= threshold { return (true, probability, elapsed) }
            if elapsed + interval > timeout { return (false, probability, elapsed) }
            Thread.sleep(forTimeInterval: max(0, interval - Date().timeIntervalSince(asked)))
        }
    }

    /// Asks LFM3-VL about a screenshot, a data URL.
    static func describe(image: String, prompt: String?) throws -> String {
        let prompt = prompt ?? "Describe this screen briefly: which app or window is in front, any dialog, alert or progress bar and what it says, and what someone would do next."
        let body: JSONValue = [
            "messages": [[
                "role": "user",
                "content": [
                    ["type": "image_url", "image_url": ["url": .string(image)]],
                    ["type": "text", "text": .string(prompt)],
                ],
            ]],
            "max_tokens": 1024,
        ]
        let reply = try post("/v1/chat/completions", body, to: .vision)
        guard let text = reply["choices"]?.array?.first?["message"]?["content"]?.string else { throw Failure("LFM3-VL sent no answer.") }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Posts to the model's server, starting it first if needed. A server whose GPU work failed (when the Mac
    /// ran short of memory, say) answers every request with an error from then on, so it's restarted once.
    private static func post(_ path: String, _ body: JSONValue, to model: LocalModel) throws -> JSONValue {
        for attempt in 0..<2 {
            let base = try server(for: model)
            var request = URLRequest(url: base.appending(path: path), timeoutInterval: 300)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(body)
            let (data, status) = try http(request)
            ModelServer.touch(model)
            let reply = (try? JSONDecoder().decode(JSONValue.self, from: data)) ?? .null
            if status == 200 { return reply }
            let message = reply["error"]?["message"]?.string ?? String(decoding: data.prefix(300), as: UTF8.self)
            guard status >= 500, attempt == 0 else { throw Failure("\(model.rawValue) couldn't answer: \(message)") }
            stopAndWait(model)
        }
        throw Failure("\(model.rawValue) couldn't answer.")
    }

    // MARK: The servers

    /// The model's server, downloading and starting it as needed. One start at a time, so commands run
    /// side by side share one server.
    static func server(for model: LocalModel) throws -> URL {
        guard ModelSettings.enabled else { throw Failure("local models are turned off in Hyperbox's Settings › Models.") }
        if !model.isDownloaded { try download(model) }
        Paths.ensure(Paths.run)
        let lock = open(Paths.run.appending(path: "models.lock").path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        if lock >= 0 { flock(lock, LOCK_EX) }
        defer { if lock >= 0 { flock(lock, LOCK_UN); close(lock) } }

        var started: Process?
        if ModelServer.running(model) == nil {
            try? FileManager.default.removeItem(at: ModelServer.state(for: model))
            let p = Process()
            p.executableURL = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
            p.arguments = [Command.modelServer.name, model.rawValue]
            p.standardInput = FileHandle.nullDevice
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try p.run()
            started = p
        }
        // Loading takes a few seconds; /health answers 503 until it's done.
        let deadline = Date().addingTimeInterval(180)
        while Date() < deadline {
            if let state = ModelServer.running(model) {
                let base = URL(string: "http://127.0.0.1:\(state.port)")!
                if let (_, status) = try? http(URLRequest(url: base.appending(path: "/health"), timeoutInterval: 5)), status == 200 {
                    ModelServer.touch(model)
                    return base
                }
            } else if let started, !started.isRunning {
                throw Failure("\(model.rawValue)'s server stopped while loading. Its log: \(ModelServer.log(for: model).path)\n\(logTail(model))")
            }
            Thread.sleep(forTimeInterval: 0.25)
        }
        throw Failure("\(model.rawValue)'s server didn't start in 3 minutes. Its log: \(ModelServer.log(for: model).path)")
    }

    private static func stopAndWait(_ model: LocalModel) {
        ModelServer.stop(model)
        for _ in 0..<100 where ModelServer.running(model) != nil { Thread.sleep(forTimeInterval: 0.1) }
    }

    private static func logTail(_ model: LocalModel) -> String {
        let text = (try? String(contentsOf: ModelServer.log(for: model), encoding: .utf8)) ?? ""
        return text.split(separator: "\n").suffix(5).joined(separator: "\n")
    }

    /// Runs llama-server for `model` until it's idle for `ModelServer.idleTimeout`, it exits, or this process
    /// is told to stop. In a session of its own, so closing the terminal that started it doesn't stop it.
    static func serve(_ model: LocalModel) -> Never {
        setsid()
        signal(SIGHUP, SIG_IGN)
        signal(SIGINT, SIG_IGN)
        signal(SIGPIPE, SIG_IGN)
        Paths.ensure(Paths.run)
        // HYPERBOX_MODEL_PORT pins the port, for a firewall or a test; otherwise any free one.
        let port = ProcessInfo.processInfo.environment["HYPERBOX_MODEL_PORT"].flatMap(Int.init) ?? freePort()
        FileManager.default.createFile(atPath: ModelServer.log(for: model).path, contents: nil)
        let log = FileHandle(forWritingAtPath: ModelServer.log(for: model).path) ?? .nullDevice
        let server = Process()
        server.executableURL = LlamaCpp.server
        server.arguments = ["-m", model.path(model.weights).path, "--mmproj", model.path(model.projector).path,
                            "--host", "127.0.0.1", "--port", String(port), "-c", "16384", "-np", "1", "--no-webui"]
            + model.serverArguments
        server.standardInput = FileHandle.nullDevice
        server.standardOutput = log
        server.standardError = log
        do { try server.run() } catch {
            log.write(Data("Couldn't start \(LlamaCpp.server.path): \(error.localizedDescription)\n".utf8))
            exit(1)
        }
        let state = ModelServer.State(pid: getpid(), serverPid: server.processIdentifier, port: port, model: model.rawValue)
        try? JSONEncoder().encode(state).write(to: ModelServer.state(for: model), options: .atomic)

        @Sendable func finish(_ status: Int32) -> Never {
            if server.isRunning { server.terminate(); server.waitUntilExit() }
            if ModelServer.running(model)?.pid == getpid() || ModelServer.running(model) == nil {
                try? FileManager.default.removeItem(at: ModelServer.state(for: model))
            }
            exit(status)
        }
        signal(SIGTERM, SIG_IGN)
        let terminate = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        terminate.setEventHandler { finish(0) }
        terminate.resume()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 5, repeating: 5)
        timer.setEventHandler {
            if !server.isRunning { finish(server.terminationStatus == 0 ? 1 : server.terminationStatus) }
            if let used = ModelServer.lastUsed(model), Date().timeIntervalSince(used) > ModelServer.idleTimeout { finish(0) }
            // Turned off in Settings, or its state file removed: stop.
            if ModelServer.lastUsed(model) == nil || !ModelSettings.enabled { finish(0) }
        }
        timer.resume()
        dispatchMain()
    }

    private static func freePort() -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, length) == 0 ? getsockname(fd, $0, &length) : -1 }
        }
        return Int(UInt16(bigEndian: addr.sin_port))
    }

    // MARK: Downloads

    /// Downloads llama.cpp and the model, showing progress on stderr (stdout may be an MCP client's).
    static func download(_ model: LocalModel) throws {
        printError("downloading \(model.rawValue) from Hugging Face, once. \(LocalModel.licenseNote)")
        let progress = Progress()
        try blocking { try await model.download { message, fraction in progress.show(message, fraction) } }
        progress.done()
    }

    private final class Progress: @unchecked Sendable {
        private let lock = NSLock()
        private let live = isatty(STDERR_FILENO) != 0
        private var stage = ""

        func show(_ message: String, _ fraction: Double?) {
            lock.withLock {
                let percent = fraction.map { " (\(Int($0 * 100))%)" } ?? ""
                if live {
                    FileHandle.standardError.write(Data("\r\u{1B}[K\(message)\(percent)".utf8))
                } else {
                    // One line per file in a log, not one per update.
                    let stage = String(message.prefix { $0 != ":" })
                    if stage != self.stage { FileHandle.standardError.write(Data("\(stage)…\n".utf8)) }
                    self.stage = stage
                }
            }
        }

        func done() {
            if live { FileHandle.standardError.write(Data("\r\u{1B}[K".utf8)) }
        }
    }

    // MARK: Plumbing

    static func http(_ request: URLRequest) throws -> (Data, Int) {
        let semaphore = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var result: Result<(Data, Int), Error> = .failure(Failure("no answer."))
        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error { result = .failure(error) } else {
                result = .success((data ?? Data(), (response as? HTTPURLResponse)?.statusCode ?? 0))
            }
            semaphore.signal()
        }.resume()
        semaphore.wait()
        return try result.get()
    }

    static func blocking<T: Sendable>(_ work: @escaping @Sendable () async throws -> T) throws -> T {
        let semaphore = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var result: Result<T, Error> = .failure(CancellationError())
        Task.detached {
            do { result = .success(try await work()) } catch { result = .failure(error) }
            semaphore.signal()
        }
        semaphore.wait()
        return try result.get()
    }

    // MARK: Arguments

    static func kind(_ args: inout Arguments) throws -> QuestionKind {
        var options: [String: String] = [:]
        while let option = try args.option("--choice") {
            let parts = option.split(separator: "=", maxSplits: 1).map(String.init)
            guard let name = parts.first, !name.isEmpty else { throw Failure("--choice takes a name, or name=description.") }
            options[name] = parts.count > 1 ? parts[1] : name
        }
        let levels = try args.option("--levels").map { $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } }
        switch (options.isEmpty, levels) {
        case (true, nil): return .noul
        case (false, nil):
            guard options.count >= 2 else { throw Failure("give at least two --choice options.") }
            return .choice(options)
        case (true, let levels?):
            guard (2...10).contains(levels.count) else { throw Failure("--levels takes 2 to 10 levels, lowest first, between commas.") }
            return .score(levels)
        case (false, _?):
            throw Failure("ask with --choice or --levels, not both.")
        }
    }

    static func maxWidth(_ args: inout Arguments) throws -> Int {
        try args.option("--max-width").map { value in
            guard let width = Int(value), width >= 256 else { throw Failure("--max-width takes pixels, 256 or more.") }
            return width
        } ?? defaultWidth
    }

    static func probability(_ value: String) throws -> Double {
        guard let p = Double(value), (0...1).contains(p) else { throw Failure("a threshold is a probability, from 0 to 1.") }
        return p
    }

    static func seconds(_ value: String) throws -> Double {
        guard let seconds = Double(value), seconds > 0 else { throw Failure("\(value) isn't a number of seconds.") }
        return seconds
    }
}
