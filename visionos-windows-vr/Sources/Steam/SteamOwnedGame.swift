// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 Jfishin, 125hz
// Madeira Converter Exception: see LICENSE-EXCEPTION.md
//
// Adapted from SteamOwnedLibrary.swift at upstream commit
// 48f976429c189f8396e23d251d8a82f43c705922; see third-party/steam-native.

import Foundation

struct SteamOwnedGame: Codable, Identifiable, Hashable, Sendable {
    var id: Int
    var name: String
    var installDir: String
    var buildID: Int
    var libraryCapsule: String?
    var libraryHero: String?
    var headerImage: String?
    var parentID: Int?
    var launches: [SteamLaunchOption]?
    var downloadBytes: UInt64?
    var installedBytes: UInt64?

    init(_ info: SteamAppInfo) {
        id = Int(info.appID)
        name = info.name
        installDir = info.installDir
        buildID = Int(info.buildID)
        libraryCapsule = info.libraryCapsule
        libraryHero = info.libraryHero
        headerImage = info.headerImage
        parentID = info.parentID.map(Int.init)
        launches = info.launches
        let sizes = info.installSizeEstimates()
        downloadBytes = sizes.download
        installedBytes = sizes.installed
    }

    var folderName: String {
        SteamInstallFiles.safeFolderName(installDir.isEmpty ? "app_\(id)" : installDir)
    }
}
