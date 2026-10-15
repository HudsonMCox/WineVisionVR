#import <QuartzCore/CAMetalLayer.h>
#import "../../windows-vr-native/include/WindowsVRCompositorBridge.h"
#import "../../windows-vr-native/include/WindowsVRMetalDiagnostics.h"
#import "../../windows-vr-native/include/WindowsVRThreadDump.h"
#import "../../windows-vr-native/include/WindowsVRThreadTrace.h"

// Exported by the embedded Madeira runtime. Steam preparation seeds files;
// it does not start Wine or require JIT.
int wine_process_is_running(void);
int wineserver_is_running(void);
void madeira_seed_prefix_if_needed(const char *prefix_path);
// The single CAMetalLayer DXMT's swapchain binds to (IOSDisplayShim.m keeps a raw pointer).
void madeira_display_set_layer(CAMetalLayer *layer);
#import "Steam/SwiftSteam/lzma_shim.h"
#import "../../windows-vr-native/include/WindowsVRAudioSession.h"
