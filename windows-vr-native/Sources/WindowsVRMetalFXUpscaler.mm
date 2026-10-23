#include "WindowsVRMetalFXUpscaler.h"

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <simd/simd.h>

#if __has_include(<MetalFX/MetalFX.h>)
#import <MetalFX/MetalFX.h>
#endif

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <mutex>

namespace {

struct WVRMetalFXPrepassParams {
  simd_float4x4 currentInverseProjection;
  simd_float4x4 previousViewFromCurrentView;
  simd_float4x4 previousProjection;
  float deviceToViewDepth0;
  float deviceToViewDepth1;
  float nearZ;
  float farZ;
  uint32_t renderWidth;
  uint32_t renderHeight;
  uint32_t reset;
  uint32_t pad0;
};
static_assert(sizeof(WVRMetalFXPrepassParams) == 224, "WVRMetalFXPrepassParams must be 224 bytes");

static NSString *const kWVRMetalFXPrepassMetalSource = @R"MSL(
#include <metal_stdlib>
using namespace metal;

struct WVRMetalFXPrepassParams {
  float4x4 currentInverseProjection;
  float4x4 previousViewFromCurrentView;
  float4x4 previousProjection;
  float    deviceToViewDepth0;
  float    deviceToViewDepth1;
  float    nearZ;
  float    farZ;
  uint     renderWidth;
  uint     renderHeight;
  uint     reset;
  uint     pad0;
};

kernel void metalfx_prepass(
    constant WVRMetalFXPrepassParams& p [[buffer(0)]],
    texture2d<float, access::read> in_depth [[texture(0)]],
    texture2d<float, access::write> out_mv [[texture(1)]],
    texture2d<float, access::write> out_depth [[texture(2)]],
    uint2 gid [[thread_position_in_grid]]) {
  if (gid.x >= p.renderWidth || gid.y >= p.renderHeight) return;

  float devDepth = 1.0f;

  if (p.reset != 0u) {
    out_mv.write(float4(0.0f), gid);
    out_depth.write(float4(devDepth, 0.0f, 0.0f, 0.0f), gid);
    return;
  }

  float4 d = in_depth.read(gid);
  float linearDepth = d.x;
  float valid = d.y;
  if (valid <= 0.1f || !isfinite(linearDepth) || linearDepth <= 1e-4f) {
    out_mv.write(float4(0.0f), gid);
    out_depth.write(float4(devDepth, 0.0f, 0.0f, 0.0f), gid);
    return;
  }

  float z = clamp(linearDepth, p.nearZ, p.farZ);
  devDepth = saturate(p.deviceToViewDepth0 + (p.deviceToViewDepth1 / z));
  out_depth.write(float4(devDepth, 0.0f, 0.0f, 0.0f), gid);

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
      // MetalFX expects motion vectors in pixel units of the render resolution,
      // pointing from current pixel location to previous frame's pixel location.
      mv = (prevUV - curUV) * float2(float(p.renderWidth), float(p.renderHeight));
    }
  }

  out_mv.write(float4(mv, 0.0f, 0.0f), gid);
}
)MSL";

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
      (*slot).mipmapLevelCount == mipCount &&
      ((*slot).usage & usage) == usage) {
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

struct WVRMetalFXUpscalerContext {
  std::mutex lock;
  id<MTLDevice> device = nil;
  id<MTLLibrary> helperLibrary = nil;
  id<MTLComputePipelineState> psoPrepass = nil;

#if __has_include(<MetalFX/MetalFX.h>)
  id<MTLFXTemporalScaler> scaler = nil;
#else
  id scaler = nil;
#endif

  id<MTLTexture> depthTexture = nil;
  id<MTLTexture> motionVectorTexture = nil;
  id<MTLTexture> internalOutputTexture = nil;

  uint32_t renderWidth = 0;
  uint32_t renderHeight = 0;
  uint32_t displayWidth = 0;
  uint32_t displayHeight = 0;
  MTLPixelFormat colorFormat = MTLPixelFormatInvalid;
  MTLPixelFormat outputFormat = MTLPixelFormatInvalid;

  bool pendingReset = true;

  uint64_t dispatches = 0;
  uint64_t resets = 0;
  uint64_t resizes = 0;
  uint64_t pipelineErrors = 0;
};

} // namespace

extern "C" void *wvr_metalfx_create_v1(void *devicePtr) {
  if (!devicePtr) return nullptr;
  @autoreleasepool {
    id<MTLDevice> device = (__bridge id<MTLDevice>)devicePtr;

#if __has_include(<MetalFX/MetalFX.h>)
    if (@available(visionOS 1.0, macOS 13.0, iOS 16.0, *)) {
      if (![MTLFXTemporalScalerDescriptor supportsDevice:device]) {
        static bool sDeviceNotSupportedLogged = false;
        if (!sDeviceNotSupportedLogged) {
          NSLog(@"[WVR-MetalFX] Device '%@' does not support MTLFXTemporalScaler", device.name);
          sDeviceNotSupportedLogged = true;
        }
        return nullptr;
      }
    } else {
      static bool sUnavailableLogged = false;
      if (!sUnavailableLogged) {
        NSLog(@"[WVR-MetalFX] MetalFX temporal scaling is unavailable on this OS version");
        sUnavailableLogged = true;
      }
      return nullptr;
    }
#else
    static bool sHeaderMissingLogged = false;
    if (!sHeaderMissingLogged) {
      NSLog(@"[WVR-MetalFX] <MetalFX/MetalFX.h> not available in build environment");
      sHeaderMissingLogged = true;
    }
    return nullptr;
#endif

    auto *ctx = new WVRMetalFXUpscalerContext();
    ctx->device = device;

    NSError *helperErr = nil;
    MTLCompileOptions *opts = [[MTLCompileOptions alloc] init];
    opts.fastMathEnabled = YES;
    ctx->helperLibrary =
        [device newLibraryWithSource:kWVRMetalFXPrepassMetalSource options:opts error:&helperErr];
    if (!ctx->helperLibrary) {
      ctx->pipelineErrors++;
      NSLog(@"[WVR-MetalFX] Runtime helper library compile failed: %@", helperErr);
      delete ctx;
      return nullptr;
    }

    id<MTLFunction> fn = [ctx->helperLibrary newFunctionWithName:@"metalfx_prepass"];
    if (!fn) {
      ctx->pipelineErrors++;
      NSLog(@"[WVR-MetalFX] Missing Metal function 'metalfx_prepass'");
      delete ctx;
      return nullptr;
    }
    NSError *psoErr = nil;
    ctx->psoPrepass = [device newComputePipelineStateWithFunction:fn error:&psoErr];
    if (!ctx->psoPrepass) {
      ctx->pipelineErrors++;
      NSLog(@"[WVR-MetalFX] Failed to create PSO for 'metalfx_prepass': %@", psoErr);
      delete ctx;
      return nullptr;
    }

    NSLog(@"[WVR-MetalFX] Created MetalFX temporal upscaler wrapper on device '%@'", device.name);
    return ctx;
  }
}

extern "C" void wvr_metalfx_destroy_v1(void *ctxPtr) {
  if (!ctxPtr) return;
  @autoreleasepool {
    auto *ctx = static_cast<WVRMetalFXUpscalerContext *>(ctxPtr);
    delete ctx;
  }
}

extern "C" void wvr_metalfx_reset_v1(void *ctxPtr) {
  if (!ctxPtr) return;
  auto *ctx = static_cast<WVRMetalFXUpscalerContext *>(ctxPtr);
  std::lock_guard<std::mutex> guard(ctx->lock);
  ctx->pendingReset = true;
  ctx->resets++;
}

extern "C" int32_t wvr_metalfx_dispatch_v1(void *ctxPtr, const WVRMetalFXDispatchV1 *d) {
  if (!ctxPtr || !d) return -1;
  if (!d->commandBuffer || !d->color || !d->depth || !d->output) return -2;
  if (d->renderWidth == 0 || d->renderHeight == 0 ||
      d->displayWidth == 0 || d->displayHeight == 0) {
    return -3;
  }

  @autoreleasepool {
    auto *ctx = static_cast<WVRMetalFXUpscalerContext *>(ctxPtr);
    std::lock_guard<std::mutex> guard(ctx->lock);

    id<MTLCommandBuffer> cmdBuf = (__bridge id<MTLCommandBuffer>)d->commandBuffer;
    id<MTLTexture> colorTex = (__bridge id<MTLTexture>)d->color;
    id<MTLTexture> depthTex = (__bridge id<MTLTexture>)d->depth;
    id<MTLTexture> outputTex = (__bridge id<MTLTexture>)d->output;

#if __has_include(<MetalFX/MetalFX.h>)
    const float minScale = [MTLFXTemporalScalerDescriptor supportedInputContentMinScaleForDevice:ctx->device];
    const float maxScale = [MTLFXTemporalScalerDescriptor supportedInputContentMaxScaleForDevice:ctx->device];
    // MetalFX scale limits are output/input upscale factors.
    const float scaleX = float(d->displayWidth) / float(d->renderWidth);
    const float scaleY = float(d->displayHeight) / float(d->renderHeight);

    if (scaleX < minScale - 1e-4f || scaleX > maxScale + 1e-4f ||
        scaleY < minScale - 1e-4f || scaleY > maxScale + 1e-4f) {
      static bool sScaleLogged = false;
      if (!sScaleLogged) {
        NSLog(@"[WVR-MetalFX] Requested scale %.4fx%.4f is outside supported range [%.4f, %.4f] on device '%@'",
              scaleX, scaleY, minScale, maxScale, ctx->device.name);
        sScaleLogged = true;
      }
      return -4;
    }

    const bool dimensionChanged =
        (ctx->renderWidth != d->renderWidth) || (ctx->renderHeight != d->renderHeight) ||
        (ctx->displayWidth != d->displayWidth) || (ctx->displayHeight != d->displayHeight);
    const bool formatChanged =
        (ctx->colorFormat != colorTex.pixelFormat) || (ctx->outputFormat != outputTex.pixelFormat);

    bool resized = false;
    if (!ctx->scaler || dimensionChanged || formatChanged) {
      MTLFXTemporalScalerDescriptor *desc = [[MTLFXTemporalScalerDescriptor alloc] init];
      desc.colorTextureFormat = colorTex.pixelFormat;
      desc.depthTextureFormat = MTLPixelFormatR32Float;
      desc.motionTextureFormat = MTLPixelFormatRG16Float;
      desc.outputTextureFormat = outputTex.pixelFormat;
      desc.inputWidth = d->renderWidth;
      desc.inputHeight = d->renderHeight;
      desc.outputWidth = d->displayWidth;
      desc.outputHeight = d->displayHeight;

      ctx->scaler = [desc newTemporalScalerWithDevice:ctx->device];
      if (!ctx->scaler) {
        static bool sCreateFailedLogged = false;
        if (!sCreateFailedLogged) {
          NSLog(@"[WVR-MetalFX] Failed to create MTLFXTemporalScaler (render=%ux%u display=%ux%u colorFmt=%lu outFmt=%lu)",
                d->renderWidth, d->renderHeight, d->displayWidth, d->displayHeight,
                (unsigned long)colorTex.pixelFormat, (unsigned long)outputTex.pixelFormat);
          sCreateFailedLogged = true;
        }
        return -5;
      }

      ctx->renderWidth = d->renderWidth;
      ctx->renderHeight = d->renderHeight;
      ctx->displayWidth = d->displayWidth;
      ctx->displayHeight = d->displayHeight;
      ctx->colorFormat = colorTex.pixelFormat;
      ctx->outputFormat = outputTex.pixelFormat;
      resized = true;
      ctx->resizes++;
    }

    MTLTextureUsage depthUsage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
    MTLTextureUsage motionUsage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
    if (ctx->scaler) {
      depthUsage |= ctx->scaler.depthTextureUsage;
      motionUsage |= ctx->scaler.motionTextureUsage;
    }

    bool texReallocated = false;
    texReallocated |= ensure_tex(
        ctx->device, &ctx->depthTexture, MTLPixelFormatR32Float,
        d->renderWidth, d->renderHeight, 1, MTLStorageModePrivate, depthUsage,
        @"WVR.MetalFX.Depth");
    texReallocated |= ensure_tex(
        ctx->device, &ctx->motionVectorTexture, MTLPixelFormatRG16Float,
        d->renderWidth, d->renderHeight, 1, MTLStorageModePrivate, motionUsage,
        @"WVR.MetalFX.MotionVectors");

    id<MTLTexture> targetOutputTex = outputTex;
    bool needsBlitOutput = false;
    if (ctx->scaler) {
      const MTLTextureUsage reqOutputUsage = ctx->scaler.outputTextureUsage;
      if ((outputTex.usage & reqOutputUsage) != reqOutputUsage) {
        texReallocated |= ensure_tex(
            ctx->device, &ctx->internalOutputTexture, outputTex.pixelFormat,
            d->displayWidth, d->displayHeight, 1, MTLStorageModePrivate,
            reqOutputUsage | MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite,
            @"WVR.MetalFX.InternalOutput");
        if (!ctx->internalOutputTexture) {
          return -6;
        }
        targetOutputTex = ctx->internalOutputTexture;
        needsBlitOutput = true;
      }
    }

    if (!ctx->depthTexture || !ctx->motionVectorTexture) {
      return -6;
    }
    if (texReallocated) {
      resized = true;
    }

    const bool doReset = (d->reset != 0u) || ctx->pendingReset || resized || (ctx->dispatches == 0u);
    if (d->reset != 0u) {
      ctx->resets++;
    }
    ctx->pendingReset = false;

    float curJitterPixels[2] = {0.0f, 0.0f};
    if (d->jitterValid != 0u) {
      curJitterPixels[0] = -0.5f * d->jitterNDC[0] * float(d->renderWidth);
      curJitterPixels[1] = 0.5f * d->jitterNDC[1] * float(d->renderHeight);
    }

    float cameraNear = 0.05f;
    float cameraFar = 1000.0f;
    extract_near_far_from_projection(d->projection, &cameraNear, &cameraFar);
    const float fMin = std::min(cameraNear, cameraFar);
    const float fMax = std::max(cameraNear, cameraFar);
    const float fQ = fMax / (fMin - fMax);
    const float devToView0 = -1.0f * fQ;
    const float devToView1 = fQ * fMin;

    WVRMetalFXPrepassParams prepass{};
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
    prepass.deviceToViewDepth0 = devToView0;
    prepass.deviceToViewDepth1 = devToView1;
    prepass.nearZ = fMin;
    prepass.farZ = fMax;
    prepass.renderWidth = d->renderWidth;
    prepass.renderHeight = d->renderHeight;
    prepass.reset = (doReset || !matricesValid) ? 1u : 0u;

    id<MTLComputeCommandEncoder> enc = [cmdBuf computeCommandEncoder];
    if (!enc) return -7;
    enc.label = @"WVR.MetalFX.Prepass";

    [enc setComputePipelineState:ctx->psoPrepass];
    [enc setBytes:&prepass length:sizeof(prepass) atIndex:0];
    [enc setTexture:depthTex atIndex:0];
    [enc setTexture:ctx->motionVectorTexture atIndex:1];
    [enc setTexture:ctx->depthTexture atIndex:2];

    const MTLSize tg8x8 = MTLSizeMake(8, 8, 1);
    const MTLSize renderGroups8x8 =
        MTLSizeMake((d->renderWidth + 7u) / 8u, (d->renderHeight + 7u) / 8u, 1);
    [enc dispatchThreadgroups:renderGroups8x8 threadsPerThreadgroup:tg8x8];
    [enc endEncoding];

    id<MTLFXTemporalScaler> scaler = ctx->scaler;
    scaler.colorTexture = colorTex;
    scaler.depthTexture = ctx->depthTexture;
    scaler.motionTexture = ctx->motionVectorTexture;
    scaler.outputTexture = targetOutputTex;
    scaler.jitterOffsetX = curJitterPixels[0];
    scaler.jitterOffsetY = curJitterPixels[1];
    scaler.motionVectorScaleX = 1.0f;
    scaler.motionVectorScaleY = 1.0f;
    scaler.reset = doReset ? YES : NO;
    scaler.depthReversed = NO;
    scaler.inputContentWidth = d->renderWidth;
    scaler.inputContentHeight = d->renderHeight;

    [scaler encodeToCommandBuffer:cmdBuf];

    if (needsBlitOutput) {
      id<MTLBlitCommandEncoder> blit = [cmdBuf blitCommandEncoder];
      if (!blit) return -8;
      blit.label = @"WVR.MetalFX.OutputBlit";
      [blit copyFromTexture:ctx->internalOutputTexture toTexture:outputTex];
      [blit endEncoding];
    }

    ctx->dispatches++;
    return 0;
#else
    return -99;
#endif
  }
}

extern "C" int32_t wvr_metalfx_copy_stats_v1(void *ctxPtr, char *buf, uint32_t cap) {
  if (!buf || cap == 0) return 0;
  if (!ctxPtr) {
    buf[0] = '\0';
    return 0;
  }
  auto *ctx = static_cast<WVRMetalFXUpscalerContext *>(ctxPtr);
  std::lock_guard<std::mutex> guard(ctx->lock);
  const int n = std::snprintf(
      buf,
      cap,
      "dispatches=%llu resets=%llu resizes=%llu pipelineErrors=%llu "
      "render=%ux%u display=%ux%u",
      (unsigned long long)ctx->dispatches,
      (unsigned long long)ctx->resets,
      (unsigned long long)ctx->resizes,
      (unsigned long long)ctx->pipelineErrors,
      ctx->renderWidth,
      ctx->renderHeight,
      ctx->displayWidth,
      ctx->displayHeight);
  if (n < 0) {
    buf[0] = '\0';
    return 0;
  }
  return int32_t(std::min<uint32_t>(uint32_t(n), cap - 1u));
}
