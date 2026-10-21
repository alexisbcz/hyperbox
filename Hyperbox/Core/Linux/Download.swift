import Foundation

/// Fetches a file into `Paths.downloads`, reporting how far along it is. A finished download is kept,
/// so a second machine from the same image doesn't fetch it again.
nonisolated enum Download {
    /// Downloads `url` to `destination`, unless it's already there. `progress` gets the fraction done.
    static func fetch(_ url: URL, to destination: URL, progress: @escaping @Sendable (Double?) -> Void) async throws {
        if FileManager.default.fileExists(atPath: destination.path) { return }
        Paths.ensure(destination.deletingLastPathComponent())
        let delegate = Delegate(progress: progress)
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let task = session.downloadTask(with: url)
        let file: URL = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                delegate.continuation = continuation
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: file, to: destination)
    }

    private final class Delegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
        let progress: @Sendable (Double?) -> Void
        var continuation: CheckedContinuation<URL, Error>?
        private var lastReport = Date.distantPast

        init(progress: @escaping @Sendable (Double?) -> Void) { self.progress = progress }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                        totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
            guard Date().timeIntervalSince(lastReport) > 0.2 else { return }
            lastReport = Date()
            progress(totalBytesExpectedToWrite > 0 ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite) : nil)
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
            if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                finish(.failure(ControlError("The download failed: \(downloadTask.originalRequest?.url?.absoluteString ?? "") answered \(http.statusCode).")))
                return
            }
            // The file is deleted when this returns, so move it somewhere it stays.
            let kept = location.deletingLastPathComponent().appending(path: UUID().uuidString)
            do {
                try FileManager.default.moveItem(at: location, to: kept)
                finish(.success(kept))
            } catch {
                finish(.failure(error))
            }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            if let error { finish(.failure((error as? URLError)?.code == .cancelled ? CancellationError() : error)) }
        }

        private func finish(_ result: Result<URL, Error>) {
            continuation?.resume(with: result)
            continuation = nil
        }
    }
}
