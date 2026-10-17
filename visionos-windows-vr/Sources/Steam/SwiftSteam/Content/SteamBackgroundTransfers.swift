// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 WineVisionVR contributors

import Foundation
import CryptoKit

/// Steam CDN chunks remain encrypted here. The depot downloader decrypts and
/// verifies them before removing the temporary copy. The system can finish the
/// currently submitted transfers while the app is suspended; scheduling more
/// chunks still requires execution time granted by visionOS.
final class SteamBackgroundTransfers: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    static let shared = SteamBackgroundTransfers()

    private final class Request: @unchecked Sendable {
        let id = UUID()
        var cancelled = false                 // All mutable state uses owner.lock.
        var continuation: CheckedContinuation<Data, Error>?
        var readyContinuation: CheckedContinuation<Void, Error>?
        var taskID: Int?
    }

    private struct Transfer {
        let task: URLSessionDownloadTask
        let key: String
        var requests: [UUID: Request] = [:]
        var downloadError: Error?
        var receivedFile = false
    }

    private final class Completion: @unchecked Sendable {
        let callback: () -> Void
        init(_ callback: @escaping () -> Void) { self.callback = callback }
    }

    private enum Failure: LocalizedError {
        case invalidURL, invalidResponse, missingFile
        var errorDescription: String? {
            switch self {
            case .invalidURL: "The Steam content server URL is not permitted."
            case .invalidResponse: "The Steam content server did not return a complete chunk."
            case .missingFile: "The background download did not provide a chunk file."
            }
        }
    }

    private let lock = NSLock()
    private let identifier: String
    private let cacheDirectory: URL
    private var session: URLSession!
    private var transfers: [Int: Transfer] = [:]
    private var taskByKey: [String: Int] = [:]
    private var reconnected = false
    private var reconnectWaiters: [UUID: Request] = [:]
    private var eventsCompletion: Completion?

    private override convenience init() {
        let identifier = (Bundle.main.bundleIdentifier ?? "org.avpplay.visionos-windows-vr") + ".steam-chunks.v1"
        let cacheDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SteamBackgroundChunks-v1", isDirectory: true)
        let configuration = URLSessionConfiguration.background(withIdentifier: identifier)
        configuration.sessionSendsLaunchEvents = true
        configuration.isDiscretionary = false
        configuration.waitsForConnectivity = true
        configuration.httpMaximumConnectionsPerHost = 8
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 24 * 60 * 60
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        self.init(configuration: configuration, cacheDirectory: cacheDirectory, identifier: identifier)
    }

    /// Isolated transport setup for host contract tests. The application uses
    /// only shared, whose background configuration and identifier are fixed.
    init(configuration: URLSessionConfiguration, cacheDirectory: URL, identifier: String) {
        self.identifier = identifier
        self.cacheDirectory = cacheDirectory
        super.init()
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.name = "Steam background chunk callbacks"
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
        lock.withLock { try? prepareCache(); pruneCache() }
        session.getAllTasks { [self] tasks in reconcile(tasks) }
    }

    /// Reconnect at application launch, including launches without a visible UI.
    func prepare() { _ = session }

    /// Returns false for an unrelated background session identifier.
    @discardableResult
    func handleEvents(identifier: String, completionHandler: @escaping () -> Void) -> Bool {
        guard identifier == self.identifier else { return false }
        lock.withLock { eventsCompletion = Completion(completionHandler) }
        prepare()
        return true
    }

    func data(for url: URL) async throws -> Data {
        let key = try Self.cacheKey(for: url)
        let request = Request()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let result: Result<Void, Error>? = lock.withLock {
                    if request.cancelled { return .failure(CancellationError()) }
                    if reconnected { return .success(()) }
                    request.readyContinuation = continuation
                    reconnectWaiters[request.id] = request
                    return nil
                }
                if let result { continuation.resume(with: result) }
            }
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                enqueue(url: url, key: key, request: request, continuation: continuation)
            }
        } onCancel: {
            self.cancel(request)
        }
    }

    /// Call only after the decrypted chunk was verified and written, or to
    /// discard a corrupt cached chunk before retrying it from the network.
    func removeCachedData(for url: URL) {
        guard let key = try? Self.cacheKey(for: url) else { return }
        lock.withLock { try? FileManager.default.removeItem(at: cacheURL(key)) }
    }

    private func enqueue(url: URL, key: String, request: Request,
                         continuation: CheckedContinuation<Data, Error>) {
        var result: Result<Data, Error>?
        var start: URLSessionDownloadTask?
        lock.withLock {
            if request.cancelled { result = .failure(CancellationError()); return }
            if let cached = try? Data(contentsOf: cacheURL(key)) {
                result = .success(cached)
                return
            }
            request.continuation = continuation
            if let taskID = taskByKey[key], var transfer = transfers[taskID] {
                request.taskID = taskID
                transfer.requests[request.id] = request
                transfers[taskID] = transfer
            } else {
                let task = session.downloadTask(with: url)
                task.taskDescription = key  // Persist only an opaque, token-free key.
                request.taskID = task.taskIdentifier
                transfers[task.taskIdentifier] = Transfer(task: task, key: key, requests: [request.id: request])
                taskByKey[key] = task.taskIdentifier
                start = task
            }
        }
        if let result { continuation.resume(with: result) }
        // Starting inside the lock prevents cancellation from being followed by
        // a resume of the same task (URLSession also tolerates cancelled resume).
        if let start { lock.withLock { if !request.cancelled { start.resume() } } }
    }

    private func cancel(_ request: Request) {
        var continuation: CheckedContinuation<Data, Error>?
        var readyContinuation: CheckedContinuation<Void, Error>?
        var task: URLSessionDownloadTask?
        lock.withLock {
            request.cancelled = true
            readyContinuation = request.readyContinuation
            request.readyContinuation = nil
            reconnectWaiters.removeValue(forKey: request.id)
            continuation = request.continuation
            request.continuation = nil
            guard let taskID = request.taskID, var transfer = transfers[taskID],
                  transfer.requests.removeValue(forKey: request.id) != nil else { return }
            if transfer.requests.isEmpty {
                transfers.removeValue(forKey: taskID)
                if taskByKey[transfer.key] == taskID { taskByKey.removeValue(forKey: transfer.key) }
                task = transfer.task
            } else {
                transfers[taskID] = transfer
            }
        }
        task?.cancel()
        continuation?.resume(throwing: CancellationError())
        readyContinuation?.resume(throwing: CancellationError())
    }

    private func reconcile(_ tasks: [URLSessionTask]) {
        var invalid: [URLSessionTask] = []
        let waiters = lock.withLock {
            for task in tasks {
                // A getAllTasks snapshot can race a delegate completion. Do
                // not resurrect a task that can no longer call its delegate.
                guard task.state != .completed, task.state != .canceling else { continue }
                guard let download = task as? URLSessionDownloadTask,
                      let url = task.originalRequest?.url,
                      let key = try? Self.cacheKey(for: url),
                      task.taskDescription == key else { invalid.append(task); continue }
                // Orphan transfers have no in-memory callers after relaunch.
                // Keep them alive so completed encrypted chunks can be resumed.
                if transfers[task.taskIdentifier] == nil {
                    transfers[task.taskIdentifier] = Transfer(task: download, key: key,
                                                             receivedFile: FileManager.default.fileExists(atPath: cacheURL(key).path))
                    if taskByKey[key] == nil { taskByKey[key] = task.taskIdentifier }
                }
                if task.state == .suspended { task.resume() }
            }
            reconnected = true
            let waiters = reconnectWaiters.values.compactMap { request -> CheckedContinuation<Void, Error>? in
                let continuation = request.readyContinuation
                request.readyContinuation = nil
                return continuation
            }
            reconnectWaiters.removeAll()
            return waiters
        }
        invalid.forEach { $0.cancel() }
        waiters.forEach { $0.resume() }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        // URLSession deletes location as soon as this callback returns. Preserve
        // it synchronously, even if no downloader exists following a relaunch.
        lock.withLock {
            do {
                guard let response = downloadTask.response as? HTTPURLResponse,
                      response.statusCode == 200,
                      let url = downloadTask.originalRequest?.url else { throw Failure.invalidResponse }
                let key = try Self.cacheKey(for: url)
                guard downloadTask.taskDescription == key else { throw Failure.invalidURL }
                try prepareCache()
                let temporary = cacheDirectory.appendingPathComponent(UUID().uuidString + ".partial")
                defer { try? FileManager.default.removeItem(at: temporary) }
                try FileManager.default.copyItem(at: location, to: temporary)
                if !Self.cacheAttributes.isEmpty {
                    try FileManager.default.setAttributes(Self.cacheAttributes, ofItemAtPath: temporary.path)
                }
                let destination = cacheURL(key)
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.moveItem(at: temporary, to: destination)
                transfers[downloadTask.taskIdentifier]?.receivedFile = true
                pruneCache(keeping: key)
            } catch {
                transfers[downloadTask.taskIdentifier]?.downloadError = error
            }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        var continuations: [CheckedContinuation<Data, Error>] = []
        let result: Result<Data, Error>? = lock.withLock {
            guard let transfer = transfers.removeValue(forKey: task.taskIdentifier) else { return nil }
            if taskByKey[transfer.key] == task.taskIdentifier { taskByKey.removeValue(forKey: transfer.key) }
            for request in transfer.requests.values {
                if let continuation = request.continuation { continuations.append(continuation) }
                request.continuation = nil
                request.taskID = nil
            }
            if let error {
                let code = (error as NSError).code
                return .failure(URLError(URLError.Code(rawValue: code)))
            }
            if let failure = transfer.downloadError { return .failure(failure) }
            guard transfer.receivedFile else { return .failure(Failure.missingFile) }
            return Result { try Data(contentsOf: cacheURL(transfer.key)) }
        }
        if let result { continuations.forEach { $0.resume(with: result) } }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        let completion = lock.withLock {
            let completion = eventsCompletion
            eventsCompletion = nil
            return completion
        }
        if let completion { DispatchQueue.main.async { completion.callback() } }
    }

    private static func cacheKey(for url: URL) throws -> String {
        guard let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased(), !host.isEmpty,
              url.user == nil, url.password == nil,
              scheme == "https" || (scheme == "http" && ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host)),
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { throw Failure.invalidURL }
        components.query = nil
        components.fragment = nil
        guard let identity = components.string else { throw Failure.invalidURL }
        return SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func cacheURL(_ key: String) -> URL { cacheDirectory.appendingPathComponent(key + ".chunk") }

    private static var cacheAttributes: [FileAttributeKey: Any] {
        #if os(visionOS) || os(iOS)
        return [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        #else
        return [:]
        #endif
    }

    private func prepareCache() throws {
        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true,
                                               attributes: Self.cacheAttributes)
        var directory = cacheDirectory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try directory.setResourceValues(values)
    }

    /// Caches are disposable and bounded, including chunks whose caller never
    /// returned after process termination. No URLs, tokens or depot keys persist.
    private func pruneCache(keeping: String? = nil) {
        let manager = FileManager.default
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
        guard let files = try? manager.contentsOfDirectory(at: cacheDirectory, includingPropertiesForKeys: Array(keys)) else { return }
        let cutoff = Date().addingTimeInterval(-7 * 24 * 60 * 60)
        var retained: [(URL, Date, Int)] = []
        for file in files {
            guard let values = try? file.resourceValues(forKeys: keys), values.isRegularFile == true else { continue }
            let date = values.contentModificationDate ?? .distantPast
            if file.pathExtension != "chunk" || date < cutoff {
                try? manager.removeItem(at: file)
            } else {
                retained.append((file, date, values.fileSize ?? 0))
            }
        }
        var total = retained.reduce(0) { $0 + $1.2 }
        for (file, _, size) in retained.sorted(by: { $0.1 < $1.1 }) where total > 256 * 1024 * 1024 {
            if file.deletingPathExtension().lastPathComponent == keeping { continue }
            try? manager.removeItem(at: file)
            total -= size
        }
    }
}
