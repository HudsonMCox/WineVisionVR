#ifndef WINDOWS_VR_FRAME_SYNTHESIS_H
#define WINDOWS_VR_FRAME_SYNTHESIS_H
#include "WindowsVRCompositorBridge.h"
#ifdef __cplusplus
extern "C" {
#endif
// Native-host API only: no changes to the guest or Unix carrier ABI.
// 1 = edge-adaptive spatial reconstruction; 2 adds bounded object
// extrapolation. These are custom Metal algorithms, not NVIDIA DLSS or a
// MetalFX interpolator.
void *wvr_synthesis_create_v1(void *device, uint32_t mode);
void wvr_synthesis_destroy_v1(void *context);
void wvr_synthesis_reset_v1(void *context);
int32_t wvr_synthesis_ingest_v1(void *context,
                                const WVRAcquiredStereoFrameV2 *frame,
                                const WVRFrameTrackingV1 *tracking,
                                uint64_t generation, void *commandBuffer);
typedef struct WVRFrameSynthesisViewV1 {
  float originFromEye[16], projection[16];
  uint32_t width, height;
} WVRFrameSynthesisViewV1;
// Produces both eyes in the SDK-predicted DISPLAY pose. The caller must present
// this output without applying the old guest-to-display head warp a second
// time.
int32_t wvr_synthesis_encode_display_v1(void *context,
                                        uint64_t timestampNanoseconds,
                                        const WVRFrameSynthesisViewV1 views[2],
                                        uint32_t extrapolate,
                                        void *commandBuffer);
// Both eye outputs are encoded together. They stay owned by the context and are
// borrowed until its next encode/destroy; the caller's retained command buffer
// owns resources used for presentation. No CPU/GPU wait is performed here.
int32_t wvr_synthesis_encode_v1(void *context,
                                uint64_t displayTimestampNanoseconds,
                                uint32_t leftWidth, uint32_t leftHeight,
                                uint32_t rightWidth, uint32_t rightHeight,
                                uint32_t extrapolate, void *commandBuffer);
// Owned, unmodified eye snapshot. Sharing this with display fallback avoids a
// second full-resolution stereo copy per new game frame. Release with the
// bridge.
void *wvr_synthesis_copy_source_v1(void *context, uint32_t eye);
void *wvr_synthesis_copy_output_v1(void *context, uint32_t eye);
// Diagnostic flow: xy are backward residuals in CURRENT-eye normalized UV,
// z is photometric confidence and w is depth confidence. Wait for GPU
// completion.
void *wvr_synthesis_copy_motion_v1(void *context, uint32_t eye);
void *wvr_synthesis_copy_depth_v1(void *context, uint32_t eye);
int32_t wvr_synthesis_copy_stats_v1(void *context, char *buffer,
                                    uint32_t capacity);
#ifdef __cplusplus
}
#endif
#endif
