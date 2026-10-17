// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 WineVision VR contributors

import Foundation
import os

/// Registers the bundled OpenXR runtime in the Wine prefix registry for games Steam starts.
///
/// The runtime plugin points a game at its OpenXR runtime with the XR_RUNTIME_JSON environment variable.
/// A game that Steam launches inside the dock session reports "failed to find active runtime file in
/// registry" from the OpenXR loader, so the variable does not reach it and the game never starts VR.
/// The loader also reads HKLM\Software\Khronos\OpenXR\1\ActiveRuntime, which is not affected by how a
/// process environment is built. The registry value must outlive the plugin's per-launch runtime folder,
/// so it names a stable `windows-vr-runtime\active\<architecture>` folder refreshed on every launch.
/// The 32-bit loader reads the Wow6432Node registry view; 64-bit registration is preserved separately.
enum OpenXRRegistration {
    private static let log = Logger(subsystem: "org.avpplay.windows-vr", category: "openxr-registry")
    enum Architecture: String {
        case x86, x64, arm64ec

        var sectionName: String {
            self == .x86 ? #"Software\\Wow6432Node\\Khronos\\OpenXR\\1"# : #"Software\\Khronos\\OpenXR\\1"#
        }
        var guestFolder: String { "C:\\windows-vr-runtime\\active\\" + rawValue }
        var clientName: String { self == .x86 ? "vrclient.dll" : "vrclient_x64.dll" }
    }

    /// Select the plugin's native 64-bit guest package without accepting arbitrary paths.
    static func install(prefix: URL, architecture: String) throws {
        guard let architecture = Architecture(rawValue: architecture) else {
            throw RegistrationFailure.runtimeMissing
        }
        try install(prefix: prefix, architecture: architecture)
    }

    /// Call before the runtime starts: the registry file is only read when the Wine server starts.
    static func install(prefix: URL, architecture: Architecture = .x64) throws {
        guard wineserver_is_running() == 0, wine_process_is_running() == 0 else {
            throw RegistrationFailure.runtimeActive
        }
        removeStaleRuntimeSessions(prefix: prefix)
        // The runtime appends its call trace here; start each launch with an empty one.
        try? FileManager.default.removeItem(at: prefix.appendingPathComponent("drive_c/windows-vr-runtime/openxr-trace.txt"))
        do {
            try refreshActiveFolder(prefix: prefix, architecture: architecture)
            try registerActiveRuntime(prefix: prefix, architecture: architecture)
            try registerOpenVRRuntime(prefix: prefix, architecture: architecture)
        } catch {
            log.error("OpenXR registration failed: \(String(describing: error))")
            throw error
        }
    }

    /// The plugin makes one private folder per launch under `windows-vr-runtime` and removes it when the guest
    /// ends cleanly. A run that is killed leaves its folder behind, and they accumulate in the prefix. Nothing
    /// is running here (checked by the caller), so every folder except the stable `active` one is stale.
    private static func removeStaleRuntimeSessions(prefix: URL) {
        let fm = FileManager.default
        let parent = prefix.appendingPathComponent("drive_c/windows-vr-runtime", isDirectory: true)
        guard let entries = try? fm.contentsOfDirectory(at: parent, includingPropertiesForKeys: [.isDirectoryKey]) else { return }
        var removed = 0
        for entry in entries where entry.lastPathComponent != "active" {
            guard (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
                  UUID(uuidString: entry.lastPathComponent) != nil else { continue }
            if (try? fm.removeItem(at: entry)) != nil { removed += 1 }
        }
        if removed > 0 { log.notice("Removed \(removed) stale guest runtime folders") }
    }

    private static func refreshActiveFolder(prefix: URL, architecture: Architecture) throws {
        let fm = FileManager.default
        guard let resources = Bundle.main.resourceURL else { throw RegistrationFailure.runtimeMissing }
        let runtimeDLL = resources.appendingPathComponent("WindowsVR/Guest/\(architecture.rawValue)/wvr_openxr.dll")
        guard fm.fileExists(atPath: runtimeDLL.path) else {
            throw RegistrationFailure.runtimeMissing
        }
        let folder = prefix.appendingPathComponent("drive_c/windows-vr-runtime/active/\(architecture.rawValue)", isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let link = folder.appendingPathComponent("wvr_openxr.dll")
        // The app container path changes on reinstall, so always point the link at this bundle.
        try? fm.removeItem(at: link)
        try fm.createSymbolicLink(at: link, withDestinationURL: runtimeDLL)
        let composite = resources.appendingPathComponent("WindowsVR/Guest/\(architecture.rawValue)/OpenComposite", isDirectory: true)
        guard fm.fileExists(atPath: composite.appendingPathComponent("bin/" + architecture.clientName).path) else {
            throw RegistrationFailure.runtimeMissing
        }
        let compositeLink = folder.appendingPathComponent("OpenComposite")
        try? fm.removeItem(at: compositeLink)
        try fm.createSymbolicLink(at: compositeLink, withDestinationURL: composite)
        let manifest: [String: Any] = [
            "file_format_version": "1.0.0",
            "runtime": [
                "name": "WineVision VR Runtime",
                "library_path": architecture.guestFolder + "\\wvr_openxr.dll",
                "functions": ["xrNegotiateLoaderRuntimeInterface": "xrNegotiateLoaderRuntimeInterface"],
            ] as [String: Any],
        ]
        let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted])
        try data.write(to: folder.appendingPathComponent("runtime.json"), options: .atomic)
    }

    private static func registerActiveRuntime(prefix: URL, architecture: Architecture) throws {
        let sectionName = architecture.sectionName
        let manifestGuestPath = architecture.guestFolder + "\\runtime.json"
        let registry = prefix.appendingPathComponent("system.reg")
        guard var text = try? String(contentsOf: registry, encoding: .utf8) else {
            throw RegistrationFailure.registryMissing
        }
        let value = "\"ActiveRuntime\"=\"" + manifestGuestPath.replacingOccurrences(of: "\\", with: "\\\\") + "\""
        let backup = prefix.appendingPathComponent("system.reg.before-openxr")
        if !FileManager.default.fileExists(atPath: backup.path) { try? text.write(to: backup, atomically: true, encoding: .utf8) }

        // Update only this architecture's registry view.
        var lines = text.components(separatedBy: "\n")
        if let start = lines.firstIndex(where: { $0.hasPrefix("[\(sectionName)]") }) {
            var end = start + 1
            while end < lines.count, !lines[end].hasPrefix("[") { end += 1 }
            if lines[start..<end].contains(value) { return }
            lines.removeSubrange(start..<end)
        }
        let now = Int(Date().timeIntervalSince1970)
        let fileTime = (UInt64(now) + 11_644_473_600) * 10_000_000
        let section = ["[\(sectionName)] \(now)", "#time=\(String(fileTime, radix: 16))", value, ""]
        let anchor = lines.firstIndex(where: { $0.hasPrefix(#"[Software\\Khronos\\Vulkan\\Drivers]"#) }) ?? lines.count
        lines.insert(contentsOf: section, at: anchor)
        text = lines.joined(separator: "\n")
        try text.write(to: registry, atomically: true, encoding: .utf8)
        log.notice("Registered the OpenXR runtime in the prefix registry")
    }

    /// Unity's OpenVR loader reads the user's path registry even when Steam
    /// does not inherit VR_OVERRIDE. Register the same stable bundled bridge.
    private static func registerOpenVRRuntime(prefix: URL, architecture: Architecture) throws {
        let fm = FileManager.default
        let users = prefix.appendingPathComponent("drive_c/users", isDirectory: true)
        let profiles = try fm.contentsOfDirectory(at: users, includingPropertiesForKeys: [.isDirectoryKey])
        for profile in profiles {
            let local = profile.appendingPathComponent("AppData/Local", isDirectory: true)
            guard fm.fileExists(atPath: local.path) else { continue }
            let folder = local.appendingPathComponent("openvr", isDirectory: true)
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            let registry = folder.appendingPathComponent("openvrpaths.vrpath")
            var contents: [String: Any] = [:]
            if let data = try? Data(contentsOf: registry), let existing = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                contents = existing
            }
            let windowsFolder = "C:\\users\\"+profile.lastPathComponent+"\\AppData\\Local\\openvr"
            contents["jsonid"] = "vrpathreg"
            contents["version"] = 1
            contents["runtime"] = [architecture.guestFolder + "\\OpenComposite"]
            // Keep configured driver/config/log paths; supply valid defaults for a fresh prefix.
            if (contents["config"] as? [String])?.isEmpty != false { contents["config"] = [windowsFolder+"\\config"] }
            if (contents["log"] as? [String])?.isEmpty != false { contents["log"] = [windowsFolder+"\\logs"] }
            for name in ["config", "logs"] { try fm.createDirectory(at: folder.appendingPathComponent(name), withIntermediateDirectories: true) }
            let data = try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: registry, options: .atomic)
        }
        log.notice("Registered the bundled OpenVR runtime in the prefix user profiles")
    }

    private enum RegistrationFailure: LocalizedError {
        case runtimeActive, runtimeMissing, registryMissing
        var errorDescription: String? {
            switch self {
            case .runtimeActive: "Restart the app before updating the OpenXR runtime registration."
            case .runtimeMissing: "The bundled OpenXR runtime DLL is missing. Reinstall a complete build."
            case .registryMissing: "The Steam Wine prefix registry is missing or unreadable. Prepare the Valve client before launching."
            }
        }
    }
}
