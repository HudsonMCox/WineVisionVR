// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 WineVision VR contributors

import Foundation

/// Reads an app's launch options from the Steam client's own product-info cache
/// (`appcache/appinfo.vdf`, binary format version 41) inside the Wine prefix.
///
/// The library model only has launch options after it has signed in and fetched
/// the library from the network. Restoring a saved game happens before that, and
/// Steam lists every platform's and build type's entry (Moss II VR lists a Test
/// build at index 0 that is not installed), so a restored selection needs the
/// options offline. The file is a local cache written by Valve's client; sizes
/// are bounded and any malformed input returns nil.
enum SteamLocalAppInfo {
    private static let magic41: UInt32 = 0x0756_4429
    private static let maxFileBytes = 64 << 20
    private static let maxDepth = 16

    /// The launch options of `appID`, or nil when the cache is missing, another version, or unreadable.
    static func launchOptions(appID: Int, game: DockGame, drive: URL) -> [SteamLaunchOption]? {
        let steamFolder = (game.library as NSString).deletingLastPathComponent
        let url = drive.appendingPathComponent(steamFolder, isDirectory: true)
            .appendingPathComponent("appcache/appinfo.vdf")
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? Int, size > 32, size <= maxFileBytes,
              let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        return launchOptions(appID: appID, appInfo: data)
    }

    /// Parser entry point on raw file bytes (host-testable).
    static func launchOptions(appID: Int, appInfo data: Data) -> [SteamLaunchOption]? {
        var reader = Reader(data: data)
        guard reader.u32(at: 0) == magic41, let tableOffset = reader.u64(at: 8),
              tableOffset < UInt64(data.count), let table = readStringTable(&reader, at: Int(tableOffset)) else { return nil }
        var position = 16
        while let id = reader.u32(at: position), let size = reader.u32(at: position + 4), id != 0 {
            let end = position + 8 + Int(size)
            guard Int(size) >= 60, end <= data.count else { return nil }
            if Int(id) == appID {
                // 60 bytes of record header (state, time, token, two SHA-1 hashes, change number) precede the KV data.
                var cursor = position + 8 + 60
                guard let root = parseDictionary(&reader, cursor: &cursor, end: end, table: table, depth: 0),
                      let appinfo = root["appinfo"] as? [String: Any],
                      let config = appinfo["config"] as? [String: Any],
                      let launch = config["launch"] as? [String: Any] else { return nil }
                return SteamLaunchOption.parse(launch)
            }
            position = end
        }
        return nil
    }

    /// First Windows option, VR types first, whose program exists in the install folder.
    static func installedOption(appID: Int, game: DockGame, drive: URL) -> SteamLaunchOption? {
        guard let options = launchOptions(appID: appID, game: game, drive: drive) else { return nil }
        return SteamLibraryModel.preferredLaunchOption(options, game: game, drive: drive)
    }

    // MARK: Binary key-value parsing

    private struct Reader {
        let data: Data
        func u32(at offset: Int) -> UInt32? {
            guard offset >= 0, offset + 4 <= data.count else { return nil }
            return data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self) }.littleEndian
        }
        func u64(at offset: Int) -> UInt64? {
            guard offset >= 0, offset + 8 <= data.count else { return nil }
            return data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt64.self) }.littleEndian
        }
        func byte(at offset: Int) -> UInt8? { offset >= 0 && offset < data.count ? data[data.startIndex + offset] : nil }
        func cString(at offset: Int, end: Int) -> (String, Int)? {
            guard offset >= 0, offset < end, end <= data.count else { return nil }
            var cursor = offset
            while cursor < end, data[data.startIndex + cursor] != 0 { cursor += 1 }
            guard cursor < end else { return nil }
            let bytes = data[(data.startIndex + offset)..<(data.startIndex + cursor)]
            return (String(decoding: bytes, as: UTF8.self), cursor + 1)
        }
    }

    private static func readStringTable(_ reader: inout Reader, at offset: Int) -> [String]? {
        guard let count = reader.u32(at: offset), count < 200_000 else { return nil }
        var strings: [String] = []
        strings.reserveCapacity(Int(count))
        var cursor = offset + 4
        for _ in 0..<Int(count) {
            guard let (string, next) = reader.cString(at: cursor, end: reader.data.count) else { return nil }
            strings.append(string)
            cursor = next
        }
        return strings
    }

    private static func parseDictionary(_ reader: inout Reader, cursor: inout Int, end: Int,
                                        table: [String], depth: Int) -> [String: Any]? {
        guard depth < maxDepth else { return nil }
        var result: [String: Any] = [:]
        while true {
            guard let type = reader.byte(at: cursor), cursor < end else { return nil }
            cursor += 1
            if type == 8 { return result }
            guard let keyIndex = reader.u32(at: cursor), Int(keyIndex) < table.count else { return nil }
            cursor += 4
            let key = table[Int(keyIndex)]
            switch type {
            case 0: // nested dictionary
                guard let nested = parseDictionary(&reader, cursor: &cursor, end: end, table: table, depth: depth + 1) else { return nil }
                result[key] = nested
            case 1: // string
                guard let (value, next) = reader.cString(at: cursor, end: end) else { return nil }
                result[key] = value; cursor = next
            case 2, 3, 4, 6: // int32 / float / pointer / color: 4 bytes
                guard let value = reader.u32(at: cursor) else { return nil }
                result[key] = Int(Int32(bitPattern: value)); cursor += 4
            case 7, 10: // uint64 / int64
                guard let value = reader.u64(at: cursor) else { return nil }
                result[key] = value; cursor += 8
            default:
                return nil
            }
        }
    }
}
