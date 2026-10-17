import Foundation
import CryptoKit
import AVFAudio
import Observation
import Metal
import QuartzCore
import UIKit
import Darwin
import MachO
import WindowsVRCore
import os

private let launchLog = LaunchLog()

/// Logs where the app's own images and the system libraries are loaded, so a return
/// address from the JIT debugger's fault backtrace can be mapped to a library.
private func logImageBases() {
    let interesting = ["WindowsRuntimePlugin", "WindowsVRLaunchAdapter", "WindowsVRNativeBridge", "WineVision VR", "libsystem_platform",
                       "libsystem_c.dylib", "libsystem_pthread", "libsystem_kernel", "libsystem_malloc",
                       "libc++.1", "libobjc", "CoreFoundation", "libdispatch"]
    for index in 0..<_dyld_image_count() {
        guard let namePointer = _dyld_get_image_name(index), let header = _dyld_get_image_header(index) else { continue }
        let name = String(cString: namePointer)
        guard interesting.contains(where: { name.contains($0) }) else { continue }
        launchLog.notice("image 0x\(String(UInt(bitPattern: header), radix: 16)) \(name)")
    }
}

struct TransferredWindowsVRGame: Identifiable {
    let id: String
    let manifest: WindowsGameManifest
    let directory: URL
}

/// Shader warm-up state written by DXMT as `<root>/warmup-progress` ("done total" or "done total complete").
struct ShaderWarmupProgress: Equatable {
    let done: Int
    let total: Int
    let complete: Bool
}

@MainActor
@Observable
final class LauncherModel {
    private(set) var manifest: WindowsGameManifest?
    private(set) var manifestName: String?
    private(set) var gameDirectory: URL?
    private(set) var gameFolderName: String?
    private(set) var isLaunching = false
    private(set) var hasAcceptedLaunch = false
    private(set) var isStopping = false
    private(set) var stopRequested = false
    private(set) var requiresRestart = false
    private(set) var runtimeStatus = L("No runtime session", "Keine Laufzeitsitzung")
    private(set) var launchError: String?
    private(set) var library: [WindowsVRLibraryEntry] = []
    private(set) var selectedLibraryEntryID: String?
    private(set) var selectedProfileID: String?
    private(set) var compositorCounters: WindowsVRCompositorCounters?
    private(set) var libraryError: String?
    private(set) var transferredGames: [TransferredWindowsVRGame] = []
    private var steamSelection: (game: DockGame, option: UInt32)?
    private(set) var transferImportError: String?
    var renderScaleDraft: Float = 1
    var presentationModeDraft: WindowsPresentationMode = .immersiveVR
    private(set) var desktopPresentationVisible = false
    private(set) var desktopSurfaceReady = false
    var profileNameDraft = L("Default", "Standard")
    var launchArgumentsText = "[]"
    var isShowingImportError = false
    private(set) var importError: String?

    @ObservationIgnored private let runtime = NativePluginWindowsRuntime(frameworkName: Bundle.main.object(forInfoDictionaryKey: "WVRRuntimePluginFramework") as? String ?? "WindowsRuntimePlugin.framework")
    @ObservationIgnored private let jitCoordinator = JITCoordinator()
    @ObservationIgnored private var sessionDiagnostics: SessionDiagnostics?
    private var diagnosticsFailureReason: String?
    private var diagnosticsAttemptActive = false
    private var diagnosticsNativeState: Int32?
    private var gameDirectoryAccessURL: URL?
    private var immersiveSpaceIsOpen = false
    private var immersiveSpaceClosedDuringLaunch = false
    private var statusMonitor: Task<Void, Never>?
    private var warmupMonitor: Task<Void, Never>?
    /// Non-nil while DXMT is still preparing shaders for the running game; drives the warm-up ornament.
    private(set) var shaderWarmup: ShaderWarmupProgress?
    private var compilerFailureHandled = false

    init() {
        // Recover the previous attempt before cleanup or a new launch can
        // rotate its global runtime log.
        if let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            do {
                let diagnostics = try SessionDiagnostics(documentsDirectory: documents)
                try diagnostics.recoverPendingAttempt()
                sessionDiagnostics = diagnostics
            } catch {
                launchLog.error("Test session recovery failed: \(error.localizedDescription)")
            }
        }
        MadeiraDock.cleanup()
        do {
            library = try WindowsVRLibraryStore.load()
        } catch {
            libraryError = error.localizedDescription
        }
        let lastSteamApp = UserDefaults.standard.integer(forKey: Self.lastSteamAppKey)
        if lastSteamApp > 0 { try? selectInstalledSteamGame(appID: lastSteamApp) }
    }

    var selectedSteamAppID: Int? { steamSelection?.game.id }

    var canLaunch: Bool {
        guard manifest != nil, gameDirectory != nil,
              !isLaunching, !hasAcceptedLaunch, !isStopping, !requiresRestart,
              runtime.isAvailable,
              manifest.map({ runtime.supportsGraphics($0.graphics) }) == true,
              runtime.supportsPresentation(presentationModeDraft),
              manifest?.backend == .windowsWineFEX
        else { return false }
        let arguments = draftArguments
        return arguments.count <= 64 && arguments.allSatisfy { !$0.contains("\0") }
    }

    var launchUnavailableReason: String? {
        guard let manifest else { return L("Import a Windows VR manifest and select a game folder.", "Importiere ein Windows-VR-Manifest und wähle einen Spielordner aus.") }
        guard gameDirectory != nil else { return L("Select the folder containing the game before launching.", "Wähle vor dem Start den Ordner mit dem Spiel aus.") }
        if manifest.backend != .windowsWineFEX {
            return L("This app packages the x64 Wine/FEX runtime only. A native ARM64/ARM64EC Windows VR package is not embedded.", "Diese App enthält nur die x64-Wine/FEX-Laufzeit. Ein natives ARM64/ARM64EC-Windows-VR-Paket ist nicht eingebettet.")
        }
        if manifest.graphics == .vulkan {
            return L("Vulkan is not implemented by this runtime adapter. The request is blocked; no graphics fallback will be selected.", "Vulkan wird von diesem Laufzeitadapter nicht unterstützt. Die Anfrage wird blockiert; es wird kein Grafikmodus als Ersatz gewählt.")
        }
        if !runtime.isAvailable {
            return L("The signed WindowsRuntimePlugin.framework is unavailable. Launch is blocked; no placeholder backend will run.", "Das signierte WindowsRuntimePlugin.framework ist nicht verfügbar. Der Start wird blockiert; es wird kein Platzhalter-Backend ausgeführt.")
        }
        if !runtime.supportsGraphics(manifest.graphics) {
            return L("The app does not contain the matching experimental DXMT D3D12 runtime package. D3D11 is not substituted for a D3D12 request.", "Das passende experimentelle DXMT-D3D12-Laufzeitpaket ist nicht in der App enthalten. Eine D3D12-Anfrage wird nicht durch D3D11 ersetzt.")
        }
        if !runtime.supportsPresentation(presentationModeDraft) {
            return WindowsRuntimeError.presentationUnavailable(presentationModeDraft).localizedDescription
        }
        if requiresRestart {
            return L("This process has consumed its single runtime session. Restart the app before another launch.", "Dieser Prozess hat seine einzige Laufzeitsitzung verwendet. Starte die App neu, bevor du ein weiteres Spiel startest.")
        }
        if isLaunching || hasAcceptedLaunch || isStopping {
            return L("A runtime session is active or changing state.", "Eine Laufzeitsitzung ist aktiv oder ändert gerade ihren Zustand.")
        }
        if draftArguments.count > 64 || draftArguments.contains(where: { $0.contains("\0") }) {
            return L("The profile arguments exceed the plugin limit or contain an invalid NUL character.", "Die Profilargumente überschreiten das Plugin-Limit oder enthalten ein ungültiges Nullzeichen.")
        }
        return nil
    }

    var canChangeSelection: Bool {
        !isLaunching && !hasAcceptedLaunch && !isStopping && !requiresRestart
    }

    var selectedEntry: WindowsVRLibraryEntry? {
        guard let selectedLibraryEntryID else { return nil }
        return library.first(where: { $0.id == selectedLibraryEntryID })
    }

    var selectedProfileName: String? {
        selectedEntry?.profiles.first(where: { $0.id == selectedProfileID })?.name
    }

    var sessionStatus: String {
        if isStopping { return L("Stopping", "Wird beendet") }
        if isLaunching { return L("Starting", "Wird gestartet") }
        if hasAcceptedLaunch { return runtimeStatus }
        if requiresRestart { return runtimeStatus }
        return L("Not running", "Nicht gestartet")
    }

    func importManifest(_ result: Result<[URL], Error>) {
        guard canChangeSelection else { return }
        steamSelection = nil
        MadeiraDock.cleanup()
        do {
            guard let url = try result.get().first else { return }
            guard url.startAccessingSecurityScopedResource() else {
                throw ImportFailure.manifestAccessDenied
            }
            defer { url.stopAccessingSecurityScopedResource() }
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
            guard size <= 1024 * 1024 else { throw WindowsVRLibraryError.corruptLibrary }
            let data = try Data(contentsOf: url)
            let decoded = try JSONDecoder().decode(WindowsGameManifest.self, from: data)
            try decoded.validate()
            manifest = decoded
            presentationModeDraft = decoded.presentation
            manifestName = url.lastPathComponent
            launchArgumentsText = Self.argumentText(decoded.launchArguments)
            selectedLibraryEntryID = nil
            selectedProfileID = nil
            renderScaleDraft = 1
            profileNameDraft = L("Default", "Standard")
            launchError = nil
        } catch {
            guard !isCancellation(error) else { return }
            showImportError(error)
        }
    }

    func importGameFolder(_ result: Result<[URL], Error>) {
        guard canChangeSelection else { return }
        do {
            guard let url = try result.get().first else { return }
            guard url.startAccessingSecurityScopedResource() else {
                throw ImportFailure.folderAccessDenied
            }
            do {
                let values = try url.resourceValues(forKeys: [.isDirectoryKey])
                guard values.isDirectory == true else { throw ImportFailure.folderAccessDenied }
            } catch {
                url.stopAccessingSecurityScopedResource()
                throw error
            }
            releaseGameDirectoryAccess()
            gameDirectoryAccessURL = url
            gameDirectory = url
            gameFolderName = url.lastPathComponent
            launchError = nil
        } catch {
            guard !isCancellation(error) else { return }
            showImportError(error)
        }
    }

    /// Discovers only app-container files copied by the Mac companion. External
    /// folders still require explicit import/bookmark access, never a broad scan.
    func refreshTransferredGames() {
        guard canChangeSelection else { return }
        transferredGames = []
        transferImportError = nil
        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let root = documents.appendingPathComponent("WindowsVR/Games", isDirectory: true)
        guard FileManager.default.fileExists(atPath: root.path) else { return }
        do {
            let fm = FileManager.default
            let gameFolders = try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            var candidates: [URL] = []
            for folder in gameFolders {
                let info = try folder.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard info.isDirectory == true, info.isSymbolicLink != true, isAppOwnedURL(folder) else { continue }
                // Accept both the original direct layout and immutable transfer
                // generations; incomplete transfers have no manifest marker.
                candidates.append(folder)
                candidates.append(contentsOf: try fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]))
            }
            for folder in candidates {
                let info = try folder.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard info.isDirectory == true, info.isSymbolicLink != true, isAppOwnedURL(folder) else { continue }
                let manifestURL = folder.appendingPathComponent("manifest.json")
                guard fm.fileExists(atPath: manifestURL.path), isAppOwnedURL(manifestURL) else { continue }
                let attributes = try fm.attributesOfItem(atPath: manifestURL.path)
                guard attributes[.type] as? FileAttributeType == .typeRegular,
                      ((attributes[.size] as? NSNumber)?.intValue ?? Int.max) <= 1024 * 1024 else { continue }
                do {
                    let decoded = try JSONDecoder().decode(WindowsGameManifest.self, from: Data(contentsOf: manifestURL))
                    try decoded.validate()
                    let executable = folder.appendingPathComponent(decoded.executableRelativePath.replacingOccurrences(of: String(decoding: [UInt8(92)], as: UTF8.self), with: "/")).resolvingSymlinksInPath()
                    let prefix = folder.resolvingSymlinksInPath().path + "/"
                    guard executable.path.hasPrefix(prefix),
                          try executable.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
                    transferredGames.append(.init(id: folder.path, manifest: decoded, directory: folder))
                } catch {
                    transferImportError = L("Some transferred manifests could not be imported: \(error.localizedDescription)", "Einige übertragene Manifeste konnten nicht importiert werden: \(error.localizedDescription)")
                }
            }
            transferredGames.sort { $0.manifest.title.localizedCaseInsensitiveCompare($1.manifest.title) == .orderedAscending }
        } catch {
            transferImportError = L("Transferred games could not be listed: \(error.localizedDescription)", "Die übertragenen Spiele konnten nicht aufgelistet werden: \(error.localizedDescription)")
        }
    }

    func selectTransferredGame(id: String) throws {
        guard canChangeSelection else { return }
        guard let game = transferredGames.first(where: { $0.id == id }), isAppOwnedURL(game.directory) else {
            throw WindowsVRLibraryError.noSavedGame
        }
        releaseGameDirectoryAccess()
        gameDirectory = game.directory
        gameFolderName = game.directory.lastPathComponent
        manifest = game.manifest
        presentationModeDraft = game.manifest.presentation
        manifestName = L("manifest.json — Mac transfer", "manifest.json — Mac-Übertragung")
        selectedLibraryEntryID = nil
        selectedProfileID = nil
        renderScaleDraft = 1
        profileNameDraft = L("Default", "Standard")
        launchArgumentsText = Self.argumentText(game.manifest.launchArguments)
        launchError = nil
    }

    private func isAppOwnedURL(_ url: URL) -> Bool {
        guard url.isFileURL,
              let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return false }
        let root = documents.resolvingSymlinksInPath().standardizedFileURL.path
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        return path.hasPrefix(root + "/")
    }

    func saveCurrentGameToLibrary() throws {
        guard canChangeSelection, let manifest, let gameDirectory else {
            throw WindowsVRLibraryError.noActiveGame
        }
        let bookmark = try WindowsVRLibraryStore.makeFolderBookmark(for: gameDirectory)
        let defaultProfile = try WindowsVRLaunchProfile(
            name: L("Default", "Standard"),
            backend: manifest.backend,
            graphics: manifest.graphics,
            launchArguments: draftArguments,
            environment: manifest.environment,
            renderScale: renderScaleDraft,
            presentation: presentationModeDraft
        )
        var updated = library
        if let index = updated.firstIndex(where: { $0.manifest.id == manifest.id }) {
            updated[index].manifest = manifest
            updated[index].folderBookmark = bookmark
            if updated[index].profiles.isEmpty {
                updated[index].profiles = [defaultProfile]
                updated[index].selectedProfileID = defaultProfile.id
            }
            updated[index].updatedAt = Date()
            selectedLibraryEntryID = updated[index].id
            selectedProfileID = updated[index].selectedProfileID
        } else {
            let entry = WindowsVRLibraryEntry(
                manifest: manifest,
                folderBookmark: bookmark,
                profiles: [defaultProfile],
                selectedProfileID: defaultProfile.id
            )
            updated.append(entry)
            selectedLibraryEntryID = entry.id
            selectedProfileID = defaultProfile.id
        }
        try persist(updated)
        profileNameDraft = selectedProfileName ?? L("Default", "Standard")
    }

    func selectLibraryEntry(id: String) throws {
        guard canChangeSelection else { return }
        guard let entry = library.first(where: { $0.id == id }) else {
            throw WindowsVRLibraryError.noSavedGame
        }
        let resolved = try WindowsVRLibraryStore.resolveFolderBookmark(entry.folderBookmark)
        let didStartAccess = resolved.url.startAccessingSecurityScopedResource()
        guard didStartAccess || isAppOwnedURL(resolved.url) else {
            throw WindowsVRLibraryError.invalidBookmark
        }
        do {
            let values = try resolved.url.resourceValues(forKeys: [.isDirectoryKey])
            guard values.isDirectory == true else { throw WindowsVRLibraryError.invalidBookmark }
            var updated = library
            if let index = updated.firstIndex(where: { $0.id == id }), resolved.isStale {
                updated[index].folderBookmark = try WindowsVRLibraryStore.makeFolderBookmark(for: resolved.url)
                updated[index].updatedAt = Date()
                try persist(updated)
            }
            releaseGameDirectoryAccess()
            gameDirectoryAccessURL = didStartAccess ? resolved.url : nil
            gameDirectory = resolved.url
            gameFolderName = resolved.url.lastPathComponent
            selectedLibraryEntryID = id
            manifestName = L("\(entry.manifest.title) — library", "\(entry.manifest.title) — Bibliothek")
            manifest = entry.manifest
            presentationModeDraft = entry.manifest.presentation
            let profile = entry.selectedProfile
            selectedProfileID = profile?.id
            if let profile {
                manifest = try profile.applying(to: entry.manifest)
                renderScaleDraft = profile.renderScale
                presentationModeDraft = profile.presentation
                profileNameDraft = profile.name
                launchArgumentsText = Self.argumentText(profile.launchArguments)
            } else {
                renderScaleDraft = 1
                profileNameDraft = L("Default", "Standard")
                launchArgumentsText = Self.argumentText(entry.manifest.launchArguments)
            }
            restoreSteamSelection(for: entry.manifest)
            launchError = nil
        } catch {
            if didStartAccess { resolved.url.stopAccessingSecurityScopedResource() }
            throw error
        }
    }

    private static let steamLaunchOptionsKey = "steam.launchOptionsByAppID"
    private static let lastSteamAppKey = "steam.lastSelectedAppID"

    private func rememberSteamLaunchOption(_ option: UInt32, for game: DockGame) {
        var options = UserDefaults.standard.dictionary(forKey: Self.steamLaunchOptionsKey) as? [String: Int] ?? [:]
        options[String(game.id)] = Int(option)
        UserDefaults.standard.set(options, forKey: Self.steamLaunchOptionsKey)
        UserDefaults.standard.set(game.id, forKey: Self.lastSteamAppKey)
    }

    /// A saved Steam library entry only stores a manifest (`steam.shared`, titled with the
    /// game's name); the chosen game and launch option lived in memory, so every app launch
    /// forced re-picking the game from the Steam list. Rebuild the selection from the
    /// installed games by name, and the launch option from the remembered per-game choice.
    private func restoreSteamSelection(for manifest: WindowsGameManifest) {
        // Reconcile every time: a previous in-memory game must not survive a
        // switch to a different saved entry. Ambiguous names require re-selection.
        guard manifest.id == "steam.shared" else { steamSelection = nil; return }
        let matches = MadeiraDock.games(drive: MadeiraDock.drive)
            .filter { $0.installed && $0.name == manifest.title }
        guard matches.count == 1, let game = matches.first else {
            steamSelection = nil
            launchLog.notice("Steam selection not restored: expected one installed game named \(manifest.title), found \(matches.count)")
            return
        }
        let remembered = UserDefaults.standard.dictionary(forKey: Self.steamLaunchOptionsKey) as? [String: Int] ?? [:]
        var option = UInt32(clamping: remembered[String(game.id)] ?? 0)
        // A remembered (or default) option can name a program that is not installed, such as a
        // game's Test build; prefer one whose executable exists when the library's options are known.
        if let launches = SteamLocalAppInfo.launchOptions(appID: game.id, game: game, drive: MadeiraDock.drive)
            ?? SteamLibraryModel.shared.games.first(where: { $0.id == game.id })?.game.launches {
            let current = launches.first(where: { $0.index == option })
            let currentInstalled = current.map { SteamLibraryModel.isInstalled($0, game: game, drive: MadeiraDock.drive) } ?? false
            if !currentInstalled,
               let better = SteamLibraryModel.preferredLaunchOption(launches, game: game, drive: MadeiraDock.drive),
               let index = better.index {
                launchLog.notice("Steam launch option \(option) is not installed; using \(index) (\(better.executable))")
                option = index
            }
        }
        steamSelection = (game, option)
        launchLog.notice("Steam selection restored for \(game.name) (app \(game.id), option \(option))")
    }

    func selectProfile(id: String) throws {
        guard canChangeSelection else { return }
        guard let entry = selectedEntry,
              let profile = entry.profiles.first(where: { $0.id == id }) else {
            throw WindowsVRLibraryError.noSelectedProfile
        }
        manifest = try profile.applying(to: entry.manifest)
        selectedProfileID = profile.id
        renderScaleDraft = profile.renderScale
        presentationModeDraft = profile.presentation
        profileNameDraft = profile.name
        launchArgumentsText = Self.argumentText(profile.launchArguments)
        var updated = library
        if let index = updated.firstIndex(where: { $0.id == entry.id }) {
            updated[index].selectedProfileID = profile.id
            updated[index].updatedAt = Date()
            try persist(updated)
        }
    }

    func saveProfile(asNew: Bool = false) throws {
        guard canChangeSelection, let entry = selectedEntry else {
            throw WindowsVRLibraryError.noSavedGame
        }
        guard let baseManifest = manifest else { throw WindowsVRLibraryError.noActiveGame }
        let arguments = draftArguments
        guard arguments.count <= 64, arguments.allSatisfy({ !$0.contains("\0") }) else {
            throw WindowsVRLibraryError.invalidProfileArguments
        }
        let cleanName = profileNameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty, cleanName.count <= 80 else {
            throw WindowsVRLibraryError.invalidProfileName
        }
        let existing = asNew ? nil : entry.profiles.first(where: { $0.id == selectedProfileID })
        let profile = try WindowsVRLaunchProfile(
            id: existing?.id ?? UUID().uuidString,
            name: cleanName,
            backend: baseManifest.backend,
            graphics: baseManifest.graphics,
            launchArguments: arguments,
            environment: baseManifest.environment,
            renderScale: renderScaleDraft,
            presentation: presentationModeDraft
        )
        var updated = library
        guard let index = updated.firstIndex(where: { $0.id == entry.id }) else {
            throw WindowsVRLibraryError.noSavedGame
        }
        if let profileIndex = updated[index].profiles.firstIndex(where: { $0.id == profile.id }) {
            updated[index].profiles[profileIndex] = profile
        } else {
            updated[index].profiles.append(profile)
        }
        updated[index].selectedProfileID = profile.id
        updated[index].updatedAt = Date()
        try persist(updated)
        selectedProfileID = profile.id
        renderScaleDraft = profile.renderScale
        presentationModeDraft = profile.presentation
        profileNameDraft = profile.name
        manifest = try profile.applying(to: updated[index].manifest)
    }

    func removeSelectedProfile() throws {
        guard canChangeSelection, let entry = selectedEntry,
              let selectedProfileID,
              entry.profiles.contains(where: { $0.id == selectedProfileID }) else {
            throw WindowsVRLibraryError.noSelectedProfile
        }
        var updated = library
        guard let index = updated.firstIndex(where: { $0.id == entry.id }) else {
            throw WindowsVRLibraryError.noSavedGame
        }
        updated[index].profiles.removeAll(where: { $0.id == selectedProfileID })
        updated[index].selectedProfileID = updated[index].profiles.first?.id
        updated[index].updatedAt = Date()
        try persist(updated)
        self.selectedProfileID = updated[index].selectedProfileID
        if let profile = updated[index].selectedProfile {
            manifest = try profile.applying(to: updated[index].manifest)
            renderScaleDraft = profile.renderScale
            presentationModeDraft = profile.presentation
            profileNameDraft = profile.name
            launchArgumentsText = Self.argumentText(profile.launchArguments)
        } else {
            manifest = updated[index].manifest
            presentationModeDraft = updated[index].manifest.presentation
            renderScaleDraft = 1
            profileNameDraft = L("Default", "Standard")
            launchArgumentsText = Self.argumentText(updated[index].manifest.launchArguments)
        }
    }

    func removeLibraryEntry(id: String) throws {
        guard canChangeSelection else { return }
        var updated = library
        guard updated.contains(where: { $0.id == id }) else { throw WindowsVRLibraryError.noSavedGame }
        updated.removeAll(where: { $0.id == id })
        try persist(updated)
        if selectedLibraryEntryID == id {
            releaseGameDirectoryAccess()
            selectedLibraryEntryID = nil
            selectedProfileID = nil
            manifest = nil
            manifestName = nil
            gameDirectory = nil
            gameFolderName = nil
            launchArgumentsText = "[]"
            renderScaleDraft = 1
            profileNameDraft = L("Default", "Standard")
        }
    }

    func selectInstalledSteamGame(appID: Int) throws {
        guard let game = MadeiraDock.games(drive: MadeiraDock.drive).first(where: { $0.id == appID && $0.installed }) else {
            throw DockError.message("The requested Steam game is not installed.")
        }
        let remembered = UserDefaults.standard.dictionary(forKey: Self.steamLaunchOptionsKey) as? [String: Int] ?? [:]
        let previousIndex = remembered[String(appID)].flatMap(UInt32.init(exactly:))
        let options = SteamLocalAppInfo.launchOptions(appID: appID, game: game, drive: MadeiraDock.drive)
            ?? SteamLibraryModel.shared.games.first(where: { $0.id == appID })?.game.launches
        guard let options else {
            // Before Valve's first successful run there is no appinfo cache.
            // Reuse only a choice the user already made; never invent an index.
            guard let previousIndex else { throw DockError.message("Select this game and its launch option in the Steam library once before retrying.") }
            selectSteamGame(game, launchOption: previousIndex)
            return
        }
        let previous = options.first { $0.index == previousIndex && SteamLibraryModel.isInstalled($0, game: game, drive: MadeiraDock.drive) }
        guard let option = previous ?? SteamLibraryModel.preferredLaunchOption(options, game: game, drive: MadeiraDock.drive),
              let index = option.index else { throw DockError.message("No installed Windows launch option was found.") }
        selectSteamGame(game, launchOption: index)
    }

    /// The physical Windlands trial passes its splash with OpenSSL's optional
    /// CPU acceleration disabled. Keep this workaround local to that game;
    /// the underlying CPU/emulator fault has not been established.
    nonisolated static func steamCompatibilityEnvironment(appID: Int, base: [String: String] = [:]) -> [String: String] {
        var environment = base
        if appID == 428370 { environment["OPENSSL_ia32cap"] = "0" }
        return environment
    }

    /// Steam's 64-bit launch host may start a 32-bit game. Select the VR
    /// package from that game's actual installed PE header, without running it.
    nonisolated static func steamGuestArchitecture(option: SteamLaunchOption?, game: DockGame, drive: URL) -> WindowsGuestArchitecture? {
        guard let option,
              let executable = SteamInstalledExecutable.resolve(option.executable, game: game, drive: drive),
              let size = (try? executable.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])),
              size.isRegularFile == true, let count = size.fileSize, count >= 70,
              let file = try? FileHandle(forReadingFrom: executable) else { return nil }
        defer { try? file.close() }
        guard let header = try? file.read(upToCount: 64), header.count == 64,
              header[0] == 0x4d, header[1] == 0x5a else { return nil }
        let offset = header[60..<64].enumerated().reduce(UInt64(0)) { $0 | (UInt64($1.element) << ($1.offset * 8)) }
        guard offset >= 64, offset <= (16 << 20), offset <= UInt64(count - 6),
              (try? file.seek(toOffset: offset)) != nil,
              let pe = try? file.read(upToCount: 6), pe.count == 6,
              Array(pe.prefix(4)) == [0x50, 0x45, 0, 0] else { return nil }
        return UInt16(pe[4]) | (UInt16(pe[5]) << 8) == 0x14c ? .x86 : nil
    }

    /// Older verified native plugins do not understand the architecture field.
    /// Reject a missing x86 package before passing a Steam child to that plugin.
    nonisolated static func bundledX86RuntimeAvailable(resources: URL?, immersiveVR: Bool) -> Bool {
        guard let resources else { return false }
        let files = ["Runtime/i386-windows/ntdll.dll"] + (immersiveVR
            ? ["WindowsVR/Guest/x86/wvr_openxr.dll", "WindowsVR/Guest/x86/OpenComposite/bin/vrclient.dll"] : [])
        return files.allSatisfy { path in
            (try? resources.appendingPathComponent(path).resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        }
    }

    func selectSteamGame(_ game: DockGame, launchOption: UInt32) {
        guard canChangeSelection else { return }
        do {
            try MadeiraDock.validate(game, drive: MadeiraDock.drive)
            guard let host = Bundle.main.url(forResource: "dockhost", withExtension: "exe", subdirectory: "arm64ec-windows") else {
                throw DockError.message("The Steam launch host is missing from this build.")
            }
            let directory = MadeiraDock.drive.appendingPathComponent("AVPPlaySteam", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            guard directory.standardizedFileURL == directory.resolvingSymlinksInPath().standardizedFileURL else {
                throw DockError.message("The Steam launch folder is unsafe.")
            }
            let executable = directory.appendingPathComponent("dockhost.exe")
            if FileManager.default.fileExists(atPath: executable.path) { try FileManager.default.removeItem(at: executable) }
            try FileManager.default.copyItem(at: host, to: executable)
            let options = SteamLocalAppInfo.launchOptions(appID: game.id, game: game, drive: MadeiraDock.drive)
                ?? SteamLibraryModel.shared.games.first(where: { $0.id == game.id })?.game.launches ?? []
            let option = options.first(where: { $0.index == launchOption })
            let type = option?.type.lowercased()
            let mode: WindowsPresentationMode
            switch type {
            case "vr", "othervr", nil: mode = .immersiveVR
            default: mode = .desktop
            }
            let selected = try WindowsGameManifest(id: "steam.shared", title: game.name,
                executableRelativePath: "AVPPlaySteam/dockhost.exe", backend: .windowsWineFEX,
                graphics: .direct3D11, launchArguments: [],
                environment: Self.steamCompatibilityEnvironment(appID: game.id),
                presentation: mode,
                guestArchitecture: Self.steamGuestArchitecture(option: option, game: game, drive: MadeiraDock.drive),
                schemaVersion: 1)
            presentationModeDraft = mode
            releaseGameDirectoryAccess()
            manifest = selected
            manifestName = L("Steam — \(game.name)", "Steam — \(game.name)")
            gameDirectory = MadeiraDock.drive
            gameFolderName = game.installDir
            selectedLibraryEntryID = nil
            selectedProfileID = nil
            launchArgumentsText = "[]"
            steamSelection = (game, launchOption)
            rememberSteamLaunchOption(launchOption, for: game)
            launchError = nil
        } catch { showImportError(error) }
    }

    /// The layer a game's Direct3D swapchain presents into. DXMT aborts the game ("Failed to create
    /// metal view", exit code 3) when no layer is registered. The stereo path reaches the compositor
    /// through the OpenXR runtime, so this layer is never attached to a view; it only has to vend drawables.
    /// The runtime appends to Documents/madeira-log.txt and stops writing at its size cap, which a few
    /// sessions reach. Preserve the previous three sessions before starting a
    /// fresh log, so testing another game cannot erase a failed launch's evidence.
    private static func resetRuntimeLog() {
        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let fm = FileManager.default
        let log = documents.appendingPathComponent("madeira-log.txt")
        guard let size = (try? fm.attributesOfItem(atPath: log.path))?[.size] as? Int, size > 0 else { return }
        do {
            for index in stride(from: 3, through: 1, by: -1) {
                let archived = documents.appendingPathComponent("madeira-log.previous-\(index).txt")
                guard fm.fileExists(atPath: archived.path) else { continue }
                if index == 3 { try fm.removeItem(at: archived) }
                else { try fm.moveItem(at: archived, to: documents.appendingPathComponent("madeira-log.previous-\(index + 1).txt")) }
            }
            try fm.moveItem(at: log, to: documents.appendingPathComponent("madeira-log.previous-1.txt"))
            try Data().write(to: log)
            launchLog.notice("Previous runtime log preserved (\(size) bytes); new session log started")
        } catch {
            launchLog.error("Could not rotate runtime logs: \(error.localizedDescription)")
        }
    }

    /// Keep routine graphics logging inexpensive. Explicit DXMT overrides remain
    /// available for shader diagnosis without flooding the normal frame loop.
    private static func configureGraphicsEnvironment() {
        WindowsVRTranslationEnvironment.applyDefaults()
        let guestFoveation = wvr_guest_foveation_install_v1()
        launchLog.notice("Guest foveation transport installed=\(guestFoveation != 0)")
        #if DEBUG
        if getenv("DXMT_LOG_LEVEL") == nil { setenv("DXMT_LOG_LEVEL", "info", 1) }
        #endif
        // Shader capture performs startup disk writes; normal play leaves it off.
        // Locally enabled diagnostics may opt in even in a signed Release build.
        let captureRequested = getenv("WVR_METAL_CAPTURE").map { String(cString: $0) == "1" } ?? false
        let capture = LaunchDiagnostics.enabled && (captureRequested ||
            ProcessInfo.processInfo.arguments.contains("--capture-metal-diagnostics"))
        wvr_metal_shader_compatibility_install(capture ? 1 : 0)
    }

    private static func configureAudioEnvironment() throws {
        // The JIT helper uses a background audio session. Both the host and
        // the preserved runtime's legacy activation must allow it to continue.
        guard wvr_audio_session_install_mixing_policy_v1() == 0 else {
            throw NSError(domain: "WineVision.AudioSession", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Could not configure cooperative audio for the JIT helper."
            ])
        }
        if getenv("MADEIRA_AUDIO_LEAD_MS") == nil { setenv("MADEIRA_AUDIO_LEAD_MS", "90", 0) }
        let audio = AVAudioSession.sharedInstance()
        try audio.setCategory(.playback, options: .mixWithOthers)
        try audio.setPreferredSampleRate(48_000)
        try audio.setActive(true)
        launchLog.notice("Audio session: mixing enabled; actual rate=\(audio.sampleRate)Hz output latency=\(audio.outputLatency)s")
    }

    private static var guestDisplayLayer: CAMetalLayer?
    private static func registerGuestDisplayLayer() {
        guard guestDisplayLayer == nil else { return }
        let layer = CAMetalLayer()
        layer.device = MTLCreateSystemDefaultDevice()
        layer.pixelFormat = .bgra8Unorm
        let env = ProcessInfo.processInfo.environment
        layer.drawableSize = CGSize(width: Double(env["MADEIRA_SCREEN_W"] ?? "") ?? 1024,
                                    height: Double(env["MADEIRA_SCREEN_H"] ?? "") ?? 768)
        guestDisplayLayer = layer
        madeira_display_set_layer(layer)
        launchLog.notice("Guest display layer registered (\(Int(layer.drawableSize.width))x\(Int(layer.drawableSize.height)))")
    }

    func launch(preparePresentation: () async throws -> Void) async {
        guard canLaunch, let gameDirectory else { return }
        do {
            if let manifest { restoreSteamSelection(for: manifest) }
            // Freeze the reconciled option alongside the manifest before any
            // async work can change the Steam library or remembered selection.
            let launchSelection = steamSelection
            do { try beginTestSession() }
            catch { launchLog.error("Test session archive could not start; launch will continue: \(error.localizedDescription)") }
            let launchManifest = try effectiveManifest()
            isLaunching = true
            immersiveSpaceClosedDuringLaunch = false
            launchError = nil
            defer { isLaunching = false }
            guard runtime.isAvailable else { throw LauncherFailure.runtimePluginMissing }
            if launchManifest.guestArchitecture == .x86,
               !Self.bundledX86RuntimeAvailable(resources: Bundle.main.resourceURL,
                                               immersiveVR: launchManifest.presentation == .immersiveVR) {
                throw DockError.message("This build does not contain the experimental 32-bit runtime required by this game.")
            }
            try runtime.preflight(manifest: launchManifest, gameDirectory: gameDirectory)
            launchLog.notice("Launch: preflight passed, preparing debugger")
            try await jitCoordinator.prepareDebugger()
            launchLog.notice("Launch: debugger prepared, opening \(launchManifest.presentation.rawValue)")
            if launchManifest.presentation == .immersiveVR && wvr_compositor_set_render_scale_v1(renderScaleDraft) != 0 {
                throw WindowsVRLibraryError.invalidProfileArguments
            }
            try await preparePresentation()
            launchLog.notice("Launch: presentation ready (mode=\(launchManifest.presentation.rawValue), immersiveOpen=\(self.immersiveSpaceIsOpen), desktopReady=\(self.desktopSurfaceReady))")
            guard launchManifest.presentation == .desktop ? desktopSurfaceReady : (immersiveSpaceIsOpen && !immersiveSpaceClosedDuringLaunch) else {
                throw LaunchPreparationFailure.immersiveSpaceClosed
            }
            // The native downloader logs off before Valve's guest client uses
            // the account. Keep the token out of manifests, argv and reports.
            await SteamLibraryModel.shared.prepareForLaunch()
            if launchManifest.id == "steam.shared" {
                // Say which of the four conditions fails; the user-facing error is the same for all.
                launchLog.notice("Steam launch checks: selection=\(launchSelection != nil) exe=\(launchManifest.executableRelativePath == "AVPPlaySteam/dockhost.exe") dockFolder=\(gameDirectory.resolvingSymlinksInPath() == MadeiraDock.drive.resolvingSymlinksInPath()) signedIn=\(SteamSignIn.credentialsForDock() != nil)")
                guard let selection = launchSelection,
                      selection.game.name == launchManifest.title,
                      launchManifest.executableRelativePath == "AVPPlaySteam/dockhost.exe",
                      gameDirectory.resolvingSymlinksInPath() == MadeiraDock.drive.resolvingSymlinksInPath(),
                      let credentials = SteamSignIn.credentialsForDock() else {
                    throw DockError.message("Select an installed Steam game and sign in again before launching.")
                }
                try MadeiraDock.validate(selection.game, drive: MadeiraDock.drive)
                try MadeiraDock.writeHandoff(account: credentials.accountName, token: credentials.refreshToken, appID: selection.game.id)
                MadeiraDock.configure(selection.game, launchOption: selection.option)
            }
            // WindowsVRCore emits only the unchanged v1 plugin JSON request.
            launchLog.notice("Launch: starting runtime")
            logImageBases()
            if launchManifest.presentation == .immersiveVR { Self.registerGuestDisplayLayer() }
            Self.resetRuntimeLog()
            if LaunchDiagnostics.enabled { setenv("WVR_TRACE_BRIDGE", "1", 1) }
            if LaunchDiagnostics.enabled, let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
                _ = wvr_trace_thread_creation_v1("WindowsRuntimePlugin", documents.appendingPathComponent("launcher-log.txt").path)
            }
            Self.configureGraphicsEnvironment()
            try Self.configureAudioEnvironment()
            if launchManifest.id == "steam.shared" && launchManifest.presentation == .immersiveVR {
                let architecture = launchManifest.guestArchitecture == .x86
                    ? "x86" : (runtime.guestRuntimeArchitecture ?? "x64")
                try OpenXRRegistration.install(prefix: MadeiraDock.prefix, architecture: architecture)
            }
            try await runtime.launch(manifest: launchManifest, gameDirectory: gameDirectory)
            launchLog.notice("Launch: runtime accepted the launch")
            hasAcceptedLaunch = true
            snapshotTestSession(reason: "Runtime accepted launch; game readiness and rendering unknown")
            if LaunchDiagnostics.enabled { watchGuestStartup() }
            runtimeStatus = L("Launch accepted; game readiness unknown", "Start wurde angenommen; Spielbereitschaft unbekannt")
            beginStatusMonitoring()
            beginShaderWarmupMonitoring(manifest: launchManifest, gameDirectory: gameDirectory)
            if launchManifest.presentation == .immersiveVR && (!immersiveSpaceIsOpen || immersiveSpaceClosedDuringLaunch) {
                try await runtime.stop()
                finishTestSession(outcome: .stopped, reason: "Stop confirmed after immersive presentation closed during launch")
                hasAcceptedLaunch = false
                requiresRestart = true
                statusMonitor?.cancel()
                statusMonitor = nil
                releaseGameDirectoryAccess()
                runtimeStatus = L("Runtime stopped; restart the app before another launch", "Laufzeit beendet; starte die App neu, bevor du ein weiteres Spiel startest")
            }
        } catch {
            launchLog.error("Launch failed (accepted=\(self.hasAcceptedLaunch)): \(String(describing: error)); native=\(self.runtime.nativeStatus().lastError ?? "")")
            if hasAcceptedLaunch {
                noteTestSessionFailure("Launch preparation or stop failed while the native session remained active")
            } else {
                finishTestSession(outcome: .failed, reason: "Launch failed before runtime acceptance")
            }
            if !hasAcceptedLaunch {
                MadeiraDock.cleanup()
                SteamLibraryModel.shared.resumeAfterLaunchFailure()
            }
            if immersiveSpaceClosedDuringLaunch && hasAcceptedLaunch { requiresRestart = true }
            if hasAcceptedLaunch {
                recordStopFailure(error, becauseImmersiveClosed: immersiveSpaceClosedDuringLaunch)
            } else {
                let detail = runtime.nativeStatus().lastError
                launchError = L("The game could not be launched: \(detail?.isEmpty == false ? detail! : error.localizedDescription)", "Das Spiel konnte nicht gestartet werden: \(detail?.isEmpty == false ? detail! : error.localizedDescription)")
            }
        }
    }

    func showDesktopPresentation() {
        desktopSurfaceReady = false
        desktopPresentationVisible = true
    }

    func desktopSurfaceDidAttach() { desktopSurfaceReady = true }

    func desktopSurfaceDidDetach() { desktopSurfaceReady = false }

    func waitForDesktopReady(timeout: Duration = .seconds(12)) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            guard desktopPresentationVisible else { throw LaunchPreparationFailure.desktopUnavailable }
            if desktopSurfaceReady { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw LaunchPreparationFailure.desktopUnavailable
    }

    func hideDesktopPresentation() {
        // A live guest keeps its surface and folder access until exit is confirmed.
        guard !isLaunching, !hasAcceptedLaunch, !isStopping else { return }
        _ = winios_compositor_set_hidden(1)
        desktopPresentationVisible = false
        desktopSurfaceReady = false
    }

    func selectDesktopDemo() throws {
        guard canChangeSelection else { return }
        guard let resource = Bundle.main.url(forResource: "DesktopDemo", withExtension: nil),
              let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            throw CocoaError(.fileNoSuchFile)
        }
        let fm = FileManager.default
        let directory = documents.appendingPathComponent("WindowsVR/Apps/DesktopDemo", isDirectory: true)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        guard isAppOwnedURL(directory), directory.standardizedFileURL == directory.resolvingSymlinksInPath().standardizedFileURL else {
            throw ImportFailure.folderAccessDenied
        }
        let executable = directory.appendingPathComponent("desktop-demo.exe")
        let values = try? executable.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey])
        guard values?.isSymbolicLink != true, values?.isRegularFile != false else { throw ImportFailure.folderAccessDenied }
        // Atomic replacement of only our executable preserves the user's demo-note.txt.
        try Data(contentsOf: resource.appendingPathComponent("desktop-demo.exe")).write(to: executable, options: .atomic)
        let demo = try JSONDecoder().decode(WindowsGameManifest.self,
            from: Data(contentsOf: resource.appendingPathComponent("manifest.json")))
        releaseGameDirectoryAccess()
        manifest = demo
        presentationModeDraft = .desktop
        manifestName = L("Built-in Windows desktop test", "Integrierter Windows-Desktop-Test")
        gameDirectory = directory
        gameFolderName = directory.lastPathComponent
        selectedLibraryEntryID = nil
        selectedProfileID = nil
        renderScaleDraft = 1
        launchArgumentsText = "[]"
        launchError = nil
    }

    func selectVRSmoke(architecture: WindowsGuestArchitecture? = nil, fixtureExecutable: String? = nil) throws {
        guard canChangeSelection else { return }
        let resourceName = architecture == .x86 ? "VRSmokeX86" : "VRSmoke"
        guard let resource = Bundle.main.url(forResource: resourceName, withExtension: nil),
              let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            throw CocoaError(.fileNoSuchFile)
        }
        let fm = FileManager.default
        let directory = documents.appendingPathComponent("WindowsVR/Apps/" + resourceName, isDirectory: true)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        guard isAppOwnedURL(directory), directory.standardizedFileURL == directory.resolvingSymlinksInPath().standardizedFileURL else {
            throw ImportFailure.folderAccessDenied
        }
        let executableName = fixtureExecutable ?? "vr-smoke.exe"
        guard fixtureExecutable == nil || (architecture == .x86 && ["abi-test.exe", "handle-test.exe"].contains(executableName)) else {
            throw WindowsGameManifestError.invalidLaunchConfiguration
        }
        let executable = directory.appendingPathComponent(executableName)
        let values = try? executable.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey])
        guard values?.isSymbolicLink != true, values?.isRegularFile != false else { throw ImportFailure.folderAccessDenied }
        // Atomic replacement of only our executable preserves the user's test log in the Windows prefix.
        try Data(contentsOf: resource.appendingPathComponent(executableName)).write(to: executable, options: .atomic)
        let sourceManifest = try JSONDecoder().decode(WindowsGameManifest.self,
            from: Data(contentsOf: resource.appendingPathComponent("manifest.json")))
        let demo = try fixtureExecutable.map { name in
            try WindowsGameManifest(id: sourceManifest.id + "." + name, title: "32-bit runtime diagnostic",
                executableRelativePath: name, backend: .windowsWineFEX, graphics: .direct3D11,
                launchArguments: [], presentation: .desktop, guestArchitecture: .x86, schemaVersion: 1)
        } ?? sourceManifest
        releaseGameDirectoryAccess()
        manifest = demo
        presentationModeDraft = demo.presentation
        manifestName = L("Built-in VR test scene", "Integrierte VR-Testszene")
        gameDirectory = directory
        gameFolderName = directory.lastPathComponent
        selectedLibraryEntryID = nil
        selectedProfileID = nil
        renderScaleDraft = 1
        launchArgumentsText = "[]"
        launchError = nil
    }

    func waitForCompositorReady(timeout: Duration = .seconds(12)) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            if !immersiveSpaceIsOpen { throw LaunchPreparationFailure.immersiveSpaceClosed }
            var readiness = WVRCompositorReadinessV1()
            readiness.structSize = UInt32(MemoryLayout<WVRCompositorReadinessV1>.size)
            let status = wvr_compositor_copy_readiness_v1(&readiness)
            let nowNanoseconds = UInt64(max(0, CACurrentMediaTime() * 1.0e9))
            let trackingTimestamp = readiness.trackingTimestampNanoseconds
            let poseIsFresh = trackingTimestamp <= nowNanoseconds
                ? nowNanoseconds - trackingTimestamp < 500_000_000
                : trackingTimestamp - nowNanoseconds <= 100_000_000
            if status == 0, readiness.metalDeviceBound != 0,
               readiness.stereoTargetsPublished != 0,
               readiness.trackedHeadPoseAvailable != 0, poseIsFresh {
                return
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw LaunchPreparationFailure.rendererTimedOut
    }

    func immersiveSpaceDidOpen() {
        recordLifecycleEvent("immersiveSpaceDidOpen")
        launchLog.notice("Immersive space opened")
        immersiveSpaceIsOpen = true
        immersiveSpaceClosedDuringLaunch = false
    }

    func immersiveSpaceDidClose() async {
        recordLifecycleEvent("immersiveSpaceDidClose")
        launchLog.notice("Immersive space closed (launching=\(self.isLaunching), accepted=\(self.hasAcceptedLaunch))")
        immersiveSpaceIsOpen = false
        if isLaunching { immersiveSpaceClosedDuringLaunch = true }
        guard presentationModeDraft == .immersiveVR, hasAcceptedLaunch, !isStopping, !stopRequested else { return }
        snapshotTestSession(reason: "Immersive presentation closed; requesting native stop")
        isStopping = true
        defer { isStopping = false }
        do {
            try await runtime.stop()
            finishTestSession(outcome: .stopped, reason: "Native stop confirmed after immersive presentation closed")
            hasAcceptedLaunch = false
            requiresRestart = true
            runtimeStatus = L("Runtime stopped; restart the app before another launch", "Laufzeit beendet; starte die App neu, bevor du ein weiteres Spiel startest")
            statusMonitor?.cancel()
            statusMonitor = nil
            releaseGameDirectoryAccess()
        } catch {
            requiresRestart = true
            recordStopFailure(error, becauseImmersiveClosed: true)
        }
    }

    func stop() async {
        guard hasAcceptedLaunch, !isStopping, !stopRequested else { return }
        recordLifecycleEvent("stop() called")
        snapshotTestSession(reason: "User requested native stop")
        isStopping = true
        launchError = nil
        defer { isStopping = false }
        do {
            try await runtime.stop()
            finishTestSession(outcome: .stopped, reason: "User-requested native stop confirmed")
            hasAcceptedLaunch = false
            requiresRestart = true
            runtimeStatus = L("Runtime stopped; restart the app before another launch", "Laufzeit beendet; starte die App neu, bevor du ein weiteres Spiel startest")
            statusMonitor?.cancel()
            statusMonitor = nil
            warmupMonitor?.cancel()
            warmupMonitor = nil
            shaderWarmup = nil
            releaseGameDirectoryAccess()
        } catch {
            recordStopFailure(error, becauseImmersiveClosed: false)
        }
    }

    func makeCompatibilityReport() -> WindowsVRCompatibilityReport? {
        refreshCompositorCounters()
        guard let manifest, let launchManifest = try? effectiveManifest() else { return nil }
        let state = runtime.nativeStatus()
        let wine = WindowsVRWineStatus(
            stateCode: runtime.isAvailable ? state.state : nil,
            state: runtime.isAvailable ? wineStateName(state.state) : "plugin unavailable",
            detail: runtime.isAvailable ? state.lastError : WindowsRuntimeError.integrationMissing.localizedDescription
        )
        let profile = selectedEntry?.profiles.first(where: { $0.id == selectedProfileID })
        let requested = WindowsVRRequestedProfile(
            gameID: manifest.id,
            gameTitle: manifest.title,
            profileID: profile?.id,
            profileName: profileNameDraft.isEmpty ? "Current manifest" : profileNameDraft,
            backend: launchManifest.backend,
            graphics: launchManifest.graphics,
            executableRelativePath: launchManifest.executableRelativePath,
            launchArguments: launchManifest.launchArguments,
            environment: launchManifest.environment,
            spatialRenderScale: renderScaleDraft,
            presentation: launchManifest.presentation
        )
        let pluginAvailable = runtime.isAvailable
        let graphicsAssessment: WindowsVRCapabilityAssessment
        if launchManifest.graphics == .vulkan {
            graphicsAssessment = .init(id: "Vulkan", status: "unavailable", reason: "Vulkan requests are rejected; no graphics fallback is selected.")
        } else if launchManifest.graphics == .direct3D12 {
            graphicsAssessment = .init(id: "Direct3D 12", status: runtime.supportsGraphics(.direct3D12) ? "experimental / unverified" : "unavailable", reason: runtime.supportsGraphics(.direct3D12)
                ? "The signed bundle declares a matching DXMT D3D12 transport package. The pinned backend exposes Shader Model 5.1/DXBC; DXIL/Shader Model 6, mesh shaders and ray tracing are unsupported. Headset execution, game compatibility and performance are not established by this report."
                : "The matching experimental DXMT D3D12 native/guest package is absent. A D3D12 manifest is retained but cannot launch; D3D11 is not substituted.")
        } else if pluginAvailable {
            graphicsAssessment = .init(id: "Direct3D 11", status: "conditional", reason: "The signed plugin is loadable, but this source-only report cannot establish that game startup or frame submission succeeds.")
        } else {
            graphicsAssessment = .init(id: "Direct3D 11", status: "unavailable", reason: "The signed runtime plugin is not available in this app process.")
        }
        let backendAssessment = WindowsVRCapabilityAssessment(
            id: launchManifest.backend.rawValue,
            status: pluginAvailable && launchManifest.backend == .windowsWineFEX ? "conditional" : "unavailable",
            reason: pluginAvailable && launchManifest.backend == .windowsWineFEX
                ? "The version-1 plugin can receive this explicit backend request; guest readiness and runtime resource availability remain unverified. The plugin must reject unsupported backends without fallback."
                : "The selected backend is not packaged or the signed runtime plugin is unavailable; launch is blocked."
        )
        let capabilities = [
            backendAssessment,
            graphicsAssessment,
            .init(id: "Spatial eye scaling", status: "conditional", reason: "Uniform per-eye Metal bilinear scaling is implemented in source; default render scale is 1.0. Quality and GPU benefit are unmeasured."),
            .init(id: "MetalFX temporal super resolution", status: "unavailable", reason: "The visionOS 27 SDK marks the temporal scaler unavailable on the initial target; no alternate SR backend is connected."),
            .init(id: "Frame generation", status: "unavailable", reason: "No frame-generation adapter or measured stereo pacing path is implemented."),
            .init(id: "Guest-pipeline foveation", status: "unavailable", reason: "No guest rendering-pass integration or validated gaze/raster-rate path is connected.")
        ]
        let device = UIDevice.current
        return WindowsVRCompatibilityReport(
            deviceModel: device.model + " (" + (Self.systemString("hw.machine") ?? "hardware identifier unavailable") + ")",
            operatingSystemName: device.systemName,
            operatingSystemVersion: device.systemVersion,
            operatingSystemBuildDescription: ProcessInfo.processInfo.operatingSystemVersionString + " / " + (Self.systemString("kern.osversion") ?? "build identifier unavailable"),
            requestedProfile: requested,
            runtimePluginAvailable: pluginAvailable,
            wineStatus: wine,
            compositorCounters: compositorCounters,
            capabilities: capabilities
        )
    }

    func makeCompatibilityReportJSON() throws -> Data {
        guard let report = makeCompatibilityReport() else { throw WindowsVRLibraryError.noActiveGame }
        return try report.encodedJSON()
    }

    var reportFilename: String {
        let name = manifest?.title ?? "windows-vr"
        let safe = name.map { character in
            character.isLetter || character.isNumber || character == "-" || character == "_" ? character : "-"
        }
        return "\(String(safe))-compatibility-report.json"
    }

    func dismissImportError() {
        isShowingImportError = false
        importError = nil
    }

    func presentLibraryError(_ error: Error) {
        showImportError(error)
    }

    private func beginTestSession() throws {
        diagnosticsAttemptActive = false
        guard let sessionDiagnostics, let manifest else { throw LauncherFailure.sessionDiagnosticsUnavailable }
        // Invalid drafts still receive a journal entry before effectiveManifest
        // throws; valid saved Steam entries use the reconciled child architecture.
        let requested = (try? effectiveManifest()) ?? manifest
        let profile = selectedEntry?.profiles.first(where: { $0.id == selectedProfileID })
        let receipt = Bundle.main.resourceURL?.appendingPathComponent("Runtime/AVPPLAY_NATIVE_BUILD_RECEIPT.json")
        let receiptData = receipt.flatMap { try? Data(contentsOf: $0) }
        let runtimeBuildID = receiptData.map { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() }
        let metadata = SessionDiagnostics.Metadata(
            title: requested.title, manifestID: requested.id,
            steamAppID: steamSelection?.game.id,
            steamLaunchOptionID: steamSelection.map { Int($0.option) },
            architecture: requested.guestArchitecture?.rawValue ?? "automatic",
            graphics: requested.graphics.rawValue, renderScale: Double(renderScaleDraft),
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
            buildNumber: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
            runtimeBuildID: runtimeBuildID, profileID: selectedProfileID, profileName: profile?.name ?? profileNameDraft)
        let prefix: URL?
        if requested.id == "steam.shared" {
            prefix = MadeiraDock.prefix
        } else if let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            let identity = SHA256.hash(data: Data(requested.id.utf8)).map { String(format: "%02x", $0) }.joined()
            prefix = documents.appendingPathComponent("WindowsVR/Prefixes/" + identity, isDirectory: true)
        } else { prefix = nil }
        diagnosticsFailureReason = nil
        diagnosticsNativeState = nil
        _ = try sessionDiagnostics.beginAttempt(metadata: metadata, prefixURL: prefix)
        diagnosticsAttemptActive = true
    }

    private func snapshotTestSession(reason: String) {
        guard diagnosticsAttemptActive else { return }
        do { try sessionDiagnostics?.snapshot(reason: reason) }
        catch { launchLog.error("Test session snapshot failed: \(error.localizedDescription)") }
    }

    private func noteTestSessionFailure(_ reason: String) {
        guard diagnosticsAttemptActive else { return }
        diagnosticsFailureReason = reason
        do { try sessionDiagnostics?.snapshot(reason: reason, outcome: .failed) }
        catch { launchLog.error("Test session failure snapshot failed: \(error.localizedDescription)") }
    }

    private func finishTestSession(outcome: SessionDiagnostics.Outcome, reason: String) {
        guard diagnosticsAttemptActive else { return }
        do {
            try sessionDiagnostics?.finish(outcome: diagnosticsFailureReason == nil ? outcome : .failed,
                                           reason: diagnosticsFailureReason ?? reason)
            diagnosticsAttemptActive = false
        } catch { launchLog.error("Test session final snapshot failed: \(error.localizedDescription)") }
    }

    func makeTestSessionsJSON() throws -> Data {
        guard let sessionDiagnostics else { throw LauncherFailure.sessionDiagnosticsUnavailable }
        let url = try sessionDiagnostics.exportBundle()
        return try Data(contentsOf: url)
    }

    private var draftArguments: [String] {
        // JSON preserves empty argv entries, spaces, and embedded newlines.
        // Invalid drafts stay visibly invalid rather than silently repairing argv.
        (try? JSONDecoder().decode([String].self, from: Data(launchArgumentsText.utf8))) ?? [String(decoding: [UInt8(0)], as: UTF8.self)]
    }

    private static func argumentText(_ arguments: [String]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(arguments) else { return "[]" }
        return String(decoding: data, as: UTF8.self)
    }

    private func effectiveManifest() throws -> WindowsGameManifest {
        guard let manifest else { throw WindowsVRLibraryError.noActiveGame }
        guard draftArguments.count <= 64, !draftArguments.contains(where: { $0.contains(String(decoding: [UInt8(0)], as: UTF8.self)) }) else {
            throw WindowsVRLibraryError.invalidProfileArguments
        }
        let selectedProfile = selectedEntry?.profiles.first(where: { $0.id == selectedProfileID })
        let base = try selectedProfile?.applying(to: selectedEntry?.manifest ?? manifest) ?? manifest
        var environment = base.environment
        // The Advanced setting is stored in AppStorage; 1.0 (or unset) adds nothing to the launch environment.
        let internalScale = UserDefaults.standard.double(forKey: "WVRInternalRenderScale")
        if internalScale >= 0.5 && internalScale < 1 {
            environment["WVR_INTERNAL_RENDER_SCALE"] = String(format: "%.2f", internalScale)
        }
        // Temporal upscaling needs the game's projection jitter; selecting it turns jitter on.
        if UserDefaults.standard.integer(forKey: "WVRFrameSynthesisMode") == 3 {
            environment["WVR_PROJECTION_JITTER"] = "1"
        }
        // Opt-in lossy render target compression; the Advanced toggle is off by default.
        if UserDefaults.standard.bool(forKey: "WVRLossyRenderTargets") {
            environment["DXMT_LOSSY_RENDER_TARGETS"] = "1"
        }
        var guestArchitecture = base.guestArchitecture
        if base.id == "steam.shared" {
            guard let selection = steamSelection, selection.game.name == base.title else {
                throw DockError.message("Select this installed Steam game and its launch option again before launching.")
            }
            if let options = SteamLocalAppInfo.launchOptions(appID: selection.game.id, game: selection.game, drive: MadeiraDock.drive)
                ?? SteamLibraryModel.shared.games.first(where: { $0.id == selection.game.id })?.game.launches {
                guard let option = options.first(where: { $0.index == selection.option }) else {
                    throw DockError.message("Select this installed Steam game and its launch option again before launching.")
                }
                // The installed child wins over stale saved architecture fields.
                guestArchitecture = Self.steamGuestArchitecture(option: option, game: selection.game, drive: MadeiraDock.drive)
            } else {
                // Steam's offline cache may omit a game before library refresh.
                // Retain only an explicit remembered choice, as selection does;
                // never invent a launch index or clear a known x86 architecture.
                let remembered = UserDefaults.standard.dictionary(forKey: Self.steamLaunchOptionsKey) as? [String: Int] ?? [:]
                guard remembered[String(selection.game.id)].flatMap(UInt32.init(exactly:)) == selection.option else {
                    throw DockError.message("Select this installed Steam game and its launch option again before launching.")
                }
            }
        }
        return try WindowsGameManifest(
            id: base.id,
            title: base.title,
            executableRelativePath: base.executableRelativePath,
            backend: base.backend,
            graphics: base.graphics,
            launchArguments: draftArguments,
            environment: environment,
            presentation: presentationModeDraft,
            guestArchitecture: guestArchitecture,
            schemaVersion: base.schemaVersion
        )
    }

    private static func systemString(_ key: String) -> String? {
        var size = 0
        guard sysctlbyname(key, nil, &size, nil, 0) == 0, size > 0, size <= 4096 else { return nil }
        var bytes = [CChar](repeating: 0, count: size)
        let result = bytes.withUnsafeMutableBufferPointer { buffer in
            sysctlbyname(key, buffer.baseAddress, &size, nil, 0)
        }
        guard result == 0 else { return nil }
        return String(decoding: bytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    private func persist(_ updated: [WindowsVRLibraryEntry]) throws {
        guard libraryError == nil else { throw WindowsVRLibraryError.corruptLibrary }
        try WindowsVRLibraryStore.save(updated)
        library = updated
        libraryError = nil
    }

    private func refreshCompositorCounters() {
        guard presentationModeDraft == .immersiveVR else { compositorCounters = nil; return }
        var stats = WVRCompositorStatsV1()
        stats.abiVersion = WVR_COMPOSITOR_ABI_VERSION
        stats.structSize = UInt32(MemoryLayout<WVRCompositorStatsV1>.size)
        guard wvr_compositor_copy_stats_v1(&stats) == 0 else {
            compositorCounters = nil
            return
        }
        compositorCounters = WindowsVRCompositorCounters(
            abiVersion: stats.abiVersion,
            submittedFrames: stats.submittedFrames,
            acquiredFrames: stats.acquiredFrames,
            droppedFrames: stats.droppedFrames,
            completedFrames: stats.completedFrames,
            queuedFrames: stats.queuedFrames
        )
    }

    /// The emulated Windows process loads its ntdll within seconds of the launch being accepted. If the runtime's
    /// log never shows that, startup is stuck inside the runtime (the guest thread never asks the Wine server for
    /// ntdll, so the debugger waits for a second handshake that never comes). The runtime cannot be restarted in
    /// this process, so say so quickly instead of leaving a silent, empty headset.
    private func watchGuestStartup() {
        let marker = "XLATE-HOOK installed"
        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let log = documents.appendingPathComponent("madeira-log.txt")
        Task { [weak self] in
            let deadline = ContinuousClock.now.advanced(by: .seconds(60))
            while ContinuousClock.now < deadline {
                try? await Task.sleep(for: .seconds(2))
                guard let self, self.hasAcceptedLaunch else { return }
                if let handle = try? FileHandle(forReadingFrom: log) {
                    defer { try? handle.close() }
                    let size = (try? handle.seekToEnd()) ?? 0
                    if size > 0, let data = try? handle.read(upToCount: Int(min(size, 3_000_000))) ??
                        (try? { try handle.seek(toOffset: 0); return try handle.read(upToCount: Int(min(size, 3_000_000))) }()),
                       String(decoding: data, as: UTF8.self).contains(marker) {
                        launchLog.notice("Guest startup: ntdll loaded, the emulated Windows process is running")
                        return
                    }
                }
            }
            guard let self, self.hasAcceptedLaunch else { return }
            launchLog.error("Guest startup stalled: no ntdll load within 60 s of the launch being accepted")
            self.snapshotTestSession(reason: "Startup watchdog did not observe its ntdll marker within 60 seconds; game readiness unknown")
            let dumpPath = documents.appendingPathComponent("launcher-log.txt").path
            wvr_dump_thread_stacks_v1(dumpPath, "startup stall")
            // A second sample shows whether the odd threads are moving or fixed.
            try? await Task.sleep(for: .seconds(15))
            wvr_dump_thread_stacks_v1(dumpPath, "startup stall, 15 s later")
            self.runtimeStatus = L("The Windows runtime stalled while starting. Quit the app and launch again.",
                                   "Die Windows-Laufzeit ist beim Start hängen geblieben. Beende die App und starte erneut.")
        }
    }

    /// Polls the warm-up progress file every 250 ms while the game runs. It never blocks the launch.
    /// The overlay hides when the file reports completion, or when no file appears within 5 s.
    private func beginShaderWarmupMonitoring(manifest: WindowsGameManifest, gameDirectory: URL) {
        warmupMonitor?.cancel()
        shaderWarmup = nil
        // Steam launches run through dockhost.exe, whose cwd is not the game folder; no warm-up root is mapped there.
        guard manifest.id != "steam.shared" else { return }
        let progressFile = Self.shaderWarmupProgressFile(manifest: manifest, gameDirectory: gameDirectory)
        launchLog.notice("Shader warm-up progress file: \(progressFile.path)")
        warmupMonitor = Task { [weak self] in
            let started = ContinuousClock.now
            var sawFile = false
            while !Task.isCancelled, let model = self, model.hasAcceptedLaunch {
                if let progress = Self.readShaderWarmupProgress(at: progressFile) {
                    sawFile = true
                    if progress.complete {
                        model.shaderWarmup = nil
                        return
                    }
                    model.shaderWarmup = progress
                } else if !sawFile, ContinuousClock.now - started >= .seconds(5) {
                    model.shaderWarmup = nil
                    return
                }
                try? await Task.sleep(for: .milliseconds(250))
            }
            self?.shaderWarmup = nil
        }
    }

    /// Host location of `C:\windows-vr\<mount>\dxmt\<exe>\warmup-progress`. The mount name and the
    /// prefix follow WindowsRuntimePlugin (game-<SHA-256 of resolved folder|gameID>, per-game prefix).
    private static func shaderWarmupProgressFile(manifest: WindowsGameManifest, gameDirectory: URL) -> URL {
        let identity = gameDirectory.resolvingSymlinksInPath().path + "|" + manifest.id
        let mount = "game-" + SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
        let executable = manifest.executableRelativePath.replacingOccurrences(of: "\\", with: "/")
            .split(separator: "/").last.map(String.init) ?? manifest.executableRelativePath
        let windowsPath = "C:\\windows-vr\\\(mount)\\dxmt\\\(executable)\\warmup-progress"
        let digest = SHA256.hash(data: Data(manifest.id.utf8)).map { String(format: "%02x", $0) }.joined()
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let prefix = documents.appendingPathComponent("WindowsVR/Prefixes/\(digest)", isDirectory: true)
        // Wine maps C: to <prefix>/drive_c.
        var relative = windowsPath
        if relative.hasPrefix("C:\\") { relative.removeFirst(3) }
        return URL(fileURLWithPath: prefix.path + "/drive_c/" + relative.replacingOccurrences(of: "\\", with: "/"))
    }

    private static func readShaderWarmupProgress(at url: URL) -> ShaderWarmupProgress? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let fields = text.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\r" })
        guard fields.count >= 2, let done = Int(fields[0]), let total = Int(fields[1]) else { return nil }
        return ShaderWarmupProgress(done: done, total: total, complete: fields.count >= 3 && fields[2] == "complete")
    }

    func recordLifecycleEvent(_ reason: String) {
        let snapshot = runtime.nativeStatus()
        LaunchLogFile.append("lifecycle", "\(reason.prefix(160)) accepted=\(hasAcceptedLaunch) restart=\(requiresRestart) launching=\(isLaunching) stopping=\(isStopping) stopRequested=\(stopRequested) immersiveOpen=\(immersiveSpaceIsOpen) nativeState=\(snapshot.state) compilerHandled=\(compilerFailureHandled)")
    }

    private func beginStatusMonitoring() {
        statusMonitor?.cancel()
        statusMonitor = Task { [weak self] in
            while !Task.isCancelled, let self, self.hasAcceptedLaunch {
                self.refreshRuntimeStatus()
                self.refreshCompositorCounters()
                var shaderError = [CChar](repeating: 0, count: 1024)
                if !self.compilerFailureHandled,
                   wvr_metal_copy_compiler_failure(&shaderError, UInt32(shaderError.count)) != 0 {
                    self.compilerFailureHandled = true
                    let detail = String(cString: shaderError)
                    self.recordLifecycleEvent("compiler failure requests session stop")
                    self.noteTestSessionFailure("Native shader compiler reported a failure and requested stop")
                    LaunchLogFile.append("compiler-failure", String(detail.prefix(768)))
                    await self.stop()
                    self.launchError = detail
                    self.requiresRestart = true
                }
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    private func refreshRuntimeStatus() {
        let snapshot = runtime.nativeStatus()
        if manifest?.id == "steam.shared", let failure = MadeiraDock.pollReport().failure {
            if launchError != failure {
                launchLog.error("Steam launch failure: \(failure)")
                noteTestSessionFailure("Steam reported a launch failure")
            }
            launchError = failure
        }
        if diagnosticsNativeState != snapshot.state {
            diagnosticsNativeState = snapshot.state
            if snapshot.state == 4 {
                snapshotTestSession(reason: "Wine process active; game readiness and rendering unknown")
            }
        }
        switch snapshot.state {
        case 0: runtimeStatus = L("Launch accepted; runtime is idle", "Start wurde angenommen; Laufzeit ist im Leerlauf")
        case 1: runtimeStatus = L("Runtime preparing", "Laufzeit wird vorbereitet")
        case 2: runtimeStatus = L("Wine services starting", "Wine-Dienste werden gestartet")
        case 3: runtimeStatus = L("Guest process launching", "Gastprozess wird gestartet")
        case 4: runtimeStatus = L("Wine process active; game readiness and rendering unknown", "Wine-Prozess aktiv; Spielbereitschaft und Rendering unbekannt")
        case 5:
            stopRequested = true
            runtimeStatus = L("Exit requested; waiting for the guest and Wine process", "Beenden angefordert; warte auf Gast- und Wine-Prozess")
        case 6:
            recordLifecycleEvent("native runtime transitioned to stopped")
            finishTestSession(outcome: .stopped, reason: "Native runtime stopped; game result unverified")
            stopRequested = false
            runtimeStatus = L("Runtime stopped; restart the app before another launch", "Laufzeit beendet; starte die App neu, bevor du ein weiteres Spiel startest")
            hasAcceptedLaunch = false
            requiresRestart = true
            statusMonitor?.cancel()
            releaseGameDirectoryAccess()
        case 7:
            recordLifecycleEvent("native runtime transitioned to failed")
            if let error = snapshot.lastError { LaunchLogFile.append("runtime-failure", String(error.prefix(768))) }
            finishTestSession(outcome: .failed, reason: "Native runtime reported failure")
            stopRequested = false
            runtimeStatus = L("Runtime failed; restart the app before another launch", "Laufzeitfehler; starte die App neu, bevor du ein weiteres Spiel startest")
            hasAcceptedLaunch = false
            requiresRestart = true
            statusMonitor?.cancel()
            releaseGameDirectoryAccess()
            if let error = snapshot.lastError, !error.isEmpty {
                launchError = L("The runtime reported a failure: \(error)", "Die Laufzeit meldet einen Fehler: \(error)")
            }
        default: runtimeStatus = L("Runtime status unavailable", "Laufzeitstatus nicht verfügbar")
        }
    }

    private func wineStateName(_ state: Int32) -> String {
        switch state {
        case 0: "idle"
        case 1: "preparing"
        case 2: "Wine services starting"
        case 3: "guest process launching"
        case 4: "Wine process active; game readiness unknown"
        case 5: "stopping"
        case 6: "stopped"
        case 7: "failed"
        default: "unknown state"
        }
    }

    private func releaseGameDirectoryAccess() {
        steamSelection = nil
        MadeiraDock.cleanup()
        gameDirectoryAccessURL?.stopAccessingSecurityScopedResource()
        gameDirectoryAccessURL = nil
    }

    private func recordStopFailure(_ error: Error, becauseImmersiveClosed: Bool) {
        if case WindowsRuntimeError.stopPending = error {
            snapshotTestSession(reason: "Cooperative stop pending; native process still owns the session")
            stopRequested = true
            runtimeStatus = L("Exit requested; waiting for the guest and Wine process", "Beenden angefordert; warte auf Gast- und Wine-Prozess")
            launchError = becauseImmersiveClosed
                ? L("The immersive renderer closed. Cooperative exit was requested; the runtime still owns the session until Wine exits.", "Der immersive Renderer wurde geschlossen. Das geordnete Beenden wurde angefordert; die Laufzeit behält die Sitzung bis zum Ende von Wine.")
                : nil
            // Keep both access and monitoring until native stopped/failed status.
            return
        }
        snapshotTestSession(reason: "Stop could not be confirmed; native session remains active")
        launchError = stopFailureMessage(error, becauseImmersiveClosed: becauseImmersiveClosed)
    }

    private func stopFailureMessage(_ error: Error, becauseImmersiveClosed: Bool) -> String {
        if case WindowsRuntimeError.pluginRejectedRequest(let status) = error,
           status == 16 || status == -16 {
            return L("The runtime is busy (EBUSY) and could not stop the guest. Let the guest exit naturally or restart the app; the session remains marked active.", "Die Laufzeit ist ausgelastet (EBUSY) und konnte den Gast nicht beenden. Warte, bis der Gast selbst beendet wird, oder starte die App neu; die Sitzung bleibt als aktiv markiert.")
        }
        if becauseImmersiveClosed {
            return L("The immersive renderer closed, but the runtime could not confirm a stop. Restart the app before another launch. \(error.localizedDescription)", "Der immersive Renderer wurde geschlossen, aber die Laufzeit konnte das Beenden nicht bestätigen. Starte die App neu, bevor du ein weiteres Spiel startest. \(error.localizedDescription)")
        }
        return L("The runtime could not confirm that the session stopped. The session remains marked active. \(error.localizedDescription)", "Die Laufzeit konnte das Beenden der Sitzung nicht bestätigen. Die Sitzung bleibt als aktiv markiert. \(error.localizedDescription)")
    }

    private func showImportError(_ error: Error) {
        importError = error.localizedDescription
        isShowingImportError = true
    }

    private func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        let cocoaError = error as NSError
        return cocoaError.domain == NSCocoaErrorDomain && cocoaError.code == NSUserCancelledError
    }
}

private enum LauncherFailure: LocalizedError {
    case runtimePluginMissing
    case sessionDiagnosticsUnavailable
    var errorDescription: String? {
        switch self {
        case .runtimePluginMissing:
            L("The signed WindowsRuntimePlugin.framework is not embedded in this app, so no launch request was sent.", "Das signierte WindowsRuntimePlugin.framework ist nicht in dieser App eingebettet. Es wurde keine Startanfrage gesendet.")
        case .sessionDiagnosticsUnavailable:
            L("Test session logs are unavailable for this app launch. Reopen the app and try exporting again.", "Testsitzungsprotokolle sind für diesen App-Start nicht verfügbar. Öffne die App erneut und versuche den Export noch einmal.")
        }
    }
}

private enum LaunchPreparationFailure: LocalizedError {
    case immersiveSpaceClosed
    case rendererTimedOut
    case desktopUnavailable

    var errorDescription: String? {
        switch self {
        case .immersiveSpaceClosed:
            L("The immersive renderer closed before the launch request was sent.", "Der immersive Renderer wurde geschlossen, bevor die Startanfrage gesendet wurde.")
        case .desktopUnavailable:
            L("The Windows desktop surface could not be prepared.", "Die Windows-Desktop-Anzeige konnte nicht vorbereitet werden.")
        case .rendererTimedOut:
            L("The immersive renderer did not bind Metal, publish stereo targets, and provide a fresh tracked head pose within 12 seconds. No launch request was sent.", "Der immersive Renderer hat innerhalb von 12 Sekunden weder Metal gebunden und Stereo-Ziele veröffentlicht noch eine aktuelle getrackte Kopfpose bereitgestellt. Es wurde keine Startanfrage gesendet.")
        }
    }
}

private enum ImportFailure: LocalizedError {
    case manifestAccessDenied
    case folderAccessDenied

    var errorDescription: String? {
        switch self {
        case .manifestAccessDenied:
            L("The app could not get permission to read the selected manifest.", "Die App konnte keine Leseberechtigung für das ausgewählte Manifest erhalten.")
        case .folderAccessDenied:
            L("The app could not get permission to read the selected game folder.", "Die App konnte keine Leseberechtigung für den ausgewählten Spielordner erhalten.")
        }
    }
}
