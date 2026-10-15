import Foundation
import os

/// Launch milestones go to os_log and to `Documents/launcher-log.txt`, so a session can be diagnosed from
/// the app container without a live debugger console. The file is bounded and restarts when it grows.
struct LaunchLog {
    private let logger = Logger(subsystem: "org.avpplay.windows-vr", category: "launcher")

    func notice(_ message: String) {
        logger.notice("\(message, privacy: .public)")
        LaunchLogFile.append("notice", message)
    }

    func error(_ message: String) {
        logger.error("\(message, privacy: .public)")
        LaunchLogFile.append("error", message)
    }
}

/// Diagnostics that write files or trace the bridge are off unless the app's Info.plist sets `WVRDiagnostics`.
enum LaunchDiagnostics {
    static let frameCaptureEnabled = (Bundle.main.object(forInfoDictionaryKey: "WVRFrameCapture") as? Bool) ?? false
    static let enabled: Bool = (Bundle.main.object(forInfoDictionaryKey: "WVRDiagnostics") as? Bool) ?? false
}

enum LaunchLogFile {
    private static let lock = NSLock()
    private static let maxBytes = 512 * 1024
    private static let url: URL? = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
        .appendingPathComponent("launcher-log.txt")
    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    static func append(_ level: String, _ message: String) {
        guard LaunchDiagnostics.enabled, let url else { return }
        lock.lock(); defer { lock.unlock() }
        let line = "\(formatter.string(from: Date())) [\(level)] \(message)\n"
        let fm = FileManager.default
        if let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int, size > maxBytes {
            try? fm.removeItem(at: url)
        }
        if !fm.fileExists(atPath: url.path) { fm.createFile(atPath: url.path, contents: nil) }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data(line.utf8))
    }
}
