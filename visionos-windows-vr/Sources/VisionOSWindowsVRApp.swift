import SwiftUI

@main
struct VisionOSWindowsVRApp: App {
    @State private var launcherModel = LauncherModel()

    init() {
        // Before anything calls the compositor bridge, which reads this switch once.
        if LaunchDiagnostics.enabled {
            setenv("WVR_TRACE_BRIDGE", "1", 1)
            wvr_metal_gpu_statistics_install()
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView(model: launcherModel)
        }
        .windowStyle(.automatic)

        WindowsVRCompositorScene(model: launcherModel)
    }
}
