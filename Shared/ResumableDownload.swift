import Foundation

/// Downloads a big file to `<destination>.part`, picking up where an earlier try stopped, and moves it
/// into place once it's all there. A macOS restore image is over 20 GB, so starting over hurts.
nonisolated final class ResumableDownload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    /// Bytes so far, and the total once the server has said.
    typealias Progress = @Sendable (Int64, Int64?) -> Void

    static func fetch(_ url: URL, to destination: URL, progress: @escaping Progress) async throws {
        let download = ResumableDownload(destination: destination, progress: progress)
        try await download.run(url)
    }

    /// Asks the server how big the file is, for checking there's room first.
    static func size(of url: URL) async -> Int64? {
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        guard let (_, response) = try? await URLSession.shared.data(for: request) else { return nil }
        let length = response.expectedContentLength
        return length > 0 ? length : nil
    }

    static func partial(_ destination: URL) -> URL {
        destination.deletingLastPathComponent().appending(path: destination.lastPathComponent + ".part")
    }

    // Everything below runs on the session's serial delegate queue.
    private let destination: URL
    private let part: URL
    private let progress: Progress
    private var handle: FileHandle?
    private var received: Int64 = 0
    private var total: Int64?
    private var lastReport = Date.distantPast
    private var failure: Error?
    private var continuation: CheckedContinuation<Void, Error>?

    private init(destination: URL, progress: @escaping Progress) {
        self.destination = destination
        part = Self.partial(destination)
        self.progress = progress
    }

    private func run(_ url: URL) async throws {
        let fm = FileManager.default
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fm.fileExists(atPath: part.path) { fm.createFile(atPath: part.path, contents: nil) }
        received = (try? fm.attributesOfItem(atPath: part.path)[.size] as? Int64) ?? 0

        var request = URLRequest(url: url)
        if received > 0 { request.setValue("bytes=\(received)-", forHTTPHeaderField: "Range") }
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: queue)
        defer { session.finishTasksAndInvalidate() }
        let task = session.dataTask(with: request)

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                queue.addOperation {
                    self.continuation = continuation
                    task.resume()
                }
            }
        } onCancel: {
            task.cancel()
        }
        try fm.moveItem(at: part, to: destination)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        do {
            let handle = try FileHandle(forWritingTo: part)
            switch status {
            case 206:
                // "bytes 100-199/200": the total is after the slash.
                let range = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Range") ?? ""
                total = range.split(separator: "/").last.flatMap { Int64($0) }
                try handle.seekToEnd()
            case 200:
                // The server ignored the range, so start over.
                try handle.truncate(atOffset: 0)
                received = 0
                total = response.expectedContentLength > 0 ? response.expectedContentLength : nil
            case 416:
                // Nothing left to fetch: an earlier try got it all.
                try handle.close()
                completionHandler(.cancel)
                finish(nil)
                return
            default:
                try handle.close()
                throw ControlError("The download failed: the server answered \(status).")
            }
            self.handle = handle
            completionHandler(.allow)
        } catch {
            failure = error
            completionHandler(.cancel)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let handle, failure == nil else { return }
        do {
            try handle.write(contentsOf: data)
            received += Int64(data.count)
            if Date().timeIntervalSince(lastReport) > 0.25 {
                lastReport = Date()
                progress(received, total)
            }
        } catch {
            failure = error
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        try? handle?.close()
        handle = nil
        if let failure { return finish(failure) }
        if let error {
            return finish((error as? URLError)?.code == .cancelled ? CancellationError() : error)
        }
        if let total, received != total {
            return finish(ControlError("The download stopped early, at \(received) of \(total) bytes. Try again to pick it up from there."))
        }
        progress(received, total)
        finish(nil)
    }

    private func finish(_ error: Error?) {
        guard let continuation else { return }
        self.continuation = nil
        if let error { continuation.resume(throwing: error) } else { continuation.resume() }
    }
}
