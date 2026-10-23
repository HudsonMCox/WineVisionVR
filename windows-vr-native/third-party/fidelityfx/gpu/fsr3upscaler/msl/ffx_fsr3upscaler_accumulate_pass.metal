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

// Default permutation options for Accumulate pass
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

// Resource binding macros for Pass 7: Accumulate
#define FSR3UPSCALER_BIND_CB_FSR3UPSCALER                           0

#define FSR3UPSCALER_BIND_SRV_INPUT_EXPOSURE                        0
#define FSR3UPSCALER_BIND_SRV_DILATED_REACTIVE_MASKS                1
#define FSR3UPSCALER_BIND_SRV_INPUT_MOTION_VECTORS                  2
#define FSR3UPSCALER_BIND_SRV_DILATED_MOTION_VECTORS                3
#define FSR3UPSCALER_BIND_SRV_INTERNAL_UPSCALED                     4
#define FSR3UPSCALER_BIND_SRV_LANCZOS_LUT                           5
#define FSR3UPSCALER_BIND_SRV_FARTHEST_DEPTH_MIP1                   6
#define FSR3UPSCALER_BIND_SRV_LUMA_INSTABILITY                      7
#define FSR3UPSCALER_BIND_SRV_INPUT_COLOR                           8

#define FSR3UPSCALER_BIND_UAV_INTERNAL_UPSCALED                     9
#define FSR3UPSCALER_BIND_UAV_NEW_LOCKS                             10
#define FSR3UPSCALER_BIND_UAV_UPSCALED_OUTPUT                       11

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

struct AccumulatePass
{
#include "fsr3upscaler/ffx_fsr3upscaler_callbacks_msl.h"
#include "fsr3upscaler/ffx_fsr3upscaler_common.h"
#include "fsr3upscaler/ffx_fsr3upscaler_sample.h"
#include "fsr3upscaler/ffx_fsr3upscaler_upsample.h"
#include "fsr3upscaler/ffx_fsr3upscaler_reproject.h"
#include "fsr3upscaler/ffx_fsr3upscaler_accumulate.h"
};

[[max_total_threads_per_threadgroup(64)]]
kernel void fsr3_accumulate(
    constant Fsr3UpscalerConstants&           cb                          [[buffer(0)]],
    texture2d<FfxFloat32, access::sample>     r_input_exposure            [[texture(0)]],
    texture2d<FfxFloat32, access::sample>     r_dilated_reactive_masks    [[texture(1)]],
    texture2d<FfxFloat32, access::sample>     r_input_motion_vectors      [[texture(2)]],
    texture2d<FfxFloat32, access::sample>     r_dilated_motion_vectors    [[texture(3)]],
    texture2d<FfxFloat32, access::sample>     r_internal_upscaled_color   [[texture(4)]],
    texture2d<FfxFloat32, access::sample>     r_lanczos_lut               [[texture(5)]],
    texture2d<FfxFloat32, access::sample>     r_farthest_depth_mip1       [[texture(6)]],
    texture2d<FfxFloat32, access::sample>     r_luma_instability          [[texture(7)]],
    texture2d<FfxFloat32, access::sample>     r_input_color_jittered      [[texture(8)]],
    texture2d<FfxFloat32, access::read_write> rw_internal_upscaled_color  [[texture(9)]],
    texture2d<FfxFloat32, access::read_write> rw_new_locks                [[texture(10)]],
    texture2d<FfxFloat32, access::read_write> rw_upscaled_output          [[texture(11)]],
    uint3                                     dtid                        [[thread_position_in_grid]])
{
    AccumulatePass pass = {
        cb,
        r_input_color_jittered,
        r_input_motion_vectors,
        r_internal_upscaled_color,
        rw_internal_upscaled_color,
        rw_upscaled_output,
        r_farthest_depth_mip1,
        r_luma_instability,
        rw_new_locks,
        r_dilated_motion_vectors,
        r_input_exposure,
        r_lanczos_lut,
        r_dilated_reactive_masks
    };

    pass.Accumulate(FfxInt32x2(dtid.xy));
}
