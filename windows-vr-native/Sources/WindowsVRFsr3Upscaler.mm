#include "WindowsVRFsr3Upscaler.h"

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <simd/simd.h>

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <mutex>

@interface WVRFsr3UpscalerBundleAnchor : NSObject
@end

@implementation WVRFsr3UpscalerBundleAnchor
@end

namespace {

static constexpr uint32_t kFsr3LanczosLutWidth = 128;
static constexpr uint32_t kFsr3SpdMipCount = 6;
static constexpr float kFsr3Pi = 3.14159265358979323846f;

struct Fsr3UpscalerConstants {
  int32_t iRenderSize[2];
  int32_t iPreviousFrameRenderSize[2];
  int32_t iUpscaleSize[2];
  int32_t iPreviousFrameUpscaleSize[2];
  int32_t iMaxRenderSize[2];
  int32_t iMaxUpscaleSize[2];
  float fDeviceToViewDepth[4];
  float fJitter[2];
  float fPreviousFrameJitter[2];
  float fMotionVectorScale[2];
  float fDownscaleFactor[2];
  float fMotionVectorJitterCancellation[2];
  float fTanHalfFOV;
  float fJitterSequenceLength;
  float fDeltaTime;
  float fDeltaPreExposure;
  float fViewSpaceToMetersFactor;
  float fFrameIndex;
  float fVelocityFactor;
  float fReactivenessScale;
  float fShadingChangeScale;
  float fAccumulationAddedPerFrame;
  float fMinDisocclusionAccumulation;
  float fPad[3];
};
static_assert(sizeof(Fsr3UpscalerConstants) == 160, "Fsr3UpscalerConstants must be 160 bytes");

struct FfxSpdConstants {
  uint32_t mips;
  uint32_t numWorkGroups;
  uint32_t workGroupOffset[2];
  uint32_t renderSize[2];
};
static_assert(sizeof(FfxSpdConstants) == 24, "FfxSpdConstants must be 24 bytes");

struct FfxRcasConstants {
  uint32_t rcasConfig[4];
};
static_assert(sizeof(FfxRcasConstants) == 16, "FfxRcasConstants must be 16 bytes");

struct WVRFsr3PrepassParams {
  simd_float4x4 currentInverseProjection;
  simd_float4x4 previousViewFromCurrentView;
  simd_float4x4 previousProjection;
  float invMotionVectorScale[2];
  float deviceToViewDepth0;
  float deviceToViewDepth1;
  float nearZ;
  float farZ;
  uint32_t renderWidth;
  uint32_t renderHeight;
  uint32_t reset;
  uint32_t pad[3];
};

static NSString *const kWVRFsr3RuntimeHelperMetalSource = @R"MSL(
using namespace metal;

struct WVRFsr3PrepassParams {
  float4x4 currentInverseProjection;
  float4x4 previousViewFromCurrentView;
  float4x4 previousProjection;
  float2   invMotionVectorScale;
  float    deviceToViewDepth0;
  float    deviceToViewDepth1;
  float    nearZ;
  float    farZ;
  uint     renderWidth;
  uint     renderHeight;
  uint     reset;
  uint     pad0;
  uint     pad1;
  uint     pad2;
};

kernel void camera_motion_vectors(
    constant WVRFsr3PrepassParams& p [[buffer(0)]],
    texture2d<float, access::read> in_depth [[texture(0)]],
    texture2d<float, access::write> out_mv [[texture(1)]],
    uint2 gid [[thread_position_in_grid]]) {
  if (gid.x >= p.renderWidth || gid.y >= p.renderHeight) return;

  if (p.reset != 0u) {
    out_mv.write(float4(0.0f), gid);
    return;
  }

  float4 d = in_depth.read(gid);
  float linearDepth = d.x;
  float valid = d.y;
  if (valid <= 0.1f || !isfinite(linearDepth) || linearDepth <= 1e-4f) {
    out_mv.write(float4(0.0f), gid);
    return;
  }

  float2 curUV = (float2(gid) + 0.5f) / float2(float(p.renderWidth), float(p.renderHeight));
  float2 ndc = curUV * float2(2.0f, -2.0f) + float2(-1.0f, 1.0f);

  float4 clipRay = float4(ndc, 0.5f, 1.0f);
  float4 viewRay = p.currentInverseProjection * clipRay;
  float3 viewDir = viewRay.xyz / max(1e-8f, abs(viewRay.z));
  float3 viewPos = viewDir * linearDepth;

  float4 prevViewPos = p.previousViewFromCurrentView * float4(viewPos, 1.0f);
  float4 prevClip = p.previousProjection * prevViewPos;

  float2 mv = float2(0.0f);
  if (prevClip.w > 1e-6f && isfinite(prevClip.w)) {
    float2 prevNDC = prevClip.xy / prevClip.w;
    float2 prevUV = prevNDC * float2(0.5f, -0.5f) + 0.5f;
    if (all(isfinite(prevUV))) {
      // FSR3 expects low-res MVs pointing current -> previous in UV space,
      // scaled by 1.0 / cb.fMotionVectorScale.
      mv = clamp((prevUV - curUV) * p.invMotionVectorScale, float2(-1.0f), float2(1.0f));
    }
  }

  out_mv.write(float4(mv, 0.0f, 0.0f), gid);
}

kernel void depth_to_device(
    constant WVRFsr3PrepassParams& p [[buffer(0)]],
    texture2d<float, access::read> in_depth [[texture(0)]],
    texture2d<float, access::write> out_device_depth [[texture(1)]],
    texture2d<uint, access::write> out_reconstructed_prev_depth [[texture(2)]],
    uint2 gid [[thread_position_in_grid]]) {
  if (gid.x >= p.renderWidth || gid.y >= p.renderHeight) return;

  float4 d = in_depth.read(gid);
  float linearDepth = d.x;
  float valid = d.y;

  // Non-inverted [0, 1] device depth matching FFX_FSR3UPSCALER_OPTION_INVERTED_DEPTH == 0:
  // GetViewSpaceDepth(z_dev) = abs(fDeviceToViewDepth[1] / (z_dev - fDeviceToViewDepth[0]))
  // => z_dev = fDeviceToViewDepth[0] + fDeviceToViewDepth[1] / z_view
  float devDepth = 1.0f;
  if (valid > 0.1f && isfinite(linearDepth) && linearDepth > 1e-4f) {
    float z = clamp(linearDepth, p.nearZ, p.farZ);
    devDepth = saturate(p.deviceToViewDepth0 + (p.deviceToViewDepth1 / z));
  }

  out_device_depth.write(float4(devDepth, 0.0f, 0.0f, 0.0f), gid);
  // Initialize reconstructed previous nearest depth to 1.0f (0x3f800000u) before atomic_fetch_min
  out_reconstructed_prev_depth.write(uint4(0x3f800000u, 0u, 0u, 0u), gid);
}

kernel void clear_fsr3_state(
    texture2d<float, access::write> rw_frame_info [[texture(0)]],
    texture2d<uint, access::write> rw_spd_atomic [[texture(1)]],
    uint2 gid [[thread_position_in_grid]]) {
  if (gid.x == 0u && gid.y == 0u) {
    rw_frame_info.write(float4(1.0f, 1e4f, 1.0f, 0.0f), uint2(0u, 0u));
    rw_spd_atomic.write(uint4(0u, 0u, 0u, 0u), uint2(0u, 0u));
  }
}

kernel void clear_history_textures(
    texture2d<float, access::write> tex_render_r8_0 [[texture(0)]],
    texture2d<float, access::write> tex_render_r8_1 [[texture(1)]],
    texture2d<float, access::write> tex_render_rgba16_0 [[texture(2)]],
    texture2d<float, access::write> tex_render_rgba16_1 [[texture(3)]],
    texture2d<float, access::write> tex_render_r16_0 [[texture(4)]],
    texture2d<float, access::write> tex_render_r16_1 [[texture(5)]],
    texture2d<float, access::write> tex_display_rgba16_0 [[texture(6)]],
    texture2d<float, access::write> tex_display_rgba16_1 [[texture(7)]],
    texture2d<float, access::write> tex_display_locks [[texture(8)]],
    uint2 gid [[thread_position_in_grid]]) {
  if (gid.x < tex_render_r8_0.get_width() && gid.y < tex_render_r8_0.get_height()) {
    tex_render_r8_0.write(float4(0.0f), gid);
    tex_render_r8_1.write(float4(0.0f), gid);
    tex_render_rgba16_0.write(float4(0.0f), gid);
    tex_render_rgba16_1.write(float4(0.0f), gid);
    tex_render_r16_0.write(float4(0.0f), gid);
    tex_render_r16_1.write(float4(0.0f), gid);
  }
  if (gid.x < tex_display_rgba16_0.get_width() && gid.y < tex_display_rgba16_0.get_height()) {
    tex_display_rgba16_0.write(float4(0.0f), gid);
    tex_display_rgba16_1.write(float4(0.0f), gid);
    tex_display_locks.write(float4(0.0f), gid);
  }
}
)MSL";

static uint16_t float_to_fp16(float value) {
  uint32_t bits = 0;
  std::memcpy(&bits, &value, sizeof(bits));
  const uint32_t sign = (bits >> 16) & 0x8000u;
  const int32_t exp = int32_t((bits >> 23) & 0xffu) - 127 + 15;
  uint32_t mant = bits & 0x007fffffu;
  if (exp <= 0) {
    if (exp < -10) return uint16_t(sign);
    mant = (mant | 0x00800000u) >> (1 - exp);
    return uint16_t(sign | ((mant + 0x00000fffu + ((mant >> 13) & 1u)) >> 13));
  }
  if (exp >= 31) {
    return uint16_t(sign | 0x7c00u);
  }
  return uint16_t(sign | (uint32_t(exp) << 10) | ((mant + 0x00000fffu + ((mant >> 13) & 1u)) >> 13));
}

static uint32_t float_as_u32(float v) {
  uint32_t u = 0;
  std::memcpy(&u, &v, sizeof(u));
  return u;
}

static uint32_t pack_half_2x16(float x, float y) {
  const uint32_t lo = uint32_t(float_to_fp16(x));
  const uint32_t hi = uint32_t(float_to_fp16(y));
  return lo | (hi << 16);
}

static float lanczos2_scalar(float value) {
  return std::abs(value) < 1e-5f
             ? 1.0f
             : (std::sin(kFsr3Pi * value) / (kFsr3Pi * value)) *
                   (std::sin(0.5f * kFsr3Pi * value) / (0.5f * kFsr3Pi * value));
}

static void fsr_rcas_con(uint32_t *con, float sharpness) {
  // FidelityFX FsrRcasCon: sharpness is RCAS stops (0.0 = max sharp, 2.0 = min sharp).
  const float sharp = std::exp2(-sharpness);
  con[0] = float_as_u32(sharp);
  con[1] = pack_half_2x16(sharp, sharp);
  con[2] = 0u;
  con[3] = 0u;
}

static void ffx_spd_setup(
    uint32_t dispatchThreadGroupCountXY[2],
    uint32_t workGroupOffset[2],
    uint32_t numWorkGroupsAndMips[2],
    const uint32_t rectInfo[4]) {
  workGroupOffset[0] = rectInfo[0] / 64u;
  workGroupOffset[1] = rectInfo[1] / 64u;

  const uint32_t endIndexX = (rectInfo[0] + rectInfo[2] - 1u) / 64u;
  const uint32_t endIndexY = (rectInfo[1] + rectInfo[3] - 1u) / 64u;

  dispatchThreadGroupCountXY[0] = endIndexX + 1u - workGroupOffset[0];
  dispatchThreadGroupCountXY[1] = endIndexY + 1u - workGroupOffset[1];

  numWorkGroupsAndMips[0] = dispatchThreadGroupCountXY[0] * dispatchThreadGroupCountXY[1];

  const uint32_t maxDim = std::max(rectInfo[2], rectInfo[3]);
  uint32_t mips = 0u;
  if (maxDim > 0u) {
    mips = uint32_t(std::floor(std::log2(double(maxDim))));
  }
  numWorkGroupsAndMips[1] = std::min(mips, 12u);
}

static simd_float4x4 load_mat4(const float m[16]) {
  simd_float4x4 out;
  out.columns[0] = simd_make_float4(m[0], m[1], m[2], m[3]);
  out.columns[1] = simd_make_float4(m[4], m[5], m[6], m[7]);
  out.columns[2] = simd_make_float4(m[8], m[9], m[10], m[11]);
  out.columns[3] = simd_make_float4(m[12], m[13], m[14], m[15]);
  return out;
}

static bool mat4_is_valid(const simd_float4x4 &m) {
  float normSq = 0.0f;
  for (int c = 0; c < 4; ++c) {
    for (int r = 0; r < 4; ++r) {
      const float v = m.columns[c][r];
      if (!std::isfinite(v)) return false;
      normSq += v * v;
    }
  }
  if (normSq < 1e-8f) return false;
  const float det = simd_determinant(m);
  return std::isfinite(det) && std::fabs(det) > 1e-10f;
}

static void extract_near_far_from_projection(const float proj[16], float *outNear, float *outFar) {
  // Standard VR right-handed [0, 1] perspective projection has:
  // m22 = proj[10] = f / (n - f), m23 = proj[11] = -1, m32 = proj[14] = (f * n) / (n - f)
  float nearZ = 0.05f;
  float farZ = 1000.0f;
  const float m22 = proj[10];
  const float m32 = proj[14];
  if (std::isfinite(m22) && std::isfinite(m32) && std::fabs(m22) > 1e-6f && std::fabs(m32) > 1e-6f) {
    const float candNear = std::fabs(m32 / m22);
    const float denomFar = (proj[11] < 0.0f) ? (m22 + 1.0f) : (m22 - 1.0f);
    float candFar = 1000.0f;
    if (std::fabs(denomFar) > 1e-5f) {
      candFar = std::fabs(m32 / denomFar);
    } else {
      candFar = std::max(candNear * 1000.0f, 1000.0f);
    }
    if (std::isfinite(candNear) && candNear >= 1e-4f && candNear < 100.0f) {
      nearZ = candNear;
    }
    if (std::isfinite(candFar) && candFar > nearZ + 0.1f && candFar <= 100000.0f) {
      farZ = candFar;
    } else {
      farZ = std::max(nearZ * 1000.0f, 1000.0f);
    }
  }
  *outNear = nearZ;
  *outFar = farZ;
}

static MTLTextureUsage fsr3_rw_texture_usage(bool atomicAccess) {
  MTLTextureUsage usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
  if (atomicAccess) {
    if (@available(macOS 13.0, iOS 16.0, tvOS 16.0, *)) {
      usage |= MTLTextureUsageShaderAtomic;
    }
  }
  return usage;
}

static bool ensure_tex(
    id<MTLDevice> device,
    id<MTLTexture> __strong *slot,
    MTLPixelFormat fmt,
    uint32_t w,
    uint32_t h,
    uint32_t mipCount,
    MTLStorageMode storageMode,
    MTLTextureUsage usage,
    NSString *label) {
  if (*slot &&
      (*slot).pixelFormat == fmt &&
      (*slot).width == w &&
      (*slot).height == h &&
      (*slot).mipmapLevelCount == mipCount) {
    return false;
  }
  MTLTextureDescriptor *desc =
      [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:fmt
                                                         width:w
                                                        height:h
                                                     mipmapped:(mipCount > 1)];
  desc.mipmapLevelCount = mipCount;
  desc.storageMode = storageMode;
  desc.usage = usage;
  *slot = [device newTextureWithDescriptor:desc];
  if (*slot && label) {
    (*slot).label = label;
  }
  return true;
}

struct WVRFsr3UpscalerContext {
  std::mutex lock;
  id<MTLDevice> device = nil;
  id<MTLLibrary> fsrLibrary = nil;
  id<MTLLibrary> helperLibrary = nil;

  // 8 SDK FSR3 passes from default.metallib
  id<MTLComputePipelineState> psoPrepareInputs = nil;
  id<MTLComputePipelineState> psoLumaPyramid = nil;
  id<MTLComputePipelineState> psoShadingChangePyramid = nil;
  id<MTLComputePipelineState> psoShadingChange = nil;
  id<MTLComputePipelineState> psoPrepareReactivity = nil;
  id<MTLComputePipelineState> psoLumaInstability = nil;
  id<MTLComputePipelineState> psoAccumulate = nil;
  id<MTLComputePipelineState> psoRcas = nil;

  // Runtime-compiled helper passes
  id<MTLComputePipelineState> psoCameraMotionVectors = nil;
  id<MTLComputePipelineState> psoDepthToDevice = nil;
  id<MTLComputePipelineState> psoClearFsr3State = nil;
  id<MTLComputePipelineState> psoClearHistory = nil;

  // Constant/static internal resources
  id<MTLTexture> lanczosLut = nil;
  id<MTLTexture> defaultReactivity = nil;
  id<MTLTexture> defaultTransparencyAndComposition = nil;
  id<MTLTexture> defaultExposure = nil;
  id<MTLTexture> frameInfo = nil;
  id<MTLTexture> spdAtomicCounter = nil;

  // Render-size internal resources
  id<MTLTexture> deviceDepth = nil;
  id<MTLTexture> motionVectors = nil;
  id<MTLTexture> reconstructedPrevNearestDepth = nil;
  id<MTLTexture> dilatedMotionVectors = nil;
  id<MTLTexture> dilatedDepth = nil;
  id<MTLTexture> farthestDepth = nil;
  id<MTLTexture> luma[2] = {nil, nil};
  id<MTLTexture> accumulation[2] = {nil, nil};
  id<MTLTexture> lumaHistory[2] = {nil, nil};
  id<MTLTexture> dilatedReactiveMasks = nil;
  id<MTLTexture> lumaInstability = nil;

  // Half-render-size & SPD mip resources
  id<MTLTexture> farthestDepthMip1 = nil;
  id<MTLTexture> shadingChange = nil;
  id<MTLTexture> spdMips = nil;
  id<MTLTexture> spdMipViews[kFsr3SpdMipCount] = {nil, nil, nil, nil, nil, nil};

  // Display-size internal resources
  id<MTLTexture> internalUpscaledColor[2] = {nil, nil};
  id<MTLTexture> newLocks = nil;

  // Frame state
  uint32_t renderWidth = 0;
  uint32_t renderHeight = 0;
  uint32_t displayWidth = 0;
  uint32_t displayHeight = 0;
  uint32_t prevRenderWidth = 0;
  uint32_t prevRenderHeight = 0;
  uint32_t prevDisplayWidth = 0;
  uint32_t prevDisplayHeight = 0;
  float prevJitterPixels[2] = {0.0f, 0.0f};
  uint32_t frameIndex = 0;
  bool pendingReset = true;

  // Diagnostic counters
  uint64_t dispatches = 0;
  uint64_t resets = 0;
  uint64_t resizes = 0;
  uint64_t missingPipelines = 0;
};

static id<MTLComputePipelineState> build_pso(
    id<MTLDevice> device,
    id<MTLLibrary> lib,
    NSString *fnName,
    uint64_t *missingCounter) {
  if (!device || !lib) {
    if (missingCounter) (*missingCounter)++;
    return nil;
  }
  id<MTLFunction> fn = [lib newFunctionWithName:fnName];
  if (!fn) {
    if (missingCounter) (*missingCounter)++;
    NSLog(@"[WVR-FSR3] Missing Metal function '%@'", fnName);
    return nil;
  }
  NSError *err = nil;
  id<MTLComputePipelineState> pso = [device newComputePipelineStateWithFunction:fn error:&err];
  if (!pso) {
    if (missingCounter) (*missingCounter)++;
    NSLog(@"[WVR-FSR3] Failed to create PSO for '%@': %@", fnName, err);
  }
  return pso;
}

static bool init_static_resources(WVRFsr3UpscalerContext *ctx) {
  id<MTLDevice> dev = ctx->device;

  // 1. Lanczos2 LUT (128 x 1, R16Float) initialized on CPU like SDK's lanczos2 LUT
  ensure_tex(
      dev,
      &ctx->lanczosLut,
      MTLPixelFormatR16Float,
      kFsr3LanczosLutWidth,
      1,
      1,
      MTLStorageModeShared,
      MTLTextureUsageShaderRead,
      @"WVR.FSR3.LanczosLut");
  if (!ctx->lanczosLut) return false;
  uint16_t lutData[kFsr3LanczosLutWidth];
  for (uint32_t i = 0; i < kFsr3LanczosLutWidth; ++i) {
    const float x = (2.0f * float(i)) / float(kFsr3LanczosLutWidth - 1u);
    lutData[i] = float_to_fp16(lanczos2_scalar(x));
  }
  [ctx->lanczosLut replaceRegion:MTLRegionMake2D(0, 0, kFsr3LanczosLutWidth, 1)
                     mipmapLevel:0
                       withBytes:lutData
                     bytesPerRow:sizeof(lutData)];

  // 2. Default 1x1 reactive and transparency/composition masks (R8Unorm = 0)
  ensure_tex(
      dev,
      &ctx->defaultReactivity,
      MTLPixelFormatR8Unorm,
      1,
      1,
      1,
      MTLStorageModeShared,
      MTLTextureUsageShaderRead,
      @"WVR.FSR3.DefaultReactivity");
  ensure_tex(
      dev,
      &ctx->defaultTransparencyAndComposition,
      MTLPixelFormatR8Unorm,
      1,
      1,
      1,
      MTLStorageModeShared,
      MTLTextureUsageShaderRead,
      @"WVR.FSR3.DefaultTransparencyAndComposition");
  if (!ctx->defaultReactivity || !ctx->defaultTransparencyAndComposition) return false;
  const uint8_t zeroByte = 0u;
  [ctx->defaultReactivity replaceRegion:MTLRegionMake2D(0, 0, 1, 1)
                            mipmapLevel:0
                              withBytes:&zeroByte
                            bytesPerRow:1];
  [ctx->defaultTransparencyAndComposition replaceRegion:MTLRegionMake2D(0, 0, 1, 1)
                                            mipmapLevel:0
                                              withBytes:&zeroByte
                                            bytesPerRow:1];

  // 3. Default 1x1 exposure texture (RGBA32Float = {1, 1, 0, 0})
  ensure_tex(
      dev,
      &ctx->defaultExposure,
      MTLPixelFormatRGBA32Float,
      1,
      1,
      1,
      MTLStorageModeShared,
      MTLTextureUsageShaderRead,
      @"WVR.FSR3.DefaultExposure");
  if (!ctx->defaultExposure) return false;
  const float defaultExp[4] = {1.0f, 1.0f, 0.0f, 0.0f};
  [ctx->defaultExposure replaceRegion:MTLRegionMake2D(0, 0, 1, 1)
                          mipmapLevel:0
                            withBytes:defaultExp
                          bytesPerRow:sizeof(defaultExp)];

  // 4. 1x1 FrameInfo (RGBA32Float) and 1x1 SPD atomic counter (R32Uint)
  ensure_tex(
      dev,
      &ctx->frameInfo,
      MTLPixelFormatRGBA32Float,
      1,
      1,
      1,
      MTLStorageModeShared,
      fsr3_rw_texture_usage(false),
      @"WVR.FSR3.FrameInfo");
  ensure_tex(
      dev,
      &ctx->spdAtomicCounter,
      MTLPixelFormatR32Uint,
      1,
      1,
      1,
      MTLStorageModePrivate,
      fsr3_rw_texture_usage(true),
      @"WVR.FSR3.SpdAtomicCounter");
  if (!ctx->frameInfo || !ctx->spdAtomicCounter) return false;
  const float initFrameInfo[4] = {1.0f, 1e4f, 1.0f, 0.0f};
  [ctx->frameInfo replaceRegion:MTLRegionMake2D(0, 0, 1, 1)
                    mipmapLevel:0
                      withBytes:initFrameInfo
                    bytesPerRow:sizeof(initFrameInfo)];

  return true;
}

static bool ensure_dynamic_resources(
    WVRFsr3UpscalerContext *ctx,
    uint32_t renderW,
    uint32_t renderH,
    uint32_t displayW,
    uint32_t displayH,
    bool *outResized) {
  id<MTLDevice> dev = ctx->device;
  bool anyReallocated = false;
  const MTLTextureUsage rwUsage = fsr3_rw_texture_usage(false);
  const MTLTextureUsage atomicUsage = fsr3_rw_texture_usage(true);

  // Render-size resources
  anyReallocated |= ensure_tex(
      dev, &ctx->deviceDepth, MTLPixelFormatR32Float, renderW, renderH, 1,
      MTLStorageModePrivate, rwUsage, @"WVR.FSR3.DeviceDepth");
  anyReallocated |= ensure_tex(
      dev, &ctx->motionVectors, MTLPixelFormatRG16Float, renderW, renderH, 1,
      MTLStorageModePrivate, rwUsage, @"WVR.FSR3.MotionVectors");
  anyReallocated |= ensure_tex(
      dev, &ctx->reconstructedPrevNearestDepth, MTLPixelFormatR32Uint, renderW, renderH, 1,
      MTLStorageModePrivate, atomicUsage, @"WVR.FSR3.ReconstructedPrevNearestDepth");
  anyReallocated |= ensure_tex(
      dev, &ctx->dilatedMotionVectors, MTLPixelFormatRGBA16Float, renderW, renderH, 1,
      MTLStorageModePrivate, rwUsage, @"WVR.FSR3.DilatedMotionVectors");
  anyReallocated |= ensure_tex(
      dev, &ctx->dilatedDepth, MTLPixelFormatR32Float, renderW, renderH, 1,
      MTLStorageModePrivate, rwUsage, @"WVR.FSR3.DilatedDepth");
  anyReallocated |= ensure_tex(
      dev, &ctx->farthestDepth, MTLPixelFormatR16Float, renderW, renderH, 1,
      MTLStorageModePrivate, rwUsage, @"WVR.FSR3.FarthestDepth");
  anyReallocated |= ensure_tex(
      dev, &ctx->luma[0], MTLPixelFormatR16Float, renderW, renderH, 1,
      MTLStorageModePrivate, rwUsage, @"WVR.FSR3.Luma0");
  anyReallocated |= ensure_tex(
      dev, &ctx->luma[1], MTLPixelFormatR16Float, renderW, renderH, 1,
      MTLStorageModePrivate, rwUsage, @"WVR.FSR3.Luma1");
  anyReallocated |= ensure_tex(
      dev, &ctx->accumulation[0], MTLPixelFormatR8Unorm, renderW, renderH, 1,
      MTLStorageModePrivate, rwUsage, @"WVR.FSR3.Accumulation0");
  anyReallocated |= ensure_tex(
      dev, &ctx->accumulation[1], MTLPixelFormatR8Unorm, renderW, renderH, 1,
      MTLStorageModePrivate, rwUsage, @"WVR.FSR3.Accumulation1");
  anyReallocated |= ensure_tex(
      dev, &ctx->lumaHistory[0], MTLPixelFormatRGBA16Float, renderW, renderH, 1,
      MTLStorageModePrivate, rwUsage, @"WVR.FSR3.LumaHistory0");
  anyReallocated |= ensure_tex(
      dev, &ctx->lumaHistory[1], MTLPixelFormatRGBA16Float, renderW, renderH, 1,
      MTLStorageModePrivate, rwUsage, @"WVR.FSR3.LumaHistory1");
  anyReallocated |= ensure_tex(
      dev, &ctx->dilatedReactiveMasks, MTLPixelFormatRGBA8Unorm, renderW, renderH, 1,
      MTLStorageModePrivate, rwUsage, @"WVR.FSR3.DilatedReactiveMasks");
  anyReallocated |= ensure_tex(
      dev, &ctx->lumaInstability, MTLPixelFormatR16Float, renderW, renderH, 1,
      MTLStorageModePrivate, rwUsage, @"WVR.FSR3.LumaInstability");

  // Half-render-size resources
  const uint32_t halfRenderW = std::max(1u, renderW / 2u);
  const uint32_t halfRenderH = std::max(1u, renderH / 2u);
  anyReallocated |= ensure_tex(
      dev, &ctx->farthestDepthMip1, MTLPixelFormatR16Float, halfRenderW, halfRenderH, 1,
      MTLStorageModePrivate, rwUsage, @"WVR.FSR3.FarthestDepthMip1");
  anyReallocated |= ensure_tex(
      dev, &ctx->shadingChange, MTLPixelFormatR8Unorm, halfRenderW, halfRenderH, 1,
      MTLStorageModePrivate, rwUsage, @"WVR.FSR3.ShadingChange");

  // SPD mip hierarchy (6 mips: mip 0 is renderSize/2, minimum 32x32 so all 6 mips exist)
  const uint32_t spdBaseW = std::max(32u, halfRenderW);
  const uint32_t spdBaseH = std::max(32u, halfRenderH);
  const bool spdReallocated = ensure_tex(
      dev, &ctx->spdMips, MTLPixelFormatRGBA16Float, spdBaseW, spdBaseH, kFsr3SpdMipCount,
      MTLStorageModePrivate, rwUsage, @"WVR.FSR3.SpdMips");
  anyReallocated |= spdReallocated;
  if (spdReallocated || !ctx->spdMipViews[0]) {
    for (uint32_t m = 0; m < kFsr3SpdMipCount; ++m) {
      ctx->spdMipViews[m] = nil;
      if (ctx->spdMips) {
        ctx->spdMipViews[m] =
            [ctx->spdMips newTextureViewWithPixelFormat:MTLPixelFormatRGBA16Float
                                            textureType:MTLTextureType2D
                                                 levels:NSMakeRange(m, 1)
                                                 slices:NSMakeRange(0, 1)];
      }
    }
  }

  // Display-size resources
  anyReallocated |= ensure_tex(
      dev, &ctx->internalUpscaledColor[0], MTLPixelFormatRGBA16Float, displayW, displayH, 1,
      MTLStorageModePrivate, rwUsage, @"WVR.FSR3.InternalUpscaledColor0");
  anyReallocated |= ensure_tex(
      dev, &ctx->internalUpscaledColor[1], MTLPixelFormatRGBA16Float, displayW, displayH, 1,
      MTLStorageModePrivate, rwUsage, @"WVR.FSR3.InternalUpscaledColor1");
  anyReallocated |= ensure_tex(
      dev, &ctx->newLocks, MTLPixelFormatR8Unorm, displayW, displayH, 1,
      MTLStorageModePrivate, rwUsage, @"WVR.FSR3.NewLocks");

  if (outResized) *outResized = anyReallocated;

  if (!ctx->deviceDepth || !ctx->motionVectors || !ctx->reconstructedPrevNearestDepth ||
      !ctx->dilatedMotionVectors || !ctx->dilatedDepth || !ctx->farthestDepth ||
      !ctx->luma[0] || !ctx->luma[1] || !ctx->accumulation[0] || !ctx->accumulation[1] ||
      !ctx->lumaHistory[0] || !ctx->lumaHistory[1] || !ctx->dilatedReactiveMasks ||
      !ctx->lumaInstability || !ctx->farthestDepthMip1 || !ctx->shadingChange ||
      !ctx->spdMips || !ctx->internalUpscaledColor[0] || !ctx->internalUpscaledColor[1] ||
      !ctx->newLocks) {
    return false;
  }
  for (uint32_t m = 0; m < kFsr3SpdMipCount; ++m) {
    if (!ctx->spdMipViews[m]) return false;
  }
  return true;
}

} // namespace

extern "C" void *wvr_fsr3_create_v1(void *devicePtr) {
  if (!devicePtr) return nullptr;
  @autoreleasepool {
    id<MTLDevice> device = (__bridge id<MTLDevice>)devicePtr;
    auto *ctx = new WVRFsr3UpscalerContext();
    ctx->device = device;

    NSBundle *bundle = [NSBundle bundleForClass:[WVRFsr3UpscalerBundleAnchor class]];
    NSError *libErr = nil;
    if (bundle) {
      ctx->fsrLibrary = [device newDefaultLibraryWithBundle:bundle error:&libErr];
    }
    if (!ctx->fsrLibrary) {
      NSLog(@"[WVR-FSR3] newDefaultLibraryWithBundle failed (bundle=%@ err=%@)",
            bundle.bundlePath, libErr);
      delete ctx;
      return nullptr;
    }

    ctx->psoPrepareInputs =
        build_pso(device, ctx->fsrLibrary, @"fsr3_prepare_inputs", &ctx->missingPipelines);
    ctx->psoLumaPyramid =
        build_pso(device, ctx->fsrLibrary, @"fsr3_luma_pyramid", &ctx->missingPipelines);
    ctx->psoShadingChangePyramid =
        build_pso(device, ctx->fsrLibrary, @"fsr3_shading_change_pyramid", &ctx->missingPipelines);
    ctx->psoShadingChange =
        build_pso(device, ctx->fsrLibrary, @"fsr3_shading_change", &ctx->missingPipelines);
    ctx->psoPrepareReactivity =
        build_pso(device, ctx->fsrLibrary, @"fsr3_prepare_reactivity", &ctx->missingPipelines);
    ctx->psoLumaInstability =
        build_pso(device, ctx->fsrLibrary, @"fsr3_luma_instability", &ctx->missingPipelines);
    ctx->psoAccumulate =
        build_pso(device, ctx->fsrLibrary, @"fsr3_accumulate", &ctx->missingPipelines);
    ctx->psoRcas =
        build_pso(device, ctx->fsrLibrary, @"fsr3_rcas", &ctx->missingPipelines);

    NSError *helperErr = nil;
    MTLCompileOptions *opts = [[MTLCompileOptions alloc] init];
    opts.fastMathEnabled = YES;
    ctx->helperLibrary =
        [device newLibraryWithSource:kWVRFsr3RuntimeHelperMetalSource options:opts error:&helperErr];
    if (!ctx->helperLibrary) {
      ctx->missingPipelines++;
      NSLog(@"[WVR-FSR3] Runtime helper library compile failed: %@", helperErr);
      delete ctx;
      return nullptr;
    }

    ctx->psoCameraMotionVectors =
        build_pso(device, ctx->helperLibrary, @"camera_motion_vectors", &ctx->missingPipelines);
    ctx->psoDepthToDevice =
        build_pso(device, ctx->helperLibrary, @"depth_to_device", &ctx->missingPipelines);
    ctx->psoClearFsr3State =
        build_pso(device, ctx->helperLibrary, @"clear_fsr3_state", &ctx->missingPipelines);
    ctx->psoClearHistory =
        build_pso(device, ctx->helperLibrary, @"clear_history_textures", &ctx->missingPipelines);

    if (ctx->missingPipelines > 0 || !init_static_resources(ctx)) {
      NSLog(@"[WVR-FSR3] Create failed (missingPipelines=%llu)",
            (unsigned long long)ctx->missingPipelines);
      delete ctx;
      return nullptr;
    }

    NSLog(@"[WVR-FSR3] Created FSR 3.1 Metal upscaler on device '%@' (bundle=%@)",
          device.name, bundle.bundlePath);
    return ctx;
  }
}

extern "C" void wvr_fsr3_destroy_v1(void *ctxPtr) {
  if (!ctxPtr) return;
  @autoreleasepool {
    auto *ctx = static_cast<WVRFsr3UpscalerContext *>(ctxPtr);
    delete ctx;
  }
}

extern "C" void wvr_fsr3_reset_v1(void *ctxPtr) {
  if (!ctxPtr) return;
  auto *ctx = static_cast<WVRFsr3UpscalerContext *>(ctxPtr);
  std::lock_guard<std::mutex> guard(ctx->lock);
  ctx->pendingReset = true;
  ctx->resets++;
}

extern "C" int32_t wvr_fsr3_dispatch_v1(void *ctxPtr, const WVRFsr3DispatchV1 *d) {
  if (!ctxPtr || !d) return -1;
  if (!d->commandBuffer || !d->color || !d->depth || !d->output) return -2;
  if (d->renderWidth == 0 || d->renderHeight == 0 ||
      d->displayWidth == 0 || d->displayHeight == 0) {
    return -3;
  }

  @autoreleasepool {
    auto *ctx = static_cast<WVRFsr3UpscalerContext *>(ctxPtr);
    std::lock_guard<std::mutex> guard(ctx->lock);

    id<MTLCommandBuffer> cmdBuf = (__bridge id<MTLCommandBuffer>)d->commandBuffer;
    id<MTLTexture> colorTex = (__bridge id<MTLTexture>)d->color;
    id<MTLTexture> depthTex = (__bridge id<MTLTexture>)d->depth;
    id<MTLTexture> outputTex = (__bridge id<MTLTexture>)d->output;

    bool resized = false;
    if (!ensure_dynamic_resources(
            ctx, d->renderWidth, d->renderHeight, d->displayWidth, d->displayHeight, &resized)) {
      return -4;
    }
    if (resized) {
      ctx->resizes++;
    }

    const bool dimensionChanged =
        (ctx->renderWidth != d->renderWidth) || (ctx->renderHeight != d->renderHeight) ||
        (ctx->displayWidth != d->displayWidth) || (ctx->displayHeight != d->displayHeight);
    const bool doReset = (d->reset != 0u) || ctx->pendingReset || resized || dimensionChanged ||
                         (ctx->dispatches == 0u);
    if (d->reset != 0u) {
      ctx->resets++;
    }
    ctx->pendingReset = false;

    if (doReset) {
      ctx->frameIndex = 0u;
      ctx->prevRenderWidth = d->renderWidth;
      ctx->prevRenderHeight = d->renderHeight;
      ctx->prevDisplayWidth = d->displayWidth;
      ctx->prevDisplayHeight = d->displayHeight;
    } else {
      ctx->frameIndex = (ctx->frameIndex + 1u) & 16383u;
    }

    const uint32_t cur = ctx->frameIndex & 1u;
    const uint32_t prev = cur ^ 1u;

    // Jitter in render pixels [-0.5, 0.5]:
    // NDC jitter is (2 * pixelX / renderW, 2 * pixelY / renderH) with UV Y inverted relative to NDC Y.
    const float curJitterPixels[2] = {
        -0.5f * d->jitterNDC[0] * float(d->renderWidth),
        0.5f * d->jitterNDC[1] * float(d->renderHeight),
    };
    const float prevJitterPixels[2] = {
        doReset ? curJitterPixels[0] : ctx->prevJitterPixels[0],
        doReset ? curJitterPixels[1] : ctx->prevJitterPixels[1],
    };

    // Camera near/far and setupDeviceDepthToViewSpaceDepthParams (non-inverted [0, 1] depth)
    float cameraNear = 0.05f;
    float cameraFar = 1000.0f;
    extract_near_far_from_projection(d->projection, &cameraNear, &cameraFar);
    const float fMin = std::min(cameraNear, cameraFar);
    const float fMax = std::max(cameraNear, cameraFar);
    const float fQ = fMax / (fMin - fMax);
    const float devToView0 = -1.0f * fQ; // fMax / (fMax - fMin)
    const float devToView1 = fQ * fMin;  // (fMax * fMin) / (fMin - fMax)

    const float aspect = float(d->renderWidth) / float(d->renderHeight);
    const float cotHalfFovY =
        (std::isfinite(d->projection[5]) && std::fabs(d->projection[5]) > 1e-5f)
            ? std::fabs(d->projection[5])
            : 1.0f;
    const float a = cotHalfFovY / aspect;
    const float b = cotHalfFovY;

    // Fill Fsr3UpscalerConstants matching ffxFsr3UpscalerContextDispatch
    Fsr3UpscalerConstants cbFsr3 = {};
    cbFsr3.iRenderSize[0] = int32_t(d->renderWidth);
    cbFsr3.iRenderSize[1] = int32_t(d->renderHeight);
    cbFsr3.iPreviousFrameRenderSize[0] = int32_t(ctx->prevRenderWidth);
    cbFsr3.iPreviousFrameRenderSize[1] = int32_t(ctx->prevRenderHeight);
    cbFsr3.iUpscaleSize[0] = int32_t(d->displayWidth);
    cbFsr3.iUpscaleSize[1] = int32_t(d->displayHeight);
    cbFsr3.iPreviousFrameUpscaleSize[0] = int32_t(ctx->prevDisplayWidth);
    cbFsr3.iPreviousFrameUpscaleSize[1] = int32_t(ctx->prevDisplayHeight);
    cbFsr3.iMaxRenderSize[0] = int32_t(d->renderWidth);
    cbFsr3.iMaxRenderSize[1] = int32_t(d->renderHeight);
    cbFsr3.iMaxUpscaleSize[0] = int32_t(d->displayWidth);
    cbFsr3.iMaxUpscaleSize[1] = int32_t(d->displayHeight);

    cbFsr3.fDeviceToViewDepth[0] = devToView0;
    cbFsr3.fDeviceToViewDepth[1] = devToView1;
    cbFsr3.fDeviceToViewDepth[2] = 1.0f / a;
    cbFsr3.fDeviceToViewDepth[3] = 1.0f / b;

    cbFsr3.fJitter[0] = curJitterPixels[0];
    cbFsr3.fJitter[1] = curJitterPixels[1];
    cbFsr3.fPreviousFrameJitter[0] = prevJitterPixels[0];
    cbFsr3.fPreviousFrameJitter[1] = prevJitterPixels[1];

    cbFsr3.fMotionVectorScale[0] = 1.0f;
    cbFsr3.fMotionVectorScale[1] = 1.0f;

    cbFsr3.fDownscaleFactor[0] = float(d->renderWidth) / float(d->displayWidth);
    cbFsr3.fDownscaleFactor[1] = float(d->renderHeight) / float(d->displayHeight);

    cbFsr3.fMotionVectorJitterCancellation[0] =
        (prevJitterPixels[0] / float(ctx->prevRenderWidth)) -
        (curJitterPixels[0] / float(d->renderWidth));
    cbFsr3.fMotionVectorJitterCancellation[1] =
        (prevJitterPixels[1] / float(ctx->prevRenderHeight)) -
        (curJitterPixels[1] / float(d->renderHeight));

    cbFsr3.fTanHalfFOV = 1.0f / a;
    const float upscaleRatio = float(d->displayWidth) / float(d->renderWidth);
    const int32_t jitterPhaseCount = std::max(1, int32_t(8.0f * upscaleRatio * upscaleRatio));
    cbFsr3.fJitterSequenceLength = float(jitterPhaseCount);
    cbFsr3.fDeltaTime = std::clamp(d->frameTimeDeltaMs * 0.001f, 0.0f, 1.0f);
    cbFsr3.fDeltaPreExposure = 1.0f;
    cbFsr3.fViewSpaceToMetersFactor = 1.0f;
    cbFsr3.fFrameIndex = float(ctx->frameIndex);
    cbFsr3.fVelocityFactor = 1.0f;
    cbFsr3.fReactivenessScale = 1.0f;
    cbFsr3.fShadingChangeScale = 1.0f;
    cbFsr3.fAccumulationAddedPerFrame = 1.0f / 3.0f;
    cbFsr3.fMinDisocclusionAccumulation = -1.0f / 3.0f;

    // Fill FfxSpdConstants via ffxSpdSetup equivalent
    uint32_t spdThreadGroupCountXY[2] = {1u, 1u};
    uint32_t spdWorkGroupOffset[2] = {0u, 0u};
    uint32_t spdNumWorkGroupsAndMips[2] = {1u, 0u};
    const uint32_t rectInfo[4] = {0u, 0u, d->renderWidth, d->renderHeight};
    ffx_spd_setup(spdThreadGroupCountXY, spdWorkGroupOffset, spdNumWorkGroupsAndMips, rectInfo);

    FfxSpdConstants cbSpd = {};
    cbSpd.mips = spdNumWorkGroupsAndMips[1];
    cbSpd.numWorkGroups = spdNumWorkGroupsAndMips[0];
    cbSpd.workGroupOffset[0] = spdWorkGroupOffset[0];
    cbSpd.workGroupOffset[1] = spdWorkGroupOffset[1];
    cbSpd.renderSize[0] = d->renderWidth;
    cbSpd.renderSize[1] = d->renderHeight;

    // Fill FfxRcasConstants via FsrRcasCon equivalent
    FfxRcasConstants cbRcas = {};
    const float clampedSharpness = std::clamp(d->sharpness, 0.0f, 1.0f);
    const float rcasStops = (-2.0f * clampedSharpness) + 2.0f;
    fsr_rcas_con(cbRcas.rcasConfig, rcasStops);

    // Fill prepass params for camera_motion_vectors and depth_to_device
    WVRFsr3PrepassParams prepass = {};
    const simd_float4x4 curProj = load_mat4(d->projection);
    const simd_float4x4 prevProj = load_mat4(d->previousProjection);
    const simd_float4x4 curOriginFromEye = load_mat4(d->originFromEye);
    const simd_float4x4 prevOriginFromEye = load_mat4(d->previousOriginFromEye);

    const bool matricesValid =
        mat4_is_valid(curProj) && mat4_is_valid(prevProj) &&
        mat4_is_valid(curOriginFromEye) && mat4_is_valid(prevOriginFromEye);
    if (matricesValid) {
      prepass.currentInverseProjection = simd_inverse(curProj);
      prepass.previousViewFromCurrentView =
          simd_mul(simd_inverse(prevOriginFromEye), curOriginFromEye);
      prepass.previousProjection = prevProj;
    } else {
      prepass.currentInverseProjection = matrix_identity_float4x4;
      prepass.previousViewFromCurrentView = matrix_identity_float4x4;
      prepass.previousProjection = matrix_identity_float4x4;
    }
    prepass.invMotionVectorScale[0] = 1.0f / cbFsr3.fMotionVectorScale[0];
    prepass.invMotionVectorScale[1] = 1.0f / cbFsr3.fMotionVectorScale[1];
    prepass.deviceToViewDepth0 = devToView0;
    prepass.deviceToViewDepth1 = devToView1;
    prepass.nearZ = fMin;
    prepass.farZ = fMax;
    prepass.renderWidth = d->renderWidth;
    prepass.renderHeight = d->renderHeight;
    prepass.reset = (doReset || !matricesValid) ? 1u : 0u;

    id<MTLComputeCommandEncoder> enc = [cmdBuf computeCommandEncoder];
    if (!enc) return -5;
    enc.label = @"WVR.FSR3.Upscaler";

    const MTLSize tg8x8 = MTLSizeMake(8, 8, 1);
    const MTLSize renderGroups8x8 =
        MTLSizeMake((d->renderWidth + 7u) / 8u, (d->renderHeight + 7u) / 8u, 1);
    const uint32_t halfRenderW = std::max(1u, d->renderWidth / 2u);
    const uint32_t halfRenderH = std::max(1u, d->renderHeight / 2u);
    const MTLSize halfRenderGroups8x8 =
        MTLSizeMake((halfRenderW + 7u) / 8u, (halfRenderH + 7u) / 8u, 1);
    const MTLSize displayGroups8x8 =
        MTLSizeMake((d->displayWidth + 7u) / 8u, (d->displayHeight + 7u) / 8u, 1);

    // Optional reset/resize clear of internal state and history textures
    if (doReset) {
      [enc setComputePipelineState:ctx->psoClearFsr3State];
      [enc setTexture:ctx->frameInfo atIndex:0];
      [enc setTexture:ctx->spdAtomicCounter atIndex:1];
      [enc dispatchThreadgroups:MTLSizeMake(1, 1, 1) threadsPerThreadgroup:MTLSizeMake(1, 1, 1)];

      const uint32_t maxW = std::max(d->renderWidth, d->displayWidth);
      const uint32_t maxH = std::max(d->renderHeight, d->displayHeight);
      [enc setComputePipelineState:ctx->psoClearHistory];
      [enc setTexture:ctx->accumulation[0] atIndex:0];
      [enc setTexture:ctx->accumulation[1] atIndex:1];
      [enc setTexture:ctx->lumaHistory[0] atIndex:2];
      [enc setTexture:ctx->lumaHistory[1] atIndex:3];
      [enc setTexture:ctx->luma[0] atIndex:4];
      [enc setTexture:ctx->luma[1] atIndex:5];
      [enc setTexture:ctx->internalUpscaledColor[0] atIndex:6];
      [enc setTexture:ctx->internalUpscaledColor[1] atIndex:7];
      [enc setTexture:ctx->newLocks atIndex:8];
      [enc dispatchThreadgroups:MTLSizeMake((maxW + 7u) / 8u, (maxH + 7u) / 8u, 1)
          threadsPerThreadgroup:tg8x8];
      [enc memoryBarrierWithScope:MTLBarrierScopeTextures];
    }

    // Prepass 1: camera_motion_vectors -> motionVectors (RG16Float)
    [enc setComputePipelineState:ctx->psoCameraMotionVectors];
    [enc setBytes:&prepass length:sizeof(prepass) atIndex:0];
    [enc setTexture:depthTex atIndex:0];
    [enc setTexture:ctx->motionVectors atIndex:1];
    [enc dispatchThreadgroups:renderGroups8x8 threadsPerThreadgroup:tg8x8];

    // Prepass 2: depth_to_device -> deviceDepth (R32Float) + clear reconstructedPrevNearestDepth
    [enc setComputePipelineState:ctx->psoDepthToDevice];
    [enc setBytes:&prepass length:sizeof(prepass) atIndex:0];
    [enc setTexture:depthTex atIndex:0];
    [enc setTexture:ctx->deviceDepth atIndex:1];
    [enc setTexture:ctx->reconstructedPrevNearestDepth atIndex:2];
    [enc dispatchThreadgroups:renderGroups8x8 threadsPerThreadgroup:tg8x8];

    [enc memoryBarrierWithScope:MTLBarrierScopeTextures];

    // Pass 1: fsr3_prepare_inputs
    [enc setComputePipelineState:ctx->psoPrepareInputs];
    [enc setBytes:&cbFsr3 length:sizeof(cbFsr3) atIndex:0];
    [enc setTexture:colorTex atIndex:0];
    [enc setTexture:ctx->deviceDepth atIndex:1];
    [enc setTexture:ctx->motionVectors atIndex:2];
    [enc setTexture:ctx->reconstructedPrevNearestDepth atIndex:3];
    [enc setTexture:ctx->dilatedMotionVectors atIndex:4];
    [enc setTexture:ctx->dilatedDepth atIndex:5];
    [enc setTexture:ctx->farthestDepth atIndex:6];
    [enc setTexture:ctx->luma[cur] atIndex:7];
    [enc dispatchThreadgroups:renderGroups8x8 threadsPerThreadgroup:tg8x8];

    [enc memoryBarrierWithScope:MTLBarrierScopeTextures];

    // Pass 2: fsr3_luma_pyramid (SPD)
    const MTLSize spdGroups =
        MTLSizeMake(spdThreadGroupCountXY[0], spdThreadGroupCountXY[1], 1);
    const MTLSize spdThreads = MTLSizeMake(256, 1, 1);
    [enc setComputePipelineState:ctx->psoLumaPyramid];
    [enc setBytes:&cbFsr3 length:sizeof(cbFsr3) atIndex:0];
    [enc setBytes:&cbSpd length:sizeof(cbSpd) atIndex:1];
    [enc setTexture:ctx->luma[cur] atIndex:0];
    [enc setTexture:ctx->farthestDepth atIndex:1];
    [enc setTexture:ctx->spdAtomicCounter atIndex:2];
    [enc setTexture:ctx->frameInfo atIndex:3];
    [enc setTexture:ctx->farthestDepthMip1 atIndex:4];
    [enc setTexture:ctx->spdMipViews[0] atIndex:5];
    [enc setTexture:ctx->spdMipViews[1] atIndex:6];
    [enc setTexture:ctx->spdMipViews[2] atIndex:7];
    [enc setTexture:ctx->spdMipViews[3] atIndex:8];
    [enc setTexture:ctx->spdMipViews[4] atIndex:9];
    [enc setTexture:ctx->spdMipViews[5] atIndex:10];
    [enc dispatchThreadgroups:spdGroups threadsPerThreadgroup:spdThreads];

    [enc memoryBarrierWithScope:MTLBarrierScopeTextures];

    // Pass 3: fsr3_shading_change_pyramid (SPD)
    [enc setComputePipelineState:ctx->psoShadingChangePyramid];
    [enc setBytes:&cbFsr3 length:sizeof(cbFsr3) atIndex:0];
    [enc setBytes:&cbSpd length:sizeof(cbSpd) atIndex:1];
    [enc setTexture:ctx->luma[cur] atIndex:0];
    [enc setTexture:ctx->luma[prev] atIndex:1];
    [enc setTexture:ctx->dilatedMotionVectors atIndex:2];
    [enc setTexture:ctx->defaultExposure atIndex:3];
    [enc setTexture:ctx->spdAtomicCounter atIndex:4];
    [enc setTexture:ctx->spdMipViews[0] atIndex:5];
    [enc setTexture:ctx->spdMipViews[1] atIndex:6];
    [enc setTexture:ctx->spdMipViews[2] atIndex:7];
    [enc setTexture:ctx->spdMipViews[3] atIndex:8];
    [enc setTexture:ctx->spdMipViews[4] atIndex:9];
    [enc setTexture:ctx->spdMipViews[5] atIndex:10];
    [enc dispatchThreadgroups:spdGroups threadsPerThreadgroup:spdThreads];

    [enc memoryBarrierWithScope:MTLBarrierScopeTextures];

    // Pass 4: fsr3_shading_change
    [enc setComputePipelineState:ctx->psoShadingChange];
    [enc setBytes:&cbFsr3 length:sizeof(cbFsr3) atIndex:0];
    [enc setTexture:ctx->spdMips atIndex:0];
    [enc setTexture:ctx->shadingChange atIndex:1];
    [enc dispatchThreadgroups:halfRenderGroups8x8 threadsPerThreadgroup:tg8x8];

    [enc memoryBarrierWithScope:MTLBarrierScopeTextures];

    // Pass 5: fsr3_prepare_reactivity
    [enc setComputePipelineState:ctx->psoPrepareReactivity];
    [enc setBytes:&cbFsr3 length:sizeof(cbFsr3) atIndex:0];
    [enc setTexture:ctx->reconstructedPrevNearestDepth atIndex:0];
    [enc setTexture:ctx->dilatedMotionVectors atIndex:1];
    [enc setTexture:ctx->dilatedDepth atIndex:2];
    [enc setTexture:ctx->defaultReactivity atIndex:3];
    [enc setTexture:ctx->defaultTransparencyAndComposition atIndex:4];
    [enc setTexture:ctx->accumulation[prev] atIndex:5];
    [enc setTexture:ctx->shadingChange atIndex:6];
    [enc setTexture:ctx->luma[cur] atIndex:7];
    [enc setTexture:ctx->defaultExposure atIndex:8];
    [enc setTexture:ctx->accumulation[cur] atIndex:9];
    [enc setTexture:ctx->dilatedReactiveMasks atIndex:10];
    [enc setTexture:ctx->newLocks atIndex:11];
    [enc dispatchThreadgroups:renderGroups8x8 threadsPerThreadgroup:tg8x8];

    // Pass 6: fsr3_luma_instability (independent of Pass 5 outputs; reads dilatedReactiveMasks after barrier)
    [enc memoryBarrierWithScope:MTLBarrierScopeTextures];

    [enc setComputePipelineState:ctx->psoLumaInstability];
    [enc setBytes:&cbFsr3 length:sizeof(cbFsr3) atIndex:0];
    [enc setTexture:ctx->defaultExposure atIndex:0];
    [enc setTexture:ctx->dilatedReactiveMasks atIndex:1];
    [enc setTexture:ctx->dilatedMotionVectors atIndex:2];
    [enc setTexture:ctx->luma[cur] atIndex:3];
    [enc setTexture:ctx->lumaHistory[prev] atIndex:4];
    [enc setTexture:ctx->farthestDepthMip1 atIndex:5];
    [enc setTexture:ctx->lumaHistory[cur] atIndex:6];
    [enc setTexture:ctx->lumaInstability atIndex:7];
    [enc dispatchThreadgroups:renderGroups8x8 threadsPerThreadgroup:tg8x8];

    [enc memoryBarrierWithScope:MTLBarrierScopeTextures];

    // Pass 7: fsr3_accumulate
    [enc setComputePipelineState:ctx->psoAccumulate];
    [enc setBytes:&cbFsr3 length:sizeof(cbFsr3) atIndex:0];
    [enc setTexture:ctx->defaultExposure atIndex:0];
    [enc setTexture:ctx->dilatedReactiveMasks atIndex:1];
    [enc setTexture:ctx->motionVectors atIndex:2];
    [enc setTexture:ctx->dilatedMotionVectors atIndex:3];
    [enc setTexture:ctx->internalUpscaledColor[prev] atIndex:4];
    [enc setTexture:ctx->lanczosLut atIndex:5];
    [enc setTexture:ctx->farthestDepthMip1 atIndex:6];
    [enc setTexture:ctx->lumaInstability atIndex:7];
    [enc setTexture:colorTex atIndex:8];
    [enc setTexture:ctx->internalUpscaledColor[cur] atIndex:9];
    [enc setTexture:ctx->newLocks atIndex:10];
    [enc setTexture:outputTex atIndex:11];
    [enc dispatchThreadgroups:displayGroups8x8 threadsPerThreadgroup:tg8x8];

    // Pass 8: fsr3_rcas (when sharpness > 0)
    if (d->sharpness > 0.0f) {
      [enc memoryBarrierWithScope:MTLBarrierScopeTextures];

      const MTLSize rcasGroups =
          MTLSizeMake((d->displayWidth + 15u) / 16u, (d->displayHeight + 15u) / 16u, 1);
      const MTLSize rcasThreads = MTLSizeMake(64, 1, 1);
      [enc setComputePipelineState:ctx->psoRcas];
      [enc setBytes:&cbFsr3 length:sizeof(cbFsr3) atIndex:0];
      [enc setBytes:&cbRcas length:sizeof(cbRcas) atIndex:1];
      [enc setTexture:ctx->defaultExposure atIndex:0];
      [enc setTexture:ctx->internalUpscaledColor[cur] atIndex:1];
      [enc setTexture:outputTex atIndex:2];
      [enc dispatchThreadgroups:rcasGroups threadsPerThreadgroup:rcasThreads];
    }

    [enc endEncoding];

    ctx->renderWidth = d->renderWidth;
    ctx->renderHeight = d->renderHeight;
    ctx->displayWidth = d->displayWidth;
    ctx->displayHeight = d->displayHeight;
    ctx->prevRenderWidth = d->renderWidth;
    ctx->prevRenderHeight = d->renderHeight;
    ctx->prevDisplayWidth = d->displayWidth;
    ctx->prevDisplayHeight = d->displayHeight;
    ctx->prevJitterPixels[0] = curJitterPixels[0];
    ctx->prevJitterPixels[1] = curJitterPixels[1];
    ctx->dispatches++;

    return 0;
  }
}

extern "C" int32_t wvr_fsr3_copy_stats_v1(void *ctxPtr, char *buf, uint32_t cap) {
  if (!buf || cap == 0) return 0;
  if (!ctxPtr) {
    buf[0] = '\0';
    return 0;
  }
  auto *ctx = static_cast<WVRFsr3UpscalerContext *>(ctxPtr);
  std::lock_guard<std::mutex> guard(ctx->lock);
  const int n = std::snprintf(
      buf,
      cap,
      "dispatches=%llu resets=%llu resizes=%llu missingPipelines=%llu "
      "render=%ux%u display=%ux%u frameIndex=%u",
      (unsigned long long)ctx->dispatches,
      (unsigned long long)ctx->resets,
      (unsigned long long)ctx->resizes,
      (unsigned long long)ctx->missingPipelines,
      ctx->renderWidth,
      ctx->renderHeight,
      ctx->displayWidth,
      ctx->displayHeight,
      ctx->frameIndex);
  if (n < 0) {
    buf[0] = '\0';
    return 0;
  }
  return int32_t(std::min<uint32_t>(uint32_t(n), cap - 1u));
}
