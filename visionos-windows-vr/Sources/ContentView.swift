import SwiftUI
import UniformTypeIdentifiers
import WindowsVRCore
import Darwin

struct ContentView: View {
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace
    @Bindable var model: LauncherModel
    @AppStorage("WVRFrameSynthesisMode") private var frameSynthesisMode = 0
    @AppStorage("WVRReconstructionValidation") private var reconstructionValidation = false
    @AppStorage("WVRRenderQuality") private var renderQuality: Double = 0
    @AppStorage("WVRInternalRenderScale") private var internalRenderScale = 1.0
    @AppStorage("WVRLossyRenderTargets") private var lossyRenderTargets = false
    @State private var importingManifest = false
    @State private var importingGameFolder = false
    @State private var exportingReport = false
    @State private var exportFilename = "winevision-test-sessions.json"
    @State private var showingSteamLibrary = false
    @State private var didStartDesktopSmokeTest = false
    @State private var reportDocument = CompatibilityReportDocument(data: Data())

    var body: some View {
        Group {
            if model.desktopPresentationVisible {
                WindowsDesktopView(model: model)
            } else {
                NavigationStack {
                    launcherHome
                        .navigationTitle("WineVision VR")
                        .toolbar {
                            ToolbarItem(placement: .topBarTrailing) {
                                Button(L("Export test sessions", "Testsitzungen exportieren"), systemImage: "square.and.arrow.up") {
                                    exportTestSessions()
                                }
                            }
                        }
                }
            }
        }
        .ornament(visibility: model.shaderWarmup == nil ? .hidden : .visible, attachmentAnchor: .scene(.bottom)) {
            if let warmup = model.shaderWarmup {
                ShaderWarmupBanner(progress: warmup)
            }
        }
        .sheet(isPresented: $showingSteamLibrary) {
            SteamLibraryView(model: .shared)
                .onAppear {
                    SteamLibraryModel.shared.runtimeBusy = !model.canChangeSelection
                    SteamLibraryModel.shared.onPlaySelected = { game, option in
                        model.selectSteamGame(game, launchOption: option)
                        showingSteamLibrary = false
                    }
                }
        }
        .onChange(of: model.canChangeSelection) { _, allowed in
            SteamLibraryModel.shared.runtimeBusy = !allowed
        }
        .task {
            model.refreshTransferredGames()
            // Explicit developer launch argument for repeatable device testing.
            // The normal app/library launch remains user driven.
            if LaunchDiagnostics.enabled,
               ProcessInfo.processInfo.arguments.contains("--vr-smoke-test"),
               !didStartDesktopSmokeTest {
                didStartDesktopSmokeTest = true
                do {
                    try model.selectVRSmoke(architecture: ProcessInfo.processInfo.arguments.contains("--x86-guest") ? .x86 : nil,
                        fixtureExecutable: ProcessInfo.processInfo.arguments.contains("--x86-abi-test") ? "abi-test.exe" : nil)
                    if ProcessInfo.processInfo.arguments.contains("--cpu-self-test") {
                        model.presentationModeDraft = .desktop
                        model.launchArgumentsText = "[\"--cpu-self-test\"]"
                    } else if ProcessInfo.processInfo.arguments.contains("--inverted-bounds") {
                        model.launchArgumentsText = "[\"--inverted-bounds\"]"
                    }
                    await startLaunch()
                } catch { model.presentLibraryError(error) }
            } else if LaunchDiagnostics.enabled,
               ProcessInfo.processInfo.arguments.contains("--desktop-smoke-test"),
               !didStartDesktopSmokeTest {
                didStartDesktopSmokeTest = true
                do {
                    setenv("MADEIRA_DUMP_SURFACES", "1", 1)
                    try model.selectDesktopDemo()
                    model.launchArgumentsText = "[\"--self-test\"]"
                    await startLaunch()
                } catch { model.presentLibraryError(error) }
            } else if LaunchDiagnostics.enabled, !didStartDesktopSmokeTest,
                      let argument = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--steam-smoke-test=") }),
                      let appID = Int(argument.dropFirst("--steam-smoke-test=".count)) {
                didStartDesktopSmokeTest = true
                do {
                    try model.selectInstalledSteamGame(appID: appID)
                    await startLaunch()
                } catch { model.presentLibraryError(error) }
            }
        }
        .fileImporter(
            isPresented: $importingManifest,
            allowedContentTypes: [.json],
            allowsMultipleSelection: false,
            onCompletion: model.importManifest
        )
        .fileImporter(
            isPresented: $importingGameFolder,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false,
            onCompletion: model.importGameFolder
        )
        .fileExporter(
            isPresented: $exportingReport,
            document: reportDocument,
            contentType: .json,
            defaultFilename: exportFilename
        ) { result in
            if case .failure(let error) = result { model.presentLibraryError(error) }
        }
        .alert(L("Couldn’t open selection", "Auswahl konnte nicht geöffnet werden"), isPresented: $model.isShowingImportError) {
            Button(L("OK", "OK"), role: .cancel) { model.dismissImportError() }
        } message: {
            Text(model.importError ?? L("The selected item could not be opened.", "Das ausgewählte Element konnte nicht geöffnet werden."))
        }
        .onChange(of: model.hasAcceptedLaunch) { _, accepted in
            if model.presentationModeDraft == .immersiveVR && !accepted && model.requiresRestart {
                model.recordLifecycleEvent("dismissImmersiveSpace: accepted=false and requiresRestart=true")
                Task { await dismissImmersiveSpace() }
            }
        }
    }

    private func exportTestSessions() {
        do {
            reportDocument = CompatibilityReportDocument(data: try model.makeTestSessionsJSON())
            exportFilename = "winevision-test-sessions.json"
            exportingReport = true
        } catch { model.presentLibraryError(error) }
    }

    private var launcherHome: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 20) {
                    HStack(alignment: .center, spacing: 20) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 16).fill(.blue.opacity(0.15))
                            if let appID = model.selectedSteamAppID,
                               let url = URL(string: "https://cdn.cloudflare.steamstatic.com/steam/apps/\(appID)/header.jpg") {
                                AsyncImage(url: url) { phase in
                                    if case .success(let image) = phase {
                                        image.resizable().scaledToFill()
                                    } else {
                                        Image(systemName: "gamecontroller.fill").font(.largeTitle)
                                    }
                                }.id(appID)
                            } else {
                                Image(systemName: "gamecontroller.fill").font(.largeTitle)
                            }
                        }
                        .frame(width: 184, height: 96)
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                        .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 8) {
                            Text(model.manifest?.title ?? L("Choose your next game", "Wähle dein nächstes Spiel"))
                                .font(.title2.bold())
                                .fixedSize(horizontal: false, vertical: true)
                            Text(model.manifest == nil
                                 ? L("Open your library to get started.", "Öffne deine Bibliothek, um loszulegen.")
                                 : model.hasAcceptedLaunch
                                     ? L("Session active", "Sitzung aktiv")
                                     : model.isLaunching
                                         ? L("Preparing your game…", "Spiel wird vorbereitet …")
                                         : model.canLaunch
                                             ? L("Ready to start", "Bereit zum Start")
                                             : L("Setup needed", "Einrichtung erforderlich"))
                                .foregroundStyle(.secondary)
                        }
                    }
                    if model.manifest != nil {
                        Picker(L("Display", "Anzeige"), selection: $model.presentationModeDraft) {
                            Text(L("Immersive VR", "Immersives VR")).tag(WindowsPresentationMode.immersiveVR)
                            Text(L("Desktop window", "Desktop-Fenster")).tag(WindowsPresentationMode.desktop)
                        }
                        .pickerStyle(.segmented)
                        .disabled(!model.canChangeSelection)
                        Button { Task { await startLaunch() } } label: {
                            HStack {
                                Spacer()
                                if model.isLaunching {
                                    ProgressView()
                                    Text(L("Starting…", "Wird gestartet …"))
                                } else {
                                    Label(L("Play", "Spielen"), systemImage: "play.fill")
                                }
                                Spacer()
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .disabled(!model.canLaunch)
                        if model.hasAcceptedLaunch {
                            Button(role: .destructive) { Task { await model.stop() } } label: {
                                Label(model.isStopping ? L("Stopping…", "Wird beendet …") : L("End session", "Sitzung beenden"), systemImage: "stop.fill")
                            }.disabled(model.isStopping || model.stopRequested)
                        }
                    }
                    if model.stopRequested || model.requiresRestart {
                        ForceQuitSessionButton()
                    }
                    if let error = model.launchError {
                        Label(error, systemImage: "exclamationmark.circle")
                            .foregroundStyle(.red)
                            .accessibilityIdentifier("launch-error")
                    } else if model.requiresRestart {
                        Label(L("Close and reopen WineVision VR to play again.", "Schließe und öffne WineVision VR erneut, um weiterzuspielen."), systemImage: "arrow.clockwise")
                            .foregroundStyle(.orange)
                    } else if !model.isLaunching && !model.hasAcceptedLaunch && model.manifest != nil,
                              let reason = model.launchUnavailableReason {
                        Label(reason, systemImage: "info.circle").foregroundStyle(.secondary)
                    }
                }
                .padding(24)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 24))

                Button {
                    do { try model.selectVRSmoke() }
                    catch { model.presentLibraryError(error) }
                } label: {
                    Label(L("Built-in VR test scene", "Integrierte VR-Testszene"), systemImage: "cube.transparent")
                }
                .buttonStyle(.bordered)
                .disabled(!model.canChangeSelection)

                Button {
                    do { try model.selectDesktopDemo() }
                    catch { model.presentLibraryError(error) }
                } label: {
                    Label(L("Windows desktop test", "Windows-Desktop-Test"), systemImage: "desktopcomputer")
                }
                .buttonStyle(.bordered)
                .disabled(!model.canChangeSelection)

                Button {
                    SteamLibraryModel.shared.resumeAfterLaunchFailure()
                    showingSteamLibrary = true
                } label: {
                    HStack(spacing: 16) {
                        Image(systemName: "square.grid.2x2.fill").font(.title2)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(L("Steam library", "Steam-Bibliothek")).font(.headline)
                            Text(L("Choose a game or download something new", "Spiel auswählen oder ein neues herunterladen"))
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").foregroundStyle(.secondary)
                    }.padding(8)
                }
                .buttonStyle(.bordered)
                .disabled(!model.canChangeSelection)

                if !model.library.isEmpty {
                    Picker(L("Saved games", "Gespeicherte Spiele"), selection: Binding(
                        get: { model.selectedLibraryEntryID ?? "" },
                        set: { identifier in
                            guard !identifier.isEmpty else { return }
                            do { try model.selectLibraryEntry(id: identifier) }
                            catch { model.presentLibraryError(error) }
                        }
                    )) {
                        Text(L("Choose a saved game", "Gespeichertes Spiel auswählen")).tag("")
                        ForEach(model.library) { Text($0.manifest.title).tag($0.id) }
                    }.disabled(!model.canChangeSelection)
                }
                NavigationLink { advancedOptions } label: {
                    Label(L("Game options & local imports", "Spieloptionen & lokale Importe"), systemImage: "slider.horizontal.3")
                }.buttonStyle(.bordered)
                if let error = model.libraryError {
                    Text(error).font(.footnote).foregroundStyle(.orange)
                }
            }
            .frame(maxWidth: 700)
            .padding(28)
            .frame(maxWidth: .infinity)
        }
    }

    private var advancedOptions: some View {
        Form {
                Section(L("Rendering experiments", "Rendering-Experimente")) {
                    Picker(L("Image reconstruction", "Bildrekonstruktion"), selection: $frameSynthesisMode) {
                        Text(L("Standard", "Standard")).tag(0)
                        Text(L("Metal spatial reconstruction", "Räumliche Metal-Rekonstruktion")).tag(1)
                        Text(L("Metal reconstruction + frame extrapolation", "Metal-Rekonstruktion + Frame-Extrapolation")).tag(2)
                        Text(L("Metal temporal upscaling", "Metal-temporales Upscaling")).tag(3)
                        Text(L("Metal frame generation (adaptive)", "Metal-Frame-Generierung (adaptiv)")).tag(4)
                    }
                    .disabled(!model.canChangeSelection)
                    Text(L("Experimental. Uses submitted scene depth when available, otherwise estimates depth from the stereo images. Frame extrapolation estimates object motion; it does not increase simulation FPS. Applies on the next launch. Render scale is unchanged.", "Experimentell. Nutzt übermittelte Szenentiefe oder schätzt Tiefe aus Stereobildern. Frame-Extrapolation schätzt Objektbewegung; die Simulationsrate steigt nicht. Gilt beim nächsten Start. Die Render-Skalierung bleibt unverändert."))
                        .font(.footnote).foregroundStyle(.secondary)

                    if frameSynthesisMode == 4 {
                        Text(L("Adaptive generation engages when the game sustains below 85 FPS for 1 s and disengages at 88 FPS or more for 2 s. Between real frames it presents synthesized frames that extrapolate at most one game frame interval, and falls back to plain reprojection when the game stalls or the forecast is unreliable. At a stable 40-50 FPS, generated frames alternate with real frames.", "Die adaptive Generierung startet, wenn das Spiel 1 s lang unter 85 FPS liegt, und endet bei 88 FPS oder mehr für 2 s. Zwischen echten Frames werden synthetisierte Frames gezeigt, die höchstens ein Spielbild-Intervall extrapolieren; bei Stillstand des Spiels oder unzuverlässiger Prognose wird einfach reprojiziert. Bei stabilen 40-50 FPS wechseln generierte und echte Frames einander ab.")).font(.footnote).foregroundStyle(.secondary)
                    }
                    if frameSynthesisMode == 3 {
                        Text(L("Temporal upscaling sets sub-pixel projection jitter at launch and blends history only in the central fovea. Pair it with an internal render scale below 100%. Requires game depth.", "Temporales Upscaling setzt beim Start einen Subpixel-Projektionsjitter und mischt Verlauf nur im zentralen Fovea-Bereich. Kombinieren Sie es mit einer internen Render-Skalierung unter 100%. Benötigt Spieltiefe.")).font(.footnote).foregroundStyle(.secondary)
                    }

                    Toggle(L("Validate depth reconstruction", "Tiefenrekonstruktion prüfen"), isOn: $reconstructionValidation)
                        .disabled(!model.canChangeSelection || frameSynthesisMode != 0)
                    if frameSynthesisMode != 0 {
                        Text(L("Shadow validation is paused while image reconstruction is active.", "Die Schattenvalidierung pausiert während der Bildrekonstruktion.")).font(.footnote).foregroundStyle(.secondary)
                    }
                    Text(L("Compares reconstructed views with the original game images when scene depth is available. Adds GPU work; keeps normal stereo output. Applies on the next launch.", "Vergleicht rekonstruierte Ansichten mit den Originalbildern, wenn Szenentiefe verfügbar ist. Zusätzliche GPU-Arbeit; normale Stereoausgabe bleibt erhalten. Gilt beim nächsten Start."))
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section(L("Advanced rendering", "Erweitertes Rendering")) {
                    Slider(value: $internalRenderScale, in: 0.5...1, step: 0.05) {
                        Text(L("Internal render scale", "Interne Render-Skalierung"))
                    }
                    .disabled(!model.canChangeSelection)
                    LabeledContent(L("Internal render scale", "Interne Render-Skalierung"), value: String(format: "%.0f%%", internalRenderScale * 100))
                    Text(L("Asks the game to render each eye below the full recommended size and applies sub-pixel projection jitter for temporal upscaling. Applies on the next launch.", "Lässt das Spiel jedes Auge unterhalb der vollen empfohlenen Größe rendern und wendet einen Subpixel-Projektionsjitter für temporales Upscaling an. Wirkt beim nächsten Start."))
                        .font(.footnote).foregroundStyle(.secondary)
                    Picker(L("Render quality", "Renderqualität"), selection: $renderQuality) {
                        Text(L("System default", "Systemstandard")).tag(0.0)
                        Text(L("Sharper", "Schärfer")).tag(1.0)
                    }
                    .disabled(!model.canChangeSelection)
                    Text(L("Raises the system render quality ceiling for eye-tracked foveated rendering only; has no effect when foveation is unavailable. Applies on the next launch.", "Erhöht die systemseitige Render-Qualitätsobergrenze nur für augenverfolgtes foveiertes Rendering; ohne verfügbare Foveation ohne Wirkung. Wirkt beim nächsten Start."))
                        .font(.footnote).foregroundStyle(.secondary)
                    Toggle(L("Lossy render target compression", "Verlustbehaftete Render-Target-Kompression"), isOn: $lossyRenderTargets)
                        .disabled(!model.canChangeSelection)
                    Text(L("Stores plain color render targets with Metal lossy compression to save memory bandwidth. Lossy, so output can differ slightly from the default. Applies on the next launch.", "Speichert einfache Farb-Render-Targets mit der verlustbehafteten Metal-Kompression, um Speicherbandbreite zu sparen. Verlustbehaftet, daher kann die Ausgabe leicht vom Standard abweichen. Wirkt beim nächsten Start."))
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section {
                    Picker(L("Saved game", "Gespeichertes Spiel"), selection: Binding(
                        get: { model.selectedLibraryEntryID ?? "" },
                        set: { identifier in
                            guard !identifier.isEmpty else { return }
                            do { try model.selectLibraryEntry(id: identifier) }
                            catch { model.presentLibraryError(error) }
                        }
                    )) {
                        Text(L("Not selected", "Nicht ausgewählt")).tag("")
                        ForEach(model.library) { entry in
                            Text(entry.manifest.title).tag(entry.id)
                        }
                    }
                    .disabled(!model.canChangeSelection || model.library.isEmpty)

                    if let error = model.libraryError {
                        Text(error).font(.footnote).foregroundStyle(.orange)
                    }
                    if model.manifest != nil && model.gameDirectory != nil {
                        Button(L("Save game to library", "Spiel in Bibliothek speichern"), systemImage: "square.and.arrow.down") {
                            do { try model.saveCurrentGameToLibrary() }
                            catch { model.presentLibraryError(error) }
                        }
                        .disabled(!model.canChangeSelection)
                    }
                    if let selectedID = model.selectedLibraryEntryID {
                        Button(L("Remove saved game", "Gespeichertes Spiel entfernen"), systemImage: "trash", role: .destructive) {
                            do { try model.removeLibraryEntry(id: selectedID) }
                            catch { model.presentLibraryError(error) }
                        }
                        .disabled(!model.canChangeSelection)
                    }
                } header: {
                        Text(L("Game library", "Spielebibliothek"))
                    } footer: {
                    Text(L("Save games on this headset for quick access.", "Speichere Spiele auf diesem Headset für schnellen Zugriff."))
                }

                Section {
                    Button(L("Refresh transferred games", "Übertragene Spiele aktualisieren"), systemImage: "arrow.clockwise") { model.refreshTransferredGames() }
                        .disabled(!model.canChangeSelection)
                    ForEach(model.transferredGames) { game in
                        Button(game.manifest.title) {
                            do { try model.selectTransferredGame(id: game.id) }
                            catch { model.presentLibraryError(error) }
                        }.disabled(!model.canChangeSelection)
                    }
                    if let error = model.transferImportError {
                        Text(error).font(.footnote).foregroundStyle(.orange)
                    }
                } header: {
                        Text(L("Mac transfers", "Mac-Übertragungen"))
                    } footer: {
                    Text(L("The Mac companion copies owned local files into this app. Only folders with a final manifest marker appear; copying is not game compatibility verification.", "Die Mac-Begleit-App kopiert lokal vorhandene Dateien in diese App. Angezeigt werden nur Ordner mit einer abschließenden Manifestmarkierung; das Kopieren prüft nicht die Spielkompatibilität."))
                }

                Section(L("Import", "Importieren")) {
                    LabeledContent(L("Manifest", "Manifest")) {
                        Text(model.manifestName ?? L("Choose a Windows VR manifest", "Windows-VR-Manifest auswählen"))
                            .foregroundStyle(model.manifest == nil ? .secondary : .primary)
                    }
                    Button(L("Choose manifest…", "Manifest auswählen …"), systemImage: "doc.badge.gearshape") {
                        importingManifest = true
                    }
                    .disabled(!model.canChangeSelection)

                    LabeledContent(L("Game folder", "Spielordner")) {
                        Text(model.gameFolderName ?? L("Choose the folder containing the game", "Ordner mit dem Spiel auswählen"))
                            .foregroundStyle(model.gameDirectory == nil ? .secondary : .primary)
                    }
                    Button(L("Choose game folder…", "Spielordner auswählen …"), systemImage: "folder") {
                        importingGameFolder = true
                    }
                    .disabled(!model.canChangeSelection)
                }

                if model.manifest != nil {
                    Section {
                        if let entry = model.selectedEntry, !entry.profiles.isEmpty {
                            Picker(L("Profile", "Profil"), selection: Binding(
                                get: { model.selectedProfileID ?? "" },
                                set: { identifier in
                                    guard !identifier.isEmpty else { return }
                                    do { try model.selectProfile(id: identifier) }
                                    catch { model.presentLibraryError(error) }
                                }
                            )) {
                                ForEach(entry.profiles) { profile in
                                    Text(profile.name).tag(profile.id)
                                }
                            }
                            .disabled(!model.canChangeSelection)
                        } else {
                            Text(L("Save this game to the library to create persistent profiles.", "Speichere dieses Spiel in der Bibliothek, um dauerhafte Profile anzulegen."))
                                .foregroundStyle(.secondary)
                        }

                        TextField(L("Profile name", "Profilname"), text: $model.profileNameDraft)
                            .disabled(!model.canChangeSelection)
                        TextField(L("Launch arguments — JSON array of strings", "Startargumente — JSON-Array aus Zeichenfolgen"), text: $model.launchArgumentsText, axis: .vertical)
                            .lineLimit(2...6)
                            .disabled(!model.canChangeSelection)
                        Slider(value: $model.renderScaleDraft, in: 0.5...1, step: 0.05) {
                            Text(L("Spatial render scale", "Räumliche Render-Skalierung"))
                        }.disabled(!model.canChangeSelection || model.presentationModeDraft == .desktop)
                        LabeledContent(L("Spatial render scale", "Räumliche Render-Skalierung"), value: String(format: "%.0f%%", model.renderScaleDraft * 100))
                        Text(L("Below 100%, the guest renders smaller eyes and an ordinary Metal bilinear pass scales each eye. This is not temporal SR or DLSS.", "Unter 100 % rendert das Gastsystem kleinere Augenbilder, die anschließend mit einem gewöhnlichen bilinearen Metal-Durchlauf skaliert werden. Das ist weder temporales Super-Resolution noch DLSS."))
                            .font(.footnote).foregroundStyle(.secondary)
                        HStack {
                            Button(L("Save profile", "Profil speichern")) {
                                do { try model.saveProfile() }
                                catch { model.presentLibraryError(error) }
                            }
                            .disabled(!model.canChangeSelection || model.selectedEntry == nil)
                            Button(L("Save as new", "Als neues Profil speichern")) {
                                do { try model.saveProfile(asNew: true) }
                                catch { model.presentLibraryError(error) }
                            }
                            .disabled(!model.canChangeSelection || model.selectedEntry == nil)
                        }
                        if model.selectedProfileID != nil {
                            Button(L("Remove selected profile", "Ausgewähltes Profil entfernen"), systemImage: "trash", role: .destructive) {
                                do { try model.removeSelectedProfile() }
                                catch { model.presentLibraryError(error) }
                            }
                            .disabled(!model.canChangeSelection)
                        }
                    } header: {
                        Text(L("Per-game profiles", "Spielprofile"))
                    } footer: {
                        Text(L("Use a JSON array of strings. Arguments are passed as exact separate argv entries. Backend and graphics choices remain manifest-defined; unsupported graphics are blocked rather than silently substituted.", "Verwende ein JSON-Array aus Zeichenfolgen. Argumente werden exakt als einzelne argv-Einträge übergeben. Backend und Grafikoption bleiben im Manifest festgelegt; nicht unterstützte Grafikmodi werden blockiert und nicht stillschweigend ersetzt."))
                    }

                }

                Section(L("Wine process status", "Wine-Prozessstatus")) {
                    LabeledContent(L("Wine/runtime", "Wine/Laufzeit"), value: model.sessionStatus)
                    Text(L("Wine status is not compositor output or proof that the game is ready.", "Der Wine-Status zeigt weder die Compositor-Ausgabe noch die Spielbereitschaft an."))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section(L("Compositor queue counters", "Compositor-Warteschlangenzähler")) {
                    LabeledContent(L("Submitted", "Eingereiht"), value: counter(model.compositorCounters?.submittedFrames))
                    LabeledContent(L("Acquired", "Übernommen"), value: counter(model.compositorCounters?.acquiredFrames))
                    LabeledContent(L("Dropped", "Verworfen"), value: counter(model.compositorCounters?.droppedFrames))
                    LabeledContent(L("Completed", "Abgeschlossen"), value: counter(model.compositorCounters?.completedFrames))
                    LabeledContent(L("Queued now", "Aktuell eingereiht"), value: counter(model.compositorCounters?.queuedFrames))
                    Text(L("Native compositor ABI v1 advisory queue counters only. They are separate from Wine status and do not prove game rendering, display presentation, or readiness.", "Die Zähler der nativen Compositor-ABI v1 sind nur Richtwerte. Sie sind unabhängig vom Wine-Status und belegen weder Spielrendering noch Bildausgabe oder Spielbereitschaft."))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section(L("Compatibility report", "Kompatibilitätsbericht")) {
                    Button(L("Export versioned JSON report", "Versionierten JSON-Bericht exportieren"), systemImage: "square.and.arrow.up") {
                        do {
                            reportDocument = CompatibilityReportDocument(data: try model.makeCompatibilityReportJSON())
                            exportFilename = model.reportFilename
                            exportingReport = true
                        } catch {
                            model.presentLibraryError(error)
                        }
                    }
                    .disabled(model.manifest == nil)
                    Text(L("Includes the device and OS version, requested profile, conservative capability reasons, separate Wine and compositor status, and explicit unknown/unmeasured metrics. Environment values are not exported.", "Der Bericht enthält Geräte- und Betriebssystemversion, das angeforderte Profil, vorsichtige Begründungen zu Funktionen, getrennte Wine- und Compositor-Status sowie ausdrücklich unbekannte oder nicht gemessene Werte. Umgebungsvariablen werden nicht exportiert."))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
        }
        .navigationTitle(L("Game options", "Spieloptionen"))
    }

    private func displayName(_ value: String) -> String {
        switch value {
        case "direct3D11": L("Direct3D 11", "Direct3D 11")
        case "direct3D12": L("Direct3D 12 (experimental DXMT)", "Direct3D 12 (DXMT, experimentell)")
        case "vulkan": L("Vulkan (unavailable; launch blocked)", "Vulkan (nicht verfügbar; Start blockiert)")
        case "windowsWineFEX": L("Windows through Wine/FEX", "Windows über Wine/FEX")
        case "nativeARM64": L("Native ARM64 PE (not packaged)", "Natives ARM64-PE (nicht enthalten)")
        default: value
        }
    }

    private func counter<T: BinaryInteger>(_ value: T?) -> String {
        guard let value else { return L("Unavailable", "Nicht verfügbar") }
        return String(value)
    }

    @MainActor
    private func startLaunch() async {
        let presentation = model.presentationModeDraft
        await model.launch {
            if presentation == .desktop {
                model.showDesktopPresentation()
                try await model.waitForDesktopReady()
            } else {
                guard case .opened = await openImmersiveSpace(id: WindowsVRCompositorScene.identifier) else {
                    throw LaunchPreparationFailure.immersiveSpaceUnavailable
                }
                model.immersiveSpaceDidOpen()
                try await model.waitForCompositorReady()
            }
        }
        if !model.hasAcceptedLaunch {
            if presentation == .desktop { model.hideDesktopPresentation() }
            else {
                model.recordLifecycleEvent("dismissImmersiveSpace: launch returned without accepted session")
                await dismissImmersiveSpace()
            }
        }
    }
}

private struct CompatibilityReportDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    let data: Data

    init(data: Data) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

private struct ShaderWarmupBanner: View {
    let progress: ShaderWarmupProgress

    var body: some View {
        HStack(spacing: 12) {
            ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1)))
                .frame(width: 160)
            Text(L("Preparing shaders… \(progress.done) / \(progress.total)", "Shader werden vorbereitet … \(progress.done) / \(progress.total)"))
                .monospacedDigit()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.thinMaterial, in: Capsule())
        .accessibilityElement(children: .combine)
    }
}

private enum LaunchPreparationFailure: LocalizedError {
    case immersiveSpaceUnavailable
    var errorDescription: String? {
        L("The immersive compositor window could not be opened, so no launch request was sent.", "Das immersive Compositor-Fenster konnte nicht geöffnet werden. Es wurde keine Startanfrage gesendet.")
    }
}

// Wine/FEX owns one session per app process. A stuck guest cannot be safely
// reset by killing its threads; explicit process exit releases the whole session.
struct ForceQuitSessionButton: View {
    @State private var confirming = false

    var body: some View {
        Button(role: .destructive) { confirming = true } label: {
            Label(L("Force quit app", "App sofort beenden"), systemImage: "xmark.circle")
        }
        .confirmationDialog(L("Quit WineVision VR?", "WineVision VR beenden?"),
                            isPresented: $confirming, titleVisibility: .visible) {
            Button(L("Force quit app", "App sofort beenden"), role: .destructive) {
                Darwin._exit(0)
            }
        } message: {
            Text(L("This closes the app immediately. Unsaved Windows work will be lost. Reopen it to start another session.",
                   "Die App wird sofort geschlossen. Ungespeicherte Windows-Arbeit geht verloren. Öffne sie erneut für eine neue Sitzung."))
        }
    }
}
