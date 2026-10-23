#pragma once

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct WVRMetalFXDispatchV1 {
  void *commandBuffer;
  void *color;
  void *depth;  /* RG32Float linear metres .r, validity .g, render size */
  void *output; /* RGBA16Float display size */
  float jitterNDC[2];
  uint32_t jitterValid;
  float originFromEye[16];
  float projection[16];
  float previousOriginFromEye[16];
  float previousProjection[16];
  float frameTimeDeltaMs;
  uint32_t reset;
  uint32_t renderWidth, renderHeight, displayWidth, displayHeight;
} WVRMetalFXDispatchV1;

void *wvr_metalfx_create_v1(void *device);
void wvr_metalfx_destroy_v1(void *ctx);
void wvr_metalfx_reset_v1(void *ctx);
int32_t wvr_metalfx_dispatch_v1(void *ctx, const WVRMetalFXDispatchV1 *d);
int32_t wvr_metalfx_copy_stats_v1(void *ctx, char *buf, uint32_t cap);

#ifdef __cplusplus
}
#endif
