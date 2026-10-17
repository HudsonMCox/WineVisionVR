#pragma once
#include <stdint.h>

// Versioned request carried through Winemetal's existing pointer transport.
// Old native handlers reject this version; callers then render uniformly.
#define WVR_GUEST_FOVEATION_ABI 0x57564631u
#define WVR_GUEST_FOVEATION_SAFE_SHADER 1u
#pragma pack(push, 4)
typedef struct WVRGuestFoveationAttachmentV1 {
  uint64_t texture;
  uint32_t slice, load;
  double clearColor[4];
} WVRGuestFoveationAttachmentV1;
typedef struct WVRGuestFoveationPassV1 {
  uint32_t abiVersion, structSize;
  int32_t status;
  uint32_t operation; // 0 capabilities (encoder=borrowed identity buffer), 1 begin scene, 2 resolve, 3 bind
                      // uniform identity map, 4 finish preload; 5 register event progress,
                      // 6 cancel event progress (colorTexture=event; encoder=page; token=lease)
  uint32_t flags, width, height, colorLoad, depthLoad;
  uint64_t commandBuffer, colorTexture, depthTexture;
  double clearColor[4];
  double clearDepth;
  uint64_t encoder, token;
  uint32_t colorSlice, depthSlice;
  uint32_t colorCount;
  WVRGuestFoveationAttachmentV1 additionalColors[7];
  uint64_t stencilTexture;
  uint32_t stencilSlice, stencilLoad, stencilClear;
  uint32_t depthStencilReadOnlyMask;
  uint32_t drawCalls;
} WVRGuestFoveationPassV1;
#pragma pack(pop)
#ifdef __cplusplus
static_assert(sizeof(WVRGuestFoveationPassV1) == 492);
extern "C" {
#endif
int wvr_guest_foveation_install_v1(void);
void wvr_guest_foveation_reset_v1(void);
void wvr_guest_foveation_publish_maps_v1(void *left, uint32_t leftLayer,
                                         void *right, uint32_t rightLayer);
void wvr_guest_foveation_register_eye_v1(uint32_t role, void *texture,
                                         uint32_t slice, uint32_t x, uint32_t y,
                                         uint32_t width, uint32_t height);
// Native endpoint also used by the synthetic GPU contract probe.
int wvr_guest_foveation_process_v1(WVRGuestFoveationPassV1 *request);
int wvr_guest_foveation_copy_stats_v1(char *buffer, uint32_t capacity);
#ifdef __cplusplus
}
#endif
