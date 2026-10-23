#import "WindowsVRNeuralReconstruction.h"
#import "WindowsVRFsr3Upscaler.h"
#import "WindowsVRMetalFXUpscaler.h"
#import "WindowsVRGuestFoveation.h"
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <simd/simd.h>
#if __has_include(<CoreML/CoreML.h>)
#import <CoreML/CoreML.h>
#endif
#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <mutex>
#include <vector>
#if TARGET_OS_VISION || TARGET_OS_OSX
#import <IOSurface/IOSurface.h>
#endif
#if __has_include(<CoreVideo/CoreVideo.h>)
#import <CoreVideo/CoreVideo.h>
#endif

namespace {

static NSString *const kNeuralSource = @R"metal(
#include <metal_stdlib>
using namespace metal;

constexpr sampler linearSampler(coord::normalized, address::clamp_to_edge, filter::linear);
// Depth must not be filtered across silhouettes; input depth may be smaller than the eye.
constexpr sampler depthSampler(coord::normalized, address::clamp_to_edge, filter::nearest);

struct NeuralStereoWarpParams {
    float4x4 eyeAClipFromEyeBView;
    float4x4 eyeBInverseProjection;
    uint2 size;
};

struct NeuralTemporalWarpParams {
    float4x4 historyClipFromCurrent;
    float4x4 currentInverseProjection;
    float2 gazeCenterUV;
    float gazeRadiusUV;
    float pad0;
    uint2 size;
    uint historyValid;
};

struct NeuralGatherParams {
    float2 gazeCenterUV;
    float gazeRadiusUV;
    float pad0;
    float2 cropSizeUV;
    float2 jitterUV;
    float2 jitterNDC;
    uint2 cropLrSize;
    uint2 cropHrSize;
    uint eyeRole;
    uint historyValid;
    uint stereoValid;
    uint pad1;
};

struct NeuralBlendParams {
    float4x4 historyClipFromCurrent;
    float4x4 currentInverseProjection;
    float2 gazeCenterUV;
    float gazeRadiusUV;
    float pad0;
    float2 jitterUV;
    uint2 fullSize;
    uint eyeRole;
    uint historyValid;
    uint stereoValid;
    uint fuseAfwAndAnalytical;
};

struct NeuralObjectMotionParams {
    float4x4 historyClipFromCurrent;
    float4x4 currentInverseProjection;
    uint2 fullSize;
    uint2 tileCount;
    uint historyValid;
    uint pad0;
    uint pad1;
    uint pad2;
};

struct NeuralExtrapParams {
    float4x4 displayInverseProjection;
    float4x4 sourceViewFromDisplayView;
    float4x4 sourceProjection;
    float4x4 sourceInverseProjection;
    float4x4 displayProjection;
    float4x4 displayFromSource;
    float4x4 historyProjection;
    float4x4 historyViewFromDisplayView;
    uint2 displaySize;
    uint historyValid;
    float pad0;
    // Second-order non-linear trajectory curvature (NeurIPS Quadratic Extrapolation)
    float2 quadraticCurvature;
    uint objectMotionEnabled;
    float extrapFraction;
    uint2 physicalSize;
    uint rateMapLayer;
    uint pad1;
};

float3 ray(float2 uv, float4x4 invProj) {
    float4 clip = float4(uv * float2(2.0f, -2.0f) + float2(-1.0f, 1.0f), 0.5f, 1.0f);
    float4 r = invProj * clip;
    return r.xyz / max(1e-8f, -r.z);
}

float3 to_ycocg(float3 c) {
    return float3(0.25f * c.r + 0.5f * c.g + 0.25f * c.b,
                  0.5f * c.r - 0.5f * c.b,
                  -0.25f * c.r + 0.5f * c.g - 0.25f * c.b);
}

float3 from_ycocg(float3 y) {
    float t = y.x - y.z;
    return float3(t + y.y, y.x + y.z, t - y.y);
}

// --- Color Space, EOTF & HDR/EDR Color Management (Apple Vision Pro Micro-OLED) ---

// Piecewise IEC 61966-2-1 sRGB Transfer Functions (photometrically exact)
float srgb_to_linear(float c) {
    return (c <= 0.04045f) ? (c / 12.92f) : pow((c + 0.055f) / 1.055f, 2.4f);
}
float3 srgb_to_linear(float3 c) {
    return float3(srgb_to_linear(c.r), srgb_to_linear(c.g), srgb_to_linear(c.b));
}

float linear_to_srgb(float c) {
    return (c <= 0.0031308f) ? (c * 12.92f) : (1.055f * pow(max(0.0f, c), 1.0f / 2.4f) - 0.055f);
}
float3 linear_to_srgb(float3 c) {
    return float3(linear_to_srgb(c.r), linear_to_srgb(c.g), linear_to_srgb(c.b));
}

// Rec.709 vs Display P3 Gamut Conversion Matrices (D65 white point)
constant float3x3 kRec709ToDisplayP3 = float3x3(
    float3(0.822462f, 0.177538f, 0.000000f),
    float3(0.033194f, 0.966806f, 0.000000f),
    float3(0.017083f, 0.072397f, 0.910520f)
);

constant float3x3 kDisplayP3ToRec709 = float3x3(
    float3( 1.224940f, -0.224940f,  0.000000f),
    float3(-0.042057f,  1.042057f,  0.000000f),
    float3(-0.019638f, -0.078636f,  1.098274f)
);

float rec709_luminance(float3 linearCol) {
    return dot(linearCol, float3(0.2126f, 0.7152f, 0.0722f));
}

float display_p3_luminance(float3 linearCol) {
    return dot(linearCol, float3(0.2093f, 0.7211f, 0.0696f));
}

// Reversible Extended Dynamic Range (EDR) Tonemapper for Neural / Splat processing
// Compresses high-energy specular HDR highlights (>1.0 nits up to EDR headroom)
// preventing loss spikes or convolution ringing in HDR mode, then reversibly un-tonemaps.
float3 tonemap_edr(float3 linearCol, float exposure = 1.0f) {
    float3 x = linearCol * exposure;
    return x / (float3(1.0f) + x);
}

float3 inverse_tonemap_edr(float3 tonemappedCol, float exposure = 1.0f) {
    float3 x = clamp(tonemappedCol, 0.0f, 0.999f);
    return (x / max(1.0f - x, 1e-4f)) / max(exposure, 1e-4f);
}

// 5-Tap Catmull-Rom Bicubic History Sampler (DLSS / FSR 2/3 style)
// Decomposes a 4x4 cubic footprint into 5 bilinear samples for tack-sharp subpixel reprojection
float4 sample_catmull_rom_5tap(texture2d<float, access::sample> tex, float2 uv, uint2 texSize) {
    float2 samplePos = uv * float2(texSize);
    float2 tc = floor(samplePos - 0.5f) + 0.5f;
    float2 f = samplePos - tc;
    float2 f2 = f * f;
    float2 f3 = f2 * f;

    float2 w0 = f2 - 0.5f * (f3 + f);
    float2 w1 = 1.5f * f3 - 2.5f * f2 + 1.0f;
    float2 w3 = 0.5f * (f3 - f2);
    float2 w2 = 1.0f - w0 - w1 - w3;

    float2 w12 = w1 + w2;
    float2 tc12 = tc + (w2 / max(w12, 1e-4f));

    float2 tc0 = tc - 1.0f;
    float2 tc3 = tc + 2.0f;

    float2 invSize = float2(1.0f) / float2(texSize);

    float4 c0 = tex.sample(linearSampler, float2(tc12.x, tc0.y) * invSize);
    float4 c1 = tex.sample(linearSampler, float2(tc0.x, tc12.y) * invSize);
    float4 c2 = tex.sample(linearSampler, float2(tc12.x, tc12.y) * invSize);
    float4 c3 = tex.sample(linearSampler, float2(tc3.x, tc12.y) * invSize);
    float4 c4 = tex.sample(linearSampler, float2(tc12.x, tc3.y) * invSize);

    float weightCenter = w12.x * w12.y;
    float weightTop = w12.x * w0.y;
    float weightBottom = w12.x * w3.y;
    float weightLeft = w0.x * w12.y;
    float weightRight = w3.x * w12.y;

    float4 color = c0 * weightTop + c1 * weightLeft + c2 * weightCenter + c3 * weightRight + c4 * weightBottom;
    return color / max(1e-4f, weightTop + weightLeft + weightCenter + weightRight + weightBottom);
}

// Clamps history sample into local YCoCg variance box to eliminate temporal ghosting
float3 clip_history_ycocg(float3 historyRGB, float3 localMin, float3 localMax) {
    float3 h = to_ycocg(historyRGB);
    float3 bMin = to_ycocg(localMin);
    float3 bMax = to_ycocg(localMax);
    float3 clipped = clamp(h, min(bMin, bMax), max(bMin, bMax));
    return from_ycocg(clipped);
}

// 1. YORO Stereo Warp: warps Eye A HR colour into Eye B via depth + stereo pose
kernel void yoro_stereo_warp(
    texture2d<float, access::sample> eyeA_color [[texture(0)]],
    texture2d<float, access::sample> eyeB_depth [[texture(1)]],
    texture2d<float, access::write> out_stereo [[texture(2)]],
    texture2d<float, access::write> out_validity [[texture(3)]],
    constant NeuralStereoWarpParams& p [[buffer(0)]],
    uint2 at [[thread_position_in_grid]])
{
    if (any(at >= p.size)) return;
    float2 uv = (float2(at) + 0.5f) / float2(p.size);
    float2 d = eyeB_depth.sample(depthSampler, uv).rg;
    float z = d.x;
    bool valid = false;
    float4 warped = float4(0.0f);

    if (z > 0.02f && z < 1000.0f && d.y > 0.1f) {
        float3 viewPt = ray(uv, p.eyeBInverseProjection) * z;
        float4 clipA = p.eyeAClipFromEyeBView * float4(viewPt, 1.0f);
        if (clipA.w > 0.0f) {
            float2 uvA = clipA.xy / clipA.w * float2(0.5f, -0.5f) + 0.5f;
            if (all(uvA >= 0.0f) && all(uvA <= 1.0f)) {
                warped = eyeA_color.sample(linearSampler, uvA);
                valid = true;
            }
        }
    }
    out_stereo.write(warped, at);
    out_validity.write(float4(valid ? 1.0f : 0.0f, valid ? 1.0f : 0.0f, 0.0f, 1.0f), at);
}

// 2. AFW Temporal Warp: warps own previous HR history into current pose
kernel void afw_temporal_warp(
    texture2d<float, access::sample> history_color [[texture(0)]],
    texture2d<float, access::sample> history_depth [[texture(1)]],
    texture2d<float, access::sample> current_depth [[texture(2)]],
    texture2d<float, access::write> out_warped_history [[texture(3)]],
    texture2d<float, access::write> out_validity [[texture(4)]],
    constant NeuralTemporalWarpParams& p [[buffer(0)]],
    uint2 at [[thread_position_in_grid]])
{
    if (any(at >= p.size)) return;
    float2 uv = (float2(at) + 0.5f) / float2(p.size);
    float2 d = current_depth.sample(depthSampler, uv).rg;
    float z = d.x;
    bool valid = false;
    float4 warped = float4(0.0f);

    if (p.historyValid && z > 0.02f && z < 1000.0f && d.y > 0.1f) {
        float3 viewPt = ray(uv, p.currentInverseProjection) * z;
        float4 clipH = p.historyClipFromCurrent * float4(viewPt, 1.0f);
        if (clipH.w > 0.0f) {
            float2 uvH = clipH.xy / clipH.w * float2(0.5f, -0.5f) + 0.5f;
            if (all(uvH >= 0.0f) && all(uvH <= 1.0f)) {
                float histD = history_depth.sample(depthSampler, uvH).r;
                if (histD > 0.0f && abs(clipH.w - histD) <= 0.08f * clipH.w) {
                    float aspect = float(p.size.x) / float(p.size.y);
                    float2 delta = uv - p.gazeCenterUV;
                    float r = length(float2(delta.x * aspect, delta.y)) / max(1e-4f, p.gazeRadiusUV * aspect);
                    warped = (r < 1.2f)
                        ? sample_catmull_rom_5tap(history_color, uvH, p.size)
                        : history_color.sample(linearSampler, uvH);
                    valid = true;
                }
            }
        }
    }
    out_warped_history.write(warped, at);
    out_validity.write(float4(valid ? 1.0f : 0.0f, valid ? 1.0f : 0.0f, 0.0f, 1.0f), at);
}

// 3. Foveal Gather Inputs: extracts LR foveal crop and packs 40-channel FP16 tensor
// Channel order matches VRFovealNet.forward in oss/vr/model.py:
//   0..2:   lr * mask (3)
//   3:      mask (1)
//   4:      log1p(depth) / 7.0 (1)
//   5..6:   jitter (2)
//   7:      role (1)
//   8..19:  s2d(hist, 2)       [c * 4 + sy * 2 + sx] (12)
//   20..23: s2d(hist_conf, 2)  [sy * 2 + sx]         (4)
//   24..35: s2d(stereo, 2)     [c * 4 + sy * 2 + sx] (12)
//   36..39: s2d(stereo_conf, 2)[sy * 2 + sx]         (4)
kernel void foveal_gather_inputs(
    texture2d<float, access::sample> lr_color [[texture(0)]],
    texture2d<float, access::sample> lr_depth [[texture(1)]],
    texture2d<float, access::sample> hr_hist [[texture(2)]],
    texture2d<float, access::sample> hr_hist_validity [[texture(3)]],
    texture2d<float, access::sample> hr_stereo [[texture(4)]],
    texture2d<float, access::sample> hr_stereo_validity [[texture(5)]],
    device half* out_tensor [[buffer(0)]], // 40 halfs per LR pixel
    constant NeuralGatherParams& p [[buffer(1)]],
    uint2 at [[thread_position_in_grid]])
{
    if (any(at >= p.cropLrSize)) return;

    float2 lrRel = (float2(at) + 0.5f) / float2(p.cropLrSize) - 0.5f;
    float2 fullUV = p.gazeCenterUV + lrRel * p.cropSizeUV;
    float mVal = (all(fullUV >= 0.0f) && all(fullUV <= 1.0f)) ? 1.0f : 0.0f;

    float4 c = lr_color.sample(linearSampler, fullUV + p.jitterUV);
    float2 d = lr_depth.sample(depthSampler, fullUV).rg;
    float depthVal = (d.y > 0.1f) ? clamp(d.x, 0.0f, 1000.0f) : 0.0f;

    uint baseIdx = (at.y * p.cropLrSize.x + at.x) * 40u;

    out_tensor[baseIdx + 0] = half(c.r * mVal);
    out_tensor[baseIdx + 1] = half(c.g * mVal);
    out_tensor[baseIdx + 2] = half(c.b * mVal);
    out_tensor[baseIdx + 3] = half(mVal);
    out_tensor[baseIdx + 4] = half(log(1.0f + depthVal) / 7.0f);
    out_tensor[baseIdx + 5] = half(p.jitterNDC.x);
    out_tensor[baseIdx + 6] = half(p.jitterNDC.y);
    out_tensor[baseIdx + 7] = half(p.eyeRole);

    for (uint sy = 0; sy < 2; ++sy) {
        for (uint sx = 0; sx < 2; ++sx) {
            uint subIdx = sy * 2u + sx;
            uint2 hrAt = at * 2u + uint2(sx, sy);
            float2 hrRel = (float2(hrAt) + 0.5f) / float2(p.cropHrSize) - 0.5f;
            float2 hrFullUV = p.gazeCenterUV + hrRel * p.cropSizeUV;

            const bool sampleHist = (p.historyValid != 0u);
            float3 hCol = sampleHist ? hr_hist.sample(linearSampler, hrFullUV).rgb : float3(0.0f);
            float hConf = sampleHist ? hr_hist_validity.sample(linearSampler, hrFullUV).r : 0.0f;
            out_tensor[baseIdx + 8u  + 0u * 4u + subIdx] = half(hCol.r);
            out_tensor[baseIdx + 8u  + 1u * 4u + subIdx] = half(hCol.g);
            out_tensor[baseIdx + 8u  + 2u * 4u + subIdx] = half(hCol.b);
            out_tensor[baseIdx + 20u + subIdx]           = half(hConf);

            const bool sampleStereo = (p.eyeRole == 1u && p.stereoValid != 0u);
            float3 sCol = sampleStereo ? hr_stereo.sample(linearSampler, hrFullUV).rgb : float3(0.0f);
            float sConf = sampleStereo ? hr_stereo_validity.sample(linearSampler, hrFullUV).r : 0.0f;
            out_tensor[baseIdx + 24u + 0u * 4u + subIdx] = half(sCol.r);
            out_tensor[baseIdx + 24u + 1u * 4u + subIdx] = half(sCol.g);
            out_tensor[baseIdx + 24u + 2u * 4u + subIdx] = half(sCol.b);
            out_tensor[baseIdx + 36u + subIdx]           = half(sConf);
        }
    }
}

struct NeuralConvParams {
    uint2 inSize;
    uint2 outSize;
    uint inCh;
    uint outCh;
    uint stride;
    uint inputRelu;
    uint applyRelu;
    uint addResidual;
    uint weightOffset;
    uint biasOffset;
};

// 4a. FP16 3x3 Convolution (+ optional inputReLU / outputReLU / Residual add) for VRFovealNet layers
kernel void conv3x3_fp16(
    device const half* input [[buffer(0)]],
    device const half* residual [[buffer(1)]],
    device const half* weights [[buffer(2)]],
    device half* output [[buffer(3)]],
    constant NeuralConvParams& p [[buffer(4)]],
    uint3 gid [[thread_position_in_grid]])
{
    if (gid.x >= p.outSize.x || gid.y >= p.outSize.y || gid.z >= p.outCh) return;
    int ox = int(gid.x), oy = int(gid.y), oc = int(gid.z);
    int ix0 = ox * int(p.stride) - 1;
    int iy0 = oy * int(p.stride) - 1;
    uint inW = p.inSize.x, inH = p.inSize.y, inC = p.inCh;
    device const half* wBase = weights + p.weightOffset + uint(oc) * inC * 9u;
    float acc = float(weights[p.biasOffset + uint(oc)]);

    for (uint ic = 0; ic < inC; ++ic) {
        device const half* wCh = wBase + ic * 9u;
        for (int ky = 0; ky < 3; ++ky) {
            int sy = iy0 + ky;
            if (sy < 0 || sy >= int(inH)) continue;
            for (int kx = 0; kx < 3; ++kx) {
                int sx = ix0 + kx;
                if (sx < 0 || sx >= int(inW)) continue;
                uint inIdx = (uint(sy) * inW + uint(sx)) * inC + ic;
                float v = float(input[inIdx]);
                if (p.inputRelu != 0) v = max(0.0f, v);
                acc += v * float(wCh[ky * 3 + kx]);
            }
        }
    }
    uint outIdx = (uint(oy) * p.outSize.x + uint(ox)) * p.outCh + uint(oc);
    if (p.addResidual != 0) {
        acc += float(residual[outIdx]);
    }
    if (p.applyRelu != 0) {
        acc = max(0.0f, acc);
    }
    output[outIdx] = half(acc);
}

// 4a-tiled. Tiled FP16 3x3 Convolution (8x8x8 output tile, IC_CHUNK=16 input staging in threadgroup memory)
template <uint TILE_DIM, uint STRIDE>
inline void conv3x3_fp16_tiled_impl(
    device const half* input,
    device const half* residual,
    device const half* weights,
    device half* output,
    constant NeuralConvParams& p,
    uint3 tgid,
    uint3 tid,
    threadgroup half* tileIn,
    threadgroup half* tileW)
{
    constexpr uint OC_BLOCK = 8u;
    constexpr uint IC_CHUNK = 16u;
    constexpr uint TILE_PIXELS = TILE_DIM * TILE_DIM;
    constexpr uint TOTAL_TILE_ELEMS = TILE_PIXELS * IC_CHUNK;
    constexpr uint WEIGHT_TILE_ELEMS = OC_BLOCK * IC_CHUNK * 9u;

    uint linearTid = tid.y * 8u + tid.x;
    uint ox = tgid.x * 8u + tid.x;
    uint oy = tgid.y * 8u + tid.y;
    uint ocBase = tgid.z * OC_BLOCK;

    uint inW = p.inSize.x, inH = p.inSize.y, inC = p.inCh;

    int tileOriginX = int(tgid.x * 8u * STRIDE) - 1;
    int tileOriginY = int(tgid.y * 8u * STRIDE) - 1;
    uint localX0 = tid.x * STRIDE;
    uint localY0 = tid.y * STRIDE;

    float acc[OC_BLOCK];
    for (uint o = 0; o < OC_BLOCK; ++o) {
        uint oc = ocBase + o;
        acc[o] = (oc < p.outCh) ? float(weights[p.biasOffset + oc]) : 0.0f;
    }

    for (uint icBase = 0; icBase < inC; icBase += IC_CHUNK) {
        for (uint idx = linearTid; idx < TOTAL_TILE_ELEMS; idx += 64u) {
            uint pix = idx / IC_CHUNK;
            uint ic = idx % IC_CHUNK;
            uint ty = pix / TILE_DIM;
            uint tx = pix % TILE_DIM;
            int sx = tileOriginX + int(tx);
            int sy = tileOriginY + int(ty);
            uint globalIc = icBase + ic;
            half val = half(0.0f);
            if (globalIc < inC && sx >= 0 && sx < int(inW) && sy >= 0 && sy < int(inH)) {
                float v = float(input[(uint(sy) * inW + uint(sx)) * inC + globalIc]);
                if (p.inputRelu != 0) v = max(0.0f, v);
                val = half(v);
            }
            tileIn[idx] = val;
        }

        for (uint idx = linearTid; idx < WEIGHT_TILE_ELEMS; idx += 64u) {
            uint k = idx % 9u;
            uint tmp = idx / 9u;
            uint ic = tmp % IC_CHUNK;
            uint o = tmp / IC_CHUNK;
            uint oc = ocBase + o;
            uint globalIc = icBase + ic;
            half wVal = half(0.0f);
            if (oc < p.outCh && globalIc < inC) {
                wVal = weights[p.weightOffset + (oc * inC + globalIc) * 9u + k];
            }
            tileW[idx] = wVal;
        }

        threadgroup_barrier(mem_flags::mem_threadgroup);

        uint icCount = min(IC_CHUNK, inC - icBase);
        for (uint ic = 0; ic < icCount; ++ic) {
            for (uint ky = 0; ky < 3u; ++ky) {
                uint ty = localY0 + ky;
                for (uint kx = 0; kx < 3u; ++kx) {
                    uint tx = localX0 + kx;
                    float v = float(tileIn[(ty * TILE_DIM + tx) * IC_CHUNK + ic]);
                    uint wOffset = ic * 9u + ky * 3u + kx;
                    for (uint o = 0; o < OC_BLOCK; ++o) {
                        acc[o] += v * float(tileW[o * (IC_CHUNK * 9u) + wOffset]);
                    }
                }
            }
        }

        threadgroup_barrier(mem_flags::mem_threadgroup);
    }

    if (ox >= p.outSize.x || oy >= p.outSize.y) return;
    uint outPixelBase = (oy * p.outSize.x + ox) * p.outCh;
    for (uint o = 0; o < OC_BLOCK; ++o) {
        uint oc = ocBase + o;
        if (oc >= p.outCh) break;
        float val = acc[o];
        uint outIdx = outPixelBase + oc;
        if (p.addResidual != 0) {
            val += float(residual[outIdx]);
        }
        if (p.applyRelu != 0) {
            val = max(0.0f, val);
        }
        output[outIdx] = half(val);
    }
}

kernel void conv3x3_fp16_tiled(
    device const half* input [[buffer(0)]],
    device const half* residual [[buffer(1)]],
    device const half* weights [[buffer(2)]],
    device half* output [[buffer(3)]],
    constant NeuralConvParams& p [[buffer(4)]],
    uint3 tgid [[threadgroup_position_in_grid]],
    uint3 tid [[thread_position_in_threadgroup]])
{
    threadgroup half tileIn[10u * 10u * 16u];
    threadgroup half tileW[8u * 16u * 9u];
    conv3x3_fp16_tiled_impl<10u, 1u>(input, residual, weights, output, p, tgid, tid, tileIn, tileW);
}

kernel void conv3x3_fp16_tiled_s2(
    device const half* input [[buffer(0)]],
    device const half* residual [[buffer(1)]],
    device const half* weights [[buffer(2)]],
    device half* output [[buffer(3)]],
    constant NeuralConvParams& p [[buffer(4)]],
    uint3 tgid [[threadgroup_position_in_grid]],
    uint3 tid [[thread_position_in_threadgroup]])
{
    threadgroup half tileIn[17u * 17u * 16u];
    threadgroup half tileW[8u * 16u * 9u];
    conv3x3_fp16_tiled_impl<17u, 2u>(input, residual, weights, output, p, tgid, tid, tileIn, tileW);
}

// 4b. FP16 Pixel Shuffle 2x + skip connection add (dec input = f1 + pixel_shuffle(up(lo), 2))
kernel void pixel_shuffle_2x_skip_fp16(
    device const half* in_low [[buffer(0)]],
    device const half* skip_f1 [[buffer(1)]],
    device half* out_feat [[buffer(2)]],
    constant uint3& dims [[buffer(3)]], // (lr_w, lr_h, ch)
    uint3 gid [[thread_position_in_grid]])
{
    if (gid.x >= dims.x || gid.y >= dims.y || gid.z >= dims.z) return;
    uint lx = gid.x / 2u, ly = gid.y / 2u;
    uint sx = gid.x & 1u, sy = gid.y & 1u;
    uint lowW = dims.x / 2u;
    uint ch = dims.z;
    // PyTorch pixel_shuffle(2) maps channel c * 4 + sy * 2 + sx -> c at (2*ly+sy, 2*lx+sx)
    uint srcCh = gid.z * 4u + sy * 2u + sx;
    uint lowIdx = (ly * lowW + lx) * (ch * 4u) + srcCh;
    uint dstIdx = (gid.y * dims.x + gid.x) * ch + gid.z;
    out_feat[dstIdx] = in_low[lowIdx] + skip_f1[dstIdx];
}

// 4c. VRFovealNet Output Pixel Shuffle (24 ch -> 6 HR ch) + Softmax Candidate Blend + Residual
kernel void foveal_out_resolve_fp16(
    device const half* net_out [[buffer(0)]], // (cropLrH * cropLrW * 24)
    texture2d<float, access::sample> lr_color [[texture(0)]],
    texture2d<float, access::sample> hr_hist [[texture(1)]],
    texture2d<float, access::sample> hr_hist_validity [[texture(2)]],
    texture2d<float, access::sample> hr_stereo [[texture(3)]],
    texture2d<float, access::sample> hr_stereo_validity [[texture(4)]],
    texture2d<float, access::write> out_fovea_hr [[texture(5)]],
    constant NeuralGatherParams& p [[buffer(1)]],
    uint2 at [[thread_position_in_grid]])
{
    if (any(at >= p.cropHrSize)) return;
    uint2 lr_at = at / 2u;
    uint sx = at.x & 1u, sy = at.y & 1u;
    uint sub = sy * 2u + sx;
    uint baseIdx = (lr_at.y * p.cropLrSize.x + lr_at.x) * 24u;

    // PyTorch pixel_shuffle(2) on 24 channels -> 6 HR channels (3 logits + 3 residual)
    float logit0 = float(net_out[baseIdx + 0u * 4u + sub]);
    float logit1 = float(net_out[baseIdx + 1u * 4u + sub]);
    float logit2 = float(net_out[baseIdx + 2u * 4u + sub]);
    float3 residual = float3(
        float(net_out[baseIdx + 3u * 4u + sub]),
        float(net_out[baseIdx + 4u * 4u + sub]),
        float(net_out[baseIdx + 5u * 4u + sub]));

    float2 hrRel = (float2(at) + 0.5f) / float2(p.cropHrSize) - 0.5f;
    float2 fullUV = p.gazeCenterUV + hrRel * p.cropSizeUV;
    float bConf = (all(fullUV >= 0.0f) && all(fullUV <= 1.0f)) ? 1.0f : 0.0f;

    float3 base = lr_color.sample(linearSampler, fullUV + p.jitterUV).rgb;
    const bool sampleHist = (p.historyValid != 0u);
    float3 hist = sampleHist ? hr_hist.sample(linearSampler, fullUV).rgb : float3(0.0f);
    float hConf = sampleHist ? hr_hist_validity.sample(linearSampler, fullUV).r : 0.0f;
    const bool sampleStereo = (p.eyeRole == 1u && p.stereoValid != 0u);
    float3 stereo = sampleStereo ? hr_stereo.sample(linearSampler, fullUV).rgb : float3(0.0f);
    float sConf = sampleStereo ? hr_stereo_validity.sample(linearSampler, fullUV).r : 0.0f;

    float l0 = logit0 + (hConf - 1.0f) * 8.0f;
    float l1 = logit1 + (sConf - 1.0f) * 8.0f;
    float l2 = logit2 + (bConf - 1.0f) * 8.0f;
    float m = max(l0, max(l1, l2));
    float w0 = exp(l0 - m), w1 = exp(l1 - m), w2 = exp(l2 - m);
    float invSum = 1.0f / max(1e-6f, w0 + w1 + w2);
    float3 outCol = clamp((w0 * hist + w1 * stereo + w2 * base) * invSum + residual, 0.0f, 1.0f);
    out_fovea_hr.write(float4(outCol, 1.0f), at);
}

// 4b. Analytical Fallback: YORO + AFW + jitter-aware softmax blend when weights absent
kernel void analytical_foveal_blend(
    texture2d<float, access::sample> lr_color [[texture(0)]],
    texture2d<float, access::sample> hr_hist [[texture(1)]],
    texture2d<float, access::sample> hr_hist_validity [[texture(2)]],
    texture2d<float, access::sample> hr_stereo [[texture(3)]],
    texture2d<float, access::sample> hr_stereo_validity [[texture(4)]],
    texture2d<float, access::write> out_fovea_hr [[texture(5)]],
    constant NeuralGatherParams& p [[buffer(0)]],
    uint2 at [[thread_position_in_grid]])
{
    if (any(at >= p.cropHrSize)) return;

    float2 hrRel = (float2(at) + 0.5f) / float2(p.cropHrSize) - 0.5f;
    float2 fullUV = p.gazeCenterUV + hrRel * p.cropSizeUV;

    float3 base = lr_color.sample(linearSampler, fullUV + p.jitterUV).rgb;
    const bool sampleHist = (p.historyValid != 0u);
    float3 hist = sampleHist ? hr_hist.sample(linearSampler, fullUV).rgb : float3(0.0f);
    float hConf = sampleHist ? hr_hist_validity.sample(linearSampler, fullUV).r : 0.0f;

    const bool sampleStereo = (p.eyeRole == 1u && p.stereoValid != 0u);
    float3 stereo = sampleStereo ? hr_stereo.sample(linearSampler, fullUV).rgb : float3(0.0f);
    float sConf = sampleStereo ? hr_stereo_validity.sample(linearSampler, fullUV).r : 0.0f;

    // Logits: confidence-driven with eye role steering
    float l_h = hConf * 3.5f;
    float l_s = sConf * (p.eyeRole == 1u ? 4.0f : 1.0f);
    float l_b = 1.0f;

    float max_l = max(l_h, max(l_s, l_b));
    float w_h = hConf * exp(l_h - max_l);
    float w_s = (p.eyeRole == 1u ? sConf : 0.0f) * exp(l_s - max_l);
    float w_b = exp(l_b - max_l);
    float sum_w = max(1e-6f, w_h + w_s + w_b);

    // Anti-ghosting history bounding box clamp in YCoCg space
    float3 histClipped = clip_history_ycocg(hist, base * 0.75f, base * 1.25f + 0.08f);

    float3 wts = float3(w_h, w_s, w_b) / sum_w;
    float3 blended = wts.x * histClipped + wts.y * stereo + wts.z * base;

    out_fovea_hr.write(float4(blended, 1.0f), at);
}

// 5. Foveal Blend and Splice: feather foveal crop into full-eye output
kernel void foveal_blend_and_splice(
    texture2d<float, access::sample> foveal_hr [[texture(0)]],
    texture2d<float, access::sample> base_color [[texture(1)]],
    texture2d<float, access::sample> warped_stereo [[texture(2)]],
    texture2d<float, access::sample> warped_hist [[texture(3)]],
    texture2d<float, access::sample> hist_validity [[texture(4)]],
    texture2d<float, access::write> out_color [[texture(5)]],
    texture2d<float, access::sample> stereo_validity [[texture(6)]],
    texture2d<float, access::sample> history_color [[texture(7)]],
    texture2d<float, access::sample> history_depth [[texture(8)]],
    texture2d<float, access::sample> current_depth [[texture(9)]],
    constant NeuralBlendParams& p [[buffer(0)]],
    uint2 at [[thread_position_in_grid]])
{
    if (any(at >= p.fullSize)) return;
    float2 uv = (float2(at) + 0.5f) / float2(p.fullSize);
    float2 delta = (uv - p.gazeCenterUV);
    // Aspect ratio correction (circular fovea on screen)
    float aspect = float(p.fullSize.x) / float(p.fullSize.y);
    float2 deltaAspect = float2(delta.x * aspect, delta.y);
    float r = length(deltaAspect) / max(1e-4f, p.gazeRadiusUV * aspect);

    float3 base = base_color.sample(linearSampler, uv + p.jitterUV).rgb;
    const bool sampleStereo = (p.eyeRole == 1u && p.stereoValid != 0u);
    float3 stereo = sampleStereo ? warped_stereo.sample(linearSampler, uv).rgb : float3(0.0f);
    float sValid = sampleStereo ? stereo_validity.sample(linearSampler, uv).r : 0.0f;

    float3 hist = float3(0.0f);
    float hValid = 0.0f;
    if (p.fuseAfwAndAnalytical != 0u) {
        if (p.historyValid != 0u) {
            float2 d = current_depth.sample(depthSampler, uv).rg;
            float z = d.x;
            if (z > 0.02f && z < 1000.0f && d.y > 0.1f) {
                float3 viewPt = ray(uv, p.currentInverseProjection) * z;
                float4 clipH = p.historyClipFromCurrent * float4(viewPt, 1.0f);
                if (clipH.w > 0.0f) {
                    float2 uvH = clipH.xy / clipH.w * float2(0.5f, -0.5f) + 0.5f;
                    if (all(uvH >= 0.0f) && all(uvH <= 1.0f)) {
                        float histD = history_depth.sample(depthSampler, uvH).r;
                        if (histD > 0.0f && abs(clipH.w - histD) <= 0.08f * clipH.w) {
                            hist = (r < 1.2f)
                                ? sample_catmull_rom_5tap(history_color, uvH, p.fullSize).rgb
                                : history_color.sample(linearSampler, uvH).rgb;
                            hValid = 1.0f;
                        }
                    }
                }
            }
        }
    } else if (p.historyValid != 0u) {
        hist = warped_hist.sample(linearSampler, uv).rgb;
        hValid = hist_validity.sample(linearSampler, uv).r;
    }

    // Peripheral reconstruction
    float3 peripheral = base;
    if (p.eyeRole == 1u && sValid > 0.5f) {
        peripheral = mix(base, stereo, 0.70f);
    }
    if (hValid > 0.5f) {
        float3 cBase = to_ycocg(peripheral);
        float3 cHist = to_ycocg(hist);
        float3 lo = cBase - 0.15f;
        float3 hi = cBase + 0.15f;
        cHist = clamp(cHist, lo, hi);
        peripheral = mix(peripheral, from_ycocg(cHist), 0.85f);
    }

    float3 finalColor = peripheral;
    if (r < 1.0f) {
        float2 foveaUV = float2(delta.x / (2.0f * p.gazeRadiusUV), delta.y / (2.0f * p.gazeRadiusUV * aspect)) + 0.5f;
        if (all(foveaUV >= 0.0f) && all(foveaUV <= 1.0f)) {
            float3 foveal;
            if (p.fuseAfwAndAnalytical != 0u) {
                float l_h = hValid * 3.5f;
                float l_s = sValid * (p.eyeRole == 1u ? 4.0f : 1.0f);
                float l_b = 1.0f;
                float max_l = max(l_h, max(l_s, l_b));
                float w_h = hValid * exp(l_h - max_l);
                float w_s = (p.eyeRole == 1u ? sValid : 0.0f) * exp(l_s - max_l);
                float w_b = exp(l_b - max_l);
                float sum_w = max(1e-6f, w_h + w_s + w_b);
                float3 histClipped = clip_history_ycocg(hist, base * 0.75f, base * 1.25f + 0.08f);
                float3 wts = float3(w_h, w_s, w_b) / sum_w;
                foveal = wts.x * histClipped + wts.y * stereo + wts.z * base;
            } else {
                foveal = foveal_hr.sample(linearSampler, foveaUV).rgb;
            }
            float feather = (r <= 0.8f) ? 1.0f : 0.5f * (1.0f + cos((r - 0.8f) / 0.2f * 3.1415926535f));
            finalColor = mix(peripheral, foveal, feather);
        }
    }
    out_color.write(float4(finalColor, 1.0f), at);
}

// 5c. Object Motion Estimation at 1/8 resolution tiles (Residual object motion in UV per game frame)
kernel void object_motion_estimate(
    texture2d<float, access::sample> current_color [[texture(0)]],
    texture2d<float, access::sample> current_depth [[texture(1)]],
    texture2d<float, access::sample> history_color [[texture(2)]],
    texture2d<float, access::write> out_obj_motion [[texture(3)]],
    constant NeuralObjectMotionParams& p [[buffer(0)]],
    uint2 at [[thread_position_in_grid]])
{
    if (any(at >= p.tileCount)) return;

    float2 curUV = (float2(at) + 0.5f) / float2(p.tileCount);
    float2 d = current_depth.sample(depthSampler, curUV).rg;
    float z = d.x;

    if (p.historyValid == 0u || z <= 0.02f || z >= 1000.0f || d.y <= 0.1f) {
        out_obj_motion.write(float4(0.0f), at);
        return;
    }

    float3 viewPt = ray(curUV, p.currentInverseProjection) * z;
    float4 clipH = p.historyClipFromCurrent * float4(viewPt, 1.0f);
    if (clipH.w <= 0.0f) {
        out_obj_motion.write(float4(0.0f), at);
        return;
    }

    float2 histCamUV = clipH.xy / clipH.w * float2(0.5f, -0.5f) + 0.5f;
    if (any(histCamUV < 0.0f) || any(histCamUV > 1.0f)) {
        out_obj_motion.write(float4(0.0f), at);
        return;
    }

    float2 fullPixelStep = 1.0f / float2(p.fullSize);
    float curLum[4][4];
    float sumL = 0.0f;
    float sumL2 = 0.0f;
    for (int py = 0; py < 4; ++py) {
        for (int px = 0; px < 4; ++px) {
            float2 sampleUV = curUV + (float2(px, py) - 1.5f) * fullPixelStep;
            float l = rec709_luminance(current_color.sample(linearSampler, sampleUV).rgb);
            curLum[py][px] = l;
            sumL += l;
            sumL2 += l * l;
        }
    }
    float meanL = sumL * (1.0f / 16.0f);
    float variance = max(0.0f, (sumL2 * (1.0f / 16.0f)) - (meanL * meanL));

    // Reject low-texture tiles (patch variance threshold)
    if (variance < 0.0001f) {
        out_obj_motion.write(float4(0.0f), at);
        return;
    }

    // Camera-only SAD (residual motion 0)
    float cameraSAD = 0.0f;
    for (int py = 0; py < 4; ++py) {
        for (int px = 0; px < 4; ++px) {
            float2 hUV = histCamUV + (float2(px, py) - 1.5f) * fullPixelStep;
            float hl = rec709_luminance(history_color.sample(linearSampler, hUV).rgb);
            cameraSAD += abs(curLum[py][px] - hl);
        }
    }
    cameraSAD *= (1.0f / 16.0f);

    float2 tilePixelStep = 1.0f / float2(p.tileCount);
    float bestSAD = cameraSAD;
    float2 bestMotion = float2(0.0f);

    // Block-matching search +-3 tile-pixels at 1/8 res (+-24 full-res px)
    for (int dy = -3; dy <= 3; ++dy) {
        for (int dx = -3; dx <= 3; ++dx) {
            if (dx == 0 && dy == 0) continue;
            float2 candMotion = float2(dx, dy) * tilePixelStep;
            float2 candHistUV = histCamUV - candMotion;
            if (any(candHistUV < 0.0f) || any(candHistUV > 1.0f)) continue;

            float sad = 0.0f;
            for (int py = 0; py < 4; ++py) {
                for (int px = 0; px < 4; ++px) {
                    float2 hUV = candHistUV + (float2(px, py) - 1.5f) * fullPixelStep;
                    float hl = rec709_luminance(history_color.sample(linearSampler, hUV).rgb);
                    sad += abs(curLum[py][px] - hl);
                }
            }
            sad *= (1.0f / 16.0f);
            if (sad < bestSAD) {
                bestSAD = sad;
                bestMotion = candMotion;
            }
        }
    }

    // Require the SAD improvement to beat the camera-only SAD by a margin; otherwise motion 0.
    float sadImprovement = cameraSAD - bestSAD;
    float margin = max(0.015f, cameraSAD * 0.20f);
    if (sadImprovement <= margin || (bestMotion.x == 0.0f && bestMotion.y == 0.0f)) {
        out_obj_motion.write(float4(0.0f), at);
        return;
    }

    float confidence = clamp(sadImprovement / max(cameraSAD, 1e-4f), 0.0f, 1.0f);
    out_obj_motion.write(float4(bestMotion, confidence, 1.0f), at);
}

// 6. Extrapolation 90 Hz Foveal: forward depth prediction + ExtrapNet residual disocclusion fill
kernel void extrap_90hz_foveal(
    texture2d<float, access::sample> current_color [[texture(0)]],
    texture2d<float, access::sample> current_depth [[texture(1)]],
    texture2d<float, access::sample> history_color [[texture(2)]],
    texture2d<float, access::sample> history_depth [[texture(3)]],
    texture2d<float, access::write> out_display_color [[texture(4)]],
    texture2d<float, access::write> out_display_depth [[texture(5)]],
    texture2d<float, access::sample> obj_motion [[texture(6)]],
    constant NeuralExtrapParams& p [[buffer(0)]],
    uint2 at [[thread_position_in_grid]])
{
    if (any(at >= p.displaySize)) return;
    float2 uv = (float2(at) + 0.5f) / float2(p.displaySize);
    float2 curvedUV = clamp(uv + p.quadraticCurvature * 0.5f, 0.0f, 1.0f);
    float2 dCur = current_depth.sample(depthSampler, curvedUV).rg;
    float estDepthZ = (dCur.y > 0.1f && dCur.x > 0.02f && dCur.x < 1000.0f) ? dCur.x : 2.0f;

    // True 6DoF translational parallax + rotation ray (w = 1.0)
    float3 dispRay = ray(uv, p.displayInverseProjection);
    float3 viewPtDisplay = dispRay * estDepthZ;
    float4 ptSource = p.sourceViewFromDisplayView * float4(viewPtDisplay, 1.0f);
    float4 clipSource = p.sourceProjection * ptSource;

    float2 srcUV = uv;
    bool validSrc = false;
    if (clipSource.w > 0.0f) {
        srcUV = clipSource.xy / clipSource.w * float2(0.5f, -0.5f) + 0.5f;
        validSrc = all(srcUV >= 0.0f) && all(srcUV <= 1.0f);
    }
    if (!validSrc) srcUV = curvedUV;

    if (p.objectMotionEnabled != 0u) {
        float2 motion = obj_motion.sample(linearSampler, srcUV).xy;
        srcUV = clamp(srcUV - motion * p.extrapFraction, 0.0f, 1.0f);
    }

    float2 d = (validSrc && any(srcUV != curvedUV)) ? current_depth.sample(depthSampler, srcUV).rg : dCur;
    float depthZ = d.x;
    float3 col = current_color.sample(linearSampler, srcUV).rgb;

    bool disoccluded = !validSrc || (depthZ <= 0.02f || depthZ > 1000.0f || d.y < 0.2f);
    bool fromHistory = false;
    if (disoccluded && p.historyValid) {
        // True 6DoF reprojection into history pose
        float4 ptHist = p.historyViewFromDisplayView * float4(viewPtDisplay, 1.0f);
        float4 clipHist = p.historyProjection * ptHist;
        if (clipHist.w > 0.0f) {
            float2 histUV = clipHist.xy / clipHist.w * float2(0.5f, -0.5f) + 0.5f;
            if (all(histUV >= 0.0f) && all(histUV <= 1.0f)) {
                float hd = history_depth.sample(depthSampler, histUV).r;
                if (hd > 0.02f && hd < 1000.0f) {
                    float4 ptHistRefined = p.historyViewFromDisplayView * float4(dispRay * hd, 1.0f);
                    float4 clipHistRefined = p.historyProjection * ptHistRefined;
                    if (clipHistRefined.w > 0.0f) {
                        float2 refinedUV = clipHistRefined.xy / clipHistRefined.w * float2(0.5f, -0.5f) + 0.5f;
                        if (all(refinedUV >= 0.0f) && all(refinedUV <= 1.0f)) {
                            histUV = refinedUV;
                            float hdRefined = history_depth.sample(depthSampler, histUV).r;
                            if (hdRefined > 0.02f && hdRefined < 1000.0f) {
                                hd = hdRefined;
                            }
                            col = history_color.sample(linearSampler, histUV).rgb;
                            depthZ = hd;
                            disoccluded = false;
                            fromHistory = true;
                        }
                    }
                }
            }
        }
    }

    float dispZ = 0.0f;
    if (!disoccluded && depthZ > 0.02f) {
        float4 pt = fromHistory
            ? float4(dispRay * depthZ, 1.0f)
            : (p.displayFromSource * float4(ray(srcUV, p.sourceInverseProjection) * depthZ, 1.0f));
        float4 c = p.displayProjection * pt;
        dispZ = c.w > 0.0f ? c.z / c.w : 0.0f;
        if (!(isfinite(dispZ) && dispZ > 0.0f && dispZ <= 1.0f)) dispZ = 0.0f;
    }

    out_display_color.write(float4(col, 1.0f), at);
    out_display_depth.write(float4(dispZ, 0.0f, 0.0f, 1.0f), at);
}

// 6-ratemap. Extrapolation 90 Hz Foveal mapped directly to physical drawable pixels
kernel void extrap_90hz_foveal_ratemap(
    texture2d<float, access::sample> current_color [[texture(0)]],
    texture2d<float, access::sample> current_depth [[texture(1)]],
    texture2d<float, access::sample> history_color [[texture(2)]],
    texture2d<float, access::sample> history_depth [[texture(3)]],
    texture2d<float, access::write> out_display_color [[texture(4)]],
    texture2d<float, access::write> out_display_depth [[texture(5)]],
    texture2d<float, access::sample> obj_motion [[texture(6)]],
    constant NeuralExtrapParams& p [[buffer(0)]],
    constant rasterization_rate_map_data &rateMapData [[buffer(1)]],
    uint2 at [[thread_position_in_grid]])
{
    if (any(at >= p.physicalSize)) return;
    rasterization_rate_map_decoder decoder(rateMapData);
    float2 screenCoord = decoder.map_physical_to_screen_coordinates(float2(at) + 0.5f, p.rateMapLayer);
    float2 uv = screenCoord / float2(p.displaySize);
    float2 curvedUV = clamp(uv + p.quadraticCurvature * 0.5f, 0.0f, 1.0f);
    float2 dCur = current_depth.sample(depthSampler, curvedUV).rg;
    float estDepthZ = (dCur.y > 0.1f && dCur.x > 0.02f && dCur.x < 1000.0f) ? dCur.x : 2.0f;

    // True 6DoF translational parallax + rotation ray (w = 1.0)
    float3 dispRay = ray(uv, p.displayInverseProjection);
    float3 viewPtDisplay = dispRay * estDepthZ;
    float4 ptSource = p.sourceViewFromDisplayView * float4(viewPtDisplay, 1.0f);
    float4 clipSource = p.sourceProjection * ptSource;

    float2 srcUV = uv;
    bool validSrc = false;
    if (clipSource.w > 0.0f) {
        srcUV = clipSource.xy / clipSource.w * float2(0.5f, -0.5f) + 0.5f;
        validSrc = all(srcUV >= 0.0f) && all(srcUV <= 1.0f);
    }
    if (!validSrc) srcUV = curvedUV;

    if (p.objectMotionEnabled != 0u) {
        float2 motion = obj_motion.sample(linearSampler, srcUV).xy;
        srcUV = clamp(srcUV - motion * p.extrapFraction, 0.0f, 1.0f);
    }

    float2 d = (validSrc && any(srcUV != curvedUV)) ? current_depth.sample(depthSampler, srcUV).rg : dCur;
    float depthZ = d.x;
    float3 col = current_color.sample(linearSampler, srcUV).rgb;

    bool disoccluded = !validSrc || (depthZ <= 0.02f || depthZ > 1000.0f || d.y < 0.2f);
    bool fromHistory = false;
    if (disoccluded && p.historyValid) {
        // True 6DoF reprojection into history pose
        float4 ptHist = p.historyViewFromDisplayView * float4(viewPtDisplay, 1.0f);
        float4 clipHist = p.historyProjection * ptHist;
        if (clipHist.w > 0.0f) {
            float2 histUV = clipHist.xy / clipHist.w * float2(0.5f, -0.5f) + 0.5f;
            if (all(histUV >= 0.0f) && all(histUV <= 1.0f)) {
                float hd = history_depth.sample(depthSampler, histUV).r;
                if (hd > 0.02f && hd < 1000.0f) {
                    float4 ptHistRefined = p.historyViewFromDisplayView * float4(dispRay * hd, 1.0f);
                    float4 clipHistRefined = p.historyProjection * ptHistRefined;
                    if (clipHistRefined.w > 0.0f) {
                        float2 refinedUV = clipHistRefined.xy / clipHistRefined.w * float2(0.5f, -0.5f) + 0.5f;
                        if (all(refinedUV >= 0.0f) && all(refinedUV <= 1.0f)) {
                            histUV = refinedUV;
                            float hdRefined = history_depth.sample(depthSampler, histUV).r;
                            if (hdRefined > 0.02f && hdRefined < 1000.0f) {
                                hd = hdRefined;
                            }
                            col = history_color.sample(linearSampler, histUV).rgb;
                            depthZ = hd;
                            disoccluded = false;
                            fromHistory = true;
                        }
                    }
                }
            }
        }
    }

    float dispZ = 0.0f;
    if (!disoccluded && depthZ > 0.02f) {
        float4 pt = fromHistory
            ? float4(dispRay * depthZ, 1.0f)
            : (p.displayFromSource * float4(ray(srcUV, p.sourceInverseProjection) * depthZ, 1.0f));
        float4 c = p.displayProjection * pt;
        dispZ = c.w > 0.0f ? c.z / c.w : 0.0f;
        if (!(isfinite(dispZ) && dispZ > 0.0f && dispZ <= 1.0f)) dispZ = 0.0f;
    }

    out_display_color.write(float4(col, 1.0f), at);
    out_display_depth.write(float4(dispZ, 0.0f, 0.0f, 1.0f), at);
}

// 6b. Copy valid linear depth (.r metres where .g >= 0.1) into R32Float historyDepth
kernel void copy_history_depth(
    texture2d<float, access::sample> in_depth [[texture(0)]],
    texture2d<float, access::write> out_history_depth [[texture(1)]],
    constant uint2& size [[buffer(0)]],
    uint2 at [[thread_position_in_grid]])
{
    if (any(at >= size)) return;
    float2 uv = (float2(at) + 0.5f) / float2(size);
    float2 d = in_depth.sample(depthSampler, uv).rg;
    float z = (d.y >= 0.1f && isfinite(d.x) && d.x > 0.0f) ? d.x : 0.0f;
    out_history_depth.write(float4(z, 0.0f, 0.0f, 1.0f), at);
}

// 10. Auto-Reactive UI & Text Detection Kernel
kernel void auto_reactive_ui_mask(
    texture2d<float, access::sample> current_color [[texture(0)]],
    texture2d<float, access::sample> history_color [[texture(1)]],
    texture2d<float, access::write> out_ui_mask [[texture(2)]],
    constant uint2& size [[buffer(0)]],
    uint2 at [[thread_position_in_grid]])
{
    if (any(at >= size)) return;
    float2 uv = (float2(at) + 0.5f) / float2(size);
    float2 step = 1.0f / float2(max(1u, current_color.get_width()), max(1u, current_color.get_height()));
    float3 c = current_color.sample(linearSampler, uv).rgb;
    float3 h = history_color.sample(linearSampler, uv).rgb;

    float lum_c = rec709_luminance(c);
    float lum_e = rec709_luminance(current_color.sample(linearSampler, uv + float2(step.x, 0.0f)).rgb);
    float lum_w = rec709_luminance(current_color.sample(linearSampler, uv - float2(step.x, 0.0f)).rgb);
    float lum_s = rec709_luminance(current_color.sample(linearSampler, uv + float2(0.0f, step.y)).rgb);
    float lum_n = rec709_luminance(current_color.sample(linearSampler, uv - float2(0.0f, step.y)).rgb);

    float gx = lum_e - lum_w;
    float gy = lum_s - lum_n;
    float edge = sqrt(gx * gx + gy * gy + 1e-6f);

    float edge_score = clamp((edge - 0.08f) / 0.12f, 0.0f, 1.0f);
    float diff_score = clamp(max(abs(c.r - h.r), max(abs(c.g - h.g), abs(c.b - h.b))) * 2.0f, 0.0f, 1.0f);

    float ui_mask = clamp(edge_score * max(diff_score, 0.6f) * 1.5f, 0.0f, 1.0f);
    out_ui_mask.write(float4(ui_mask, 0.0f, 0.0f, 1.0f), at);
}

// 11. Robust Contrast-Adaptive Sharpening (RCAS) for Text & UI
kernel void rcas_sharpen_ui(
    texture2d<float, access::read> in_color [[texture(0)]],
    texture2d<float, access::write> out_color [[texture(1)]],
    texture2d<float, access::sample> current_color [[texture(2)]],
    texture2d<float, access::sample> history_color [[texture(3)]],
    constant uint2& size [[buffer(0)]],
    uint2 at [[thread_position_in_grid]])
{
    if (any(at >= size)) return;
    int2 iat = int2(at);
    float3 c = in_color.read(at).rgb;
    float2 uv = (float2(at) + 0.5f) / float2(size);
    float2 step = 1.0f / float2(max(1u, current_color.get_width()), max(1u, current_color.get_height()));

    float lum_e = rec709_luminance(current_color.sample(linearSampler, uv + float2(step.x, 0.0f)).rgb);
    float lum_w = rec709_luminance(current_color.sample(linearSampler, uv - float2(step.x, 0.0f)).rgb);
    float lum_s = rec709_luminance(current_color.sample(linearSampler, uv + float2(0.0f, step.y)).rgb);
    float lum_n = rec709_luminance(current_color.sample(linearSampler, uv - float2(0.0f, step.y)).rgb);
    float gx = lum_e - lum_w;
    float gy = lum_s - lum_n;
    float edge = sqrt(gx * gx + gy * gy + 1e-6f);
    float edge_score = clamp((edge - 0.08f) / 0.12f, 0.0f, 1.0f);
    if (edge_score <= 0.0f) {
        out_color.write(float4(c, 1.0f), at);
        return;
    }

    float3 cur = current_color.sample(linearSampler, uv).rgb;
    float3 h = history_color.sample(linearSampler, uv).rgb;
    float diff_score = clamp(max(abs(cur.r - h.r), max(abs(cur.g - h.g), abs(cur.b - h.b))) * 2.0f, 0.0f, 1.0f);
    float ui = clamp(edge_score * max(diff_score, 0.6f) * 1.5f, 0.0f, 1.0f);

    if (ui < 0.01f) {
        out_color.write(float4(c, 1.0f), at);
        return;
    }

    float3 n = in_color.read(uint2(uint(iat.x), uint(max(iat.y - 1, 0)))).rgb;
    float3 s = in_color.read(uint2(uint(iat.x), uint(min(iat.y + 1, int(size.y) - 1)))).rgb;
    float3 w = in_color.read(uint2(uint(max(iat.x - 1, 0)), uint(iat.y))).rgb;
    float3 e = in_color.read(uint2(uint(min(iat.x + 1, int(size.x) - 1)), uint(iat.y))).rgb;

    float lc = 0.2126f * c.r + 0.7152f * c.g + 0.0722f * c.b;
    float ln = 0.2126f * n.r + 0.7152f * n.g + 0.0722f * n.b;
    float ls = 0.2126f * s.r + 0.7152f * s.g + 0.0722f * s.b;
    float lw = 0.2126f * w.r + 0.7152f * w.g + 0.0722f * w.b;
    float le = 0.2126f * e.r + 0.7152f * e.g + 0.0722f * e.b;

    float mn = min(min(min(ln, ls), min(lw, le)), lc);
    float mx = max(max(max(ln, ls), max(lw, le)), lc);

    float amp = min(mn, 1.0f - mx) / max(mx, 1e-4f);
    float w_sharp = -0.30f * amp * ui;

    float3 surround = n + s + w + e;
    float3 sharp = clamp((c + w_sharp * surround) / (1.0f + 4.0f * w_sharp), 0.0f, 1.0f);

    out_color.write(float4(sharp, 1.0f), at);
}

// 8. Gaussian Splatting Kernels (Apple Silicon M2 16x16 Tile Rasterizer)
struct WVRGaussianPrimitiveMSL {
    float2 xy;
    packed_float3 cov; // xx, xy, yy
    packed_float3 rgb;
    float opacity;
    float depth;
    packed_float3 sh1_y;
    packed_float3 sh1_z;
    packed_float3 sh1_x;
    float reserved;
};

struct GaussianTileParams {
    uint width;
    uint height;
    uint numSplats;
    uint pad0;
};

kernel void gaussian_splat_composite(
    texture2d<float, access::read_write> out_canvas [[texture(0)]],
    device const WVRGaussianPrimitiveMSL* splats [[buffer(0)]],
    constant GaussianTileParams& p [[buffer(1)]],
    uint2 at [[thread_position_in_grid]],
    uint2 tgid [[threadgroup_position_in_grid]],
    uint2 tid [[thread_position_in_threadgroup]])
{
    const bool active = (at.x < p.width && at.y < p.height);
    float4 current = active ? out_canvas.read(at) : float4(0.0f);
    float3 accum_col = current.rgb;
    float accum_trans = 1.0f - current.a;
    float2 px = float2(at) + 0.5f;
    float3 viewDir = active
        ? normalize(float3((px.x - float(p.width) * 0.5f) / float(p.width),
                           (px.y - float(p.height) * 0.5f) / float(p.height),
                           1.0f))
        : float3(0.0f, 0.0f, 1.0f);

    uint linearTid = tid.y * 16u + tid.x;
    float2 tileMin = float2(float(tgid.x * 16u) + 0.5f, float(tgid.y * 16u) + 0.5f);
    float2 tileMax = float2(float(tgid.x * 16u + 15u) + 0.5f, float(tgid.y * 16u + 15u) + 0.5f);

    threadgroup float4 tileXYR[256];
    threadgroup float3 tileConic[256];
    threadgroup uchar tileValid[256];
    threadgroup ushort tileList[256];
    threadgroup uint tileCount;

    for (uint base = 0; base < p.numSplats; base += 256u) {
        uint idx = base + linearTid;
        uchar valid = 0u;
        if (idx < p.numSplats) {
            WVRGaussianPrimitiveMSL g = splats[idx];
            float radius = 3.0f * max(sqrt(max(g.cov.x, 0.1f)), sqrt(max(g.cov.z, 0.1f)));
            if (g.xy.x + radius >= tileMin.x && g.xy.x - radius <= tileMax.x &&
                g.xy.y + radius >= tileMin.y && g.xy.y - radius <= tileMax.y) {
                float det = g.cov.x * g.cov.z - g.cov.y * g.cov.y;
                if (det >= 1e-6f) {
                    float inv_det = 1.0f / det;
                    tileXYR[linearTid] = float4(g.xy, radius, g.opacity);
                    tileConic[linearTid] = float3(g.cov.z * inv_det, -g.cov.y * inv_det, g.cov.x * inv_det);
                    valid = 1u;
                }
            }
        }
        tileValid[linearTid] = valid;
        threadgroup_barrier(mem_flags::mem_threadgroup);

        if (linearTid == 0u) {
            uint batchCount = min(256u, p.numSplats - base);
            uint cnt = 0u;
            for (uint j = 0; j < batchCount; ++j) {
                if (tileValid[j]) tileList[cnt++] = ushort(j);
            }
            tileCount = cnt;
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);

        if (active && accum_trans >= 0.01f) {
            uint cnt = tileCount;
            for (uint k = 0; k < cnt; ++k) {
                uint j = uint(tileList[k]);
                float4 xyr = tileXYR[j];
                float2 d = px - xyr.xy;
                if (abs(d.x) > xyr.z || abs(d.y) > xyr.z) continue;
                float3 conic = tileConic[j];
                float q = conic.x * d.x * d.x + 2.0f * conic.y * d.x * d.y + conic.z * d.y * d.y;
                if (q <= 9.0f && q >= 0.0f) {
                    float alpha = xyr.w * exp(-0.5f * q);
                    if (alpha > 0.002f) {
                        WVRGaussianPrimitiveMSL g = splats[base + j];
                        float blend_alpha = alpha * accum_trans;
                        float3 shCol = float3(g.rgb) + 0.488603f * (float3(g.sh1_y) * viewDir.y + float3(g.sh1_z) * viewDir.z + float3(g.sh1_x) * viewDir.x);
                        accum_col += max(float3(0.0f), shCol) * blend_alpha;
                        accum_trans *= (1.0f - alpha);
                        if (accum_trans < 0.01f) break;
                    }
                }
            }
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);
    }

    if (active) {
        out_canvas.write(float4(accum_col, 1.0f - accum_trans), at);
    }
}
)metal";

// Host mirrors of the kernel parameter structs above (simd types match MSL layout).
struct NeuralStereoWarpParams {
  simd_float4x4 eyeAClipFromEyeBView;
  simd_float4x4 eyeBInverseProjection;
  simd_uint2 size;
};
struct NeuralTemporalWarpParams {
  simd_float4x4 historyClipFromCurrent;
  simd_float4x4 currentInverseProjection;
  simd_float2 gazeCenterUV;
  float gazeRadiusUV;
  float pad0;
  simd_uint2 size;
  uint32_t historyValid;
};
struct NeuralGatherParams {
  simd_float2 gazeCenterUV;
  float gazeRadiusUV;
  float pad0;
  simd_float2 cropSizeUV;
  simd_float2 jitterUV;
  simd_float2 jitterNDC;
  simd_uint2 cropLrSize;
  simd_uint2 cropHrSize;
  uint32_t eyeRole;
  uint32_t historyValid;
  uint32_t stereoValid;
  uint32_t pad1;
};
struct NeuralBlendParams {
  simd_float4x4 historyClipFromCurrent;
  simd_float4x4 currentInverseProjection;
  simd_float2 gazeCenterUV;
  float gazeRadiusUV;
  float pad0;
  simd_float2 jitterUV;
  simd_uint2 fullSize;
  uint32_t eyeRole;
  uint32_t historyValid;
  uint32_t stereoValid;
  uint32_t fuseAfwAndAnalytical;
};
struct NeuralObjectMotionParams {
  simd_float4x4 historyClipFromCurrent;
  simd_float4x4 currentInverseProjection;
  simd_uint2 fullSize;
  simd_uint2 tileCount;
  uint32_t historyValid;
  uint32_t pad0;
  uint32_t pad1;
  uint32_t pad2;
};
struct NeuralExtrapParams {
  simd_float4x4 displayInverseProjection;
  simd_float4x4 sourceViewFromDisplayView;
  simd_float4x4 sourceProjection;
  simd_float4x4 sourceInverseProjection;
  simd_float4x4 displayProjection;
  simd_float4x4 displayFromSource;
  simd_float4x4 historyProjection;
  simd_float4x4 historyViewFromDisplayView;
  simd_uint2 displaySize;
  uint32_t historyValid;
  float pad0;
  simd_float2 quadraticCurvature;
  uint32_t objectMotionEnabled;
  float extrapFraction;
  simd_uint2 physicalSize;
  uint32_t rateMapLayer;
  uint32_t pad1;
};
struct NeuralConvParams {
  simd_uint2 inSize;
  simd_uint2 outSize;
  uint32_t inCh;
  uint32_t outCh;
  uint32_t stride;
  uint32_t inputRelu;
  uint32_t applyRelu;
  uint32_t addResidual;
  uint32_t weightOffset;
  uint32_t biasOffset;
};
struct GaussianTileParams {
  uint32_t width;
  uint32_t height;
  uint32_t numSplats;
  uint32_t pad0;
};


simd_float4x4 mat(const float *m) {
  simd_float4x4 r;
  memcpy(&r, m, sizeof(r));
  return r;
}

id<MTLTexture> make_tex(id<MTLDevice> d, MTLPixelFormat f, unsigned w, unsigned h,
                        MTLTextureUsage use = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite) {
  auto desc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:f width:w height:h mipmapped:NO];
  desc.storageMode = MTLStorageModePrivate;
  desc.usage = use;
  return [d newTextureWithDescriptor:desc];
}

// VeRantyx-inspired zero-copy IOSurface texture allocator for Apple Silicon UMA
// Enables shared memory access between Metal compute, ANE CoreML, and video encoders
id<MTLTexture> make_iosurface_tex(id<MTLDevice> d, MTLPixelFormat f, unsigned w, unsigned h) {
#if TARGET_OS_VISION || TARGET_OS_OSX
  NSDictionary *props = @{
    (__bridge id)kIOSurfaceWidth: @(w),
    (__bridge id)kIOSurfaceHeight: @(h),
    (__bridge id)kIOSurfaceBytesPerElement: @(8),
    (__bridge id)kIOSurfacePixelFormat: @(0x32434152), // '2CAR' = 64RGBAHalf
  };
  IOSurfaceRef surface = IOSurfaceCreate((__bridge CFDictionaryRef)props);
  if (surface) {
    auto desc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:f width:w height:h mipmapped:NO];
    desc.storageMode = MTLStorageModeShared;
    desc.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
    id<MTLTexture> tex = [d newTextureWithDescriptor:desc iosurface:surface plane:0];
    CFRelease(surface);
    if (tex) return tex;
  }
#endif
  return make_tex(d, f, w, h);
}

bool ensure_tex(id<MTLDevice> d, id<MTLTexture> __strong &t, MTLPixelFormat f, unsigned w, unsigned h, bool useIOSurface = false) {
  if (!t || t.width != w || t.height != h || t.pixelFormat != f)
    t = useIOSurface ? make_iosurface_tex(d, f, w, h) : make_tex(d, f, w, h);
  if (!t || t.width != w || t.height != h || t.pixelFormat != f)
    t = make_tex(d, f, w, h);
  return t != nil;
}

static bool fsr3UpscaleEnabled() {
  static const bool on = [] {
    const char *v = getenv("WVR_FSR3_UPSCALE");
    const bool enabled = v && strcmp(v, "1") == 0;
    NSLog(@"[neural] FSR 3.1 upscale %s", enabled ? "enabled" : "disabled");
    return enabled;
  }();
  return on;
}

static bool metalFXUpscaleEnabled() {
  static const bool on = [] {
    const char *v = getenv("WVR_METALFX_UPSCALE");
    const bool enabled = v && strcmp(v, "1") == 0;
    NSLog(@"[neural] MetalFX upscale %s", enabled ? "enabled" : "disabled");
    return enabled;
  }();
  return on;
}

static float fsr3Sharpness() {
  static const float s = [] {
    const char *v = getenv("WVR_FSR3_SHARPNESS");
    float val = 0.3f;
    if (v && strlen(v) > 0) {
      char *end = nullptr;
      float parsed = std::strtof(v, &end);
      if (end != v && std::isfinite(parsed)) val = parsed;
    }
    return val;
  }();
  return s;
}

static bool objectMotionEnabled() {
  static const bool on = [] {
    const char *v = getenv("WVR_NEURAL_OBJECT_MOTION");
    const bool enabled = v && strcmp(v, "1") == 0;
    NSLog(@"[neural] object motion estimation %s", enabled ? "enabled" : "disabled");
    return enabled;
  }();
  return on;
}

static bool neuralRatemapExtrapEnabled() {
  static const bool enabled = [] {
    const char *v = getenv("WVR_NEURAL_RATEMAP_EXTRAP");
    const bool on = (v && strcmp(v, "1") == 0);
    NSLog(@"[WindowsVRNeural] Rate-map physical resolution extrapolation (WVR_NEURAL_RATEMAP_EXTRAP) is %s", on ? "ENABLED" : "DISABLED");
    return on;
  }();
  return enabled;
}

enum WVRNeuralStageIndex : uint32_t {
  STAGE_YORO_WARP = 0,
  STAGE_OBJECT_MOTION,
  STAGE_AFW_FOVEAL,
  STAGE_SPLICE,
  STAGE_RCAS_UI,
  STAGE_EXTRAP,
  STAGE_HISTORY_COPY,
  STAGE_END,
  STAGE_COUNT = STAGE_END
};

static constexpr uint32_t kTimingSampleCount = STAGE_END + 1; // 8 sample points

static const int sNeuralGpuTimingMode = [] {
  const char *v = getenv("WVR_NEURAL_GPU_TIMING");
  if (!v) return 0;
  if (strcmp(v, "1") == 0) {
    NSLog(@"[WindowsVRNeural] Per-stage GPU timing enabled (WVR_NEURAL_GPU_TIMING=1)");
    return 1;
  }
  if (strcmp(v, "2") == 0) {
    NSLog(@"[WindowsVRNeural] Per-stage GPU timing enabled (WVR_NEURAL_GPU_TIMING=2, stage-boundary mode)");
    return 2;
  }
  return 0;
}();
static const bool sNeuralGpuTimingEnabled = (sNeuralGpuTimingMode != 0);

// WVR_NEURAL_DUMP_FRAME=N dumps the N-th VRFovealNet reconstruction (input tensor, conv output, resolved
// fovea, metadata) once into Documents/WindowsVRDiagnostics/ for an offline PyTorch comparison.
static const uint64_t sNeuralDumpFrame = [] {
  const char *v = getenv("WVR_NEURAL_DUMP_FRAME");
  const uint64_t n = v ? strtoull(v, nullptr, 10) : 0;
  if (n) NSLog(@"[WindowsVRNeural] Neural tensor dump armed for reconstruction #%llu (WVR_NEURAL_DUMP_FRAME)", (unsigned long long)n);
  return n;
}();

// Path summary every N encode calls (WVR_NEURAL_PATH_LOG_EVERY, default 900 = ~10 s at 90 Hz, 0 = off).
static const uint64_t sNeuralPathLogEvery = [] {
  const char *v = getenv("WVR_NEURAL_PATH_LOG_EVERY");
  return v ? strtoull(v, nullptr, 10) : 900ull;
}();

struct WVRNeuralGpuTimingState {
  std::atomic<float> stageEmaUs[STAGE_COUNT]{};
  std::atomic<float> totalGpuUs{0.0f};
};

} // namespace

struct WVRNeuralContext {
  __strong id<MTLDevice> device;
  __strong id<MTLComputePipelineState> pYoroStereoWarp = nil;
  __strong id<MTLComputePipelineState> pAfwTemporalWarp = nil;
  __strong id<MTLComputePipelineState> pFovealGather = nil;
  __strong id<MTLComputePipelineState> pConv3x3 = nil;
  __strong id<MTLComputePipelineState> pConv3x3Tiled = nil;
  __strong id<MTLComputePipelineState> pConv3x3TiledS2 = nil;
  __strong id<MTLComputePipelineState> pPixelShuffleSkip = nil;
  __strong id<MTLComputePipelineState> pFovealOutResolve = nil;
  __strong id<MTLComputePipelineState> pAnalyticalBlend = nil;
  __strong id<MTLComputePipelineState> pFovealBlendSplice = nil;
  __strong id<MTLComputePipelineState> pExtrap90Hz = nil;
  __strong id<MTLComputePipelineState> pExtrap90HzRatemap = nil;
  __strong id<MTLBuffer> rateMapParamsRing[3][2]{};
  uint32_t rateMapRingIndex = 0;
  __strong id<MTLComputePipelineState> pObjectMotionEstimate = nil;
  __strong id<MTLComputePipelineState> pAutoReactiveUIMask = nil;
  __strong id<MTLComputePipelineState> pRCASSharpenUI = nil;
  __strong id<MTLComputePipelineState> pCopyHistoryDepth = nil;
  __strong id<MTLTexture> uiScratch[2]{};

  // In-App Gaussian Splatting
  __strong id<MTLComputePipelineState> pGaussianSplatComposite = nil;
  __strong id<MTLBuffer> splatsBuffer = nil;
  uint32_t splatsCount = 0;

  // Apple Neural Engine (ANE) Core ML Model
  bool aneLoaded = false;
  void *coreMLModel = nullptr;

  __strong id<MTLBuffer> weightsBuffer = nil;
  WVRNeuralWeightsHeaderV1 weightsHeader{};
  WVRNeuralTensorDescV1 tensorTable[48]{};
  bool weightsLoaded = false;

  // Diagnostics: which weights are live and why each eye pass took the path it did
  char weightsPath[512]{};
  uint64_t weightsHash = 0; // FNV-1a 64 over the whole .wvnw file
  bool startupSummaryLogged = false;
  std::atomic<uint64_t> encodeCalls{0};
  std::atomic<uint64_t> passNeural{0};              // eye passes through VRFovealNet
  std::atomic<uint64_t> passAnalyticalNoFlag{0};    // weights loaded, WVR_FORCE_NEURAL_RECONSTRUCTION unset
  std::atomic<uint64_t> passAnalyticalNoWeights{0}; // no usable .wvnw
  std::atomic<uint64_t> passNoHistory{0};           // no warped history candidate this pass
  std::atomic<uint64_t> passNoStereo{0};            // eye B pass without the YORO stereo candidate
  std::atomic<uint64_t> framesNoDepth{0};           // game frame arrived without depth
  std::atomic<uint64_t> framesUpscaler{0};          // MetalFX / FSR 3.1 replaced the reconstruction
  uint64_t neuralReconstructions = 0;
  bool neuralDumpDone = false;

  // Full-eye reconstructed intermediate texture (avoids in-place read/write hazard in extrap_90hz_foveal)
  __strong id<MTLTexture> reconstructed[2]{};

  // Working textures
  __strong id<MTLTexture> warpedStereo[2]{}, stereoValidity[2]{};
  __strong id<MTLTexture> warpedHist[2]{}, histValidity[2]{};
  __strong id<MTLTexture> foveaHR[2]{};
  __strong id<MTLBuffer> foveaTensor[2]{};

  // Neural feature map scratch buffers
  __strong id<MTLBuffer> f1Buffer[2]{}, f2Buffer[2]{}, fLowBuffer[2]{}, fOutBuffer[2]{};

  // Display history for 90Hz extrapolation
  __strong id<MTLTexture> historyColor[2]{}, historyDepth[2]{};
  __strong id<MTLTexture> objMotion[2]{};
  __strong id<MTLTexture> dummyDepth = nil;
  simd_float4x4 historyOrigin[2]{}, historyProjection[2]{};
  bool historyValid = false;
  float lastGazeRadiusUV[2]{0.10f, 0.10f};
  uint32_t lastCropHR[2]{256, 256};

  std::mutex mutex;
  std::atomic<uint64_t> fovealJobs{0};
  std::atomic<uint64_t> stereoWarpJobs{0};
  std::atomic<uint64_t> temporalWarpJobs{0};
  std::atomic<uint64_t> extrapJobs{0};
  std::atomic<uint64_t> extrapRateMapJobs{0};
  std::atomic<uint64_t> objectMotionJobs{0};
  // Display-rate calls repeat the same game frame; reconstruction only runs once per frame ID.
  uint64_t lastReconFrameID = UINT64_MAX;
  std::atomic<uint64_t> reconReuses{0};
  std::atomic<uint64_t> tiledConvJobs{0};
  std::atomic<uint64_t> naiveConvJobs{0};
  bool convModeInitialized = false;
  bool useNaiveConv = false;

  // MetalFX temporal upscaler (Mode 4 optional replacement)
  void *metalfx[2]{nullptr, nullptr};
  simd_float4x4 metalfxPrevOrigin[2]{};
  simd_float4x4 metalfxPrevProj[2]{};
  bool metalfxPrevValid[2]{false, false};
  std::atomic<uint64_t> metalfxJobs{0};
  bool metalfxFailed{false};

  // FSR 3.1 Metal upscaler (Mode 4 optional replacement)
  void *fsr[2]{nullptr, nullptr};
  simd_float4x4 fsrPrevOrigin[2]{};
  simd_float4x4 fsrPrevProj[2]{};
  bool fsrPrevValid[2]{false, false};
  std::atomic<uint64_t> fsrJobs{0};
  uint64_t lastTimestampNs{0};
  uint64_t prevSourceTimestampNs{0};
  uint64_t lastGameFrameIntervalNs{0};
  bool fsrFailed{false};

  // Per-stage GPU timing (WVR_NEURAL_GPU_TIMING=1)
  __strong id<MTLCounterSampleBuffer> timingSampleBuffers[3]{nil, nil, nil};
  uint32_t timingBufferIndex = 0;
  bool timingCounterSamplingSupported = false;
  // Shared with command-buffer completion handlers so a destroy before GPU completion stays safe.
  std::shared_ptr<WVRNeuralGpuTimingState> timing = std::make_shared<WVRNeuralGpuTimingState>();

  WVRNeuralContext(id<MTLDevice> d) : device(d) {}
  ~WVRNeuralContext() {
    for (int i = 0; i < 2; ++i) {
      if (metalfx[i]) {
        wvr_metalfx_destroy_v1(metalfx[i]);
        metalfx[i] = nullptr;
      }
    }
    for (int i = 0; i < 2; ++i) {
      if (fsr[i]) {
        wvr_fsr3_destroy_v1(fsr[i]);
        fsr[i] = nullptr;
      }
    }
#if __has_include(<CoreML/CoreML.h>)
    if (coreMLModel) {
      CFRelease(coreMLModel);
      coreMLModel = nullptr;
    }
#endif
  }
};

static bool load_weights(id<MTLDevice> device, WVRNeuralContext *ctx) {
  const char *envPath = getenv("WVR_NEURAL_WEIGHTS_PATH");
  NSString *path = envPath ? [NSString stringWithUTF8String:envPath] : nil;
  if (!path || ![[NSFileManager defaultManager] fileExistsAtPath:path]) {
    path = [[NSBundle mainBundle] pathForResource:@"vr_foveal_student_fp16" ofType:@"wvnw"];
  }
  if (!path || ![[NSFileManager defaultManager] fileExistsAtPath:path]) {
    // Resources/WindowsVR is a folder reference in project.yml, so it is copied to <bundle>/WindowsVR/
    path = [[NSBundle mainBundle] pathForResource:@"vr_foveal_student_fp16" ofType:@"wvnw" inDirectory:@"WindowsVR"];
  }
  if (!path || ![[NSFileManager defaultManager] fileExistsAtPath:path]) {
    NSString *bundlePath = [[NSBundle mainBundle] bundlePath];
    path = [bundlePath stringByAppendingPathComponent:@"Contents/Resources/vr_foveal_student_fp16.wvnw"];
  }
  if (!path || ![[NSFileManager defaultManager] fileExistsAtPath:path]) {
    NSString *bundlePath = [[NSBundle mainBundle] bundlePath];
    path = [bundlePath stringByAppendingPathComponent:@"Resources/vr_foveal_student_fp16.wvnw"];
  }
  if (!path || ![[NSFileManager defaultManager] fileExistsAtPath:path]) {
    NSString *bundlePath = [[NSBundle mainBundle] bundlePath];
    path = [bundlePath stringByAppendingPathComponent:@"Resources/WindowsVR/vr_foveal_student_fp16.wvnw"];
  }
  if (!path || ![[NSFileManager defaultManager] fileExistsAtPath:path]) {
    path = @"visionos-windows-vr/Resources/WindowsVR/vr_foveal_student_fp16.wvnw";
  }
  if (!path || ![[NSFileManager defaultManager] fileExistsAtPath:path]) {
    path = @"visionos-windows-vr/Resources/vr_foveal_student_fp16.wvnw";
  }
  if (!path || ![[NSFileManager defaultManager] fileExistsAtPath:path]) {
    path = @"Resources/WindowsVR/vr_foveal_student_fp16.wvnw";
  }
  if (!path || ![[NSFileManager defaultManager] fileExistsAtPath:path]) {
    path = @"Resources/vr_foveal_student_fp16.wvnw";
  }
  if (!path || ![[NSFileManager defaultManager] fileExistsAtPath:path]) {
    NSLog(@"[WindowsVRNeural] Student weights vr_foveal_student_fp16.wvnw not found (bundle %@); using analytical fallback",
          [[NSBundle mainBundle] bundlePath]);
    return false;
  }

  NSData *data = [NSData dataWithContentsOfFile:path options:NSDataReadingMappedIfSafe error:nil];
  if (!data || data.length < sizeof(WVRNeuralWeightsHeaderV1)) {
    NSLog(@"[WindowsVRNeural] Student weights %@ unreadable or truncated (%lu bytes)", path, (unsigned long)data.length);
    return false;
  }

  const auto *hdr = (const WVRNeuralWeightsHeaderV1 *)data.bytes;
  if (hdr->magic != WVR_NEURAL_WEIGHTS_MAGIC || hdr->version != 1) {
    NSLog(@"[WindowsVRNeural] Student weights %@ bad header (magic=0x%08x version=%u)", path, hdr->magic, hdr->version);
    return false;
  }

  ctx->weightsHeader = *hdr;
  uint32_t numTensors = hdr->num_tensors;
  if (numTensors > 48) numTensors = 48;
  size_t tableSize = numTensors * sizeof(WVRNeuralTensorDescV1);
  if (data.length < sizeof(WVRNeuralWeightsHeaderV1) + tableSize) {
    return false;
  }

  memcpy(ctx->tensorTable, (const uint8_t *)data.bytes + sizeof(WVRNeuralWeightsHeaderV1), tableSize);
  for (uint32_t t = 0; t < numTensors; ++t) {
    uint64_t endElem = uint64_t(ctx->tensorTable[t].offset_elements) + uint64_t(ctx->tensorTable[t].num_elements);
    if (endElem > uint64_t(hdr->total_fp16_elements)) {
      memset(ctx->tensorTable, 0, sizeof(ctx->tensorTable));
      return false;
    }
  }

  const uint8_t *payloadPtr = (const uint8_t *)data.bytes + sizeof(WVRNeuralWeightsHeaderV1) + tableSize;
  size_t payloadBytes = hdr->total_fp16_elements * sizeof(uint16_t);
  if (data.length < sizeof(WVRNeuralWeightsHeaderV1) + tableSize + payloadBytes) {
    return false;
  }

  ctx->weightsBuffer = [device newBufferWithBytes:payloadPtr length:payloadBytes options:MTLResourceStorageModeShared];
  ctx->weightsLoaded = (ctx->weightsBuffer != nil);
  uint64_t fnv = 1469598103934665603ull;
  const uint8_t *fileBytes = (const uint8_t *)data.bytes;
  for (NSUInteger i = 0; i < data.length; ++i) {
    fnv ^= fileBytes[i];
    fnv *= 1099511628211ull;
  }
  ctx->weightsHash = fnv;
  snprintf(ctx->weightsPath, sizeof(ctx->weightsPath), "%s", path.UTF8String ?: "");
  NSLog(@"[WindowsVRNeural] Student weights %@ from %@: scale=%u foveal=%u/%u x%u extrap=%u x%u tensors=%u fp16=%u bytes=%lu fnv64=%016llx",
        ctx->weightsLoaded ? @"loaded" : @"FAILED (buffer alloc)", path, hdr->scale, hdr->foveal_ch, hdr->foveal_ch_low,
        hdr->foveal_blocks, hdr->extrap_ch, hdr->extrap_blocks, hdr->num_tensors, hdr->total_fp16_elements,
        (unsigned long)data.length, (unsigned long long)fnv);
  return ctx->weightsLoaded;
}

extern "C" WVRNeuralContext *wvr_neural_create_v1(void *metalDevice) {
  @autoreleasepool {
    if (!metalDevice) return nullptr;
    id<MTLDevice> dev = (__bridge id<MTLDevice>)metalDevice;
    auto ctx = new WVRNeuralContext(dev);

    NSError *error = nil;
    id<MTLLibrary> lib = [dev newLibraryWithSource:kNeuralSource options:nil error:&error];
    if (!lib) {
      NSLog(@"[WindowsVRNeural] Failed to compile MSL: %@", error);
      delete ctx;
      return nullptr;
    }

    auto loadPipeline = [&](id<MTLComputePipelineState> __strong &pipe, const char *name) -> bool {
      id<MTLFunction> fn = [lib newFunctionWithName:[NSString stringWithUTF8String:name]];
      if (!fn) return false;
      pipe = [dev newComputePipelineStateWithFunction:fn error:nil];
      return pipe != nil;
    };

    if (!loadPipeline(ctx->pYoroStereoWarp, "yoro_stereo_warp") ||
        !loadPipeline(ctx->pAfwTemporalWarp, "afw_temporal_warp") ||
        !loadPipeline(ctx->pFovealGather, "foveal_gather_inputs") ||
        !loadPipeline(ctx->pConv3x3, "conv3x3_fp16") ||
        !loadPipeline(ctx->pPixelShuffleSkip, "pixel_shuffle_2x_skip_fp16") ||
        !loadPipeline(ctx->pFovealOutResolve, "foveal_out_resolve_fp16") ||
        !loadPipeline(ctx->pAnalyticalBlend, "analytical_foveal_blend") ||
        !loadPipeline(ctx->pFovealBlendSplice, "foveal_blend_and_splice") ||
        !loadPipeline(ctx->pExtrap90Hz, "extrap_90hz_foveal") ||
        !loadPipeline(ctx->pRCASSharpenUI, "rcas_sharpen_ui") ||
        !loadPipeline(ctx->pCopyHistoryDepth, "copy_history_depth")) {
      delete ctx;
      return nullptr;
    }

    if (!loadPipeline(ctx->pExtrap90HzRatemap, "extrap_90hz_foveal_ratemap")) {
      NSLog(@"[WindowsVRNeural] extrap_90hz_foveal_ratemap pipeline unavailable");
    }

    loadPipeline(ctx->pAutoReactiveUIMask, "auto_reactive_ui_mask");

    if (!loadPipeline(ctx->pConv3x3Tiled, "conv3x3_fp16_tiled") ||
        !loadPipeline(ctx->pConv3x3TiledS2, "conv3x3_fp16_tiled_s2")) {
      NSLog(@"[WindowsVRNeural] Failed to create conv3x3_fp16_tiled pipeline; falling back to naive conv3x3_fp16");
    }

    // Gaussian splat pipeline
    loadPipeline(ctx->pGaussianSplatComposite, "gaussian_splat_composite");

    if (!loadPipeline(ctx->pObjectMotionEstimate, "object_motion_estimate")) {
      NSLog(@"[WindowsVRNeural] Failed to load object_motion_estimate pipeline; object motion disabled");
    }

    MTLTextureDescriptor *dummyDesc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRG32Float
                                                                                         width:1
                                                                                        height:1
                                                                                     mipmapped:NO];
    dummyDesc.storageMode = MTLStorageModeShared;
    dummyDesc.usage = MTLTextureUsageShaderRead;
    ctx->dummyDepth = [dev newTextureWithDescriptor:dummyDesc];
    if (!ctx->dummyDepth) {
      delete ctx;
      return nullptr;
    }
    const float zeroDepth[2] = {0.0f, 0.0f};
    [ctx->dummyDepth replaceRegion:MTLRegionMake2D(0, 0, 1, 1)
                       mipmapLevel:0
                         withBytes:zeroDepth
                       bytesPerRow:sizeof(zeroDepth)];

    load_weights(dev, ctx);

    if (sNeuralGpuTimingEnabled) {
      id<MTLCounterSet> timestampCounterSet = nil;
      for (id<MTLCounterSet> cs in dev.counterSets) {
        if ([cs.name isEqualToString:MTLCommonCounterSetTimestamp]) {
          timestampCounterSet = cs;
          break;
        }
      }

      const bool stageBoundarySupported = [dev respondsToSelector:@selector(supportsCounterSampling:)] &&
                                          [dev supportsCounterSampling:MTLCounterSamplingPointAtStageBoundary];
      const bool dispatchBoundarySupported = [dev respondsToSelector:@selector(supportsCounterSampling:)] &&
                                             [dev supportsCounterSampling:MTLCounterSamplingPointAtDispatchBoundary];

      if (sNeuralGpuTimingMode == 2 && timestampCounterSet && stageBoundarySupported) {
        MTLCounterSampleBufferDescriptor *desc = [[MTLCounterSampleBufferDescriptor alloc] init];
        desc.counterSet = timestampCounterSet;
        desc.label = @"WVRNeuralTimingSamplesRing";
        desc.storageMode = MTLStorageModeShared;
        desc.sampleCount = 2 * STAGE_COUNT;

        bool allocOk = true;
        for (int i = 0; i < 3; ++i) {
          NSError *err = nil;
          ctx->timingSampleBuffers[i] = [dev newCounterSampleBufferWithDescriptor:desc error:&err];
          if (!ctx->timingSampleBuffers[i] || err) {
            NSLog(@"[WindowsVRNeural] Failed to allocate counter sample buffer [%d]: %@", i, err);
            allocOk = false;
            break;
          }
        }
        ctx->timingCounterSamplingSupported = allocOk;
        if (allocOk) {
          NSLog(@"[WindowsVRNeural] GPU per-stage counter sampling active (stage-boundary mode, AtStageBoundary=YES, ring=3, samples=%u)", 2 * STAGE_COUNT);
        }
      } else if (sNeuralGpuTimingMode == 1 && timestampCounterSet && dispatchBoundarySupported && !stageBoundarySupported) {
        MTLCounterSampleBufferDescriptor *desc = [[MTLCounterSampleBufferDescriptor alloc] init];
        desc.counterSet = timestampCounterSet;
        desc.label = @"WVRNeuralTimingSamplesRing";
        desc.storageMode = MTLStorageModeShared;
        desc.sampleCount = kTimingSampleCount;

        bool allocOk = true;
        for (int i = 0; i < 3; ++i) {
          NSError *err = nil;
          ctx->timingSampleBuffers[i] = [dev newCounterSampleBufferWithDescriptor:desc error:&err];
          if (!ctx->timingSampleBuffers[i] || err) {
            NSLog(@"[WindowsVRNeural] Failed to allocate counter sample buffer [%d]: %@", i, err);
            allocOk = false;
            break;
          }
        }
        ctx->timingCounterSamplingSupported = allocOk;
        if (allocOk) {
          NSLog(@"[WindowsVRNeural] GPU per-stage counter sampling active (AtDispatchBoundary=YES, AtStageBoundary=NO, ring=3)");
        }
      } else {
        ctx->timingCounterSamplingSupported = false;
        NSLog(@"[WindowsVRNeural] Per-stage counter sampling unavailable (stage=%s, dispatch=%s, counterSet=%@); falling back to command-buffer timing",
              stageBoundarySupported ? "YES" : "NO", dispatchBoundarySupported ? "YES" : "NO",
              timestampCounterSet ? @"found" : @"missing");
      }
    }

    return ctx;
  }
}

extern "C" void wvr_neural_destroy_v1(WVRNeuralContext *ctx) {
  if (ctx) delete ctx;
}

extern "C" void wvr_neural_reset_v1(WVRNeuralContext *ctx) {
  if (!ctx) return;
  std::lock_guard lock(ctx->mutex);
  ctx->historyValid = false;
  ctx->lastReconFrameID = UINT64_MAX;
  for (int i = 0; i < 2; ++i) {
    if (ctx->metalfx[i]) {
      wvr_metalfx_reset_v1(ctx->metalfx[i]);
    }
    ctx->metalfxPrevValid[i] = false;
  }
  for (int i = 0; i < 2; ++i) {
    if (ctx->fsr[i]) {
      wvr_fsr3_reset_v1(ctx->fsr[i]);
    }
    ctx->fsrPrevValid[i] = false;
  }
  ctx->lastTimestampNs = 0;
  ctx->prevSourceTimestampNs = 0;
  ctx->lastGameFrameIntervalNs = 0;
  for (uint32_t s = 0; s < STAGE_COUNT; ++s) {
    ctx->timing->stageEmaUs[s].store(0.0f, std::memory_order_relaxed);
  }
  ctx->timing->totalGpuUs.store(0.0f, std::memory_order_relaxed);
  for (int f = 0; f < 3; ++f) {
    for (int e = 0; e < 2; ++e) {
      ctx->rateMapParamsRing[f][e] = nil;
    }
  }
  ctx->rateMapRingIndex = 0;
}

extern "C" int32_t wvr_neural_encode_v1(
    WVRNeuralContext *ctx,
    void *commandBuffer,
    const WVRNeuralFrameParamsV1 *params,
    void *inputColorEye0, void *inputDepthEye0,
    void *inputColorEye1, void *inputDepthEye1,
    void *outputColorEye0, void *outputDepthEye0,
    void *outputColorEye1, void *outputDepthEye1,
    const float displayOriginFromEye0[16], const float displayProjection0[16],
    const float displayOriginFromEye1[16], const float displayProjection1[16])
{
  return wvr_neural_encode_ratemap_v1(
      ctx, commandBuffer, params,
      inputColorEye0, inputDepthEye0, inputColorEye1, inputDepthEye1,
      outputColorEye0, outputDepthEye0, outputColorEye1, outputDepthEye1,
      displayOriginFromEye0, displayProjection0, displayOriginFromEye1, displayProjection1,
      nullptr, 0, nullptr, 0);
}

extern "C" int32_t wvr_neural_encode_ratemap_v1(
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
    void *rateMapEye1, uint32_t rateMapLayer1)
{
  @autoreleasepool {
    if (!ctx || !commandBuffer || !params) return -1;
    id<MTLCommandBuffer> cmd = (__bridge id<MTLCommandBuffer>)commandBuffer;
    std::lock_guard lock(ctx->mutex);

    id<MTLTexture> inColor[2] = {(__bridge id<MTLTexture>)inputColorEye0, (__bridge id<MTLTexture>)inputColorEye1};
    id<MTLTexture> rawDepth[2] = {(__bridge id<MTLTexture>)inputDepthEye0, (__bridge id<MTLTexture>)inputDepthEye1};
    const bool depthValid = (rawDepth[0] != nil && rawDepth[1] != nil);
    id<MTLTexture> inDepth[2] = {
      rawDepth[0] ? rawDepth[0] : ctx->dummyDepth,
      rawDepth[1] ? rawDepth[1] : ctx->dummyDepth
    };
    id<MTLTexture> outColor[2] = {(__bridge id<MTLTexture>)outputColorEye0, (__bridge id<MTLTexture>)outputColorEye1};
    id<MTLTexture> outDepth[2] = {(__bridge id<MTLTexture>)outputDepthEye0, (__bridge id<MTLTexture>)outputDepthEye1};

    if (!inColor[0] || !inColor[1] || !outColor[0] || !outColor[1] || !outDepth[0] || !outDepth[1]) return -1;
    if (!depthValid) ctx->historyValid = false;

    const uint32_t primaryEye = params->primaryEye & 1u;
    const uint32_t secondaryEye = 1u - primaryEye;
    const uint32_t order[2] = {primaryEye, secondaryEye};
    simd_float4x4 invSourceProjection[2];
    for (int i = 0; i < 2; ++i) {
      invSourceProjection[i] = simd_inverse(mat(params->eyes[i].projection));
    }

    // Process Eye A then Eye B
    // Reuse the previous reconstruction when the compositor asks for another display
    // frame from the same game frame; only the 90 Hz extrapolation below runs again.
    static const bool reconEveryCall = [] {
      const char *v = getenv("WVR_NEURAL_RECON_EVERY_CALL");
      const bool on = v && strcmp(v, "1") == 0;
      NSLog(@"[neural] reconstruction reuse for repeated game frames %s", on ? "disabled" : "enabled");
      return on;
    }();
    const bool reuseRecon = !reconEveryCall && ctx->historyValid &&
                            params->frameID == ctx->lastReconFrameID;
    if (reuseRecon) ctx->reconReuses++;
    static const bool useNeural = [] {
      const char *forceNeuralEnv = getenv("WVR_FORCE_NEURAL_RECONSTRUCTION");
      return forceNeuralEnv && strcmp(forceNeuralEnv, "1") == 0;
    }();
    const bool runNeural = useNeural && ctx->weightsLoaded && ctx->weightsHeader.num_tensors >= 32;

    bool useMetalFX = metalFXUpscaleEnabled() && depthValid && !ctx->metalfxFailed;
    if (useMetalFX) {
      for (int i = 0; i < 2; ++i) {
        if (!ctx->metalfx[i]) {
          ctx->metalfx[i] = wvr_metalfx_create_v1((__bridge void *)ctx->device);
          if (!ctx->metalfx[i]) {
            static bool sMetalFXCreateLoggedOnce = false;
            if (!sMetalFXCreateLoggedOnce) {
              NSLog(@"[neural] Failed to create MetalFX upscaler context; falling back to existing path");
              sMetalFXCreateLoggedOnce = true;
            }
            ctx->metalfxFailed = true;
            useMetalFX = false;
            break;
          }
        }
      }
    }

    bool useFSR = fsr3UpscaleEnabled() && depthValid && !ctx->fsrFailed;
    if (useMetalFX && useFSR) {
      static bool sLoggedSkipFSR = false;
      if (!sLoggedSkipFSR) {
        NSLog(@"[neural] Both MetalFX and FSR 3.1 upscale requested; MetalFX wins, skipping FSR 3.1");
        sLoggedSkipFSR = true;
      }
      useFSR = false;
    }
    if (useFSR) {
      for (int i = 0; i < 2; ++i) {
        if (!ctx->fsr[i]) {
          ctx->fsr[i] = wvr_fsr3_create_v1((__bridge void *)ctx->device);
          if (!ctx->fsr[i]) {
            static bool sLoggedOnce = false;
            if (!sLoggedOnce) {
              NSLog(@"[neural] Failed to create FSR 3.1 upscaler context; falling back to existing path");
              sLoggedOnce = true;
            }
            ctx->fsrFailed = true;
            useFSR = false;
            break;
          }
        }
      }
    }

    float frameTimeDeltaMs = 11.1f;
    if (params->timestampNanoseconds > 0 && ctx->lastTimestampNs > 0 &&
        params->timestampNanoseconds > ctx->lastTimestampNs) {
      double diffMs = double(params->timestampNanoseconds - ctx->lastTimestampNs) * 1e-6;
      frameTimeDeltaMs = std::clamp(float(diffMs), 1.0f, 100.0f);
    }
    if (params->timestampNanoseconds > 0) {
      ctx->lastTimestampNs = params->timestampNanoseconds;
    }
    if (!reuseRecon && params->timestampNanoseconds > 0) {
      if (ctx->prevSourceTimestampNs > 0 && params->timestampNanoseconds > ctx->prevSourceTimestampNs) {
        ctx->lastGameFrameIntervalNs = params->timestampNanoseconds - ctx->prevSourceTimestampNs;
      }
      ctx->prevSourceTimestampNs = params->timestampNanoseconds;
    }

    for (int i = 0; i < 2; ++i) {
      if (!reuseRecon) {
        std::swap(ctx->historyColor[i], ctx->reconstructed[i]);
      }
      uint32_t w = params->eyes[i].width;
      uint32_t h = params->eyes[i].height;
      id<MTLTexture> histCol = reuseRecon ? ctx->reconstructed[i] : ctx->historyColor[i];
      if (ctx->historyValid &&
          (!histCol || !ctx->historyDepth[i] ||
           histCol.width != w || histCol.height != h ||
           ctx->historyDepth[i].width != w || ctx->historyDepth[i].height != h)) {
        ctx->historyValid = false;
      }
      if (!reuseRecon) {
        ensure_tex(ctx->device, ctx->reconstructed[i], MTLPixelFormatRGBA16Float, w, h);
      }
    }

    if (!reuseRecon && useMetalFX) {
      for (int step = 0; step < 2; ++step) {
        uint32_t eye = order[step];
        const auto &eyeParams = params->eyes[eye];
        uint32_t w = eyeParams.width;
        uint32_t h = eyeParams.height;
        uint32_t inW = inColor[eye] ? uint32_t(inColor[eye].width) : w;
        uint32_t inH = inColor[eye] ? uint32_t(inColor[eye].height) : h;

        WVRMetalFXDispatchV1 d{};
        d.commandBuffer = (__bridge void *)cmd;
        d.color = (__bridge void *)inColor[eye];
        d.depth = (__bridge void *)inDepth[eye];
        d.output = (__bridge void *)ctx->reconstructed[eye];
        d.jitterNDC[0] = eyeParams.jitterNDC[0];
        d.jitterNDC[1] = eyeParams.jitterNDC[1];
        d.jitterValid = (std::isfinite(eyeParams.jitterNDC[0]) && std::isfinite(eyeParams.jitterNDC[1])) ? 1u : 0u;
        memcpy(d.originFromEye, eyeParams.originFromEye, sizeof(d.originFromEye));
        memcpy(d.projection, eyeParams.projection, sizeof(d.projection));
        if (ctx->metalfxPrevValid[eye]) {
          memcpy(d.previousOriginFromEye, &ctx->metalfxPrevOrigin[eye], sizeof(d.previousOriginFromEye));
          memcpy(d.previousProjection, &ctx->metalfxPrevProj[eye], sizeof(d.previousProjection));
          d.reset = 0;
        } else {
          memcpy(d.previousOriginFromEye, eyeParams.originFromEye, sizeof(d.previousOriginFromEye));
          memcpy(d.previousProjection, eyeParams.projection, sizeof(d.previousProjection));
          d.reset = 1;
        }
        d.frameTimeDeltaMs = frameTimeDeltaMs;
        d.renderWidth = inW;
        d.renderHeight = inH;
        d.displayWidth = w;
        d.displayHeight = h;

        int32_t err = wvr_metalfx_dispatch_v1(ctx->metalfx[eye], &d);
        if (err == 0) {
          ctx->metalfxJobs++;
          ctx->metalfxPrevOrigin[eye] = mat(eyeParams.originFromEye);
          ctx->metalfxPrevProj[eye] = mat(eyeParams.projection);
          ctx->metalfxPrevValid[eye] = true;
        } else {
          ctx->metalfxPrevValid[eye] = false;
          static bool sDispatchFailLogged = false;
          if (!sDispatchFailLogged) {
            NSLog(@"[neural] MetalFX dispatch failed (eye=%d err=%d); falling back to existing path", eye, err);
            sDispatchFailLogged = true;
          }
          ctx->metalfxFailed = true;
          useMetalFX = false;
          break;
        }
      }
    }

    if (!reuseRecon && useFSR) {
      for (int step = 0; step < 2; ++step) {
        uint32_t eye = order[step];
        const auto &eyeParams = params->eyes[eye];
        uint32_t w = eyeParams.width;
        uint32_t h = eyeParams.height;
        uint32_t inW = inColor[eye] ? uint32_t(inColor[eye].width) : w;
        uint32_t inH = inColor[eye] ? uint32_t(inColor[eye].height) : h;

        WVRFsr3DispatchV1 d{};
        d.commandBuffer = (__bridge void *)cmd;
        d.color = (__bridge void *)inColor[eye];
        d.depth = (__bridge void *)inDepth[eye];
        d.output = (__bridge void *)ctx->reconstructed[eye];
        d.jitterNDC[0] = eyeParams.jitterNDC[0];
        d.jitterNDC[1] = eyeParams.jitterNDC[1];
        memcpy(d.originFromEye, eyeParams.originFromEye, sizeof(d.originFromEye));
        memcpy(d.projection, eyeParams.projection, sizeof(d.projection));
        if (ctx->fsrPrevValid[eye]) {
          memcpy(d.previousOriginFromEye, &ctx->fsrPrevOrigin[eye], sizeof(d.previousOriginFromEye));
          memcpy(d.previousProjection, &ctx->fsrPrevProj[eye], sizeof(d.previousProjection));
          d.reset = 0;
        } else {
          memcpy(d.previousOriginFromEye, eyeParams.originFromEye, sizeof(d.previousOriginFromEye));
          memcpy(d.previousProjection, eyeParams.projection, sizeof(d.previousProjection));
          d.reset = 1;
        }
        d.frameTimeDeltaMs = frameTimeDeltaMs;
        d.sharpness = fsr3Sharpness();
        d.renderWidth = inW;
        d.renderHeight = inH;
        d.displayWidth = w;
        d.displayHeight = h;

        int32_t err = wvr_fsr3_dispatch_v1(ctx->fsr[eye], &d);
        if (err == 0) {
          ctx->fsrJobs++;
          ctx->fsrPrevOrigin[eye] = mat(eyeParams.originFromEye);
          ctx->fsrPrevProj[eye] = mat(eyeParams.projection);
          ctx->fsrPrevValid[eye] = true;
        } else {
          ctx->fsrPrevValid[eye] = false;
          NSLog(@"[neural] FSR 3.1 dispatch failed (eye=%d err=%d); falling back to existing path", eye, err);
          ctx->fsrFailed = true;
          useFSR = false;
          break;
        }
      }
    }

    id<MTLComputeCommandEncoder> enc = [cmd computeCommandEncoder];
    if (!enc) return -1;

    id<MTLCounterSampleBuffer> sampleBuf = nil;
    if (sNeuralGpuTimingEnabled && ctx->timingCounterSamplingSupported) {
      sampleBuf = ctx->timingSampleBuffers[ctx->timingBufferIndex];
      ctx->timingBufferIndex = (ctx->timingBufferIndex + 1) % 3;
    }
    uint32_t stagesEncodedMask = 0;

    auto sampleStage = [&](WVRNeuralStageIndex stage) -> bool {
      if (!sampleBuf) return true;
      if (sNeuralGpuTimingMode == 1) {
        [enc sampleCountersInBuffer:sampleBuf atSampleIndex:stage withBarrier:YES];
      } else if (sNeuralGpuTimingMode == 2) {
        [enc endEncoding];
        MTLComputePassDescriptor *desc = [MTLComputePassDescriptor computePassDescriptor];
        desc.sampleBufferAttachments[0].sampleBuffer = sampleBuf;
        desc.sampleBufferAttachments[0].startOfEncoderSampleIndex = 2 * stage;
        desc.sampleBufferAttachments[0].endOfEncoderSampleIndex = 2 * stage + 1;
        enc = [cmd computeCommandEncoderWithDescriptor:desc];
        if (!enc) return false;
      }
      return true;
    };

    // Helper to dispatch conv3x3_fp16
    auto dispatchConv = [&enc, ctx](id<MTLBuffer> inBuf, id<MTLBuffer> resBuf, id<MTLBuffer> outBuf,
                           uint32_t inW, uint32_t inH, uint32_t inCh,
                           uint32_t outW, uint32_t outH, uint32_t outCh,
                           uint32_t stride, uint32_t inRelu, uint32_t outRelu, uint32_t addRes,
                           uint32_t wIdx, uint32_t bIdx) {
      NeuralConvParams cp{};
      cp.inSize = simd_make_uint2(inW, inH);
      cp.outSize = simd_make_uint2(outW, outH);
      cp.inCh = inCh;
      cp.outCh = outCh;
      cp.stride = stride;
      cp.inputRelu = inRelu;
      cp.applyRelu = outRelu;
      cp.addResidual = addRes;
      cp.weightOffset = ctx->tensorTable[wIdx].offset_elements;
      cp.biasOffset = ctx->tensorTable[bIdx].offset_elements;

      static const char *const naiveEnv = getenv("WVR_NEURAL_NAIVE_CONV");
      static const bool wantNaive = (naiveEnv && strcmp(naiveEnv, "1") == 0);
      if (!ctx->convModeInitialized) {
        ctx->useNaiveConv = wantNaive;
        ctx->convModeInitialized = true;
        if (ctx->useNaiveConv || !ctx->pConv3x3Tiled) {
          NSLog(@"[WindowsVRNeural] Using naive conv3x3_fp16 kernel (WVR_NEURAL_NAIVE_CONV=%s, tiledPipeline=%s)",
                naiveEnv ? naiveEnv : "0", ctx->pConv3x3Tiled ? "ready" : "unavailable");
        } else {
          NSLog(@"[WindowsVRNeural] Using tiled conv3x3_fp16_tiled kernel");
        }
      }

      [enc setBuffer:inBuf offset:0 atIndex:0];
      [enc setBuffer:resBuf ? resBuf : inBuf offset:0 atIndex:1];
      [enc setBuffer:ctx->weightsBuffer offset:0 atIndex:2];
      [enc setBuffer:outBuf offset:0 atIndex:3];
      [enc setBytes:&cp length:sizeof(cp) atIndex:4];
      id<MTLComputePipelineState> tiledPipe = (stride == 2) ? ctx->pConv3x3TiledS2 : ctx->pConv3x3Tiled;
      if (!ctx->useNaiveConv && tiledPipe) {
        [enc setComputePipelineState:tiledPipe];
        MTLSize tg = MTLSizeMake(8, 8, 1);
        MTLSize grid = MTLSizeMake((outW + 7) / 8, (outH + 7) / 8, (outCh + 7) / 8);
        [enc dispatchThreadgroups:grid threadsPerThreadgroup:tg];
        ctx->tiledConvJobs++;
      } else {
        [enc setComputePipelineState:ctx->pConv3x3];
        [enc dispatchThreads:MTLSizeMake(outW, outH, outCh) threadsPerThreadgroup:MTLSizeMake(8, 8, 4)];
        ctx->naiveConvJobs++;
      }
      [enc memoryBarrierWithScope:MTLBarrierScopeBuffers];
    };

    const uint64_t encodeIndex = ctx->encodeCalls.fetch_add(1) + 1;
    if (!depthValid) ctx->framesNoDepth++;
    if (!reuseRecon && (useFSR || useMetalFX)) ctx->framesUpscaler++;
    if (!ctx->startupSummaryLogged) {
      ctx->startupSummaryLogged = true;
      NSLog(@"[WindowsVRNeural] Pipeline summary: path=%s forceNeural=%d weights=%s fnv64=%016llx file=%s | "
            "depth=%s in=%lux%lu/%lux%lu out=%lux%lu/%lux%lu primaryEye=%u | upscaler=%s rateMapExtrap=%d objectMotion=%d "
            "reconEveryCall=%d gpuTiming=%d dumpFrame=%llu",
            runNeural ? "VRFovealNet" : (useNeural ? "analytical (weights unusable)" : "analytical (WVR_FORCE_NEURAL_RECONSTRUCTION unset)"),
            useNeural ? 1 : 0,
            ctx->weightsLoaded ? "loaded" : "missing", (unsigned long long)ctx->weightsHash, ctx->weightsPath,
            depthValid ? "valid" : "MISSING",
            (unsigned long)inColor[0].width, (unsigned long)inColor[0].height,
            (unsigned long)inColor[1].width, (unsigned long)inColor[1].height,
            (unsigned long)outColor[0].width, (unsigned long)outColor[0].height,
            (unsigned long)outColor[1].width, (unsigned long)outColor[1].height,
            primaryEye,
            useMetalFX ? "MetalFX" : (useFSR ? "FSR 3.1" : "none"),
            neuralRatemapExtrapEnabled() ? 1 : 0, objMotionOn ? 1 : 0, reconEveryCall ? 1 : 0, sNeuralGpuTimingMode,
            (unsigned long long)sNeuralDumpFrame);
    }
    if (sNeuralPathLogEvery && (encodeIndex % sNeuralPathLogEvery) == 0) {
      NSLog(@"[WindowsVRNeural] Path counters @%llu calls: neural=%llu analyticalNoFlag=%llu analyticalNoWeights=%llu "
            "noHistory=%llu noStereoB=%llu noDepthFrames=%llu upscalerFrames=%llu reconReuses=%llu",
            (unsigned long long)encodeIndex,
            (unsigned long long)ctx->passNeural.load(), (unsigned long long)ctx->passAnalyticalNoFlag.load(),
            (unsigned long long)ctx->passAnalyticalNoWeights.load(), (unsigned long long)ctx->passNoHistory.load(),
            (unsigned long long)ctx->passNoStereo.load(), (unsigned long long)ctx->framesNoDepth.load(),
            (unsigned long long)ctx->framesUpscaler.load(), (unsigned long long)ctx->reconReuses.load());
    }
    NSMutableArray<NSDictionary *> *dumpEntries = nil;
    if (runNeural && !reuseRecon && !useFSR && !useMetalFX) {
      ctx->neuralReconstructions++;
      if (sNeuralDumpFrame && !ctx->neuralDumpDone && ctx->neuralReconstructions == sNeuralDumpFrame) {
        ctx->neuralDumpDone = true;
        dumpEntries = [NSMutableArray array];
      }
    }

    for (int step = 0; step < 2 && !reuseRecon && !useFSR && !useMetalFX; ++step) {
      uint32_t eye = order[step];
      const auto &eyeParams = params->eyes[eye];
      uint32_t w = eyeParams.width;
      uint32_t h = eyeParams.height;

      // Gaze center / radius from guest foveation if available
      float gazeCenter[2] = {eyeParams.gazeCenterUV[0], eyeParams.gazeCenterUV[1]};
      // Default to realistic ~18-20 deg fovea radius (0.10 in UV on 100 deg FOV)
      // The rate-map peak is wider than the eye's real fovea, so a valid estimate is
      // clamped to 0.08..0.14; the 0.25 fallback (no map yet) becomes 0.10.
      float gazeRadius = (eyeParams.gazeValid && eyeParams.gazeRadiusUV >= 0.05f && eyeParams.gazeRadiusUV <= 0.30f)
                             ? std::clamp(eyeParams.gazeRadiusUV, 0.08f, 0.14f)
                             : 0.10f;
      // The crop samples the game's render, which is smaller than the eye when
      // WVR_INTERNAL_RENDER_SCALE < 1, so size it from the input texture width.
      const uint32_t inW = inColor[eye] ? uint32_t(inColor[eye].width) : w;
      // Shrink effective gaze radius so 2*r*inW <= 256 (avoid downsampling the foveal crop)
      if (inW > 0) {
        gazeRadius = std::min(gazeRadius, 128.0f / float(inW));
      }

      // Aspect ratio correction (circular fovea on screen)
      float aspect = float(w) / float(std::max(1u, h));
      float gazeRadiusX = gazeRadius;
      float gazeRadiusY = gazeRadius * aspect;

      // Crop size matches actual input pixel density in fovea: radius 0.10 on 960w -> 192 pixels
      uint32_t cropLR = std::clamp(uint32_t(std::round(2.0f * gazeRadiusX * float(inW))), 128u, 256u);
      cropLR = (cropLR + 1u) & ~1u; // ensure even dimensions
      uint32_t cropHR = cropLR * 2u;
      uint32_t cropLow = cropLR / 2u;
      ctx->lastGazeRadiusUV[eye] = gazeRadius;
      ctx->lastCropHR[eye] = cropHR;

      if (runNeural) {
        ensure_tex(ctx->device, ctx->foveaHR[eye], MTLPixelFormatRGBA16Float, cropHR, cropHR);
        uint64_t tensorBytes = uint64_t(cropLR) * cropLR * 40 * sizeof(uint16_t);
        if (!ctx->foveaTensor[eye] || ctx->foveaTensor[eye].length < tensorBytes) {
          ctx->foveaTensor[eye] = [ctx->device newBufferWithLength:tensorBytes options:MTLResourceStorageModePrivate];
        }
        uint64_t f1Bytes = uint64_t(cropLR) * cropLR * 32 * sizeof(uint16_t);
        uint64_t f2Bytes = uint64_t(cropLR) * cropLR * 128 * sizeof(uint16_t);
        uint64_t fLowBytes = std::max(uint64_t(cropLow) * cropLow * 48, uint64_t(cropLR) * cropLR * 32) * sizeof(uint16_t);
        uint64_t fOutBytes = uint64_t(cropLR) * cropLR * 24 * sizeof(uint16_t);

        if (!ctx->f1Buffer[eye] || ctx->f1Buffer[eye].length < f1Bytes) ctx->f1Buffer[eye] = [ctx->device newBufferWithLength:f1Bytes options:MTLResourceStorageModePrivate];
        if (!ctx->f2Buffer[eye] || ctx->f2Buffer[eye].length < f2Bytes) ctx->f2Buffer[eye] = [ctx->device newBufferWithLength:f2Bytes options:MTLResourceStorageModePrivate];
        if (!ctx->fLowBuffer[eye] || ctx->fLowBuffer[eye].length < fLowBytes) ctx->fLowBuffer[eye] = [ctx->device newBufferWithLength:fLowBytes options:MTLResourceStorageModePrivate];
        if (!ctx->fOutBuffer[eye] || ctx->fOutBuffer[eye].length < fOutBytes) ctx->fOutBuffer[eye] = [ctx->device newBufferWithLength:fOutBytes options:MTLResourceStorageModePrivate];
      }

      const simd_float4x4 curInvProj = invSourceProjection[eye];
      const bool runStereoWarp = (step == 1 && depthValid);
      bool needPreGatherBarrier = false;

      // 1. If secondary eye: run YORO stereo warp from primary eye's finished reconstructed texture
      if (sampleBuf && step == 1) {
        if (!sampleStage(STAGE_YORO_WARP)) return -1;
      }
      if (runStereoWarp) {
        stagesEncodedMask |= (1u << STAGE_YORO_WARP);
        ensure_tex(ctx->device, ctx->warpedStereo[eye], MTLPixelFormatRGBA16Float, w, h);
        ensure_tex(ctx->device, ctx->stereoValidity[eye], MTLPixelFormatR8Unorm, w, h);
        uint32_t otherEye = order[0];
        NeuralStereoWarpParams p{};
        simd_float4x4 eyeAViewFromEyeBView = simd_mul(simd_inverse(mat(params->eyes[otherEye].originFromEye)), mat(eyeParams.originFromEye));
        p.eyeAClipFromEyeBView = simd_mul(mat(params->eyes[otherEye].projection), eyeAViewFromEyeBView);
        p.eyeBInverseProjection = curInvProj;
        p.size = simd_make_uint2(w, h);

        [enc setComputePipelineState:ctx->pYoroStereoWarp];
        [enc setBytes:&p length:sizeof(p) atIndex:0];
        [enc setTexture:ctx->reconstructed[otherEye] atIndex:0]; // Eye A's reconstructed output
        [enc setTexture:inDepth[eye] atIndex:1];
        [enc setTexture:ctx->warpedStereo[eye] atIndex:2];
        [enc setTexture:ctx->stereoValidity[eye] atIndex:3];
        [enc dispatchThreads:MTLSizeMake(w, h, 1) threadsPerThreadgroup:MTLSizeMake(8, 8, 1)];
        needPreGatherBarrier = true;
        ctx->stereoWarpJobs++;
      }

      // 2. AFW Temporal Warp from eye's own previous history
      if (sampleBuf && step == 1) {
        if (!sampleStage(STAGE_AFW_FOVEAL)) return -1;
        stagesEncodedMask |= (1u << STAGE_AFW_FOVEAL);
      }
      const bool histOk = ctx->historyValid && ctx->historyColor[eye] != nil && ctx->historyDepth[eye] != nil;
      if (runNeural) ctx->passNeural++;
      else if (ctx->weightsLoaded) ctx->passAnalyticalNoFlag++;
      else ctx->passAnalyticalNoWeights++;
      if (!histOk) ctx->passNoHistory++;
      if (step == 1 && !runStereoWarp) ctx->passNoStereo++;
      simd_float4x4 historyClipFromCurrent = matrix_identity_float4x4;
      if (histOk) {
        simd_float4x4 histViewFromCurView = simd_mul(simd_inverse(ctx->historyOrigin[eye]), mat(eyeParams.originFromEye));
        historyClipFromCurrent = simd_mul(ctx->historyProjection[eye], histViewFromCurView);
      }
      if (runNeural && histOk) {
        ensure_tex(ctx->device, ctx->warpedHist[eye], MTLPixelFormatRGBA16Float, w, h);
        ensure_tex(ctx->device, ctx->histValidity[eye], MTLPixelFormatR8Unorm, w, h);
        NeuralTemporalWarpParams p{};
        p.currentInverseProjection = curInvProj;
        p.historyClipFromCurrent = historyClipFromCurrent;
        p.gazeCenterUV = simd_make_float2(gazeCenter[0], gazeCenter[1]);
        p.gazeRadiusUV = gazeRadius;
        p.historyValid = 1;
        p.size = simd_make_uint2(w, h);

        [enc setComputePipelineState:ctx->pAfwTemporalWarp];
        [enc setBytes:&p length:sizeof(p) atIndex:0];
        [enc setTexture:ctx->historyColor[eye] atIndex:0];
        [enc setTexture:ctx->historyDepth[eye] atIndex:1];
        [enc setTexture:inDepth[eye] atIndex:2];
        [enc setTexture:ctx->warpedHist[eye] atIndex:3];
        [enc setTexture:ctx->histValidity[eye] atIndex:4];
        [enc dispatchThreads:MTLSizeMake(w, h, 1) threadsPerThreadgroup:MTLSizeMake(8, 8, 1)];
        needPreGatherBarrier = true;
      }
      ctx->temporalWarpJobs++;
      if (needPreGatherBarrier) {
        [enc memoryBarrierWithScope:MTLBarrierScopeTextures];
      }

      // 3. Foveal gather inputs (packs 40-channel FP16 tensor)
      NeuralGatherParams gatherP{};
      gatherP.gazeCenterUV = simd_make_float2(gazeCenter[0], gazeCenter[1]);
      gatherP.gazeRadiusUV = gazeRadius;
      gatherP.cropSizeUV = simd_make_float2(gazeRadiusX * 2.0f, gazeRadiusY * 2.0f);
      gatherP.jitterUV = simd_make_float2(-eyeParams.jitterNDC[0] * 0.5f, eyeParams.jitterNDC[1] * 0.5f);
      gatherP.jitterNDC = simd_make_float2(eyeParams.jitterNDC[0], eyeParams.jitterNDC[1]);
      gatherP.cropLrSize = simd_make_uint2(cropLR, cropLR);
      gatherP.cropHrSize = simd_make_uint2(cropHR, cropHR);
      gatherP.eyeRole = step; // 0 for Eye A, 1 for Eye B
      gatherP.historyValid = histOk ? 1u : 0u;
      gatherP.stereoValid = runStereoWarp ? 1u : 0u;

      // 4. VRFovealNet inference (opt-in) or analytical blend fallback (default)
      if (runNeural) {
        [enc setComputePipelineState:ctx->pFovealGather];
        [enc setTexture:inColor[eye] atIndex:0];
        [enc setTexture:inDepth[eye] atIndex:1];
        [enc setTexture:histOk ? ctx->warpedHist[eye] : inColor[eye] atIndex:2];
        [enc setTexture:histOk ? ctx->histValidity[eye] : inColor[eye] atIndex:3];
        [enc setTexture:runStereoWarp ? ctx->warpedStereo[eye] : inColor[eye] atIndex:4];
        [enc setTexture:runStereoWarp ? ctx->stereoValidity[eye] : inColor[eye] atIndex:5];
        [enc setBuffer:ctx->foveaTensor[eye] offset:0 atIndex:0];
        [enc setBytes:&gatherP length:sizeof(gatherP) atIndex:1];
        [enc dispatchThreads:MTLSizeMake(cropLR, cropLR, 1) threadsPerThreadgroup:MTLSizeMake(8, 8, 1)];
        [enc memoryBarrierWithScope:MTLBarrierScopeBuffers];

        // Layer 0..1: head (40 -> 32, ReLU=1) -> f1Buffer
        dispatchConv(ctx->foveaTensor[eye], nil, ctx->f1Buffer[eye], cropLR, cropLR, 40, cropLR, cropLR, 32, 1, 0, 1, 0, 0, 1);

        // enc.0: f1 -> f2 (ReLU=1) -> f1 (addResidual f1)
        dispatchConv(ctx->f1Buffer[eye], nil, ctx->f2Buffer[eye], cropLR, cropLR, 32, cropLR, cropLR, 32, 1, 0, 1, 0, 2, 3);
        dispatchConv(ctx->f2Buffer[eye], ctx->f1Buffer[eye], ctx->f1Buffer[eye], cropLR, cropLR, 32, cropLR, cropLR, 32, 1, 0, 0, 1, 4, 5);

        // enc.1: f1 -> f2 (ReLU=1) -> f1 (addResidual f1)
        dispatchConv(ctx->f1Buffer[eye], nil, ctx->f2Buffer[eye], cropLR, cropLR, 32, cropLR, cropLR, 32, 1, 0, 1, 0, 6, 7);
        dispatchConv(ctx->f2Buffer[eye], ctx->f1Buffer[eye], ctx->f1Buffer[eye], cropLR, cropLR, 32, cropLR, cropLR, 32, 1, 0, 0, 1, 8, 9);

        // down (stride 2): f1 -> fLowBuffer (32 -> 48, ReLU=1, 128x128)
        dispatchConv(ctx->f1Buffer[eye], nil, ctx->fLowBuffer[eye], cropLR, cropLR, 32, cropLow, cropLow, 48, 2, 0, 1, 0, 10, 11);

        // mid.0: fLow -> f2 (ReLU=1) -> fLow (addResidual fLow)
        dispatchConv(ctx->fLowBuffer[eye], nil, ctx->f2Buffer[eye], cropLow, cropLow, 48, cropLow, cropLow, 48, 1, 0, 1, 0, 12, 13);
        dispatchConv(ctx->f2Buffer[eye], ctx->fLowBuffer[eye], ctx->fLowBuffer[eye], cropLow, cropLow, 48, cropLow, cropLow, 48, 1, 0, 0, 1, 14, 15);

        // mid.1: fLow -> f2 (ReLU=1) -> fLow (addResidual fLow)
        dispatchConv(ctx->fLowBuffer[eye], nil, ctx->f2Buffer[eye], cropLow, cropLow, 48, cropLow, cropLow, 48, 1, 0, 1, 0, 16, 17);
        dispatchConv(ctx->f2Buffer[eye], ctx->fLowBuffer[eye], ctx->fLowBuffer[eye], cropLow, cropLow, 48, cropLow, cropLow, 48, 1, 0, 0, 1, 18, 19);

        // up: fLow -> f2 (48 -> 128 at 128x128)
        dispatchConv(ctx->fLowBuffer[eye], nil, ctx->f2Buffer[eye], cropLow, cropLow, 48, cropLow, cropLow, 128, 1, 0, 0, 0, 20, 21);

        // pixel_shuffle_2x_skip: 128 -> 32 at 256x256 + skip f1Buffer -> fLowBuffer (used as scratch 256x256x32)
        simd_uint3 upDims = simd_make_uint3(cropLR, cropLR, 32);
        [enc setComputePipelineState:ctx->pPixelShuffleSkip];
        [enc setBuffer:ctx->f2Buffer[eye] offset:0 atIndex:0];
        [enc setBuffer:ctx->f1Buffer[eye] offset:0 atIndex:1];
        [enc setBuffer:ctx->fLowBuffer[eye] offset:0 atIndex:2];
        [enc setBytes:&upDims length:sizeof(upDims) atIndex:3];
        [enc dispatchThreads:MTLSizeMake(cropLR, cropLR, 32) threadsPerThreadgroup:MTLSizeMake(8, 8, 4)];
        [enc memoryBarrierWithScope:MTLBarrierScopeBuffers];

        // dec.0: fLow -> f1 (ReLU=1) -> fLow (addResidual fLow)
        dispatchConv(ctx->fLowBuffer[eye], nil, ctx->f1Buffer[eye], cropLR, cropLR, 32, cropLR, cropLR, 32, 1, 0, 1, 0, 22, 23);
        dispatchConv(ctx->f1Buffer[eye], ctx->fLowBuffer[eye], ctx->fLowBuffer[eye], cropLR, cropLR, 32, cropLR, cropLR, 32, 1, 0, 0, 1, 24, 25);

        // dec.1: fLow -> f1 (ReLU=1) -> fLow (addResidual fLow)
        dispatchConv(ctx->fLowBuffer[eye], nil, ctx->f1Buffer[eye], cropLR, cropLR, 32, cropLR, cropLR, 32, 1, 0, 1, 0, 26, 27);
        dispatchConv(ctx->f1Buffer[eye], ctx->fLowBuffer[eye], ctx->fLowBuffer[eye], cropLR, cropLR, 32, cropLR, cropLR, 32, 1, 0, 0, 1, 28, 29);

        // out: fLow (inputRelu=1) -> fOutBuffer (32 -> 24 at 256x256)
        dispatchConv(ctx->fLowBuffer[eye], nil, ctx->fOutBuffer[eye], cropLR, cropLR, 32, cropLR, cropLR, 24, 1, 1, 0, 0, 30, 31);

        // foveal_out_resolve_fp16: pixel_shuffle(24) -> 6 HR channels + Softmax blend + residual -> foveaHR
        [enc setComputePipelineState:ctx->pFovealOutResolve];
        [enc setBuffer:ctx->fOutBuffer[eye] offset:0 atIndex:0];
        [enc setTexture:inColor[eye] atIndex:0];
        [enc setTexture:histOk ? ctx->warpedHist[eye] : inColor[eye] atIndex:1];
        [enc setTexture:histOk ? ctx->histValidity[eye] : inColor[eye] atIndex:2];
        [enc setTexture:runStereoWarp ? ctx->warpedStereo[eye] : inColor[eye] atIndex:3];
        [enc setTexture:runStereoWarp ? ctx->stereoValidity[eye] : inColor[eye] atIndex:4];
        [enc setTexture:ctx->foveaHR[eye] atIndex:5];
        [enc setBytes:&gatherP length:sizeof(gatherP) atIndex:1];
        [enc dispatchThreads:MTLSizeMake(cropHR, cropHR, 1) threadsPerThreadgroup:MTLSizeMake(8, 8, 1)];
        [enc memoryBarrierWithScope:MTLBarrierScopeTextures];
        if (dumpEntries) {
          [dumpEntries addObject:@{
            @"input" : ctx->foveaTensor[eye], @"out24" : ctx->fOutBuffer[eye], @"foveaHR" : ctx->foveaHR[eye],
            @"meta" : @{
              @"eye" : @(eye), @"role" : @(step), @"cropLR" : @(cropLR), @"cropHR" : @(cropHR),
              @"gazeCenterUV" : @[ @(gazeCenter[0]), @(gazeCenter[1]) ], @"gazeRadiusUV" : @(gazeRadius),
              @"gazeValid" : @(eyeParams.gazeValid), @"jitterNDC" : @[ @(eyeParams.jitterNDC[0]), @(eyeParams.jitterNDC[1]) ],
              @"historyValid" : @(histOk ? 1 : 0), @"stereoValid" : @(runStereoWarp ? 1 : 0),
              @"eyeSize" : @[ @(w), @(h) ], @"inputSize" : @[ @(inColor[eye].width), @(inColor[eye].height) ],
            },
          }];
        }
      }
      ctx->fovealJobs++;

      // 5. Foveal blend and splice into full-eye intermediate texture ctx->reconstructed[eye]
      if (sampleBuf && step == 1) {
        if (!sampleStage(STAGE_SPLICE)) return -1;
        stagesEncodedMask |= (1u << STAGE_SPLICE);
      }
      NeuralBlendParams blendP{};
      blendP.historyClipFromCurrent = historyClipFromCurrent;
      blendP.currentInverseProjection = curInvProj;
      blendP.gazeCenterUV = simd_make_float2(gazeCenter[0], gazeCenter[1]);
      blendP.gazeRadiusUV = gazeRadius;
      blendP.jitterUV = gatherP.jitterUV;
      blendP.fullSize = simd_make_uint2(w, h);
      blendP.eyeRole = step;
      blendP.historyValid = histOk ? 1u : 0u;
      blendP.stereoValid = runStereoWarp ? 1u : 0u;
      blendP.fuseAfwAndAnalytical = runNeural ? 0u : 1u;

      [enc setComputePipelineState:ctx->pFovealBlendSplice];
      [enc setTexture:runNeural ? ctx->foveaHR[eye] : inColor[eye] atIndex:0];
      [enc setTexture:inColor[eye] atIndex:1];
      [enc setTexture:runStereoWarp ? ctx->warpedStereo[eye] : inColor[eye] atIndex:2];
      [enc setTexture:(runNeural && histOk) ? ctx->warpedHist[eye] : inColor[eye] atIndex:3];
      [enc setTexture:(runNeural && histOk) ? ctx->histValidity[eye] : inColor[eye] atIndex:4];
      [enc setTexture:ctx->reconstructed[eye] atIndex:5]; // writes to intermediate reconstructed texture
      [enc setTexture:runStereoWarp ? ctx->stereoValidity[eye] : inColor[eye] atIndex:6];
      [enc setTexture:histOk ? ctx->historyColor[eye] : inColor[eye] atIndex:7];
      [enc setTexture:histOk ? ctx->historyDepth[eye] : inDepth[eye] atIndex:8];
      [enc setTexture:inDepth[eye] atIndex:9];
      [enc setBytes:&blendP length:sizeof(blendP) atIndex:0];
      [enc dispatchThreads:MTLSizeMake(w, h, 1) threadsPerThreadgroup:MTLSizeMake(8, 8, 1)];
      [enc memoryBarrierWithScope:MTLBarrierScopeTextures];

      // 5b. Fused Auto-Reactive UI Mask & RCAS Sharpening pass for text / HUD clarity
      if (sampleBuf && step == 1) {
        if (!sampleStage(STAGE_RCAS_UI)) return -1;
        stagesEncodedMask |= (1u << STAGE_RCAS_UI);
      }
      ensure_tex(ctx->device, ctx->uiScratch[eye], MTLPixelFormatRGBA16Float, w, h);
      simd_uint2 fullSz = simd_make_uint2(w, h);

      [enc setComputePipelineState:ctx->pRCASSharpenUI];
      [enc setTexture:ctx->reconstructed[eye] atIndex:0];
      [enc setTexture:ctx->uiScratch[eye] atIndex:1];
      [enc setTexture:inColor[eye] atIndex:2];
      [enc setTexture:histOk ? ctx->historyColor[eye] : inColor[eye] atIndex:3];
      [enc setBytes:&fullSz length:sizeof(fullSz) atIndex:0];
      [enc dispatchThreads:MTLSizeMake(w, h, 1) threadsPerThreadgroup:MTLSizeMake(8, 8, 1)];
      [enc memoryBarrierWithScope:MTLBarrierScopeTextures];

      // Swap uiScratch back into reconstructed
      id<MTLTexture> tmpRec = ctx->reconstructed[eye];
      ctx->reconstructed[eye] = ctx->uiScratch[eye];
      ctx->uiScratch[eye] = tmpRec;
    }

    if (sampleBuf) {
      if (!sampleStage(STAGE_OBJECT_MOTION)) return -1;
    }
    const bool objMotionOn = objectMotionEnabled() && (ctx->pObjectMotionEstimate != nil);
    if (!reuseRecon && objMotionOn) {
      stagesEncodedMask |= (1u << STAGE_OBJECT_MOTION);
      for (int eye = 0; eye < 2; ++eye) {
        uint32_t w = params->eyes[eye].width;
        uint32_t h = params->eyes[eye].height;
        uint32_t motW = std::max(1u, (w + 7u) / 8u);
        uint32_t motH = std::max(1u, (h + 7u) / 8u);
        ensure_tex(ctx->device, ctx->objMotion[eye], MTLPixelFormatRGBA16Float, motW, motH);

        const bool histOk = ctx->historyValid && ctx->historyColor[eye] != nil && ctx->historyDepth[eye] != nil;
        simd_float4x4 historyClipFromCurrent = matrix_identity_float4x4;
        if (histOk) {
          simd_float4x4 histViewFromCurView = simd_mul(simd_inverse(ctx->historyOrigin[eye]), mat(params->eyes[eye].originFromEye));
          historyClipFromCurrent = simd_mul(ctx->historyProjection[eye], histViewFromCurView);
        }

        NeuralObjectMotionParams omp{};
        omp.historyClipFromCurrent = historyClipFromCurrent;
        omp.currentInverseProjection = invSourceProjection[eye];
        omp.fullSize = simd_make_uint2(w, h);
        omp.tileCount = simd_make_uint2(motW, motH);
        omp.historyValid = histOk ? 1u : 0u;

        [enc setComputePipelineState:ctx->pObjectMotionEstimate];
        [enc setTexture:inColor[eye] atIndex:0];
        [enc setTexture:inDepth[eye] atIndex:1];
        [enc setTexture:histOk ? ctx->historyColor[eye] : inColor[eye] atIndex:2];
        [enc setTexture:ctx->objMotion[eye] atIndex:3];
        [enc setBytes:&omp length:sizeof(omp) atIndex:0];
        [enc dispatchThreads:MTLSizeMake(motW, motH, 1) threadsPerThreadgroup:MTLSizeMake(8, 8, 1)];
        ctx->objectMotionJobs++;
      }
      [enc memoryBarrierWithScope:MTLBarrierScopeTextures];
    }

    uint64_t gameIntervalNs = ctx->lastGameFrameIntervalNs > 0 ? ctx->lastGameFrameIntervalNs : 22222222ULL;
    float extrapFraction = 0.0f;
    if (params->displayTimestampNanoseconds > params->timestampNanoseconds && gameIntervalNs > 0) {
      double deltaNs = double(params->displayTimestampNanoseconds - params->timestampNanoseconds);
      extrapFraction = float(std::clamp(deltaNs / double(gameIntervalNs), 0.0, 1.0));
    }

    // 6. Extrapolation 90 Hz for both eyes (reads reconstructed[eye], writes outColor[eye] - NO hazard!)
    if (sampleBuf) {
      if (!sampleStage(STAGE_EXTRAP)) return -1;
    }
    const float *dispOrigins[2] = {displayOriginFromEye0, displayOriginFromEye1};
    const float *dispProjs[2] = {displayProjection0, displayProjection1};
    id<MTLRasterizationRateMap> rateMaps[2] = {
      (__bridge id<MTLRasterizationRateMap>)rateMapEye0,
      (__bridge id<MTLRasterizationRateMap>)rateMapEye1
    };
    const uint32_t rateMapLayers[2] = {rateMapLayer0, rateMapLayer1};
    const bool ratemapExtrapOn = neuralRatemapExtrapEnabled() && (ctx->pExtrap90HzRatemap != nil);
    const uint32_t ringSlot = ctx->rateMapRingIndex % 3;
    ctx->rateMapRingIndex++;
    for (int eye = 0; eye < 2; ++eye) {
      if (!dispOrigins[eye] || !dispProjs[eye]) continue;
      stagesEncodedMask |= (1u << STAGE_EXTRAP);
      uint32_t w = params->eyes[eye].width;
      uint32_t h = params->eyes[eye].height;
      id<MTLTexture> histCol = reuseRecon ? ctx->reconstructed[eye] : ctx->historyColor[eye];
      const bool histOk = ctx->historyValid && histCol != nil && ctx->historyDepth[eye] != nil;
      const bool sameOrigin = (memcmp(dispOrigins[eye], params->eyes[eye].originFromEye, 64) == 0);
      const bool sameProj = (memcmp(dispProjs[eye], params->eyes[eye].projection, 64) == 0);

      NeuralExtrapParams ep{};
      ep.sourceProjection = mat(params->eyes[eye].projection);
      ep.sourceInverseProjection = invSourceProjection[eye];
      ep.displayProjection = sameProj ? ep.sourceProjection : mat(dispProjs[eye]);
      ep.displayInverseProjection = sameProj ? ep.sourceInverseProjection : simd_inverse(ep.displayProjection);
      simd_float4x4 dispOriginMat = mat(dispOrigins[eye]);
      ep.sourceViewFromDisplayView = sameOrigin
          ? matrix_identity_float4x4
          : simd_mul(simd_inverse(mat(params->eyes[eye].originFromEye)), dispOriginMat);
      ep.displayFromSource = sameOrigin
          ? matrix_identity_float4x4
          : simd_mul(simd_inverse(dispOriginMat), mat(params->eyes[eye].originFromEye));
      if (histOk) {
        ep.historyProjection = ctx->historyProjection[eye];
        ep.historyViewFromDisplayView = simd_mul(simd_inverse(ctx->historyOrigin[eye]), dispOriginMat);
      } else {
        ep.historyProjection = ep.sourceProjection;
        ep.historyViewFromDisplayView = ep.sourceViewFromDisplayView;
      }
      ep.displaySize = simd_make_uint2(w, h);
      ep.historyValid = histOk ? 1 : 0;

      // Compute second-order quadratic acceleration from head origins
      simd_float3 curPos = simd_make_float3(params->eyes[eye].originFromEye[12],
                                            params->eyes[eye].originFromEye[13],
                                            params->eyes[eye].originFromEye[14]);
      simd_float3 dispPos = simd_make_float3(dispOrigins[eye][12],
                                             dispOrigins[eye][13],
                                             dispOrigins[eye][14]);
      simd_float3 histPos = curPos;
      if (histOk) {
        histPos = simd_make_float3(ctx->historyOrigin[eye].columns[3].x,
                                   ctx->historyOrigin[eye].columns[3].y,
                                   ctx->historyOrigin[eye].columns[3].z);
      }
      simd_float3 accel = dispPos - 2.0f * curPos + histPos;
      ep.quadraticCurvature = simd_make_float2(accel.x * 0.15f, -accel.y * 0.15f);
      ep.objectMotionEnabled = (objMotionOn && ctx->objMotion[eye] != nil) ? 1u : 0u;
      ep.extrapFraction = extrapFraction;

      id<MTLRasterizationRateMap> rmap = rateMaps[eye];
      bool useRatemapForEye = false;
      uint32_t physW = w, physH = h;
      if (ratemapExtrapOn && rmap && rateMapLayers[eye] < rmap.layerCount) {
        MTLSize phys = [rmap physicalSizeForLayer:rateMapLayers[eye]];
        if (phys.width > 0 && phys.height > 0 &&
            outColor[eye].width == phys.width && outColor[eye].height == phys.height) {
          physW = (uint32_t)phys.width;
          physH = (uint32_t)phys.height;
          useRatemapForEye = true;
        }
      }

      if (useRatemapForEye) {
        NSUInteger paramSize = rmap.parameterBufferSizeAndAlign.size;
        __strong id<MTLBuffer> &paramBuf = ctx->rateMapParamsRing[ringSlot][eye];
        if (!paramBuf || paramBuf.length < paramSize) {
          paramBuf = [ctx->device newBufferWithLength:paramSize options:MTLResourceStorageModeShared];
        }
        [rmap copyParameterDataToBuffer:paramBuf offset:0];

        ep.physicalSize = simd_make_uint2(physW, physH);
        ep.rateMapLayer = rateMapLayers[eye];

        [enc setComputePipelineState:ctx->pExtrap90HzRatemap];
        [enc setTexture:ctx->reconstructed[eye] atIndex:0];
        [enc setTexture:inDepth[eye] atIndex:1];
        [enc setTexture:histOk ? histCol : ctx->reconstructed[eye] atIndex:2];
        [enc setTexture:histOk ? ctx->historyDepth[eye] : inDepth[eye] atIndex:3];
        [enc setTexture:outColor[eye] atIndex:4];
        [enc setTexture:outDepth[eye] atIndex:5];
        [enc setTexture:ctx->objMotion[eye] ? ctx->objMotion[eye] : inColor[eye] atIndex:6];
        [enc setBytes:&ep length:sizeof(ep) atIndex:0];
        if (paramSize <= 4096) {
          [enc setBytes:paramBuf.contents length:paramSize atIndex:1];
        } else {
          [enc setBuffer:paramBuf offset:0 atIndex:1];
        }
        [enc dispatchThreads:MTLSizeMake(physW, physH, 1) threadsPerThreadgroup:MTLSizeMake(8, 8, 1)];
        ctx->extrapRateMapJobs++;
      } else {
        uint32_t targetW = (uint32_t)std::min<uint64_t>(w, outColor[eye].width);
        uint32_t targetH = (uint32_t)std::min<uint64_t>(h, outColor[eye].height);
        ep.displaySize = simd_make_uint2(targetW, targetH);
        ep.physicalSize = simd_make_uint2(targetW, targetH);
        ep.rateMapLayer = 0;
      [enc setComputePipelineState:ctx->pExtrap90Hz];
      [enc setTexture:ctx->reconstructed[eye] atIndex:0]; // samples intermediate reconstructed texture
      [enc setTexture:inDepth[eye] atIndex:1];
      [enc setTexture:histOk ? histCol : ctx->reconstructed[eye] atIndex:2];
      [enc setTexture:histOk ? ctx->historyDepth[eye] : inDepth[eye] atIndex:3];
      [enc setTexture:outColor[eye] atIndex:4]; // writes to final output
      [enc setTexture:outDepth[eye] atIndex:5];
      [enc setTexture:ctx->objMotion[eye] ? ctx->objMotion[eye] : inColor[eye] atIndex:6];
      [enc setBytes:&ep length:sizeof(ep) atIndex:0];
      [enc dispatchThreads:MTLSizeMake(targetW, targetH, 1) threadsPerThreadgroup:MTLSizeMake(8, 8, 1)];
      }
      ctx->extrapJobs++;
    }

    // Snapshot linear source depth (metres, 0 where validity < 0.1) into R32Float historyDepth
    if (sampleBuf) {
      if (!sampleStage(STAGE_HISTORY_COPY)) return -1;
    }
    if (!reuseRecon) {
      if (depthValid) {
        stagesEncodedMask |= (1u << STAGE_HISTORY_COPY);
        [enc memoryBarrierWithScope:MTLBarrierScopeTextures];
      }
      for (int i = 0; i < 2; ++i) {
        uint32_t w = params->eyes[i].width;
        uint32_t h = params->eyes[i].height;
        if (depthValid && inDepth[i]) {
          ensure_tex(ctx->device, ctx->historyDepth[i], MTLPixelFormatR32Float, w, h);
          if (ctx->historyDepth[i]) {
            simd_uint2 sz = simd_make_uint2(w, h);
            [enc setComputePipelineState:ctx->pCopyHistoryDepth];
            [enc setTexture:inDepth[i] atIndex:0];
            [enc setTexture:ctx->historyDepth[i] atIndex:1];
            [enc setBytes:&sz length:sizeof(sz) atIndex:0];
            [enc dispatchThreads:MTLSizeMake(w, h, 1) threadsPerThreadgroup:MTLSizeMake(8, 8, 1)];
          }
        }
        ctx->historyOrigin[i] = mat(params->eyes[i].originFromEye);
        ctx->historyProjection[i] = mat(params->eyes[i].projection);
      }
      ctx->historyValid = depthValid;
      ctx->lastReconFrameID = params->frameID;
    }
    if (sNeuralGpuTimingMode == 1 && sampleBuf) {
      [enc sampleCountersInBuffer:sampleBuf atSampleIndex:STAGE_END withBarrier:YES];
    }
    [enc endEncoding];

    if (dumpEntries.count) {
      id<MTLBlitCommandEncoder> blit = [cmd blitCommandEncoder];
      NSMutableArray<NSDictionary *> *staged = [NSMutableArray array];
      for (NSDictionary *e in dumpEntries) {
        const uint32_t cLR = [e[@"meta"][@"cropLR"] unsignedIntValue];
        id<MTLTexture> hr = e[@"foveaHR"];
        const NSUInteger inBytes = NSUInteger(cLR) * cLR * 40 * sizeof(uint16_t);
        const NSUInteger outBytes = NSUInteger(cLR) * cLR * 24 * sizeof(uint16_t);
        const NSUInteger hrBytes = hr.width * hr.height * 4 * sizeof(uint16_t);
        id<MTLBuffer> sIn = [ctx->device newBufferWithLength:inBytes options:MTLResourceStorageModeShared];
        id<MTLBuffer> sOut = [ctx->device newBufferWithLength:outBytes options:MTLResourceStorageModeShared];
        id<MTLBuffer> sHR = [ctx->device newBufferWithLength:hrBytes options:MTLResourceStorageModeShared];
        if (!blit || !sIn || !sOut || !sHR) continue;
        [blit copyFromBuffer:e[@"input"] sourceOffset:0 toBuffer:sIn destinationOffset:0 size:inBytes];
        [blit copyFromBuffer:e[@"out24"] sourceOffset:0 toBuffer:sOut destinationOffset:0 size:outBytes];
        [blit copyFromTexture:hr sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0)
                   sourceSize:MTLSizeMake(hr.width, hr.height, 1) toBuffer:sHR destinationOffset:0
       destinationBytesPerRow:hr.width * 4 * sizeof(uint16_t) destinationBytesPerImage:hrBytes];
        NSMutableDictionary *meta = [e[@"meta"] mutableCopy];
        meta[@"foveaHRSize"] = @[ @(hr.width), @(hr.height) ];
        [staged addObject:@{@"in" : sIn, @"out" : sOut, @"hr" : sHR, @"meta" : meta}];
      }
      [blit endEncoding];
      const unsigned long long dumpFrameID = params->frameID;
      const unsigned long long dumpHash = ctx->weightsHash;
      NSString *dumpWeights = [NSString stringWithUTF8String:ctx->weightsPath];
      [cmd addCompletedHandler:^(id<MTLCommandBuffer> cb) {
        if (cb.status != MTLCommandBufferStatusCompleted) {
          NSLog(@"[WindowsVRNeural] Neural tensor dump skipped: command buffer status %ld", (long)cb.status);
          return;
        }
        NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject ?: NSTemporaryDirectory();
        NSString *dir = [[docs stringByAppendingPathComponent:@"WindowsVRDiagnostics"]
            stringByAppendingPathComponent:[NSString stringWithFormat:@"neural_dump_%llu", dumpFrameID]];
        [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
        NSMutableArray *metas = [NSMutableArray array];
        for (NSDictionary *s in staged) {
          NSMutableDictionary *m = s[@"meta"];
          NSString *tag = [NSString stringWithFormat:@"eye%@", m[@"eye"]];
          for (NSArray *f in @[ @[ @"in", @"input_nhwc40_f16" ], @[ @"out", @"out24_nhwc_f16" ], @[ @"hr", @"fovea_hr_rgba16f" ] ]) {
            id<MTLBuffer> buf = s[f[0]];
            NSString *name = [NSString stringWithFormat:@"%@_%@.bin", tag, f[1]];
            [[NSData dataWithBytesNoCopy:buf.contents length:buf.length freeWhenDone:NO]
                writeToFile:[dir stringByAppendingPathComponent:name] atomically:YES];
            m[f[1]] = name;
          }
          [metas addObject:m];
        }
        NSDictionary *root = @{
          @"format" : @1, @"frameID" : @(dumpFrameID), @"weightsFnv64" : [NSString stringWithFormat:@"%016llx", dumpHash],
          @"weightsPath" : dumpWeights ?: @"", @"eyes" : metas,
        };
        NSData *json = [NSJSONSerialization dataWithJSONObject:root options:NSJSONWritingPrettyPrinted error:nil];
        [json writeToFile:[dir stringByAppendingPathComponent:@"meta.json"] atomically:YES];
        NSLog(@"[WindowsVRNeural] Neural tensor dump written: %@ (%lu eyes)", dir, (unsigned long)metas.count);
      }];
    } else if (dumpEntries) {
      NSLog(@"[WindowsVRNeural] Neural tensor dump armed but no eye ran VRFovealNet this frame");
    }

    if (sNeuralGpuTimingEnabled) {
      std::shared_ptr<WVRNeuralGpuTimingState> timing = ctx->timing;
      if (sampleBuf) {
        if (sNeuralGpuTimingMode == 2) {
          [cmd addCompletedHandler:^(id<MTLCommandBuffer> cb) {
            if (cb.status != MTLCommandBufferStatusCompleted) return;

            constexpr uint32_t kMode2SampleCount = 2 * STAGE_COUNT;
            NSData *data = [sampleBuf resolveCounterRange:NSMakeRange(0, kMode2SampleCount)];
            if (!data || data.length < kMode2SampleCount * sizeof(MTLCounterResultTimestamp)) return;

            const MTLCounterResultTimestamp *results = (const MTLCounterResultTimestamp *)data.bytes;

            auto updateEma = [](std::atomic<float> &emaAtom, float valUs) {
              float prev = emaAtom.load(std::memory_order_relaxed);
              float next;
              do {
                next = (prev <= 0.0f) ? valUs : (prev * 0.9f + valUs * 0.1f);
              } while (!emaAtom.compare_exchange_weak(prev, next, std::memory_order_relaxed));
            };

            for (uint32_t s = 0; s < STAGE_COUNT; ++s) {
              if (!(stagesEncodedMask & (1u << s))) continue;
              uint64_t t0 = results[2 * s].timestamp;
              uint64_t t1 = results[2 * s + 1].timestamp;
              if (t0 == MTLCounterErrorValue || t1 == MTLCounterErrorValue) continue;
              if (t1 > t0) {
                float us = float(t1 - t0) * 1e-3f;
                updateEma(timing->stageEmaUs[s], us);
              }
            }

            if (cb.GPUEndTime > cb.GPUStartTime) {
              float totalUs = float((cb.GPUEndTime - cb.GPUStartTime) * 1e6);
              updateEma(timing->totalGpuUs, totalUs);
            }
          }];
        } else {
        const bool ranRecon = !reuseRecon && !useFSR && !useMetalFX;
        const bool hadStereoWarp = ranRecon && depthValid;
        const bool hadObjMotion = !reuseRecon && objMotionOn;
        const bool hadHistoryCopy = !reuseRecon && depthValid;

        [cmd addCompletedHandler:^(id<MTLCommandBuffer> cb) {
          if (cb.status != MTLCommandBufferStatusCompleted) return;

          // On Apple Silicon GPUs (such as M2 on Apple Vision Pro), timestamp counter ticks
          // in MTLCommonCounterSetTimestamp are calibrated directly in nanoseconds (1 tick = 1 ns).
          // (Alternatively, device sampleTimestamps:gpuTimestamp: correlates CPU/GPU domain clocks,
          // but for delta duration within the same GPU command buffer, 1 tick == 1 ns).
          // Converting nanoseconds to microseconds: us = delta_ticks * 1e-3f.
          NSData *data = [sampleBuf resolveCounterRange:NSMakeRange(0, kTimingSampleCount)];
          if (!data || data.length < kTimingSampleCount * sizeof(MTLCounterResultTimestamp)) return;

          const MTLCounterResultTimestamp *results = (const MTLCounterResultTimestamp *)data.bytes;
          uint64_t t[kTimingSampleCount];
          for (uint32_t i = 0; i < kTimingSampleCount; ++i) {
            t[i] = results[i].timestamp;
          }

          auto updateEma = [](std::atomic<float> &emaAtom, float valUs) {
            float prev = emaAtom.load(std::memory_order_relaxed);
            float next;
            do {
              next = (prev <= 0.0f) ? valUs : (prev * 0.9f + valUs * 0.1f);
            } while (!emaAtom.compare_exchange_weak(prev, next, std::memory_order_relaxed));
          };

          if (ranRecon) {
            if (hadStereoWarp && t[STAGE_AFW_FOVEAL] > t[STAGE_YORO_WARP]) {
              float us = float(t[STAGE_AFW_FOVEAL] - t[STAGE_YORO_WARP]) * 1e-3f;
              updateEma(timing->stageEmaUs[STAGE_YORO_WARP], us);
            }
            if (t[STAGE_SPLICE] > t[STAGE_AFW_FOVEAL]) {
              float us = float(t[STAGE_SPLICE] - t[STAGE_AFW_FOVEAL]) * 1e-3f;
              updateEma(timing->stageEmaUs[STAGE_AFW_FOVEAL], us);
            }
            if (t[STAGE_RCAS_UI] > t[STAGE_SPLICE]) {
              float us = float(t[STAGE_RCAS_UI] - t[STAGE_SPLICE]) * 1e-3f;
              updateEma(timing->stageEmaUs[STAGE_SPLICE], us);
            }
            if (t[STAGE_OBJECT_MOTION] > t[STAGE_RCAS_UI]) {
              float us = float(t[STAGE_OBJECT_MOTION] - t[STAGE_RCAS_UI]) * 1e-3f;
              updateEma(timing->stageEmaUs[STAGE_RCAS_UI], us);
            }
            if (hadObjMotion && t[STAGE_EXTRAP] > t[STAGE_OBJECT_MOTION]) {
              float us = float(t[STAGE_EXTRAP] - t[STAGE_OBJECT_MOTION]) * 1e-3f;
              updateEma(timing->stageEmaUs[STAGE_OBJECT_MOTION], us);
            }
          }

          if (t[STAGE_HISTORY_COPY] > t[STAGE_EXTRAP]) {
            float us = float(t[STAGE_HISTORY_COPY] - t[STAGE_EXTRAP]) * 1e-3f;
            updateEma(timing->stageEmaUs[STAGE_EXTRAP], us);
          }

          if (hadHistoryCopy && t[STAGE_END] > t[STAGE_HISTORY_COPY]) {
            float us = float(t[STAGE_END] - t[STAGE_HISTORY_COPY]) * 1e-3f;
            updateEma(timing->stageEmaUs[STAGE_HISTORY_COPY], us);
          }

          if (cb.GPUEndTime > cb.GPUStartTime) {
            float totalUs = float((cb.GPUEndTime - cb.GPUStartTime) * 1e6);
            updateEma(timing->totalGpuUs, totalUs);
          }
        }];
        }
      } else {
        // Fallback: command-buffer-level timing only via cb.GPUStartTime / cb.GPUEndTime
        [cmd addCompletedHandler:^(id<MTLCommandBuffer> cb) {
          if (cb.status == MTLCommandBufferStatusCompleted && cb.GPUEndTime > cb.GPUStartTime) {
            float totalUs = float((cb.GPUEndTime - cb.GPUStartTime) * 1e6);
            float prev = timing->totalGpuUs.load(std::memory_order_relaxed);
            float next;
            do {
              next = (prev <= 0.0f) ? totalUs : (prev * 0.9f + totalUs * 0.1f);
            } while (!timing->totalGpuUs.compare_exchange_weak(prev, next, std::memory_order_relaxed));
          }
        }];
      }
    }

    return 0;
  }
}

// Native C++ In-App Live Dynamic Resolution Governor
// Replaces offline Python scripts with real-time C++ execution on visionOS.
namespace {
struct LiveDynamicGovernor {
  float targetMs = 9.5f;
  float currentScale = 0.75f;
  float currentFoveaDeg = 14.0f;
  float integralErr = 0.0f;
  float lastMeasuredMs = 9.5f;
  uint32_t extrapRatio = 1;

  void update(float measuredMs) {
    lastMeasuredMs = measuredMs;
    float err = targetMs - measuredMs;
    integralErr = std::clamp(integralErr + err * 0.1f, -5.0f, 5.0f);

    float delta = err * 0.04f + integralErr * 0.01f;
    currentScale = std::clamp(currentScale + delta, 0.50f, 1.0f);

    float norm = (currentScale - 0.50f) / 0.50f;
    currentFoveaDeg = 11.0f + norm * 5.0f;

    if (measuredMs > 35.0f) extrapRatio = 4;
    else if (measuredMs > 22.0f) extrapRatio = 3;
    else if (measuredMs > 12.0f) extrapRatio = 2;
    else extrapRatio = 1;
  }

  WVRDynamicGovernorStatusV1 getStatus() const {
    WVRDynamicGovernorStatusV1 s{};
    s.measuredGPUFrameTimeMs = lastMeasuredMs;
    s.currentRenderScale = currentScale;
    s.currentFoveaRadiusDeg = currentFoveaDeg;
    s.mipLodBias = std::log2(std::max(0.1f, currentScale)) - 0.25f;
    s.extrapolationRatio = extrapRatio;
    return s;
  }
};
LiveDynamicGovernor s_liveGovernor;
} // namespace

extern "C" void wvr_neural_drs_update_v1(WVRNeuralContext *ctx, float measuredFrameMs) {
  s_liveGovernor.update(measuredFrameMs);
}

extern "C" WVRDynamicGovernorStatusV1 wvr_neural_drs_get_status_v1(WVRNeuralContext *ctx) {
  return s_liveGovernor.getStatus();
}

extern "C" WVRNetworkPacingStatusV1 wvr_neural_drs_get_pacing_v1(WVRNeuralContext *ctx) {
  auto drs = s_liveGovernor.getStatus();
  WVRNetworkPacingStatusV1 p{};
  if (drs.measuredGPUFrameTimeMs > 25.0f) {
    p.targetBitrateMbps = 45.0f;
    p.intraRefreshRate = 12;
    p.sliceCount = 8;
    p.dropNonEssentialSlices = true;
  } else if (drs.measuredGPUFrameTimeMs > 15.0f) {
    p.targetBitrateMbps = 75.0f;
    p.intraRefreshRate = 24;
    p.sliceCount = 4;
    p.dropNonEssentialSlices = false;
  } else {
    p.targetBitrateMbps = 110.0f;
    p.intraRefreshRate = 60;
    p.sliceCount = 2;
    p.dropNonEssentialSlices = false;
  }
  return p;
}

extern "C" int32_t wvr_neural_load_splats_v1(WVRNeuralContext *ctx, const char *path) {
  @autoreleasepool {
    if (!ctx) return -1;
    std::lock_guard lock(ctx->mutex);

    NSString *filePath = nil;
    if (path && strlen(path) > 0) {
      filePath = [NSString stringWithUTF8String:path];
    }
    if (!filePath || ![[NSFileManager defaultManager] fileExistsAtPath:filePath]) {
      filePath = [[NSBundle mainBundle] pathForResource:@"foveated_scene" ofType:@"wvrg"];
    }
    if (!filePath || ![[NSFileManager defaultManager] fileExistsAtPath:filePath]) {
      NSString *bundlePath = [[NSBundle mainBundle] bundlePath];
      filePath = [bundlePath stringByAppendingPathComponent:@"Resources/WindowsVR/foveated_scene.wvrg"];
    }
    if (!filePath || ![[NSFileManager defaultManager] fileExistsAtPath:filePath]) {
      filePath = @"visionos-windows-vr/Resources/WindowsVR/foveated_scene.wvrg";
    }
    if (!filePath || ![[NSFileManager defaultManager] fileExistsAtPath:filePath]) {
      return -2; // File not found
    }

    NSData *data = [NSData dataWithContentsOfFile:filePath options:NSDataReadingMappedIfSafe error:nil];
    if (!data || data.length < sizeof(WVRGaussianSplatHeaderV1)) {
      return -3; // Invalid file length
    }

    const auto *hdr = (const WVRGaussianSplatHeaderV1 *)data.bytes;
    if (hdr->magic != WVR_GAUSSIAN_SPLATS_MAGIC || hdr->version != 1) {
      return -4; // Magic / version mismatch
    }

    uint32_t N = hdr->numSplats;
    size_t expectedBytes = sizeof(WVRGaussianSplatHeaderV1) +
                           N * (2 + 3 + 3 + 1 + 1) * sizeof(float);
    if (data.length < expectedBytes) {
      return -5; // Truncated splat data
    }

    const float *posPtr = (const float *)((const uint8_t *)data.bytes + sizeof(WVRGaussianSplatHeaderV1));
    const float *covPtr = posPtr + N * 2;
    const float *colPtr = covPtr + N * 3;
    const float *opaPtr = colPtr + N * 3;
    const float *depPtr = opaPtr + N * 1;

    std::vector<WVRGaussianPrimitiveV1> interleaved(N);
    for (uint32_t i = 0; i < N; ++i) {
      interleaved[i].x = posPtr[i * 2 + 0];
      interleaved[i].y = posPtr[i * 2 + 1];
      interleaved[i].cov_xx = covPtr[i * 3 + 0];
      interleaved[i].cov_xy = covPtr[i * 3 + 1];
      interleaved[i].cov_yy = covPtr[i * 3 + 2];
      interleaved[i].r = colPtr[i * 3 + 0];
      interleaved[i].g = colPtr[i * 3 + 1];
      interleaved[i].b = colPtr[i * 3 + 2];
      interleaved[i].opacity = opaPtr[i];
      interleaved[i].depth = depPtr[i];
    }

    size_t bufferSize = N * sizeof(WVRGaussianPrimitiveV1);
    ctx->splatsBuffer = [ctx->device newBufferWithBytes:interleaved.data()
                                                 length:bufferSize
                                                options:MTLResourceStorageModeShared];
    ctx->splatsCount = (ctx->splatsBuffer != nil) ? N : 0;
    return ctx->splatsCount > 0 ? 0 : -6;
  }
}

extern "C" int32_t wvr_neural_rasterize_splats_v1(
    WVRNeuralContext *ctx,
    void *commandBuffer,
    void *targetTexture,
    uint32_t width,
    uint32_t height)
{
  @autoreleasepool {
    if (!ctx || !commandBuffer || !targetTexture) return -1;
    id<MTLCommandBuffer> cmd = (__bridge id<MTLCommandBuffer>)commandBuffer;
    id<MTLTexture> target = (__bridge id<MTLTexture>)targetTexture;

    std::lock_guard lock(ctx->mutex);
    if (ctx->splatsCount == 0 || !ctx->splatsBuffer || !ctx->pGaussianSplatComposite) {
      return 0; // No splats active or pipeline not available
    }

    id<MTLComputeCommandEncoder> enc = [cmd computeCommandEncoder];
    if (!enc) return -1;

    struct {
      uint32_t width;
      uint32_t height;
      uint32_t numSplats;
      uint32_t pad0;
    } p{};
    p.width = width;
    p.height = height;
    p.numSplats = ctx->splatsCount;

    [enc setComputePipelineState:ctx->pGaussianSplatComposite];
    [enc setTexture:target atIndex:0];
    [enc setBuffer:ctx->splatsBuffer offset:0 atIndex:0];
    [enc setBytes:&p length:sizeof(p) atIndex:1];

    MTLSize tg = MTLSizeMake(16, 16, 1);
    MTLSize grid = MTLSizeMake((width + 15) / 16, (height + 15) / 16, 1);
    [enc dispatchThreadgroups:grid threadsPerThreadgroup:tg];
    [enc endEncoding];
    return 0;
  }
}

extern "C" int32_t wvr_neural_load_coreml_model_v1(WVRNeuralContext *ctx, const char *modelPath) {
  @autoreleasepool {
    if (!ctx) return -1;
    std::lock_guard lock(ctx->mutex);

#if __has_include(<CoreML/CoreML.h>)
    NSString *path = nil;
    if (modelPath && strlen(modelPath) > 0) {
      path = [NSString stringWithUTF8String:modelPath];
    }
    if (!path || ![[NSFileManager defaultManager] fileExistsAtPath:path]) {
      path = [[NSBundle mainBundle] pathForResource:@"vr_foveal_ane" ofType:@"mlmodelc"];
    }
    if (!path || ![[NSFileManager defaultManager] fileExistsAtPath:path]) {
      path = [[NSBundle mainBundle] pathForResource:@"param_net_lite" ofType:@"mlmodelc"];
    }
    if (!path || ![[NSFileManager defaultManager] fileExistsAtPath:path]) {
      NSString *bundlePath = [[NSBundle mainBundle] bundlePath];
      path = [bundlePath stringByAppendingPathComponent:@"Resources/WindowsVR/vr_foveal_ane.mlmodelc"];
    }
    if (!path || ![[NSFileManager defaultManager] fileExistsAtPath:path]) {
      return -2; // CoreML compiled model package not found
    }

    NSURL *modelURL = [NSURL fileURLWithPath:path];
    MLModelConfiguration *config = [[MLModelConfiguration alloc] init];
    // Target Vision Pro 16-core Apple Neural Engine
    config.computeUnits = MLComputeUnitsCPUAndNeuralEngine;

    NSError *error = nil;
    MLModel *model = [MLModel modelWithContentsOfURL:modelURL configuration:config error:&error];
    if (!model || error) {
      NSLog(@"[WindowsVRNeural] Failed to load CoreML ANE model: %@", error);
      return -3;
    }

    ctx->coreMLModel = (void *)CFBridgingRetain(model);
    ctx->aneLoaded = true;
    NSLog(@"[WindowsVRNeural] Successfully offloaded Gaussian Splat / Foveal model to Apple Neural Engine (ANE)!");
    return 0;
#else
    return -4; // CoreML framework not available in this build environment
#endif
  }
}

extern "C" int32_t wvr_neural_predict_ane_v1(
    WVRNeuralContext *ctx,
    void *inputIOSurface,
    void *outputIOSurface)
{
  @autoreleasepool {
    if (!ctx || !ctx->aneLoaded || !ctx->coreMLModel || !inputIOSurface) {
      return -1;
    }
#if __has_include(<CoreML/CoreML.h>)
    MLModel *model = (__bridge MLModel *)ctx->coreMLModel;
    IOSurfaceRef inSurf = (__bridge IOSurfaceRef)inputIOSurface;

    CVPixelBufferRef pixelBuffer = NULL;
    CVReturn status = CVPixelBufferCreateWithIOSurface(kCFAllocatorDefault, inSurf, NULL, &pixelBuffer);
    if (status != kCVReturnSuccess || !pixelBuffer) {
      return -2;
    }

    // Zero-copy ANE evaluation on Apple Silicon Unified Memory
    NSError *error = nil;
    MLFeatureValue *inVal = [MLFeatureValue featureValueWithPixelBuffer:pixelBuffer];
    CVPixelBufferRelease(pixelBuffer);

    NSDictionary *dict = @{@"foveal_inputs": inVal};
    MLDictionaryFeatureProvider *provider = [[MLDictionaryFeatureProvider alloc] initWithDictionary:dict error:&error];
    if (!provider || error) return -3;

    id<MLFeatureProvider> outProvider = [model predictionFromFeatures:provider error:&error];
    if (!outProvider || error) return -4;

    return 0;
#else
    return -5;
#endif
  }
}

extern "C" int32_t wvr_neural_copy_stats_v1(WVRNeuralContext *ctx, char *buffer, uint32_t capacity) {
  if (!ctx || !buffer || !capacity) return 0;
  std::lock_guard lock(ctx->mutex);
  int n = snprintf(buffer, capacity,
                   "neural_foveal weights=%s fovealJobs=%llu stereoWarpJobs=%llu temporalWarpJobs=%llu extrapJobs=%llu extrapRateMapJobs=%llu objectMotionJobs=%llu tiledConvJobs=%llu naiveConvJobs=%llu reconReuses=%llu fsrEnabled=%d fsrJobs=%llu gazeRadiusL=%.4f gazeRadiusR=%.4f cropHRL=%u cropHRR=%u metalfxJobs=%llu "
                   "path=[neural=%llu noFlag=%llu noWeights=%llu noHist=%llu noStereoB=%llu noDepthFrames=%llu upscalerFrames=%llu] weightsFnv64=%016llx",
                   ctx->aneLoaded ? "apple-neural-engine" : (ctx->weightsLoaded ? "gpu-conv-loaded" : "analytical-fallback"),
                   (unsigned long long)ctx->fovealJobs.load(),
                   (unsigned long long)ctx->stereoWarpJobs.load(),
                   (unsigned long long)ctx->temporalWarpJobs.load(),
                   (unsigned long long)ctx->extrapJobs.load(),
                   (unsigned long long)ctx->extrapRateMapJobs.load(),
                   (unsigned long long)ctx->objectMotionJobs.load(),
                   (unsigned long long)ctx->tiledConvJobs.load(),
                   (unsigned long long)ctx->naiveConvJobs.load(),
                   (unsigned long long)ctx->reconReuses.load(),
                   fsr3UpscaleEnabled() ? 1 : 0,
                   (unsigned long long)ctx->fsrJobs.load(),
                   ctx->lastGazeRadiusUV[0],
                   ctx->lastGazeRadiusUV[1],
                   ctx->lastCropHR[0],
                   ctx->lastCropHR[1],
                   (unsigned long long)ctx->metalfxJobs.load(),
                   (unsigned long long)ctx->passNeural.load(),
                   (unsigned long long)ctx->passAnalyticalNoFlag.load(),
                   (unsigned long long)ctx->passAnalyticalNoWeights.load(),
                   (unsigned long long)ctx->passNoHistory.load(),
                   (unsigned long long)ctx->passNoStereo.load(),
                   (unsigned long long)ctx->framesNoDepth.load(),
                   (unsigned long long)ctx->framesUpscaler.load(),
                   (unsigned long long)ctx->weightsHash);
  if (n < 0) {
    buffer[0] = '\0';
    return 0;
  }
  if (sNeuralGpuTimingEnabled && uint32_t(n) < capacity - 1) {
    int extra = 0;
    if (ctx->timingCounterSamplingSupported) {
      extra = snprintf(buffer + n, capacity - uint32_t(n),
                       " gpuStagesUs=[yoro=%.1f obj=%.1f afw_fov=%.1f splice=%.1f rcas=%.1f extrap=%.1f hist=%.1f cbTotal=%.1f]",
                       ctx->timing->stageEmaUs[STAGE_YORO_WARP].load(std::memory_order_relaxed),
                       ctx->timing->stageEmaUs[STAGE_OBJECT_MOTION].load(std::memory_order_relaxed),
                       ctx->timing->stageEmaUs[STAGE_AFW_FOVEAL].load(std::memory_order_relaxed),
                       ctx->timing->stageEmaUs[STAGE_SPLICE].load(std::memory_order_relaxed),
                       ctx->timing->stageEmaUs[STAGE_RCAS_UI].load(std::memory_order_relaxed),
                       ctx->timing->stageEmaUs[STAGE_EXTRAP].load(std::memory_order_relaxed),
                       ctx->timing->stageEmaUs[STAGE_HISTORY_COPY].load(std::memory_order_relaxed),
                       ctx->timing->totalGpuUs.load(std::memory_order_relaxed));
    } else {
      extra = snprintf(buffer + n, capacity - uint32_t(n),
                       " gpuCbTotalUs=%.1f",
                       ctx->timing->totalGpuUs.load(std::memory_order_relaxed));
    }
    if (extra > 0) {
      n += std::min(extra, int(capacity - uint32_t(n)) - 1);
    }
  }
  if (sNeuralGpuTimingEnabled) {
    static uint32_t sLogThrottler = 0;
    if ((++sLogThrottler % 90) == 0) {
      if (ctx->timingCounterSamplingSupported) {
        NSLog(@"[WindowsVRNeural] GPU stage timings EMA (us): yoro=%.1f obj=%.1f afw_fov=%.1f splice=%.1f rcas=%.1f extrap=%.1f hist=%.1f | cbTotal=%.1f us (%.2f ms)",
              ctx->timing->stageEmaUs[STAGE_YORO_WARP].load(std::memory_order_relaxed),
              ctx->timing->stageEmaUs[STAGE_OBJECT_MOTION].load(std::memory_order_relaxed),
              ctx->timing->stageEmaUs[STAGE_AFW_FOVEAL].load(std::memory_order_relaxed),
              ctx->timing->stageEmaUs[STAGE_SPLICE].load(std::memory_order_relaxed),
              ctx->timing->stageEmaUs[STAGE_RCAS_UI].load(std::memory_order_relaxed),
              ctx->timing->stageEmaUs[STAGE_EXTRAP].load(std::memory_order_relaxed),
              ctx->timing->stageEmaUs[STAGE_HISTORY_COPY].load(std::memory_order_relaxed),
              ctx->timing->totalGpuUs.load(std::memory_order_relaxed),
              ctx->timing->totalGpuUs.load(std::memory_order_relaxed) * 0.001f);
      } else {
        NSLog(@"[WindowsVRNeural] GPU command buffer EMA: %.1f us (%.2f ms)",
              ctx->timing->totalGpuUs.load(std::memory_order_relaxed),
              ctx->timing->totalGpuUs.load(std::memory_order_relaxed) * 0.001f);
      }
    }
  }
  if (ctx->fsr[0] && uint32_t(n) < capacity - 1) {
    char fsrBuf[256];
    if (wvr_fsr3_copy_stats_v1(ctx->fsr[0], fsrBuf, sizeof(fsrBuf)) > 0) {
      int extra = snprintf(buffer + n, capacity - uint32_t(n), " fsr0: %s", fsrBuf);
      if (extra > 0) {
        n += std::min(extra, int(capacity - uint32_t(n)) - 1);
      }
    }
  }
  if (ctx->metalfx[0] && uint32_t(n) < capacity - 1) {
    char mfxBuf[256];
    if (wvr_metalfx_copy_stats_v1(ctx->metalfx[0], mfxBuf, sizeof(mfxBuf)) > 0) {
      int extra = snprintf(buffer + n, capacity - uint32_t(n), " metalfx0: %s", mfxBuf);
      if (extra > 0) {
        n += std::min(extra, int(capacity - uint32_t(n)) - 1);
      }
    }
  }
  return int32_t(std::min<uint32_t>(uint32_t(n), capacity - 1u));
}
