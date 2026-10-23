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

#define FFX_GPU  1
#define FFX_MSL  1
#define FFX_HALF 0

// Default permutation options for ShadingChangePyramid pass
#ifndef FFX_FSR3UPSCALER_OPTION_INVERTED_DEPTH
#define FFX_FSR3UPSCALER_OPTION_INVERTED_DEPTH                      0
#endif
#ifndef FFX_FSR3UPSCALER_OPTION_JITTERED_MOTION_VECTORS
#define FFX_FSR3UPSCALER_OPTION_JITTERED_MOTION_VECTORS             0
#endif
#ifndef FFX_FSR3UPSCALER_OPTION_LOW_RESOLUTION_MOTION_VECTORS
#define FFX_FSR3UPSCALER_OPTION_LOW_RESOLUTION_MOTION_VECTORS       1
#endif
#ifndef FFX_FSR3UPSCALER_OPTION_HDR_COLOR_INPUT
#define FFX_FSR3UPSCALER_OPTION_HDR_COLOR_INPUT                     0
#endif
#ifndef FFX_FSR3UPSCALER_OPTION_APPLY_SHARPENING
#define FFX_FSR3UPSCALER_OPTION_APPLY_SHARPENING                    0
#endif
#ifndef FFX_FSR3UPSCALER_OPTION_REPROJECT_USE_LANCZOS_TYPE
#define FFX_FSR3UPSCALER_OPTION_REPROJECT_USE_LANCZOS_TYPE          0
#endif
#ifndef FFX_FSR3UPSCALER_OPTION_UPSAMPLE_USE_LANCZOS_TYPE
#define FFX_FSR3UPSCALER_OPTION_UPSAMPLE_USE_LANCZOS_TYPE           2
#endif

// Resource binding macros for Pass 3: ShadingChangePyramid
#define FSR3UPSCALER_BIND_CB_FSR3UPSCALER                           0
#define FSR3UPSCALER_BIND_CB_SPD                                    1

#define FSR3UPSCALER_BIND_SRV_CURRENT_LUMA                          0
#define FSR3UPSCALER_BIND_SRV_PREVIOUS_LUMA                         1
#define FSR3UPSCALER_BIND_SRV_DILATED_MOTION_VECTORS                2
#define FSR3UPSCALER_BIND_SRV_INPUT_EXPOSURE                        3

#define FSR3UPSCALER_BIND_UAV_SPD_GLOBAL_ATOMIC                     4
#define FSR3UPSCALER_BIND_UAV_SPD_MIPS_LEVEL_0                      5
#define FSR3UPSCALER_BIND_UAV_SPD_MIPS_LEVEL_1                      6
#define FSR3UPSCALER_BIND_UAV_SPD_MIPS_LEVEL_2                      7
#define FSR3UPSCALER_BIND_UAV_SPD_MIPS_LEVEL_3                      8
#define FSR3UPSCALER_BIND_UAV_SPD_MIPS_LEVEL_4                      9
#define FSR3UPSCALER_BIND_UAV_SPD_MIPS_LEVEL_5                      10

#include "ffx_core.h"
#include "fsr3upscaler/ffx_fsr3upscaler_resources.h"

// Program-scope samplers and constant buffer structs
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
#endif

#define FFX_FSR3UPSCALER_MSL_SAMPLERS_ONLY
#include "fsr3upscaler/ffx_fsr3upscaler_callbacks_msl.h"
#undef FFX_FSR3UPSCALER_MSL_SAMPLERS_ONLY

struct ShadingChangePyramidPass
{
#include "fsr3upscaler/ffx_fsr3upscaler_callbacks_msl.h"
#include "fsr3upscaler/ffx_fsr3upscaler_common.h"
#include "fsr3upscaler/ffx_fsr3upscaler_shading_change_pyramid.h"
};

[[max_total_threads_per_threadgroup(256)]]
kernel void fsr3_shading_change_pyramid(
    constant Fsr3UpscalerConstants&           cb                          [[buffer(0)]],
    constant FfxSpdConstants&                 cbSPD                       [[buffer(1)]],
    texture2d<FfxFloat32, access::sample>     r_current_luma              [[texture(0)]],
    texture2d<FfxFloat32, access::sample>     r_previous_luma             [[texture(1)]],
    texture2d<FfxFloat32, access::sample>     r_dilated_motion_vectors    [[texture(2)]],
    texture2d<FfxFloat32, access::sample>     r_input_exposure            [[texture(3)]],
    texture2d<FfxUInt32,  access::read_write> rw_spd_global_atomic        [[texture(4)]],
    texture2d<FfxFloat32, access::read_write> rw_spd_mip0                 [[texture(5)]],
    texture2d<FfxFloat32, access::read_write> rw_spd_mip1                 [[texture(6)]],
    texture2d<FfxFloat32, access::read_write> rw_spd_mip2                 [[texture(7)]],
    texture2d<FfxFloat32, access::read_write> rw_spd_mip3                 [[texture(8)]],
    texture2d<FfxFloat32, access::read_write> rw_spd_mip4                 [[texture(9)]],
    texture2d<FfxFloat32, access::read_write> rw_spd_mip5                 [[texture(10)]],
    uint3                                     workGroupId                 [[threadgroup_position_in_grid]],
    uint                                      localThreadIndex            [[thread_index_in_threadgroup]])
{
    threadgroup FfxUInt32  spdCounter;
    threadgroup FfxFloat32 spdIntermediateR[16 * 16];
    threadgroup FfxFloat32 spdIntermediateG[16 * 16];
    threadgroup FfxFloat32 spdIntermediateB[16 * 16];
    threadgroup FfxFloat32 spdIntermediateA[16 * 16];

    ShadingChangePyramidPass pass = {
        cb,
        &cbSPD,
        r_current_luma,
        r_previous_luma,
        r_dilated_motion_vectors,
        r_input_exposure,
        rw_spd_mip0,
        rw_spd_mip1,
        rw_spd_mip2,
        rw_spd_mip3,
        rw_spd_mip4,
        rw_spd_mip5,
        rw_spd_global_atomic,
        &spdCounter,
        spdIntermediateR,
        spdIntermediateG,
        spdIntermediateB,
        spdIntermediateA
    };

    pass.ComputeShadingChangePyramid(workGroupId, localThreadIndex);
}
