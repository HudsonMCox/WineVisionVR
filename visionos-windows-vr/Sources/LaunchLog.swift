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
    private static let maxBytes = 2 * 1024 * 1024
    private static let url: URL? = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
        .appendingPathComponent("launcher-log.txt")
    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    static func append(_ level: String, _ message: String) {
        guard LaunchDiagnostics.enabled || (level == "reconstruction" && UserDefaults.standard.bool(forKey: "WVRReconstructionValidation")), let url else { return }
        lock.lock(); defer { lock.unlock() }
        let line = "\(formatter.string(from: Date())) [\(level)] \(message)\n"
        let fm = FileManager.default
        if let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int, size > maxBytes {
            // Keep recent performance evidence when native thread tracing fills
            // a chunk. A later game must not erase the preceding run's counters.
            for index in stride(from: 3, through: 1, by: -1) {
                let previous = url.deletingLastPathComponent().appendingPathComponent("launcher.previous-\(index).txt")
                if index == 3 { try? fm.removeItem(at: previous) }
                else if fm.fileExists(atPath: previous.path) {
                    try? fm.moveItem(at: previous, to: url.deletingLastPathComponent().appendingPathComponent("launcher.previous-\(index + 1).txt"))
                }
            }
            try? fm.moveItem(at: url, to: url.deletingLastPathComponent().appendingPathComponent("launcher.previous-1.txt"))
        }
        if !fm.fileExists(atPath: url.path) { fm.createFile(atPath: url.path, contents: nil) }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data(line.utf8))
    }
}
