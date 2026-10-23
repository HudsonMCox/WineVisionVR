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

#if defined(FFX_MSL)
threadgroup FfxUInt32* spdCounter;
#else
FFX_GROUPSHARED FfxUInt32 spdCounter;
#endif

void SpdIncreaseAtomicCounter(FfxUInt32 slice)
{
#if defined(FFX_MSL)
    SPD_IncreaseAtomicCounter(*spdCounter);
#else
    SPD_IncreaseAtomicCounter(spdCounter);
#endif
}

FfxUInt32 SpdGetAtomicCounter()
{
#if defined(FFX_MSL)
    return *spdCounter;
#else
    return spdCounter;
#endif
}

void SpdResetAtomicCounter(FfxUInt32 slice)
{
    SPD_ResetAtomicCounter();
}

#ifndef SPD_PACKED_ONLY
#if defined(FFX_MSL)
threadgroup FfxFloat32* spdIntermediateR;
threadgroup FfxFloat32* spdIntermediateG;
threadgroup FfxFloat32* spdIntermediateB;
threadgroup FfxFloat32* spdIntermediateA;

#define DIFFERENCE      FfxInt32(0)
#define SIGN_SUM        FfxInt32(1)
#define MIP0_INDICATOR  FfxInt32(2)
#else
FFX_GROUPSHARED FfxFloat32 spdIntermediateR[16][16];
FFX_GROUPSHARED FfxFloat32 spdIntermediateG[16][16];
FFX_GROUPSHARED FfxFloat32 spdIntermediateB[16][16];
FFX_GROUPSHARED FfxFloat32 spdIntermediateA[16][16];

FFX_STATIC const FfxInt32 DIFFERENCE        = 0;
FFX_STATIC const FfxInt32 SIGN_SUM          = 1;
FFX_STATIC const FfxInt32 MIP0_INDICATOR    = 2;
#endif

FfxFloat32x2 Sort2(FfxFloat32x2 v)
{
    return FfxFloat32x2(ffxMin(v.x, v.y), ffxMax(v.x, v.y));
}

struct SampleSet
{
    FfxFloat32 fSamples[SHADING_CHANGE_SET_SIZE];
};

#define CompareSwap(i, j) \
{ \
FfxFloat32 fTmp = ffxMin(fSet.fSamples[i], fSet.fSamples[j]);\
fSet.fSamples[j] = ffxMax(fSet.fSamples[i], fSet.fSamples[j]);\
fSet.fSamples[i] = fTmp;\
}

#if SHADING_CHANGE_SET_SIZE == 5
#if !defined(FFX_MSL)
FFX_STATIC const FfxInt32x2 iSampleOffsets[5] = {FfxInt32x2(+0, +0), FfxInt32x2(-1, +0), FfxInt32x2(+1, +0), FfxInt32x2(+0, -1), FfxInt32x2(+0, +1)};
#endif

void SortSet(FFX_PARAMETER_INOUT SampleSet FFX_PARAMETER_REF fSet)
{
    CompareSwap(0, 3);
    CompareSwap(1, 4);
    CompareSwap(0, 2);
    CompareSwap(1, 3);
    CompareSwap(0, 1);
    CompareSwap(2, 4);
    CompareSwap(1, 2);
    CompareSwap(3, 4);
    CompareSwap(2, 3);
}
#endif

FfxFloat32 ComputeMinimumDifference(FfxInt32x2 iPxPos, SampleSet fSet0, SampleSet fSet1)
{
    FfxFloat32 fMinDiff = FSR3UPSCALER_FP16_MAX - 1;
    FfxInt32   a = 0;
    FfxInt32   b = 0;

    SortSet(fSet0);
    SortSet(fSet1);

    const FfxFloat32 fMax = ffxMin(fSet0.fSamples[SHADING_CHANGE_SET_SIZE-1], fSet1.fSamples[SHADING_CHANGE_SET_SIZE-1]);

    if (fMax > FSR3UPSCALER_FP32_MIN) {

        FFX_UNROLL
        for (FfxInt32 i = 0; i < SHADING_CHANGE_SET_SIZE && (fMinDiff < FSR3UPSCALER_FP16_MAX); i++) {

            FfxFloat32 fDiff = fSet0.fSamples[a] - fSet1.fSamples[b];

            if (abs(fDiff) > FSR3UPSCALER_FP16_MIN) {

                fDiff = sign(fDiff) * (1.0f - MinDividedByMax(fSet0.fSamples[a], fSet1.fSamples[b]));

                fMinDiff = (abs(fDiff) < abs(fMinDiff)) ? fDiff : fMinDiff;

                a += FfxInt32(fSet0.fSamples[a] < fSet1.fSamples[b]);
                b += FfxInt32(fSet0.fSamples[a] >= fSet1.fSamples[b]);
            }
            else
            {
                fMinDiff = FSR3UPSCALER_FP16_MAX;
            }
        }
    }

    return fMinDiff * FfxFloat32(fMinDiff < (FSR3UPSCALER_FP16_MAX - 1));
}

SampleSet GetCurrentLumaBilinearSamples(FfxFloat32x2 fUv)
{
    const FfxFloat32x2 fUvJittered = fUv + Jitter() / FfxFloat32x2(RenderSize());
    const FfxInt32x2   iBasePos    = FfxInt32x2(floor(fUvJittered * FfxFloat32x2(RenderSize())));

    SampleSet fSet;
#if defined(FFX_MSL)
    const FfxInt32x2 iSampleOffsets[5] = {FfxInt32x2(+0, +0), FfxInt32x2(-1, +0), FfxInt32x2(+1, +0), FfxInt32x2(+0, -1), FfxInt32x2(+0, +1)};
#endif

    for (FfxInt32 iSampleIndex = 0; iSampleIndex < SHADING_CHANGE_SET_SIZE; iSampleIndex++) {
        const FfxInt32x2 iSamplePos = ClampLoad(iBasePos, iSampleOffsets[iSampleIndex], RenderSize());
        fSet.fSamples[iSampleIndex] = LoadCurrentLuma(iSamplePos) * Exposure();
        fSet.fSamples[iSampleIndex] = ffxPow(fSet.fSamples[iSampleIndex], fShadingChangeSamplePow);
        fSet.fSamples[iSampleIndex] = ffxMax(fSet.fSamples[iSampleIndex], FSR3UPSCALER_EPSILON);
    }

    return fSet;
}

struct PreviousLumaBilinearSamplesData
{
    SampleSet fSet;
    FfxBoolean bIsExistingSample;
};

PreviousLumaBilinearSamplesData GetPreviousLumaBilinearSamples(FfxFloat32x2 fUv, FfxFloat32x2 fMotionVector)
{
    PreviousLumaBilinearSamplesData data;

    const FfxFloat32x2 fUvJittered = fUv + PreviousFrameJitter() / FfxFloat32x2(PreviousFrameRenderSize());
    const FfxFloat32x2 fReprojectedUv = fUvJittered + fMotionVector;

    data.bIsExistingSample = IsUvInside(fReprojectedUv);

    if (data.bIsExistingSample) {

        const FfxInt32x2 iBasePos = FfxInt32x2(floor(fReprojectedUv * FfxFloat32x2(PreviousFrameRenderSize())));
#if defined(FFX_MSL)
        const FfxInt32x2 iSampleOffsets[5] = {FfxInt32x2(+0, +0), FfxInt32x2(-1, +0), FfxInt32x2(+1, +0), FfxInt32x2(+0, -1), FfxInt32x2(+0, +1)};
#endif

        for (FfxInt32 iSampleIndex = 0; iSampleIndex < SHADING_CHANGE_SET_SIZE; iSampleIndex++) {

            const FfxInt32x2 iSamplePos = ClampLoad(iBasePos, iSampleOffsets[iSampleIndex], PreviousFrameRenderSize());
            data.fSet.fSamples[iSampleIndex] = LoadPreviousLuma(iSamplePos) * DeltaPreExposure() * Exposure();
            data.fSet.fSamples[iSampleIndex] = ffxPow(data.fSet.fSamples[iSampleIndex], fShadingChangeSamplePow);
            data.fSet.fSamples[iSampleIndex] = ffxMax(data.fSet.fSamples[iSampleIndex], FSR3UPSCALER_EPSILON);
        }
    }

    return data;
}

FfxFloat32 ComputeDiff(FfxInt32x2 iPxPos, FfxFloat32x2 fUv, FfxFloat32x2 fMotionVector)
{
    FfxFloat32 fMinDiff = 0.0f;

    const SampleSet fCurrentSamples = GetCurrentLumaBilinearSamples(fUv);
    const PreviousLumaBilinearSamplesData previousData = GetPreviousLumaBilinearSamples(fUv, fMotionVector);

    if (previousData.bIsExistingSample) {
        fMinDiff = ComputeMinimumDifference(iPxPos, fCurrentSamples, previousData.fSet);
    }

    return fMinDiff;
}

FfxFloat32x4 SpdLoadSourceImage(FfxFloat32x2 iPxPos, FfxUInt32 slice)
{
    const FfxInt32x2   iPxSamplePos = ClampLoad(FfxInt32x2(iPxPos), FfxInt32x2(0, 0), FfxInt32x2(RenderSize()));
    const FfxFloat32x2 fDilatedMotionVector = LoadDilatedMotionVector(iPxSamplePos);
    const FfxFloat32x2 fUv = (FfxFloat32x2(iPxSamplePos) + 0.5f) / FfxFloat32x2(RenderSize());

    const FfxFloat32 fScaledAndSignedLumaDiff = ComputeDiff(iPxSamplePos, fUv, fDilatedMotionVector);

    FfxFloat32x4 fOutput    = FfxFloat32x4(0.0f, 0.0f, 0.0f, 0.0f);
    fOutput[DIFFERENCE]     = fScaledAndSignedLumaDiff;
    fOutput[SIGN_SUM]       = (fScaledAndSignedLumaDiff != 0.0f) ? sign(fScaledAndSignedLumaDiff) : 0.0f;
    fOutput[MIP0_INDICATOR] = 1.0f;

    return fOutput;
}
#if defined(FFX_MSL)
FfxFloat32x4 SpdLoadSourceImage(FfxInt32x2 iPxPos, FfxUInt32 slice)
{
    return SpdLoadSourceImage(FfxFloat32x2(iPxPos), slice);
}
#endif

FfxFloat32x4 SpdLoad(FfxInt32x2 tex, FfxUInt32 slice)
{
    return FfxFloat32x4(RWLoadPyramid(tex, 5), 0, 0);
}

FfxFloat32x4 SpdReduce4(FfxFloat32x4 v0, FfxFloat32x4 v1, FfxFloat32x4 v2, FfxFloat32x4 v3)
{
    return (v0 + v1 + v2 + v3) * 0.25f;
}

void SpdStore(FfxInt32x2 pix, FfxFloat32x4 outValue, FfxUInt32 index, FfxUInt32 slice)
{
    if (index >= iShadingChangeMipStart)
    {
        StorePyramid(pix, outValue.xy, index);
    }
}

FfxFloat32x4 SpdLoadIntermediate(FfxUInt32 x, FfxUInt32 y)
{
#if defined(FFX_MSL)
    const FfxUInt32 idx = x * 16u + y;
    return FfxFloat32x4(
        spdIntermediateR[idx],
        spdIntermediateG[idx],
        spdIntermediateB[idx],
        spdIntermediateA[idx]);
#else
    return FfxFloat32x4(
        spdIntermediateR[x][y],
        spdIntermediateG[x][y],
        spdIntermediateB[x][y],
        spdIntermediateA[x][y]);
#endif
}
void SpdStoreIntermediate(FfxUInt32 x, FfxUInt32 y, FfxFloat32x4 value)
{
#if defined(FFX_MSL)
    const FfxUInt32 idx = x * 16u + y;
    spdIntermediateR[idx] = value.x;
    spdIntermediateG[idx] = value.y;
    spdIntermediateB[idx] = value.z;
    spdIntermediateA[idx] = value.w;
#else
    spdIntermediateR[x][y] = value.x;
    spdIntermediateG[x][y] = value.y;
    spdIntermediateB[x][y] = value.z;
    spdIntermediateA[x][y] = value.w;
#endif
}

#endif

// define fetch and store functions Packed
#if FFX_HALF

#if defined(FFX_MSL)
threadgroup FfxFloat16x2* spdIntermediateRG;
threadgroup FfxFloat16x2* spdIntermediateBA;
#else
FFX_GROUPSHARED FfxFloat16x2 spdIntermediateRG[16][16];
FFX_GROUPSHARED FfxFloat16x2 spdIntermediateBA[16][16];
#endif

FfxFloat16x4 SpdLoadSourceImageH(FfxFloat32x2 tex, FfxUInt32 slice)
{
    return FfxFloat16x4(0, 0, 0, 0);
}

FfxFloat16x4 SpdLoadH(FfxInt32x2 p, FfxUInt32 slice)
{
    return FfxFloat16x4(0, 0, 0, 0);
}

void SpdStoreH(FfxInt32x2 p, FfxFloat16x4 value, FfxUInt32 mip, FfxUInt32 slice)
{
}

FfxFloat16x4 SpdLoadIntermediateH(FfxUInt32 x, FfxUInt32 y)
{
#if defined(FFX_MSL)
    const FfxUInt32 idx = x * 16u + y;
    return FfxFloat16x4(
        spdIntermediateRG[idx].x,
        spdIntermediateRG[idx].y,
        spdIntermediateBA[idx].x,
        spdIntermediateBA[idx].y);
#else
    return FfxFloat16x4(
        spdIntermediateRG[x][y].x,
        spdIntermediateRG[x][y].y,
        spdIntermediateBA[x][y].x,
        spdIntermediateBA[x][y].y);
#endif
}

void SpdStoreIntermediateH(FfxUInt32 x, FfxUInt32 y, FfxFloat16x4 value)
{
#if defined(FFX_MSL)
    const FfxUInt32 idx = x * 16u + y;
    spdIntermediateRG[idx] = value.xy;
    spdIntermediateBA[idx] = value.zw;
#else
    spdIntermediateRG[x][y] = value.xy;
    spdIntermediateBA[x][y] = value.zw;
#endif
}

FfxFloat16x4 SpdReduce4H(FfxFloat16x4 v0, FfxFloat16x4 v1, FfxFloat16x4 v2, FfxFloat16x4 v3)
{
    return (v0 + v1 + v2 + v3) * FfxFloat16(0.25);
}
#endif

#include "spd/ffx_spd.h"

void ComputeShadingChangePyramid(FfxUInt32x3 WorkGroupId, FfxUInt32 LocalThreadIndex)
{
#if FFX_HALF
    SpdDownsampleH(
        FfxUInt32x2(WorkGroupId.xy),
        FfxUInt32(LocalThreadIndex),
        FfxUInt32(MipCount()),
        FfxUInt32(NumWorkGroups()),
        FfxUInt32(WorkGroupId.z),
        FfxUInt32x2(WorkGroupOffset()));
#else
    SpdDownsample(
        FfxUInt32x2(WorkGroupId.xy),
        FfxUInt32(LocalThreadIndex),
        FfxUInt32(MipCount()),
        FfxUInt32(NumWorkGroups()),
        FfxUInt32(WorkGroupId.z),
        FfxUInt32x2(WorkGroupOffset()));
#endif
}
