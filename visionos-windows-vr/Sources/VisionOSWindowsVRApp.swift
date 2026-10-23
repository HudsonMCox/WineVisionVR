import SwiftUI

@main
struct VisionOSWindowsVRApp: App {
    @UIApplicationDelegateAdaptor(WineVisionApplicationDelegate.self) private var applicationDelegate
    @State private var launcherModel = LauncherModel()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // Mode 4 (adaptive frame generation with the OSS student reconstruction) is the default until the
        // user picks another mode; registered before any reader of the key.
        UserDefaults.standard.register(defaults: ["WVRFrameSynthesisMode": 4])
        // Before anything calls the compositor bridge, which reads this switch once.
        if LaunchDiagnostics.enabled {
            setenv("WVR_TRACE_BRIDGE", "1", 1)
            wvr_metal_gpu_statistics_install()
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView(model: launcherModel)
                .onChange(of: scenePhase, initial: true) { _, phase in
                    SteamLibraryModel.shared.applicationActivityChanged(phase == .active)
                    LaunchLogFile.append("lifecycle", "App scene phase=\(String(describing: phase)) uptime=\(ProcessInfo.processInfo.systemUptime) thermal=\(ProcessInfo.processInfo.thermalState.rawValue)")
                }
        }
        .windowStyle(.automatic)

        WindowsVRCompositorScene(model: launcherModel)
    }
}
