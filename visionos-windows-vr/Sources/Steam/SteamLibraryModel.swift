// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 WineVision VR contributors
// Adapted from SwiftSteam at 48f976429c189f8396e23d251d8a82f43c705922.
// See third-party/steam-native/COPYING and LICENSE-EXCEPTION.md.

import Foundation
import SwiftUI

struct SteamLibraryEntry: Identifiable, Sendable {
    let game: SteamOwnedGame
    var id: Int { game.id }
}

@MainActor
final class SteamLibraryModel: ObservableObject {
    static let shared = SteamLibraryModel()

    @Published private(set) var signedIn = SteamSignIn.isSignedIn
    @Published private(set) var accountName = SteamSignIn.accountName
    @Published private(set) var games: [SteamLibraryEntry] = []
    @Published private(set) var isLoadingLibrary = false
    @Published private(set) var installedIDs: Set<Int> = []
    @Published private(set) var progress: [Int: SteamDownloadProgress] = [:]
    @Published private(set) var activeDownloads: Set<Int> = []
    @Published private(set) var pausedDownloads: Set<Int> = []
    @Published private(set) var downloadErrors: [Int: String] = [:]
    @Published private(set) var isPreparingValveClient = false
    @Published private(set) var valveClientPreparationStatus: String?
    /// Set by the app while a Wine/runtime launch or accepted session is active.
    @Published var runtimeBusy = false
    @Published var error: String?

    /// The app launcher receives a validated installed record after the CM
    /// session has logged off and its socket has closed.
    var onPlaySelected: ((DockGame, UInt32) -> Void)?

    private let session = SteamSession()
    private lazy var fetcher = SteamLibraryFetcher(session: session)
    private lazy var downloader = DepotDownloader(session: session)
    private var downloadTasks: [Int: Task<Void, Never>] = [:]
    private var sessionReservedForLaunch = false
    private var accountGeneration = 0
    private var signInObserver: NSObjectProtocol?

    private init() {
        signInObserver = NotificationCenter.default.addObserver(
            forName: SteamSignIn.didChange, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.signInStateChanged() }
        }
        refreshInstalled()
        if signedIn { Task { await connectAndLoad() } }
    }

    func refreshInstalled() {
        let records = MadeiraDock.games(drive: MadeiraDock.drive)
        installedIDs = Set(records.filter(\.installed).map(\.id))
    }

    func refreshLibrary() async {
        guard signedIn else { return }
        await connectAndLoad()
    }

    private func signInStateChanged() async {
        accountGeneration &+= 1
        signedIn = SteamSignIn.isSignedIn
        accountName = SteamSignIn.accountName
        if signedIn {
            await connectAndLoad()
        } else {
            await stopConnectionAndDownloads()
            games = []
            installedIDs = []
            progress = [:]
            activeDownloads = []
            pausedDownloads = []
            downloadErrors = [:]
        }
    }

    private func connectAndLoad() async {
        guard !sessionReservedForLaunch, !runtimeBusy else { return }
        guard !isLoadingLibrary else { return }
        isLoadingLibrary = true
        defer { isLoadingLibrary = false }
        let generation = accountGeneration
        let account = SteamSignIn.accountName
        guard signedIn, account != nil else { return }
        do {
            try await session.connectAndLogin()
            let result = try await fetcher.fetchOwnedApps()
            guard generation == accountGeneration, signedIn,
                  account == SteamSignIn.accountName, !sessionReservedForLaunch else { return }
            games = result.map { SteamLibraryEntry(game: SteamOwnedGame($0)) }
                .sorted { $0.game.name.localizedCaseInsensitiveCompare($1.game.name) == .orderedAscending }
            refreshInstalled()
            error = nil
        } catch {
            if generation == accountGeneration, signedIn { self.error = SteamSignIn.message(error) }
        }
    }

    func download(_ entry: SteamLibraryEntry) {
        guard signedIn, !runtimeBusy, !sessionReservedForLaunch, downloadTasks[entry.id] == nil else { return }
        guard downloadTasks.isEmpty else {
            error = "Pause or finish the current download before starting another."
            return
        }
        let appID = entry.id
        downloadErrors.removeValue(forKey: appID)
        error = nil
        activeDownloads.insert(appID)
        pausedDownloads.remove(appID)
        let task = Task { @MainActor in
            do {
                try await session.ensureConnected()
                guard let app = try await fetcher.fetchInstallInfo(appID: UInt32(appID)) else {
                    throw SteamError.depotNotFound(UInt32(appID))
                }
                let ownedDepots = try await fetcher.ownedDepotIDs()
                _ = try await downloader.install(app, steamApps: SteamInstallPaths.steamApps(drive: MadeiraDock.drive),
                    ownedDepots: { ownedDepots }) { [weak self] value in
                        Task { @MainActor in self?.progress[appID] = value }
                    }
                refreshInstalled()
                error = nil
            } catch is CancellationError {
                if pausedDownloads.contains(appID) { pausedDownloads.insert(appID) }
            } catch {
                let message = SteamSignIn.message(error)
                downloadErrors[appID] = message
                self.error = message
            }
            activeDownloads.remove(appID)
            if !pausedDownloads.contains(appID) { pausedDownloads.remove(appID) }
            if downloadErrors[appID] == nil && !pausedDownloads.contains(appID) {
                progress.removeValue(forKey: appID)
            }
            downloadTasks.removeValue(forKey: appID)
        }
        downloadTasks[appID] = task
    }

    func pause(_ id: Int) {
        guard let task = downloadTasks[id] else { return }
        pausedDownloads.insert(id)
        task.cancel()
    }

    func resume(_ entry: SteamLibraryEntry) { download(entry) }

    func prepareValveClient() async {
        guard !isPreparingValveClient, !runtimeBusy else { return }
        let preserveLaunchReservation = sessionReservedForLaunch
        isPreparingValveClient = true
        sessionReservedForLaunch = true
        defer { isPreparingValveClient = false }
        let generation = accountGeneration
        let restartIDs = activeDownloads
        for id in restartIDs { pausedDownloads.insert(id) }
        let tasks = Array(downloadTasks.values)
        tasks.forEach { $0.cancel() }
        for task in tasks { await task.value }
        downloadTasks.removeAll()

        // The prefix seeder must not race a native Steam install creating its
        // first steamapps directory. Keep the account disconnected throughout.
        await session.suspend()
        if runtimeBusy {
            error = "Close the active game session before preparing the Valve client."
        } else {
            do {
                try await SteamRuntimeInstaller.shared.prepare(prefix: MadeiraDock.prefix) { [weak self] stage in
                    await MainActor.run { self?.valveClientPreparationStatus = stage }
                }
                valveClientPreparationStatus = nil
                error = nil
            } catch {
                valveClientPreparationStatus = nil
                self.error = error.localizedDescription
            }
        }
        sessionReservedForLaunch = preserveLaunchReservation
        if generation == accountGeneration, signedIn, !runtimeBusy, !preserveLaunchReservation {
            session.resume()
            await connectAndLoad()
            for id in restartIDs {
                if let entry = games.first(where: { $0.id == id }) { download(entry) }
            }
        }
    }

    /// Whether the program a launch option names is really in the game's install folder.
    /// Steam lists every platform's and build type's entry (Moss II VR has a Test build at option 0
    /// that is not installed), and starting a missing program fails with Steam's "could not find
    /// the game's executable" refusal.
    nonisolated static func isInstalled(_ option: SteamLaunchOption, game: DockGame, drive: URL) -> Bool {
        let relative = option.executable.replacingOccurrences(of: "\\", with: "/")
        guard !relative.isEmpty, !relative.hasPrefix("/"), !relative.contains("..") else { return false }
        let folder = drive.appendingPathComponent(game.library + "/common/" + game.installDir, isDirectory: true)
        return FileManager.default.fileExists(atPath: folder.appendingPathComponent(relative).path)
    }

    /// The launch option to start by default: Windows entries whose program is installed, VR
    /// types first. Falls back to the first entry when nothing can be checked.
    nonisolated static func preferredLaunchOption(_ options: [SteamLaunchOption], game: DockGame, drive: URL) -> SteamLaunchOption? {
        let windows = options.filter { $0.oslist.isEmpty || $0.oslist.lowercased().contains("windows") }
        let present = windows.filter { isInstalled($0, game: game, drive: drive) }
        return present.first(where: { ["vr", "othervr"].contains($0.type.lowercased()) })
            ?? present.first(where: { $0.type.isEmpty || $0.type == "default" })
            ?? present.first
    }

    func play(_ entry: SteamLibraryEntry, launchOption: UInt32? = nil) async {
        guard !runtimeBusy, signedIn else { return }
        guard !activeDownloads.contains(entry.id),
              !DepotDownloader.hasPartialDownload(appID: UInt32(entry.id), steamApps: SteamInstallPaths.steamApps(drive: MadeiraDock.drive)) else {
            error = "Finish or resume this game's download before selecting it to play."
            return
        }
        await prepareForLaunch()
        refreshInstalled()
        guard let game = MadeiraDock.games(drive: MadeiraDock.drive).first(where: { $0.id == entry.id }) else {
            error = "Steam has not finished installing this game yet."
            resumeAfterLaunchFailure()
            return
        }
        do {
            try MadeiraDock.validate(game, drive: MadeiraDock.drive)
            error = nil
            let options = entry.game.launches ?? []
            let preferred = Self.preferredLaunchOption(options, game: game, drive: MadeiraDock.drive)
                ?? options.first(where: { ["vr", "othervr"].contains($0.type.lowercased()) })
                ?? options.first(where: { $0.type.isEmpty || $0.type == "default" })
                ?? options.first
            guard let onPlaySelected else {
                error = "The WineVision VR launcher is not ready yet."
                resumeAfterLaunchFailure()
                return
            }
            onPlaySelected(game, launchOption ?? preferred?.index ?? 0)
        } catch {
            self.error = error.localizedDescription
            resumeAfterLaunchFailure()
        }
    }

    func signOut() async {
        accountGeneration &+= 1
        signedIn = false
        accountName = nil
        await stopConnectionAndDownloads()
        games = []
        installedIDs = []
        progress = [:]
        activeDownloads = []
        pausedDownloads = []
        downloadErrors = [:]
        SteamSignIn.signOut()
        signedIn = false
        accountName = nil
    }

    /// Releases the authenticated Steam connection before WineVision VR starts its
    /// Wine session. Keep it suspended until the caller has completed the game
    /// session; Steam must not log this account on from both clients at once.
    func prepareForLaunch() async {
        sessionReservedForLaunch = true
        await stopConnectionAndDownloads()
    }

    /// Called by the launcher when preflight or JIT setup fails before a
    /// session is accepted, so the native Steam library can reconnect.
    func resumeAfterLaunchFailure() {
        sessionReservedForLaunch = false
        session.resume()
        if signedIn { Task { await connectAndLoad() } }
    }

    private func stopConnectionAndDownloads() async {
        let tasks = Array(downloadTasks.values)
        tasks.forEach { $0.cancel() }
        for task in tasks { await task.value }
        downloadTasks.removeAll()
        await session.suspend()
    }
}
