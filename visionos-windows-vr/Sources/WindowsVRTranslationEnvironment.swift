import Foundation

/// Defaults must reach Wine even when the app uses the preserved native plugin.
/// Explicit process/manifest overrides remain available for controlled comparisons.
enum WindowsVRTranslationEnvironment {
    static let defaults: [String: String] = [
        "FEX_MULTIBLOCK": "1",
        // Upstream default block size limit.
        "FEX_MAXINST": "5000",
        "FEX_SILENTLOG": "1",
        // Second-level indirect-branch lookup cache before the slow path.
        "FEX_DISABLEL2CACHE": "0",
        "FEX_STACKDERIVEDNONTSO": "1",
        "FEX_THREADLOCALNONTSO": "1",
        // Safe again: patch 0015 publishes the GDI shared table into every
        // child process, so a game spawned by the cache launcher no longer
        // faults in gdi32. Environment overrides can still disable it.
        "FEX_ENABLECODECACHINGWIP": "1",
        "FEX_ENABLELAZYCODECACHINGWIP": "0",
        "FEX_ENABLECODECACHEVALIDATION": "0"
    ]

    static func applyDefaults() {
        for (name, value) in defaults where getenv(name) == nil {
            setenv(name, value, 0)
        }
    }
}
