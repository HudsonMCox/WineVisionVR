#ifndef WINDOWS_VR_RECONSTRUCTION_H
#define WINDOWS_VR_RECONSTRUCTION_H
#include <stdint.h>
#include <stddef.h>
// Fixed-width carrier extension. Existing COM vtables and Unix table slots stay frozen.
#define WVR_RECONSTRUCTION_ABI 0x57565231u
#pragma pack(push, 8)
typedef struct WVRReconstructionEyeV1 {
    uint64_t colorTexture, depthTexture;
    uint32_t colorSlice, colorX, colorY, width, height;
    uint32_t depthSlice, depthX, depthY, depthWidth, depthHeight;
    float originFromEye[16], projection[16];
    float minDepth, maxDepth;
} WVRReconstructionEyeV1;
typedef struct WVRReconstructionSubmitV1 {
    uint32_t abiVersion, structSize;
    int32_t status;
    uint32_t reserved;
    uint64_t commandBuffer, producerEvent, producerValue;
    uint64_t frameID, timestampNanoseconds, targetGeneration;
    WVRReconstructionEyeV1 eyes[2];
    uint64_t compositorTicket, consumerEvent;
} WVRReconstructionSubmitV1;
#pragma pack(pop)
#ifdef __cplusplus
static_assert(sizeof(WVRReconstructionEyeV1)==192);
static_assert(sizeof(WVRReconstructionSubmitV1)==464);
extern "C" {
#endif
// Borrowed Metal objects are valid only while the acquired frame lease is held.
int32_t wvr_compositor_submit_reconstruction_v1(WVRReconstructionSubmitV1 *request);
uint64_t wvr_reconstruction_transport_rejections_v1(void);
int32_t wvr_compositor_copy_reconstruction_v1(void *lease, WVRReconstructionSubmitV1 *out);
// Shadow validation only: these encodes never replace either displayed eye.
// The caller's command buffer must wait for the acquired frame's producer event.
void *wvr_reconstruction_create_v1(void *metalDevice);
void wvr_reconstruction_destroy_v1(void *context);
int32_t wvr_reconstruction_validate_v1(void *context, void *lease, void *commandBuffer);
// Debug validation output; borrowed GPU work must finish before CPU readback.
void *wvr_reconstruction_copy_output_v1(void *context, uint32_t kind);
int32_t wvr_reconstruction_set_interval_v1(void *context, uint32_t interval);
int32_t wvr_reconstruction_copy_stats_v1(void *context, char *buffer, uint32_t capacity);
#ifdef __cplusplus
}
#endif

#endif // WINDOWS_VR_RECONSTRUCTION_H
