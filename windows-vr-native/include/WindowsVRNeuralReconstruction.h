#ifndef WINDOWS_VR_NEURAL_RECONSTRUCTION_H
#define WINDOWS_VR_NEURAL_RECONSTRUCTION_H

#include <stdint.h>
#include <stddef.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

#define WVR_NEURAL_WEIGHTS_MAGIC 0x57564E57u

#pragma pack(push, 4)
typedef struct WVRNeuralWeightsHeaderV1 {
  uint32_t magic;               // 0x57564E57 'WVNW'
  uint32_t version;             // 1
  uint32_t scale;               // 2
  uint32_t foveal_ch;           // 32
  uint32_t foveal_ch_low;       // 48
  uint32_t foveal_blocks;       // 2
  uint32_t extrap_ch;           // 24
  uint32_t extrap_blocks;       // 2
  uint32_t num_tensors;         // 32
  uint32_t total_fp16_elements; // 278948
  uint32_t reserved[6];         // 64 bytes total
} WVRNeuralWeightsHeaderV1;

typedef struct WVRNeuralTensorDescV1 {
  uint32_t offset_elements;
  uint32_t num_elements;
  uint32_t shape0;
  uint32_t shape1;
  uint32_t shape2;
  uint32_t shape3;
} WVRNeuralTensorDescV1;
#pragma pack(pop)
#ifdef __cplusplus
static_assert(sizeof(WVRNeuralWeightsHeaderV1) == 64);
static_assert(sizeof(WVRNeuralTensorDescV1) == 24);
#endif

typedef struct WVRNeuralEyeParamsV1 {
  float originFromEye[16];
  float projection[16];
  float gazeCenterUV[2];
  float gazeRadiusUV;
  float jitterNDC[2];
  uint32_t width;
  uint32_t height;
  uint32_t eyeRole; // 0 = Eye A (primary), 1 = Eye B (secondary)
  uint32_t gazeValid; // 1 = gaze from rate map / caller, 0 = 0.25 fallback
} WVRNeuralEyeParamsV1;

typedef struct WVRNeuralFrameParamsV1 {
  uint64_t frameID;
  uint64_t timestampNanoseconds;
  uint64_t displayTimestampNanoseconds;
  uint32_t primaryEye; // frameID & 1
  WVRNeuralEyeParamsV1 eyes[2];
} WVRNeuralFrameParamsV1;

typedef struct WVRNeuralContext WVRNeuralContext;

WVRNeuralContext *wvr_neural_create_v1(void *metalDevice);
void wvr_neural_destroy_v1(WVRNeuralContext *ctx);
void wvr_neural_reset_v1(WVRNeuralContext *ctx);

int32_t wvr_neural_encode_v1(
    WVRNeuralContext *ctx,
    void *commandBuffer,
    const WVRNeuralFrameParamsV1 *params,
    void *inputColorEye0, void *inputDepthEye0,
    void *inputColorEye1, void *inputDepthEye1,
    void *outputColorEye0, void *outputDepthEye0,
    void *outputColorEye1, void *outputDepthEye1,
    const float displayOriginFromEye0[16], const float displayProjection0[16],
    const float displayOriginFromEye1[16], const float displayProjection1[16]);

int32_t wvr_neural_encode_ratemap_v1(
    WVRNeuralContext *ctx,
    void *commandBuffer,
    const WVRNeuralFrameParamsV1 *params,
    void *inputColorEye0, void *inputDepthEye0,
    void *inputColorEye1, void *inputDepthEye1,
    void *outputColorEye0, void *outputDepthEye0,
    void *outputColorEye1, void *outputDepthEye1,
    const float displayOriginFromEye0[16], const float displayProjection0[16],
    const float displayOriginFromEye1[16], const float displayProjection1[16],
    void *rateMapEye0, uint32_t rateMapLayer0,
    void *rateMapEye1, uint32_t rateMapLayer1);

int32_t wvr_neural_copy_stats_v1(WVRNeuralContext *ctx, char *buffer, uint32_t capacity);

// Live In-App Dynamic Resolution & Foveation Governor (DRS)
// Runs directly in native C++ on visionOS inside the app sandbox on every frame.
typedef struct WVRDynamicGovernorStatusV1 {
  float measuredGPUFrameTimeMs;
  float currentRenderScale;
  float currentFoveaRadiusDeg;
  float mipLodBias;
  uint32_t extrapolationRatio;
} WVRDynamicGovernorStatusV1;

void wvr_neural_drs_update_v1(WVRNeuralContext *ctx, float measuredFrameMs);
WVRDynamicGovernorStatusV1 wvr_neural_drs_get_status_v1(WVRNeuralContext *ctx);

// In-App Gaussian Splatting for Apple Vision Pro (Metal / M2 Tile Rasterizer)
#define WVR_GAUSSIAN_SPLATS_MAGIC 0x47525657u // 'WVRG'

#pragma pack(push, 4)
typedef struct WVRGaussianSplatHeaderV1 {
  uint32_t magic;      // 0x47525657 'WVRG'
  uint32_t version;    // 1
  uint32_t numSplats;  // Number of active primitives
  uint32_t reserved;   // 0
} WVRGaussianSplatHeaderV1;

typedef struct WVRGaussianPrimitiveV1 {
  float x, y;                   // Screen-space position (pixels)
  float cov_xx, cov_xy, cov_yy; // 2D upper-triangular covariance
  float r, g, b;                // Base DC color [0..1]
  float opacity;                // Alpha [0..1]
  float depth;                  // Linear view depth
  // Degree-1 Spherical Harmonics coefficients for 6DoF view-dependent specular reflection
  float sh1_y[3];               // RGB coefficients for Y_1^-1
  float sh1_z[3];               // RGB coefficients for Y_1^0
  float sh1_x[3];               // RGB coefficients for Y_1^1
  float reserved;               // 80 bytes aligned
} WVRGaussianPrimitiveV1;
#pragma pack(pop)

#ifdef __cplusplus
static_assert(sizeof(WVRGaussianSplatHeaderV1) == 16);
static_assert(sizeof(WVRGaussianPrimitiveV1) == 80);
#endif

// DRS-Coupled Wireless Slice Pacing for Wi-Fi 6E
typedef struct WVRNetworkPacingStatusV1 {
  float targetBitrateMbps;
  uint32_t intraRefreshRate;
  uint32_t sliceCount;
  bool dropNonEssentialSlices;
} WVRNetworkPacingStatusV1;

WVRNetworkPacingStatusV1 wvr_neural_drs_get_pacing_v1(WVRNeuralContext *ctx);

// Apple Neural Engine (ANE) Core ML Offloading for Gaussian Splat & Foveal Networks
// Runs on the Vision Pro 16-core Neural Engine (0% GPU overhead, ~1.2 ms latency)
int32_t wvr_neural_load_coreml_model_v1(WVRNeuralContext *ctx, const char *modelPath);
int32_t wvr_neural_predict_ane_v1(
    WVRNeuralContext *ctx,
    void *inputIOSurface,
    void *outputIOSurface);

// Loads a foveated .wvrg splat binary into GPU Metal buffers inside the visionOS app sandbox
int32_t wvr_neural_load_splats_v1(WVRNeuralContext *ctx, const char *path);

// Rasterizes Gaussian splats directly into a target Metal texture canvas using Apple Silicon 16x16 tiles
int32_t wvr_neural_rasterize_splats_v1(
    WVRNeuralContext *ctx,
    void *commandBuffer,
    void *targetTexture,
    uint32_t width,
    uint32_t height);

#ifdef __cplusplus
}
#endif

#endif // WINDOWS_VR_NEURAL_RECONSTRUCTION_H
