// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 WineVision VR contributors

import Foundation

/// Resolves Steam's Windows-style executable names on a case-sensitive volume.
/// A case-insensitive fallback must identify exactly one directory entry at
/// every component; links may never escape the selected installation.
enum SteamInstalledExecutable {
    static func resolve(_ relativePath: String, game: DockGame, drive: URL) -> URL? {
        guard let pathComponents = components(relativePath),
              let library = components(game.library), let installation = components(game.installDir) else { return nil }
        let manager = FileManager.default
        let drive = drive.resolvingSymlinksInPath().standardizedFileURL
        let folder = (library + ["common"] + installation).reduce(drive) {
            $0.appendingPathComponent($1, isDirectory: true)
        }.resolvingSymlinksInPath().standardizedFileURL
        guard contained(folder, in: drive),
              (try? folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { return nil }

        let exact = pathComponents.reduce(folder) { $0.appendingPathComponent($1) }
            .resolvingSymlinksInPath().standardizedFileURL
        if contained(exact, in: folder),
           (try? exact.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
            var prefix = folder
            for component in pathComponents {
                prefix = prefix.appendingPathComponent(component).resolvingSymlinksInPath().standardizedFileURL
                guard contained(prefix, in: folder) else { return nil }
            }
            return exact
        }

        var current = folder
        for (index, component) in pathComponents.enumerated() {
            guard let entries = try? manager.contentsOfDirectory(at: current, includingPropertiesForKeys: nil) else { return nil }
            guard let match = uniqueCaseInsensitiveMatch(component, entries: entries) else { return nil }
            let resolved = match.resolvingSymlinksInPath().standardizedFileURL
            guard contained(resolved, in: folder) else { return nil }
            let last = index == pathComponents.count - 1
            guard let values = try? resolved.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey]),
                  last ? values.isRegularFile == true : values.isDirectory == true else { return nil }
            current = resolved
        }
        return current
    }

    /// Separate name matching from disk access so ambiguity is deterministic
    /// even when a host filesystem cannot store two case variants.
    static func uniqueCaseInsensitiveMatch(_ name: String, entries: [URL]) -> URL? {
        let matches = entries.filter { $0.lastPathComponent.caseInsensitiveCompare(name) == .orderedSame }
        return matches.count == 1 ? matches[0] : nil
    }

    private static func components(_ path: String) -> [String]? {
        let normalized = path.replacingOccurrences(of: "\\", with: "/")
        guard !normalized.isEmpty, !normalized.hasPrefix("/"), !normalized.contains(":"),
              !normalized.utf8.contains(0) else { return nil }
        let parts = normalized.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.allSatisfy({ !$0.isEmpty && $0 != ".." }) else { return nil }
        let names = parts.filter { $0 != "." }
        return names.isEmpty ? nil : names
    }

    private static func contained(_ url: URL, in root: URL) -> Bool {
        url.path.hasPrefix(root.path == "/" ? "/" : root.path + "/")
    }
}
