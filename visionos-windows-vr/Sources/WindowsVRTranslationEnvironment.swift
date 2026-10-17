import Foundation

/// Defaults must reach Wine even when the app uses the preserved native plugin.
/// Explicit process/manifest overrides remain available for controlled comparisons.
enum WindowsVRTranslationEnvironment {
    static let defaults: [String: String] = [
        "FEX_MULTIBLOCK": "1",
        // A compilation-size candidate; validate against the upstream 5000 default.
        "FEX_MAXINST": "512",
        "FEX_SILENTLOG": "1",
        // The packaged FEX loader and prelaunch compiler implement eager reuse.
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
