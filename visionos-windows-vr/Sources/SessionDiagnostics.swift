import Foundation

/// App-owned, bounded journals for comparing game attempts after restarts.
/// Call recovery before the runtime can rotate its shared text logs.
final class SessionDiagnostics: @unchecked Sendable {
    enum Outcome: String, Codable, Sendable {
        case pending, completed, stopped, failed, interrupted, recovered
    }

    struct Metadata: Codable, Sendable {
        let title: String
        let manifestID: String
        let steamAppID: Int?
        let steamLaunchOptionID: Int?
        let architecture: String
        let graphics: String
        let renderScale: Double
        let appVersion: String
        let buildNumber: String
        let runtimeBuildID: String?
        let profileID: String?
        let profileName: String?

        init(title: String, manifestID: String, steamAppID: Int? = nil,
             steamLaunchOptionID: Int? = nil, architecture: String, graphics: String,
             renderScale: Double, appVersion: String, buildNumber: String,
             runtimeBuildID: String? = nil, profileID: String? = nil, profileName: String? = nil) {
            self.title = Self.limit(title)
            self.manifestID = Self.limit(manifestID)
            self.steamAppID = steamAppID
            self.steamLaunchOptionID = steamLaunchOptionID
            self.architecture = Self.limit(architecture)
            self.graphics = Self.limit(graphics)
            self.renderScale = renderScale.isFinite ? renderScale : 1
            self.appVersion = Self.limit(appVersion)
            self.buildNumber = Self.limit(buildNumber)
            self.runtimeBuildID = runtimeBuildID.map(Self.limit)
            self.profileID = profileID.map(Self.limit)
            self.profileName = profileName.map(Self.limit)
        }

        private static func limit(_ value: String) -> String { String(value.prefix(256)) }
    }

    private struct Baseline: Codable {
        var identity: String
        var bytes: UInt64
        var headHash: UInt64
        var tailHash: UInt64
    }
    private struct Source: Codable {
        var label: String
        var relativePath: String
        var prefixRelativePath: String?
        var baseline: Baseline?
    }
    private struct Log: Codable {
        var name: String
        var startup: String
        var tail: String
        var sourceBytes: UInt64
        var truncated: Bool
        var capturedAt: Date
    }
    private struct Event: Codable {
        var timestamp: Date
        var reason: String
        var outcome: Outcome?
    }
    private struct Journal: Codable {
        var schemaVersion = 1
        var id: UUID
        var startedAt: Date
        var updatedAt: Date
        var metadata: Metadata
        var outcome: Outcome
        var isPending: Bool
        var sources: [Source]
        var logs: [Log]
        var events: [Event]
    }
    private struct ExportLog: Codable {
        var name: String
        var text: String
        var sourceBytes: UInt64
        var truncated: Bool
        var capturedAt: Date
    }
    private struct ExportAttempt: Codable {
        var id: UUID
        var startedAt: Date
        var updatedAt: Date
        var metadata: Metadata
        var outcome: Outcome
        var isPending: Bool
        var logs: [ExportLog]
        var events: [Event]
    }
    private struct ExportBundle: Codable {
        var schemaVersion = 1
        var exportedAt: Date
        var retentionLimit = 20
        var attempts: [ExportAttempt]
    }

    enum DiagnosticsError: Error {
        case unsafePath, oversizedJournal, oversizedExport
    }

    private let documents: URL
    private let directory: URL
    private let lock = NSLock()
    private var currentID: UUID?
    private static let maximumJournalBytes = 2 * 1_024 * 1_024
    private static let maximumExportBytes = 32 * 1_024 * 1_024
    private static let headBytes = 16 * 1_024
    private static let tailBytes = 48 * 1_024
    private static let marker = "\n[... log truncated; startup and latest tail retained ...]\n"

    init(documentsDirectory: URL) throws {
        documents = documentsDirectory.standardizedFileURL.resolvingSymlinksInPath()
        directory = documents.appendingPathComponent("WindowsVR/SessionDiagnostics", isDirectory: true)
        guard Self.isDescendant(directory.resolvingSymlinksInPath(), of: documents) else {
            throw DiagnosticsError.unsafePath
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// Recover journals left pending by force quit/crash before shared log rotation.
    func recoverPendingAttempt() throws {
        try synchronized {
            for var journal in try journals() where journal.isPending {
                try capture(&journal, reason: "Recovered pending attempt after app restart",
                            outcome: journal.outcome == .failed ? .failed : .recovered)
                journal.isPending = false
                try save(journal)
            }
            currentID = nil
            try prune()
        }
    }

    @discardableResult
    func beginAttempt(metadata: Metadata, prefixURL: URL? = nil) throws -> UUID {
        try synchronized {
            // A failed begin must never let later snapshots target the previous game.
            currentID = nil
            // Defensively finish any prior pending attempt before changing file baselines.
            for var pending in try journals() where pending.isPending {
                try capture(&pending, reason: "Superseded by a new attempt", outcome: .interrupted)
                pending.isPending = false
                try save(pending)
            }
            var sources = [
                Source(label: "launcher", relativePath: "launcher-log.txt"),
                Source(label: "runtime", relativePath: "madeira-log.txt")
            ]
            if let prefixURL {
                let prefix = prefixURL.standardizedFileURL.resolvingSymlinksInPath()
                let owned = documents.appendingPathComponent("WindowsVR/Prefixes", isDirectory: true).resolvingSymlinksInPath()
                guard Self.isDescendant(owned, of: documents), Self.isDescendant(prefix, of: owned),
                      (try? FileManager.default.destinationOfSymbolicLink(atPath: prefixURL.path)) == nil else {
                    throw DiagnosticsError.unsafePath
                }
                let relative = String(prefix.path.dropFirst(documents.path.count + 1))
                for (label, suffix) in [
                    ("openxr", "drive_c/windows-vr-runtime/openxr-trace.txt"),
                    ("opencomposite", "drive_c/usersmadeira/AppData/Local/OpenComposite/logs/opencomposite.log")
                ] {
                    sources.append(Source(label: label, relativePath: relative + "/" + suffix,
                                          prefixRelativePath: relative))
                }
            }
            for index in sources.indices {
                if let url = sourceURL(sources[index]) { sources[index].baseline = try? baseline(url) }
            }
            let now = Date()
            let journal = Journal(id: UUID(), startedAt: now, updatedAt: now, metadata: metadata,
                                  outcome: .pending, isPending: true, sources: sources, logs: [],
                                  events: [Event(timestamp: now, reason: "Attempt created before launch", outcome: nil)])
            try save(journal) // Durable before preflight/JIT/runtime execution.
            try prune()
            currentID = journal.id
            return journal.id
        }
    }

    /// An outcome here records a diagnostic observation without closing the attempt.
    func snapshot(reason: String, outcome: Outcome? = nil) throws {
        try synchronized {
            guard let id = currentID, var journal = try load(id) else { return }
            try capture(&journal, reason: reason, outcome: outcome)
            try save(journal)
        }
    }

    func finish(outcome: Outcome, reason: String) throws {
        try synchronized {
            guard let id = currentID, var journal = try load(id) else { return }
            try capture(&journal, reason: reason, outcome: outcome)
            journal.isPending = false
            try save(journal)
            currentID = nil
            try prune()
        }
    }

    /// One bounded JSON file; private source paths and baseline fingerprints stay local.
    func exportBundle() throws -> URL {
        try synchronized {
            if let id = currentID, var journal = try load(id) {
                try capture(&journal, reason: "Batch diagnostics exported", outcome: nil)
                try save(journal)
            }
            try prune()
            let attempts = try journals().map { journal in
                ExportAttempt(id: journal.id, startedAt: journal.startedAt, updatedAt: journal.updatedAt,
                              metadata: journal.metadata, outcome: journal.outcome, isPending: journal.isPending,
                              logs: journal.logs.map { log in
                                  ExportLog(name: log.name,
                                            text: log.startup + (log.truncated ? Self.marker : "") + log.tail,
                                            sourceBytes: log.sourceBytes, truncated: log.truncated,
                                            capturedAt: log.capturedAt)
                              }, events: journal.events)
            }
            let data = try encoder().encode(ExportBundle(exportedAt: Date(), attempts: attempts))
            guard data.count <= Self.maximumExportBytes else { throw DiagnosticsError.oversizedExport }
            let url = directory.appendingPathComponent("session-diagnostics.json")
            try validateJournalPath(url)
            try data.write(to: url, options: .atomic)
            return url
        }
    }

    private func synchronized<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    private func capture(_ journal: inout Journal, reason: String, outcome: Outcome?) throws {
        for source in journal.sources {
            guard let url = sourceURL(source), let captured = try? readLog(url, source: source) else { continue }
            if let index = journal.logs.firstIndex(where: { $0.name == source.label }) {
                let old = journal.logs[index]
                // Preserve startup even if the active text log subsequently rotates.
                var updated = captured
                if !old.startup.isEmpty && !captured.startup.hasPrefix(old.startup) {
                    updated.startup = String(decoding: Data(old.startup.utf8.prefix(Self.headBytes)), as: UTF8.self)
                    let latest = captured.startup + (captured.truncated ? Self.marker : "") + captured.tail
                    updated.tail = String(decoding: Data(latest.utf8.suffix(Self.tailBytes)), as: UTF8.self)
                    updated.truncated = true
                }
                journal.logs[index] = updated
            } else {
                journal.logs.append(captured)
            }
        }
        let now = Date()
        journal.updatedAt = now
        if let outcome { journal.outcome = outcome }
        journal.events.append(Event(timestamp: now, reason: Self.clean(reason, limit: 512), outcome: outcome))
        journal.events = Array(journal.events.suffix(32))
    }

    private func sourceURL(_ source: Source) -> URL? {
        let original = documents.appendingPathComponent(source.relativePath).standardizedFileURL
        // Fixed log leaves may not redirect to auth/handoff files, even within
        // the same prefix. Ancestor aliases are allowed only inside that prefix.
        guard (try? FileManager.default.destinationOfSymbolicLink(atPath: original.path)) == nil else { return nil }
        let candidate = original.resolvingSymlinksInPath()
        guard Self.isDescendant(candidate, of: documents) else { return nil }
        if let prefixRelative = source.prefixRelativePath {
            let prefix = documents.appendingPathComponent(prefixRelative).standardizedFileURL.resolvingSymlinksInPath()
            let owned = documents.appendingPathComponent("WindowsVR/Prefixes").resolvingSymlinksInPath()
            let suffix: String
            switch source.label {
            case "openxr": suffix = "drive_c/windows-vr-runtime/openxr-trace.txt"
            case "opencomposite": suffix = "drive_c/usersmadeira/AppData/Local/OpenComposite/logs/opencomposite.log"
            default: return nil
            }
            guard source.relativePath == prefixRelative + "/" + suffix,
                  Self.isDescendant(prefix, of: owned), Self.isDescendant(candidate, of: prefix) else { return nil }
        } else {
            guard candidate.path == original.path,
                  (source.label == "launcher" && source.relativePath == "launcher-log.txt") ||
                    (source.label == "runtime" && source.relativePath == "madeira-log.txt") else { return nil }
        }
        return candidate
    }

    private static func isDescendant(_ url: URL, of parent: URL) -> Bool {
        url.path.hasPrefix(parent.path + "/")
    }

    private func fileInfo(_ url: URL) throws -> (String, UInt64) {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular else { throw DiagnosticsError.unsafePath }
        let identity = "\(attributes[.systemNumber] ?? 0):\(attributes[.systemFileNumber] ?? 0)"
        return (identity, (attributes[.size] as? NSNumber)?.uint64Value ?? 0)
    }

    private func sample(_ handle: FileHandle, offset: UInt64, count: Int) throws -> Data {
        try handle.seek(toOffset: offset)
        return try handle.read(upToCount: count) ?? Data()
    }

    private func hash(_ data: Data) -> UInt64 {
        data.reduce(14_695_981_039_346_656_037) { ($0 ^ UInt64($1)) &* 1_099_511_628_211 }
    }

    private func baseline(_ url: URL) throws -> Baseline {
        let (identity, bytes) = try fileInfo(url)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let count = Int(min(bytes, 128))
        return Baseline(identity: identity, bytes: bytes,
                        headHash: hash(try sample(handle, offset: 0, count: count)),
                        tailHash: hash(try sample(handle, offset: bytes - UInt64(count), count: count)))
    }

    private func readLog(_ url: URL, source: Source) throws -> Log? {
        let (identity, bytes) = try fileInfo(url)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var start: UInt64 = 0
        if let baseline = source.baseline, baseline.identity == identity, bytes >= baseline.bytes {
            let count = Int(min(baseline.bytes, 128))
            let head = hash(try sample(handle, offset: 0, count: count))
            let tail = hash(try sample(handle, offset: baseline.bytes - UInt64(count), count: count))
            if head == baseline.headHash && tail == baseline.tailHash { start = baseline.bytes }
        }
        guard bytes > start else { return nil } // Unchanged previous-game logs are never attributed here.
        let length = bytes - start
        let totalLimit = Self.headBytes + Self.tailBytes
        if length <= UInt64(totalLimit) {
            let data = try sample(handle, offset: start, count: Int(length))
            return Log(name: source.label, startup: Self.clean(String(decoding: data, as: UTF8.self), limit: totalLimit),
                       tail: "", sourceBytes: length, truncated: false, capturedAt: Date())
        }
        let first = try sample(handle, offset: start, count: Self.headBytes)
        let last = try sample(handle, offset: bytes - UInt64(Self.tailBytes), count: Self.tailBytes)
        // Drop partial lines at truncation boundaries so a secret value cannot
        // survive without the sensitive key that was outside the retained range.
        let firstText = String(decoding: first, as: UTF8.self)
        let lastText = String(decoding: last, as: UTF8.self)
        let head = firstText.lastIndex(of: "\n").map { String(firstText[...$0]) } ?? ""
        let tail = lastText.firstIndex(of: "\n").map { String(lastText[lastText.index(after: $0)...]) } ?? ""
        return Log(name: source.label, startup: Self.clean(head, limit: Self.headBytes),
                   tail: Self.clean(tail, limit: Self.tailBytes), sourceBytes: length,
                   truncated: true, capturedAt: Date())
    }

    private static func clean(_ text: String, limit: Int) -> String {
        let sensitive = ["auth", "token", "password", "passwd", "secret", "credential", "cookie", "handoff"]
        let lines = text.replacingOccurrences(of: "\0", with: "").components(separatedBy: "\n")
        let safe = lines.map { line -> String in
            sensitive.contains(where: { line.lowercased().contains($0) }) ? "[sensitive log line omitted]" : line
        }.joined(separator: "\n")
        // A UTF-8 byte budget prevents multi-byte text from escaping export bounds.
        return String(decoding: Data(safe.utf8.prefix(limit)), as: UTF8.self)
    }

    private func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private func validateJournalPath(_ url: URL) throws {
        guard Self.isDescendant(url.resolvingSymlinksInPath(), of: directory.resolvingSymlinksInPath()),
              Self.isDescendant(directory.resolvingSymlinksInPath(), of: documents) else { throw DiagnosticsError.unsafePath }
    }

    private func save(_ journal: Journal) throws {
        let folder = directory.appendingPathComponent(journal.id.uuidString, isDirectory: true)
        try validateJournalPath(folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("journal.json")
        try validateJournalPath(url)
        let data = try encoder().encode(journal)
        guard data.count <= Self.maximumJournalBytes else { throw DiagnosticsError.oversizedJournal }
        try data.write(to: url, options: .atomic)
    }

    private func load(_ id: UUID) throws -> Journal? {
        let url = directory.appendingPathComponent(id.uuidString).appendingPathComponent("journal.json")
        try validateJournalPath(url)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let (_, size) = try fileInfo(url)
        guard size <= UInt64(Self.maximumJournalBytes) else { throw DiagnosticsError.oversizedJournal }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return try decoder.decode(Journal.self, from: Data(contentsOf: url))
    }

    private func journals() throws -> [Journal] {
        let children = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        return children.compactMap { url -> Journal? in
            guard let id = UUID(uuidString: url.lastPathComponent) else { return nil }
            return try? load(id)
        }.sorted { $0.startedAt == $1.startedAt ? $0.id.uuidString < $1.id.uuidString : $0.startedAt < $1.startedAt }
    }

    private func prune() throws {
        let history = try journals()
        for journal in history.prefix(max(0, history.count - 20)) {
            let folder = directory.appendingPathComponent(journal.id.uuidString)
            try validateJournalPath(folder)
            try FileManager.default.removeItem(at: folder)
        }
    }
}
