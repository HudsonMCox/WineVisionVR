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
void winios_screen_size(int *width, int *height);
void winios_set_compositor_frame(double x, double y, double width, double height);
void winios_set_desktop_rect(double x, double y, double width, double height, int set);
int winios_desktop_point_from_window(double x, double y, int *px, int *py);
int winios_compositor_set_hidden(int hidden);
void winios_pointer(int x, int y, unsigned int flags, unsigned int data);
void winios_post_key(int virtual_key, int down);
unsigned long long winios_surface_present_count(void);
#import "Steam/SwiftSteam/lzma_shim.h"
#import "../../windows-vr-native/include/WindowsVRAudioSession.h"

#import "../../windows-vr-native/include/WindowsVRReconstruction.h"

#import "../../windows-vr-native/include/WindowsVRFrameSynthesis.h"
