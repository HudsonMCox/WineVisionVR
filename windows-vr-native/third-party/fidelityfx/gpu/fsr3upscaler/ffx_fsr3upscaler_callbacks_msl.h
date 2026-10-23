// This file is part of the FidelityFX SDK.
//
// Copyright (C) 2024 Advanced Micro Devices, Inc.
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files(the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and /or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions :
//
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
// THE SOFTWARE.

//==============================================================================================================================
// Companion program-scope section (samplers + constant buffer structs).
// Either:
//   1. Define FFX_FSR3UPSCALER_MSL_SAMPLERS_ONLY and #include this header at program scope before the pass struct, OR
//   2. Define FFX_FSR3UPSCALER_MSL_SAMPLERS and declare s_PointClamp / s_LinearClamp at program scope before the pass struct,
//      then #include this header inside the pass struct body.
//==============================================================================================================================
#ifndef FFX_FSR3UPSCALER_MSL_SAMPLERS
#define FFX_FSR3UPSCALER_MSL_SAMPLERS

constexpr sampler s_PointClamp(
    coord::normalized,
    address::clamp_to_edge,
    filter::nearest,
    mip_filter::nearest
);

constexpr sampler s_LinearClamp(
    coord::normalized,
    address::clamp_to_edge,
    filter::linear,
    mip_filter::linear
);

#endif // !defined(FFX_FSR3UPSCALER_MSL_SAMPLERS)

#ifndef FFX_FSR3UPSCALER_MSL_CB_TYPES
#define FFX_FSR3UPSCALER_MSL_CB_TYPES

// Mirrors HLSL cbuffer cbFSR3Upscaler layout in ffx_fsr3upscaler_callbacks_hlsl.h exactly (160 bytes / 40 dwords).
struct Fsr3UpscalerConstants
{
    FfxInt32x2    iRenderSize;
    FfxInt32x2    iPreviousFrameRenderSize;

    FfxInt32x2    iUpscaleSize;
    FfxInt32x2    iPreviousFrameUpscaleSize;

    FfxInt32x2    iMaxRenderSize;
    FfxInt32x2    iMaxUpscaleSize;

    FfxFloat32x4  fDeviceToViewDepth;

    FfxFloat32x2  fJitter;
    FfxFloat32x2  fPreviousFrameJitter;

    FfxFloat32x2  fMotionVectorScale;
    FfxFloat32x2  fDownscaleFactor;

    FfxFloat32x2  fMotionVectorJitterCancellation;
    FfxFloat32    fTanHalfFOV;
    FfxFloat32    fJitterSequenceLength;

    FfxFloat32    fDeltaTime;
    FfxFloat32    fDeltaPreExposure;
    FfxFloat32    fViewSpaceToMetersFactor;
    FfxFloat32    fFrameIndex;

    FfxFloat32    fVelocityFactor;
    FfxFloat32    fReactivenessScale;
    FfxFloat32    fShadingChangeScale;
    FfxFloat32    fAccumulationAddedPerFrame;
    FfxFloat32    fMinDisocclusionAccumulation;
    FfxFloat32    fPad[3];
};

// Mirrors HLSL cbuffer cbGenerateReactive (FSR3UPSCALER_BIND_CB_AUTOREACTIVE).
struct FfxAutoReactiveConstants
{
    FfxFloat32    fTcThreshold;
    FfxFloat32    fTcScale;
    FfxFloat32    fReactiveScale;
    FfxFloat32    fReactiveMax;
};

// Mirrors HLSL cbuffer cbRCAS (FSR3UPSCALER_BIND_CB_RCAS).
struct FfxRcasConstants
{
    FfxUInt32x4   rcasConfig;
};

// Mirrors HLSL cbuffer cbGenerateReactive (FSR3UPSCALER_BIND_CB_REACTIVE).
struct FfxGenerateReactiveConstants
{
    FfxFloat32    gen_reactive_scale;
    FfxFloat32    gen_reactive_threshold;
    FfxFloat32    gen_reactive_binaryValue;
    FfxUInt32     gen_reactive_flags;
};

// Mirrors HLSL cbuffer cbSPD (FSR3UPSCALER_BIND_CB_SPD).
struct FfxSpdConstants
{
    FfxUInt32     mips;
    FfxUInt32     numWorkGroups;
    FfxUInt32x2   workGroupOffset;
    FfxUInt32x2   renderSize;
};

#endif // !defined(FFX_FSR3UPSCALER_MSL_CB_TYPES)

//==============================================================================================================================
// Pass struct member declarations and accessor member functions (included inside a pass struct body).
//==============================================================================================================================
#if !defined(FFX_FSR3UPSCALER_MSL_SAMPLERS_ONLY) && defined(FFX_GPU) && defined(FFX_MSL)

#if defined(FSR3UPSCALER_BIND_CB_FSR3UPSCALER)
constant Fsr3UpscalerConstants& cb;

FfxInt32x2 RenderSize()
{
    return cb.iRenderSize;
}

FfxInt32x2 PreviousFrameRenderSize()
{
    return cb.iPreviousFrameRenderSize;
}

FfxInt32x2 MaxRenderSize()
{
    return cb.iMaxRenderSize;
}

FfxInt32x2 UpscaleSize()
{
    return cb.iUpscaleSize;
}

FfxInt32x2 PreviousFrameUpscaleSize()
{
    return cb.iPreviousFrameUpscaleSize;
}

FfxInt32x2 MaxUpscaleSize()
{
    return cb.iMaxUpscaleSize;
}

FfxFloat32x2 Jitter()
{
    return cb.fJitter;
}

FfxFloat32x2 PreviousFrameJitter()
{
    return cb.fPreviousFrameJitter;
}

FfxFloat32x4 DeviceToViewSpaceTransformFactors()
{
    return cb.fDeviceToViewDepth;
}

FfxFloat32x2 MotionVectorScale()
{
    return cb.fMotionVectorScale;
}

FfxFloat32x2 DownscaleFactor()
{
    return cb.fDownscaleFactor;
}

FfxFloat32x2 MotionVectorJitterCancellation()
{
    return cb.fMotionVectorJitterCancellation;
}

FfxFloat32 TanHalfFoV()
{
    return cb.fTanHalfFOV;
}

FfxFloat32 JitterSequenceLength()
{
    return cb.fJitterSequenceLength;
}

FfxFloat32 DeltaTime()
{
    return cb.fDeltaTime;
}

FfxFloat32 DeltaPreExposure()
{
    return cb.fDeltaPreExposure;
}

FfxFloat32 ViewSpaceToMetersFactor()
{
    return cb.fViewSpaceToMetersFactor;
}

FfxFloat32 FrameIndex()
{
    return cb.fFrameIndex;
}

FfxFloat32 VelocityFactor()
{
    return cb.fVelocityFactor;
}

FfxFloat32 AccumulationAddedPerFrame()
{
    return cb.fAccumulationAddedPerFrame;
}

FfxFloat32 MinDisocclusionAccumulation()
{
    return cb.fMinDisocclusionAccumulation;
}
#endif // #if defined(FSR3UPSCALER_BIND_CB_FSR3UPSCALER)

#if defined(FSR3UPSCALER_BIND_CB_AUTOREACTIVE)
constant FfxAutoReactiveConstants* cbAutoReactive;

FfxFloat32 TcThreshold()
{
    return cbAutoReactive->fTcThreshold;
}

FfxFloat32 TcScale()
{
    return cbAutoReactive->fTcScale;
}

FfxFloat32 ReactiveScale()
{
    return cbAutoReactive->fReactiveScale;
}

FfxFloat32 ReactiveMax()
{
    return cbAutoReactive->fReactiveMax;
}
#endif // #if defined(FSR3UPSCALER_BIND_CB_AUTOREACTIVE)

#if defined(FSR3UPSCALER_BIND_CB_RCAS)
constant FfxRcasConstants* cbRCAS;

FfxUInt32x4 RCASConfig()
{
    return cbRCAS->rcasConfig;
}
#endif // #if defined(FSR3UPSCALER_BIND_CB_RCAS)

#if defined(FSR3UPSCALER_BIND_CB_REACTIVE)
constant FfxGenerateReactiveConstants* cbGenerateReactive;

FfxFloat32 GenReactiveScale()
{
    return cbGenerateReactive->gen_reactive_scale;
}

FfxFloat32 GenReactiveThreshold()
{
    return cbGenerateReactive->gen_reactive_threshold;
}

FfxFloat32 GenReactiveBinaryValue()
{
    return cbGenerateReactive->gen_reactive_binaryValue;
}

FfxUInt32 GenReactiveFlags()
{
    return cbGenerateReactive->gen_reactive_flags;
}
#endif // #if defined(FSR3UPSCALER_BIND_CB_REACTIVE)

#if defined(FSR3UPSCALER_BIND_CB_SPD)
constant FfxSpdConstants* cbSPD;

FfxUInt32 MipCount()
{
    return cbSPD->mips;
}

FfxUInt32 NumWorkGroups()
{
    return cbSPD->numWorkGroups;
}

FfxUInt32x2 WorkGroupOffset()
{
    return cbSPD->workGroupOffset;
}

FfxUInt32x2 SPD_RenderSize()
{
    return cbSPD->renderSize;
}
#endif // #if defined(FSR3UPSCALER_BIND_CB_SPD)

#if defined(FSR3UPSCALER_BIND_SRV_SPD_MIPS)
texture2d<FfxFloat32, access::sample> r_spd_mips;

FfxInt32x2 GetSPDMipDimensions(FfxUInt32 uMipLevel)
{
    return FfxInt32x2(r_spd_mips.get_width(uMipLevel), r_spd_mips.get_height(uMipLevel));
}

FfxFloat32x2 SampleSPDMipLevel(FfxFloat32x2 fUV, FfxUInt32 mipLevel)
{
    return r_spd_mips.sample(s_LinearClamp, fUV, level(FfxFloat32(mipLevel))).xy;
}
#endif // #if defined(FSR3UPSCALER_BIND_SRV_SPD_MIPS)

#if defined(FSR3UPSCALER_BIND_SRV_INPUT_DEPTH)
texture2d<FfxFloat32, access::sample> r_input_depth;

FfxFloat32 LoadInputDepth(FfxUInt32x2 iPxPos)
{
    return r_input_depth.read(iPxPos, 0).x;
}

FfxFloat32 LoadInputDepth(FfxInt32x2 iPxPos)
{
    return r_input_depth.read(FfxUInt32x2(iPxPos), 0).x;
}

FfxFloat32 SampleInputDepth(FfxFloat32x2 fUV)
{
    return r_input_depth.sample(s_LinearClamp, fUV, level(0.0f)).x;
}
#endif // #if defined(FSR3UPSCALER_BIND_SRV_INPUT_DEPTH)

#if defined(FSR3UPSCALER_BIND_SRV_REACTIVE_MASK)
texture2d<FfxFloat32, access::sample> r_reactive_mask;

FfxFloat32 LoadReactiveMask(FfxUInt32x2 iPxPos)
{
    return r_reactive_mask.read(iPxPos, 0).x * cb.fReactivenessScale;
}

FfxFloat32 LoadReactiveMask(FfxInt32x2 iPxPos)
{
    return r_reactive_mask.read(FfxUInt32x2(iPxPos), 0).x * cb.fReactivenessScale;
}

FfxInt32x2 GetReactiveMaskResourceDimensions()
{
    return FfxInt32x2(r_reactive_mask.get_width(), r_reactive_mask.get_height());
}

FfxFloat32 SampleReactiveMask(FfxFloat32x2 fUV)
{
    return r_reactive_mask.sample(s_LinearClamp, fUV, level(0.0f)).x * cb.fReactivenessScale;
}
#endif // #if defined(FSR3UPSCALER_BIND_SRV_REACTIVE_MASK)

#if defined(FSR3UPSCALER_BIND_SRV_TRANSPARENCY_AND_COMPOSITION_MASK)
texture2d<FfxFloat32, access::sample> r_transparency_and_composition_mask;

FfxFloat32 LoadTransparencyAndCompositionMask(FfxUInt32x2 iPxPos)
{
    return r_transparency_and_composition_mask.read(iPxPos, 0).x;
}

FfxFloat32 LoadTransparencyAndCompositionMask(FfxInt32x2 iPxPos)
{
    return r_transparency_and_composition_mask.read(FfxUInt32x2(iPxPos), 0).x;
}

FfxInt32x2 GetTransparencyAndCompositionMaskResourceDimensions()
{
    return FfxInt32x2(r_transparency_and_composition_mask.get_width(), r_transparency_and_composition_mask.get_height());
}

FfxFloat32 SampleTransparencyAndCompositionMask(FfxFloat32x2 fUV)
{
    return r_transparency_and_composition_mask.sample(s_LinearClamp, fUV, level(0.0f)).x;
}
#endif // #if defined(FSR3UPSCALER_BIND_SRV_TRANSPARENCY_AND_COMPOSITION_MASK)

#if defined(FSR3UPSCALER_BIND_SRV_INPUT_COLOR)
texture2d<FfxFloat32, access::sample> r_input_color_jittered;

FfxFloat32x3 LoadInputColor(FfxUInt32x2 iPxPos)
{
    return r_input_color_jittered.read(iPxPos, 0).rgb;
}

FfxFloat32x3 LoadInputColor(FfxInt32x2 iPxPos)
{
    return r_input_color_jittered.read(FfxUInt32x2(iPxPos), 0).rgb;
}

FfxFloat32x3 SampleInputColor(FfxFloat32x2 fUV)
{
    return r_input_color_jittered.sample(s_LinearClamp, fUV, level(0.0f)).rgb;
}
#endif // #if defined(FSR3UPSCALER_BIND_SRV_INPUT_COLOR)

#if defined(FSR3UPSCALER_BIND_SRV_INPUT_MOTION_VECTORS)
texture2d<FfxFloat32, access::sample> r_input_motion_vectors;

FfxFloat32x2 LoadInputMotionVector(FfxUInt32x2 iPxDilatedMotionVectorPos)
{
    FfxFloat32x2 fSrcMotionVector = r_input_motion_vectors.read(iPxDilatedMotionVectorPos, 0).xy;

    FfxFloat32x2 fUvMotionVector = fSrcMotionVector * MotionVectorScale();

#if FFX_FSR3UPSCALER_OPTION_JITTERED_MOTION_VECTORS
    fUvMotionVector -= MotionVectorJitterCancellation();
#endif

    return fUvMotionVector;
}

FfxFloat32x2 LoadInputMotionVector(FfxInt32x2 iPxDilatedMotionVectorPos)
{
    return LoadInputMotionVector(FfxUInt32x2(iPxDilatedMotionVectorPos));
}
#endif // #if defined(FSR3UPSCALER_BIND_SRV_INPUT_MOTION_VECTORS)

#if defined(FSR3UPSCALER_BIND_SRV_INTERNAL_UPSCALED)
texture2d<FfxFloat32, access::sample> r_internal_upscaled_color;

FfxFloat32x4 LoadHistory(FfxUInt32x2 iPxHistory)
{
    return r_internal_upscaled_color.read(iPxHistory, 0);
}

FfxFloat32x4 LoadHistory(FfxInt32x2 iPxHistory)
{
    return r_internal_upscaled_color.read(FfxUInt32x2(iPxHistory), 0);
}

FfxFloat32x4 SampleHistory(FfxFloat32x2 fUV)
{
    return r_internal_upscaled_color.sample(s_LinearClamp, fUV, level(0.0f));
}
#endif // #if defined(FSR3UPSCALER_BIND_SRV_INTERNAL_UPSCALED)

#if defined(FSR3UPSCALER_BIND_UAV_LUMA_HISTORY)
// Format: RGBA16Float (or RGBA32Float) - supports access::read_write on Metal 3 Apple GPUs.
texture2d<FfxFloat32, access::read_write> rw_luma_history;

void StoreLumaHistory(FfxUInt32x2 iPxPos, FfxFloat32x4 fLumaHistory)
{
    rw_luma_history.write(fLumaHistory, iPxPos);
}

void StoreLumaHistory(FfxInt32x2 iPxPos, FfxFloat32x4 fLumaHistory)
{
    rw_luma_history.write(fLumaHistory, FfxUInt32x2(iPxPos));
}
#endif // #if defined(FSR3UPSCALER_BIND_UAV_LUMA_HISTORY)

#if defined(FSR3UPSCALER_BIND_SRV_LUMA_HISTORY)
texture2d<FfxFloat32, access::sample> r_luma_history;

FfxFloat32x4 LoadLumaHistory(FfxInt32x2 iPxPos)
{
    return r_luma_history.read(FfxUInt32x2(iPxPos), 0);
}

FfxFloat32x4 LoadLumaHistory(FfxUInt32x2 iPxPos)
{
    return r_luma_history.read(iPxPos, 0);
}

FfxFloat32x4 SampleLumaHistory(FfxFloat32x2 fUV)
{
    return r_luma_history.sample(s_LinearClamp, fUV, level(0.0f));
}
#endif // #if defined(FSR3UPSCALER_BIND_SRV_LUMA_HISTORY)

#if defined(FSR3UPSCALER_BIND_SRV_RCAS_INPUT)
texture2d<FfxFloat32, access::sample> r_rcas_input;

FfxFloat32x4 LoadRCAS_Input(FfxInt32x2 iPxPos)
{
    return r_rcas_input.read(FfxUInt32x2(iPxPos), 0);
}

FfxFloat32x4 LoadRCAS_Input(FfxUInt32x2 iPxPos)
{
    return r_rcas_input.read(iPxPos, 0);
}

FfxFloat32x3 SampleRCAS_Input(FfxFloat32x2 fUV)
{
    return r_rcas_input.sample(s_LinearClamp, fUV, level(0.0f)).rgb;
}
#endif // #if defined(FSR3UPSCALER_BIND_SRV_RCAS_INPUT)

#if defined(FSR3UPSCALER_BIND_UAV_INTERNAL_UPSCALED)
// Format: RGBA16Float - supports access::read_write on Metal 3 Apple GPUs.
texture2d<FfxFloat32, access::read_write> rw_internal_upscaled_color;

void StoreReprojectedHistory(FfxUInt32x2 iPxHistory, FfxFloat32x4 fHistory)
{
    rw_internal_upscaled_color.write(fHistory, iPxHistory);
}

void StoreReprojectedHistory(FfxInt32x2 iPxHistory, FfxFloat32x4 fHistory)
{
    rw_internal_upscaled_color.write(fHistory, FfxUInt32x2(iPxHistory));
}

void StoreInternalColorAndWeight(FfxUInt32x2 iPxPos, FfxFloat32x4 fColorAndWeight)
{
    rw_internal_upscaled_color.write(fColorAndWeight, iPxPos);
}

void StoreInternalColorAndWeight(FfxInt32x2 iPxPos, FfxFloat32x4 fColorAndWeight)
{
    rw_internal_upscaled_color.write(fColorAndWeight, FfxUInt32x2(iPxPos));
}
#endif // #if defined(FSR3UPSCALER_BIND_UAV_INTERNAL_UPSCALED)

#if defined(FSR3UPSCALER_BIND_UAV_UPSCALED_OUTPUT)
// Format: RGBA16Float / RGBA8Unorm support access::read_write on Metal 3 Apple GPUs.
// NOTE: Format does NOT support access::read_write if the host binds BGRA8Unorm, RGB10A2Unorm, or any sRGB format
// (only access::write is supported for those formats on Apple GPUs; bind an RGBA16Float/RGBA8Unorm target or use access::write).
texture2d<FfxFloat32, access::read_write> rw_upscaled_output;

void StoreUpscaledOutput(FfxUInt32x2 iPxPos, FfxFloat32x3 fColor)
{
    rw_upscaled_output.write(FfxFloat32x4(fColor, 1.f), iPxPos);
}

void StoreUpscaledOutput(FfxInt32x2 iPxPos, FfxFloat32x3 fColor)
{
    rw_upscaled_output.write(FfxFloat32x4(fColor, 1.f), FfxUInt32x2(iPxPos));
}
#endif // #if defined(FSR3UPSCALER_BIND_UAV_UPSCALED_OUTPUT)

#if defined(FSR3UPSCALER_BIND_SRV_ACCUMULATION)
texture2d<FfxFloat32, access::sample> r_accumulation;

FfxFloat32 SampleAccumulation(FfxFloat32x2 fUV)
{
    return r_accumulation.sample(s_LinearClamp, fUV, level(0.0f)).x;
}
#endif // #if defined(FSR3UPSCALER_BIND_SRV_ACCUMULATION)

#if defined(FSR3UPSCALER_BIND_UAV_ACCUMULATION)
// Format: R8Unorm - supports access::read_write on Metal 3 Apple GPUs.
texture2d<FfxFloat32, access::read_write> rw_accumulation;

void StoreAccumulation(FfxUInt32x2 iPxPos, FfxFloat32 fAccumulation)
{
    rw_accumulation.write(FfxFloat32x4(fAccumulation, 0.0f, 0.0f, 0.0f), iPxPos);
}

void StoreAccumulation(FfxInt32x2 iPxPos, FfxFloat32 fAccumulation)
{
    rw_accumulation.write(FfxFloat32x4(fAccumulation, 0.0f, 0.0f, 0.0f), FfxUInt32x2(iPxPos));
}
#endif // #if defined(FSR3UPSCALER_BIND_UAV_ACCUMULATION)

#if defined(FSR3UPSCALER_BIND_SRV_SHADING_CHANGE)
texture2d<FfxFloat32, access::sample> r_shading_change;

FfxFloat32 LoadShadingChange(FfxUInt32x2 iPxPos)
{
    return r_shading_change.read(iPxPos, 0).x * cb.fShadingChangeScale;
}

FfxFloat32 LoadShadingChange(FfxInt32x2 iPxPos)
{
    return r_shading_change.read(FfxUInt32x2(iPxPos), 0).x * cb.fShadingChangeScale;
}

FfxFloat32 SampleShadingChange(FfxFloat32x2 fUV)
{
    return r_shading_change.sample(s_LinearClamp, fUV, level(0.0f)).x * cb.fShadingChangeScale;
}
#endif // #if defined(FSR3UPSCALER_BIND_SRV_SHADING_CHANGE)

#if defined(FSR3UPSCALER_BIND_UAV_SHADING_CHANGE)
// Format: R8Unorm / R16Float - supports access::read_write on Metal 3 Apple GPUs.
texture2d<FfxFloat32, access::read_write> rw_shading_change;

void StoreShadingChange(FfxUInt32x2 iPxPos, FfxFloat32 fShadingChange)
{
    rw_shading_change.write(FfxFloat32x4(fShadingChange, 0.0f, 0.0f, 0.0f), iPxPos);
}

void StoreShadingChange(FfxInt32x2 iPxPos, FfxFloat32 fShadingChange)
{
    rw_shading_change.write(FfxFloat32x4(fShadingChange, 0.0f, 0.0f, 0.0f), FfxUInt32x2(iPxPos));
}
#endif // #if defined(FSR3UPSCALER_BIND_UAV_SHADING_CHANGE)

#if defined(FSR3UPSCALER_BIND_SRV_FARTHEST_DEPTH)
texture2d<FfxFloat32, access::sample> r_farthest_depth;

FfxInt32x2 GetFarthestDepthResourceDimensions()
{
    return FfxInt32x2(r_farthest_depth.get_width(), r_farthest_depth.get_height());
}

FfxFloat32 LoadFarthestDepth(FfxUInt32x2 iPxPos)
{
    return r_farthest_depth.read(iPxPos, 0).x;
}

FfxFloat32 LoadFarthestDepth(FfxInt32x2 iPxPos)
{
    return r_farthest_depth.read(FfxUInt32x2(iPxPos), 0).x;
}

FfxFloat32 SampleFarthestDepth(FfxFloat32x2 fUV)
{
    return r_farthest_depth.sample(s_LinearClamp, fUV, level(0.0f)).x;
}
#endif // #if defined(FSR3UPSCALER_BIND_SRV_FARTHEST_DEPTH)

#if defined(FSR3UPSCALER_BIND_UAV_FARTHEST_DEPTH)
// Format: R16Float - supports access::read_write on Metal 3 Apple GPUs.
texture2d<FfxFloat32, access::read_write> rw_farthest_depth;

void StoreFarthestDepth(FfxUInt32x2 iPxPos, FfxFloat32 fDepth)
{
    rw_farthest_depth.write(FfxFloat32x4(fDepth, 0.0f, 0.0f, 0.0f), iPxPos);
}

void StoreFarthestDepth(FfxInt32x2 iPxPos, FfxFloat32 fDepth)
{
    rw_farthest_depth.write(FfxFloat32x4(fDepth, 0.0f, 0.0f, 0.0f), FfxUInt32x2(iPxPos));
}
#endif // #if defined(FSR3UPSCALER_BIND_UAV_FARTHEST_DEPTH)

#if defined(FSR3UPSCALER_BIND_SRV_FARTHEST_DEPTH_MIP1)
texture2d<FfxFloat32, access::sample> r_farthest_depth_mip1;

FfxInt32x2 GetFarthestDepthMip1ResourceDimensions()
{
    return FfxInt32x2(r_farthest_depth_mip1.get_width(), r_farthest_depth_mip1.get_height());
}

FfxFloat32 LoadFarthestDepthMip1(FfxUInt32x2 iPxPos)
{
    return r_farthest_depth_mip1.read(iPxPos, 0).x;
}

FfxFloat32 LoadFarthestDepthMip1(FfxInt32x2 iPxPos)
{
    return r_farthest_depth_mip1.read(FfxUInt32x2(iPxPos), 0).x;
}

FfxFloat32 SampleFarthestDepthMip1(FfxFloat32x2 fUV)
{
    return r_farthest_depth_mip1.sample(s_LinearClamp, fUV, level(0.0f)).x;
}
#endif // #if defined(FSR3UPSCALER_BIND_SRV_FARTHEST_DEPTH_MIP1)

#if defined(FSR3UPSCALER_BIND_UAV_FARTHEST_DEPTH_MIP1)
// Format: R16Float - supports access::read_write on Metal 3 Apple GPUs.
texture2d<FfxFloat32, access::read_write> rw_farthest_depth_mip1;

void StoreFarthestDepthMip1(FfxUInt32x2 iPxPos, FfxFloat32 fDepth)
{
    rw_farthest_depth_mip1.write(FfxFloat32x4(fDepth, 0.0f, 0.0f, 0.0f), iPxPos);
}

void StoreFarthestDepthMip1(FfxInt32x2 iPxPos, FfxFloat32 fDepth)
{
    rw_farthest_depth_mip1.write(FfxFloat32x4(fDepth, 0.0f, 0.0f, 0.0f), FfxUInt32x2(iPxPos));
}
#endif // #if defined(FSR3UPSCALER_BIND_UAV_FARTHEST_DEPTH_MIP1)

#if defined(FSR3UPSCALER_BIND_SRV_CURRENT_LUMA)
texture2d<FfxFloat32, access::sample> r_current_luma;

FfxFloat32 LoadCurrentLuma(FfxUInt32x2 iPxPos)
{
    return r_current_luma.read(iPxPos, 0).x;
}

FfxFloat32 LoadCurrentLuma(FfxInt32x2 iPxPos)
{
    return r_current_luma.read(FfxUInt32x2(iPxPos), 0).x;
}

FfxFloat32 SampleCurrentLuma(FfxFloat32x2 uv)
{
    return r_current_luma.sample(s_LinearClamp, uv, level(0.0f)).x;
}
#endif // #if defined(FSR3UPSCALER_BIND_SRV_CURRENT_LUMA)

#if defined(FSR3UPSCALER_BIND_UAV_CURRENT_LUMA)
// Format: R16Float - supports access::read_write on Metal 3 Apple GPUs.
texture2d<FfxFloat32, access::read_write> rw_current_luma;

void StoreCurrentLuma(FfxUInt32x2 iPxPos, FfxFloat32 fLuma)
{
    rw_current_luma.write(FfxFloat32x4(fLuma, 0.0f, 0.0f, 0.0f), iPxPos);
}

void StoreCurrentLuma(FfxInt32x2 iPxPos, FfxFloat32 fLuma)
{
    rw_current_luma.write(FfxFloat32x4(fLuma, 0.0f, 0.0f, 0.0f), FfxUInt32x2(iPxPos));
}
#endif // #if defined(FSR3UPSCALER_BIND_UAV_CURRENT_LUMA)

#if defined(FSR3UPSCALER_BIND_SRV_LUMA_INSTABILITY)
texture2d<FfxFloat32, access::sample> r_luma_instability;

FfxFloat32 SampleLumaInstability(FfxFloat32x2 uv)
{
    return r_luma_instability.sample(s_LinearClamp, uv, level(0.0f)).x;
}
#endif // #if defined(FSR3UPSCALER_BIND_SRV_LUMA_INSTABILITY)

#if defined(FSR3UPSCALER_BIND_UAV_LUMA_INSTABILITY)
// Format: R16Float - supports access::read_write on Metal 3 Apple GPUs.
texture2d<FfxFloat32, access::read_write> rw_luma_instability;

void StoreLumaInstability(FfxUInt32x2 iPxPos, FfxFloat32 fLumaInstability)
{
    rw_luma_instability.write(FfxFloat32x4(fLumaInstability, 0.0f, 0.0f, 0.0f), iPxPos);
}

void StoreLumaInstability(FfxInt32x2 iPxPos, FfxFloat32 fLumaInstability)
{
    rw_luma_instability.write(FfxFloat32x4(fLumaInstability, 0.0f, 0.0f, 0.0f), FfxUInt32x2(iPxPos));
}
#endif // #if defined(FSR3UPSCALER_BIND_UAV_LUMA_INSTABILITY)

#if defined(FSR3UPSCALER_BIND_SRV_PREVIOUS_LUMA)
texture2d<FfxFloat32, access::sample> r_previous_luma;

FfxFloat32 LoadPreviousLuma(FfxUInt32x2 iPxPos)
{
    return r_previous_luma.read(iPxPos, 0).x;
}

FfxFloat32 LoadPreviousLuma(FfxInt32x2 iPxPos)
{
    return r_previous_luma.read(FfxUInt32x2(iPxPos), 0).x;
}

FfxFloat32 SamplePreviousLuma(FfxFloat32x2 uv)
{
    return r_previous_luma.sample(s_LinearClamp, uv, level(0.0f)).x;
}
#endif // #if defined(FSR3UPSCALER_BIND_SRV_PREVIOUS_LUMA)

#if defined(FSR3UPSCALER_BIND_SRV_NEW_LOCKS)
texture2d<FfxFloat32, access::sample> r_new_locks;

FfxFloat32 LoadNewLocks(FfxUInt32x2 iPxPos)
{
    return r_new_locks.read(iPxPos, 0).x;
}

FfxFloat32 LoadNewLocks(FfxInt32x2 iPxPos)
{
    return r_new_locks.read(FfxUInt32x2(iPxPos), 0).x;
}
#endif // #if defined(FSR3UPSCALER_BIND_SRV_NEW_LOCKS)

#if defined(FSR3UPSCALER_BIND_UAV_NEW_LOCKS)
// Format: R8Unorm - supports access::read_write on Metal 3 Apple GPUs (read via LoadRwNewLocks, written via StoreNewLocks).
texture2d<FfxFloat32, access::read_write> rw_new_locks;

FfxFloat32 LoadRwNewLocks(FfxUInt32x2 iPxPos)
{
    return rw_new_locks.read(iPxPos).x;
}

FfxFloat32 LoadRwNewLocks(FfxInt32x2 iPxPos)
{
    return rw_new_locks.read(FfxUInt32x2(iPxPos)).x;
}

void StoreNewLocks(FfxUInt32x2 iPxPos, FfxFloat32 newLock)
{
    rw_new_locks.write(FfxFloat32x4(newLock, 0.0f, 0.0f, 0.0f), iPxPos);
}

void StoreNewLocks(FfxInt32x2 iPxPos, FfxFloat32 newLock)
{
    rw_new_locks.write(FfxFloat32x4(newLock, 0.0f, 0.0f, 0.0f), FfxUInt32x2(iPxPos));
}
#endif // #if defined(FSR3UPSCALER_BIND_UAV_NEW_LOCKS)

#if defined(FSR3UPSCALER_BIND_SRV_RECONSTRUCTED_PREV_NEAREST_DEPTH)
texture2d<FfxUInt32, access::sample> r_reconstructed_previous_nearest_depth;

FfxFloat32 LoadReconstructedPrevDepth(FfxUInt32x2 iPxPos)
{
    return asfloat(r_reconstructed_previous_nearest_depth.read(iPxPos, 0).x);
}

FfxFloat32 LoadReconstructedPrevDepth(FfxInt32x2 iPxPos)
{
    return asfloat(r_reconstructed_previous_nearest_depth.read(FfxUInt32x2(iPxPos), 0).x);
}
#endif // #if defined(FSR3UPSCALER_BIND_SRV_RECONSTRUCTED_PREV_NEAREST_DEPTH)

#if defined(FSR3UPSCALER_BIND_UAV_RECONSTRUCTED_PREV_NEAREST_DEPTH)
// Format: R32Uint - supports access::read_write and native texture atomics (atomic_fetch_min/max) in Metal 3.1+.
texture2d<FfxUInt32, access::read_write> rw_reconstructed_previous_nearest_depth;

void StoreReconstructedDepth(FfxUInt32x2 iPxSample, FfxFloat32 fDepth)
{
    FfxUInt32 uDepth = asuint(fDepth);

#if FFX_FSR3UPSCALER_OPTION_INVERTED_DEPTH
    rw_reconstructed_previous_nearest_depth.atomic_fetch_max(iPxSample, uDepth);
#else
    rw_reconstructed_previous_nearest_depth.atomic_fetch_min(iPxSample, uDepth); // min for standard, max for inverted depth
#endif
}

void StoreReconstructedDepth(FfxInt32x2 iPxSample, FfxFloat32 fDepth)
{
    StoreReconstructedDepth(FfxUInt32x2(iPxSample), fDepth);
}

void SetReconstructedDepth(FfxUInt32x2 iPxSample, const FfxUInt32 uValue)
{
    rw_reconstructed_previous_nearest_depth.write(FfxUInt32x4(uValue, 0u, 0u, 0u), iPxSample);
}

void SetReconstructedDepth(FfxInt32x2 iPxSample, const FfxUInt32 uValue)
{
    rw_reconstructed_previous_nearest_depth.write(FfxUInt32x4(uValue, 0u, 0u, 0u), FfxUInt32x2(iPxSample));
}
#endif // #if defined(FSR3UPSCALER_BIND_UAV_RECONSTRUCTED_PREV_NEAREST_DEPTH)

#if defined(FSR3UPSCALER_BIND_UAV_DILATED_DEPTH)
// Format: R32Float (or R16Float) - supports access::read_write on Metal 3 Apple GPUs.
texture2d<FfxFloat32, access::read_write> rw_dilated_depth;

void StoreDilatedDepth(FFX_PARAMETER_IN FfxUInt32x2 iPxPos, FFX_PARAMETER_IN FfxFloat32 fDepth)
{
    rw_dilated_depth.write(FfxFloat32x4(fDepth, 0.0f, 0.0f, 0.0f), iPxPos);
}

void StoreDilatedDepth(FFX_PARAMETER_IN FfxInt32x2 iPxPos, FFX_PARAMETER_IN FfxFloat32 fDepth)
{
    rw_dilated_depth.write(FfxFloat32x4(fDepth, 0.0f, 0.0f, 0.0f), FfxUInt32x2(iPxPos));
}
#endif // #if defined(FSR3UPSCALER_BIND_UAV_DILATED_DEPTH)

#if defined(FSR3UPSCALER_BIND_UAV_DILATED_MOTION_VECTORS)
// WARNING: Stock FSR3 uses RG16Float (R16G16_FLOAT) for dilated motion vectors, which does NOT support
// access::read_write on Metal 3 Apple GPUs (Metal Tier 2 read_write only supports 1- and 4-channel formats).
// Either allocate this texture as RGBA16Float on Metal or bind as access::write (it is write-only in PrepareInputs).
texture2d<FfxFloat32, access::read_write> rw_dilated_motion_vectors;

void StoreDilatedMotionVector(FFX_PARAMETER_IN FfxUInt32x2 iPxPos, FFX_PARAMETER_IN FfxFloat32x2 fMotionVector)
{
    rw_dilated_motion_vectors.write(FfxFloat32x4(fMotionVector, 0.0f, 0.0f), iPxPos);
}

void StoreDilatedMotionVector(FFX_PARAMETER_IN FfxInt32x2 iPxPos, FFX_PARAMETER_IN FfxFloat32x2 fMotionVector)
{
    rw_dilated_motion_vectors.write(FfxFloat32x4(fMotionVector, 0.0f, 0.0f), FfxUInt32x2(iPxPos));
}
#endif // #if defined(FSR3UPSCALER_BIND_UAV_DILATED_MOTION_VECTORS)

#if defined(FSR3UPSCALER_BIND_SRV_DILATED_MOTION_VECTORS)
texture2d<FfxFloat32, access::sample> r_dilated_motion_vectors;

FfxFloat32x2 LoadDilatedMotionVector(FfxUInt32x2 iPxInput)
{
    return r_dilated_motion_vectors.read(iPxInput, 0).xy;
}

FfxFloat32x2 LoadDilatedMotionVector(FfxInt32x2 iPxInput)
{
    return r_dilated_motion_vectors.read(FfxUInt32x2(iPxInput), 0).xy;
}

FfxFloat32x2 SampleDilatedMotionVector(FfxFloat32x2 fUV)
{
    return r_dilated_motion_vectors.sample(s_LinearClamp, fUV, level(0.0f)).xy;
}
#endif // #if defined(FSR3UPSCALER_BIND_SRV_DILATED_MOTION_VECTORS)

#if defined(FSR3UPSCALER_BIND_SRV_DILATED_DEPTH)
texture2d<FfxFloat32, access::sample> r_dilated_depth;

FfxFloat32 LoadDilatedDepth(FfxUInt32x2 iPxInput)
{
    return r_dilated_depth.read(iPxInput, 0).x;
}

FfxFloat32 LoadDilatedDepth(FfxInt32x2 iPxInput)
{
    return r_dilated_depth.read(FfxUInt32x2(iPxInput), 0).x;
}

FfxFloat32 SampleDilatedDepth(FfxFloat32x2 fUV)
{
    return r_dilated_depth.sample(s_LinearClamp, fUV, level(0.0f)).x;
}
#endif // #if defined(FSR3UPSCALER_BIND_SRV_DILATED_DEPTH)

#if defined(FSR3UPSCALER_BIND_SRV_INPUT_EXPOSURE)
texture2d<FfxFloat32, access::sample> r_input_exposure;

FfxFloat32 Exposure()
{
    FfxFloat32 exposure = r_input_exposure.read(FfxUInt32x2(0, 0), 0).x;

#if defined(__XBOX_SCARLETT)
    if (exposure < 0.000030517578f) {
        exposure = 1.0f;
    }
#else
    if (exposure == 0.0f) {
        exposure = 1.0f;
    }
#endif

    return exposure;
}
#endif // #if defined(FSR3UPSCALER_BIND_SRV_INPUT_EXPOSURE)

// BEGIN: FSR3UPSCALER_BIND_SRV_LANCZOS_LUT
#if defined(FSR3UPSCALER_BIND_SRV_LANCZOS_LUT)
texture2d<FfxFloat32, access::sample> r_lanczos_lut;
#endif

FfxFloat32 SampleLanczos2Weight(FfxFloat32 x)
{
#if defined(FSR3UPSCALER_BIND_SRV_LANCZOS_LUT)
    return r_lanczos_lut.sample(s_LinearClamp, FfxFloat32x2(x / 2, 0.5f), level(0.0f)).x;
#else
    return 0.f;
#endif
}
// END: FSR3UPSCALER_BIND_SRV_LANCZOS_LUT

#if defined(FSR3UPSCALER_BIND_SRV_DILATED_REACTIVE_MASKS)
texture2d<FfxFloat32, access::sample> r_dilated_reactive_masks;

FfxFloat32x4 SampleDilatedReactiveMasks(FfxFloat32x2 fUV)
{
    return r_dilated_reactive_masks.sample(s_LinearClamp, fUV, level(0.0f));
}
#endif // #if defined(FSR3UPSCALER_BIND_SRV_DILATED_REACTIVE_MASKS)

#if defined(FSR3UPSCALER_BIND_UAV_DILATED_REACTIVE_MASKS)
// Format: RGBA8Unorm - supports access::read_write on Metal 3 Apple GPUs (Tier 2).
texture2d<FfxFloat32, access::read_write> rw_dilated_reactive_masks;

void StoreDilatedReactiveMasks(FFX_PARAMETER_IN FfxUInt32x2 iPxPos, FFX_PARAMETER_IN FfxFloat32x4 fDilatedReactiveMasks)
{
    rw_dilated_reactive_masks.write(fDilatedReactiveMasks, iPxPos);
}

void StoreDilatedReactiveMasks(FFX_PARAMETER_IN FfxInt32x2 iPxPos, FFX_PARAMETER_IN FfxFloat32x4 fDilatedReactiveMasks)
{
    rw_dilated_reactive_masks.write(fDilatedReactiveMasks, FfxUInt32x2(iPxPos));
}
#endif // #if defined(FSR3UPSCALER_BIND_UAV_DILATED_REACTIVE_MASKS)

#if defined(FSR3UPSCALER_BIND_SRV_INPUT_OPAQUE_ONLY)
texture2d<FfxFloat32, access::sample> r_input_opaque_only;

FfxFloat32x3 LoadOpaqueOnly(FFX_PARAMETER_IN FFX_MIN16_I2 iPxPos)
{
    return r_input_opaque_only.read(FfxUInt32x2(iPxPos), 0).xyz;
}
#endif // #if defined(FSR3UPSCALER_BIND_SRV_INPUT_OPAQUE_ONLY)

#if defined(FSR3UPSCALER_BIND_SRV_PREV_PRE_ALPHA_COLOR)
texture2d<FfxFloat32, access::sample> r_input_prev_color_pre_alpha;

FfxFloat32x3 LoadPrevPreAlpha(FFX_PARAMETER_IN FFX_MIN16_I2 iPxPos)
{
    return r_input_prev_color_pre_alpha.read(FfxUInt32x2(iPxPos), 0).xyz;
}
#endif // #if defined(FSR3UPSCALER_BIND_SRV_PREV_PRE_ALPHA_COLOR)

#if defined(FSR3UPSCALER_BIND_SRV_PREV_POST_ALPHA_COLOR)
texture2d<FfxFloat32, access::sample> r_input_prev_color_post_alpha;

FfxFloat32x3 LoadPrevPostAlpha(FFX_PARAMETER_IN FFX_MIN16_I2 iPxPos)
{
    return r_input_prev_color_post_alpha.read(FfxUInt32x2(iPxPos), 0).xyz;
}
#endif // #if defined(FSR3UPSCALER_BIND_SRV_PREV_POST_ALPHA_COLOR)

#if defined(FSR3UPSCALER_BIND_UAV_AUTOREACTIVE) && \
    defined(FSR3UPSCALER_BIND_UAV_AUTOCOMPOSITION)
// Format: R8Unorm - supports access::read_write on Metal 3 Apple GPUs.
texture2d<FfxFloat32, access::read_write> rw_output_autoreactive;
texture2d<FfxFloat32, access::read_write> rw_output_autocomposition;

void StoreAutoReactive(FFX_PARAMETER_IN FFX_MIN16_I2 iPxPos, FFX_PARAMETER_IN FFX_MIN16_F2 fReactive)
{
    rw_output_autoreactive.write(FfxFloat32x4(FfxFloat32(fReactive.x), 0.0f, 0.0f, 0.0f), FfxUInt32x2(iPxPos));
    rw_output_autocomposition.write(FfxFloat32x4(FfxFloat32(fReactive.y), 0.0f, 0.0f, 0.0f), FfxUInt32x2(iPxPos));
}
#endif // #if defined(FSR3UPSCALER_BIND_UAV_AUTOREACTIVE) && defined(FSR3UPSCALER_BIND_UAV_AUTOCOMPOSITION)

#if defined(FSR3UPSCALER_BIND_UAV_PREV_PRE_ALPHA_COLOR)
// WARNING: Stock FSR3 uses R11G11B10_FLOAT (MTLPixelFormatRG11B10Float), which does NOT support access::read_write
// on Metal 3 Apple GPUs. Allocate as RGBA16Float or use access::write.
texture2d<FfxFloat32, access::read_write> rw_output_prev_color_pre_alpha;

void StorePrevPreAlpha(FFX_PARAMETER_IN FFX_MIN16_I2 iPxPos, FFX_PARAMETER_IN FFX_MIN16_F3 color)
{
    rw_output_prev_color_pre_alpha.write(FfxFloat32x4(FfxFloat32x3(color), 0.0f), FfxUInt32x2(iPxPos));
}
#endif // #if defined(FSR3UPSCALER_BIND_UAV_PREV_PRE_ALPHA_COLOR)

#if defined(FSR3UPSCALER_BIND_UAV_PREV_POST_ALPHA_COLOR)
// WARNING: Stock FSR3 uses R11G11B10_FLOAT (MTLPixelFormatRG11B10Float), which does NOT support access::read_write
// on Metal 3 Apple GPUs. Allocate as RGBA16Float or use access::write.
texture2d<FfxFloat32, access::read_write> rw_output_prev_color_post_alpha;

void StorePrevPostAlpha(FFX_PARAMETER_IN FFX_MIN16_I2 iPxPos, FFX_PARAMETER_IN FFX_MIN16_F3 color)
{
    rw_output_prev_color_post_alpha.write(FfxFloat32x4(FfxFloat32x3(color), 0.0f), FfxUInt32x2(iPxPos));
}
#endif // #if defined(FSR3UPSCALER_BIND_UAV_PREV_POST_ALPHA_COLOR)

#if defined(FSR3UPSCALER_BIND_UAV_FRAME_INFO)
// Format: 1x1 RGBA32Float (or RGBA16Float) - supports access::read_write on Metal 3 Apple GPUs.
texture2d<FfxFloat32, access::read_write> rw_frame_info;

FfxFloat32x4 LoadFrameInfo()
{
    return rw_frame_info.read(FfxUInt32x2(0, 0));
}

void StoreFrameInfo(FfxFloat32x4 fInfo)
{
    rw_frame_info.write(fInfo, FfxUInt32x2(0, 0));
}
#endif // #if defined(FSR3UPSCALER_BIND_UAV_FRAME_INFO)

#if defined(FSR3UPSCALER_BIND_SRV_FRAME_INFO)
texture2d<FfxFloat32, access::sample> r_frame_info;

FfxFloat32x4 FrameInfo()
{
    return r_frame_info.read(FfxUInt32x2(0, 0), 0);
}
#endif // #if defined(FSR3UPSCALER_BIND_SRV_FRAME_INFO)

#if defined(FSR3UPSCALER_BIND_UAV_SPD_MIPS_LEVEL_0) && \
    defined(FSR3UPSCALER_BIND_UAV_SPD_MIPS_LEVEL_1) && \
    defined(FSR3UPSCALER_BIND_UAV_SPD_MIPS_LEVEL_2) && \
    defined(FSR3UPSCALER_BIND_UAV_SPD_MIPS_LEVEL_3) && \
    defined(FSR3UPSCALER_BIND_UAV_SPD_MIPS_LEVEL_4) && \
    defined(FSR3UPSCALER_BIND_UAV_SPD_MIPS_LEVEL_5)

// WARNING: Stock FSR3 uses R16G16_FLOAT (MTLPixelFormatRG16Float) for the SPD mip pyramid, which does NOT support
// access::read_write on Metal 3 Apple GPUs (Metal Tier 2 read_write does not support 2-channel RG16Float).
// Because rw_spd_mip5 is both read (RWLoadPyramid) and written (StorePyramid) in SPD, the SPD mip pyramid texture
// MUST be allocated as MTLPixelFormatRGBA16Float on Metal (or rw_spd_mip0..4 bound with access::write and mip 5 backed
// by RGBA16Float).
texture2d<FfxFloat32, access::read_write> rw_spd_mip0;
texture2d<FfxFloat32, access::read_write> rw_spd_mip1;
texture2d<FfxFloat32, access::read_write> rw_spd_mip2;
texture2d<FfxFloat32, access::read_write> rw_spd_mip3;
texture2d<FfxFloat32, access::read_write> rw_spd_mip4;
texture2d<FfxFloat32, access::read_write> rw_spd_mip5;

FfxFloat32x2 RWLoadPyramid(FFX_PARAMETER_IN FfxInt32x2 iPxPos, FFX_PARAMETER_IN FfxUInt32 index)
{
#define LOAD(idx)                                                   \
    if (index == idx)                                               \
    {                                                               \
        return rw_spd_mip##idx.read(FfxUInt32x2(iPxPos)).xy;        \
    }
    LOAD(0);
    LOAD(1);
    LOAD(2);
    LOAD(3);
    LOAD(4);
    LOAD(5);

    return FfxFloat32x2(0.0f, 0.0f);

#undef LOAD
}

void StorePyramid(FFX_PARAMETER_IN FfxInt32x2 iPxPos, FFX_PARAMETER_IN FfxFloat32x2 outValue, FFX_PARAMETER_IN FfxUInt32 index)
{
#define STORE(idx)                                                                          \
    if (index == idx)                                                                       \
    {                                                                                       \
        rw_spd_mip##idx.write(FfxFloat32x4(outValue, 0.0f, 0.0f), FfxUInt32x2(iPxPos));     \
    }

    STORE(0);
    STORE(1);
    STORE(2);
    STORE(3);
    STORE(4);
    STORE(5);

    if (index == 5)
    {
        rw_spd_mip5.fence();
    }

#undef STORE
}
#endif // SPD_MIPS_LEVEL_0..5

#if defined(FSR3UPSCALER_BIND_UAV_SPD_GLOBAL_ATOMIC)
// Format: 1x1 R32Uint - supports access::read_write and native texture atomics in Metal 3.1+.
texture2d<FfxUInt32, access::read_write> rw_spd_global_atomic;

void SPD_IncreaseAtomicCounter(threadgroup FfxUInt32& spdCounter)
{
    atomic_thread_fence(mem_flags::mem_device_and_threadgroup, memory_order_seq_cst, thread_scope_device);
    // Texture atomics return the previous texel as a 4-component vector.
    spdCounter = rw_spd_global_atomic.atomic_fetch_add(FfxUInt32x2(0, 0), 1u).x;
}

void SPD_IncreaseAtomicCounter(FFX_PARAMETER_INOUT FfxUInt32 FFX_PARAMETER_REF spdCounter)
{
    atomic_thread_fence(mem_flags::mem_device_and_threadgroup, memory_order_seq_cst, thread_scope_device);
    // Texture atomics return the previous texel as a 4-component vector.
    spdCounter = rw_spd_global_atomic.atomic_fetch_add(FfxUInt32x2(0, 0), 1u).x;
}

void SPD_ResetAtomicCounter()
{
    rw_spd_global_atomic.write(FfxUInt32x4(0u, 0u, 0u, 0u), FfxUInt32x2(0, 0));
}
#endif // #if defined(FSR3UPSCALER_BIND_UAV_SPD_GLOBAL_ATOMIC)

#endif // !defined(FFX_FSR3UPSCALER_MSL_SAMPLERS_ONLY) && defined(FFX_GPU) && defined(FFX_MSL)
