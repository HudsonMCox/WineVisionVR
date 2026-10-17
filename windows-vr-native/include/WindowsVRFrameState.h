#pragma once
#include "WindowsVRCompositorBridge.h"
#include <stddef.h>
// Extension carried through the existing Winemetal Unix-call hook. No table
// slots, COM vtables, or existing wire records change. Unknown peers fall back.
#define WVR_FRAME_STATE_ABI 0x57565331u
#pragma pack(push, 8)
typedef struct WVRFrameStateRequestV1 {
    uint32_t abiVersion, structSize;
    int32_t status;
    uint32_t operation; // 1 coherent snapshot; 2 wait for newer tracked display pose
    uint64_t afterTimestampNanoseconds;
    uint64_t timeoutNanoseconds; // bounded by the host to 100 ms
    uint64_t expectedTargetGeneration;
    uint64_t displayPeriodNanoseconds; // compositor publish cadence, never guest frame intervals
    WVRFrameTrackingV1 tracking;
    WVRRenderTargetInfoV1 targets;
    WVRControllerStateV1 controllers[WVR_COMPOSITOR_VIEW_COUNT];
} WVRFrameStateRequestV1;
#pragma pack(pop)
#ifdef __cplusplus
static_assert(sizeof(WVRFrameStateRequestV1) == 720, "frame state wire layout changed");
static_assert(offsetof(WVRFrameStateRequestV1, tracking) == 48, "frame state wire alignment changed");
extern "C" {
#endif
WVR_COMPOSITOR_EXPORT int32_t wvr_compositor_frame_state_v1(WVRFrameStateRequestV1 *request);
#ifdef __cplusplus
}
#endif
