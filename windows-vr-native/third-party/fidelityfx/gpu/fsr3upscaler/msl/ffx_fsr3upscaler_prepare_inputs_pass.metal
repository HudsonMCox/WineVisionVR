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

// Default permutation options for PrepareInputs pass
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

// Resource binding macros for Pass 1: PrepareInputs
#define FSR3UPSCALER_BIND_CB_FSR3UPSCALER                           0

#define FSR3UPSCALER_BIND_SRV_INPUT_COLOR                           0
#define FSR3UPSCALER_BIND_SRV_INPUT_DEPTH                           1
#define FSR3UPSCALER_BIND_SRV_INPUT_MOTION_VECTORS                  2

#define FSR3UPSCALER_BIND_UAV_RECONSTRUCTED_PREV_NEAREST_DEPTH      3
#define FSR3UPSCALER_BIND_UAV_DILATED_MOTION_VECTORS                4
#define FSR3UPSCALER_BIND_UAV_DILATED_DEPTH                         5
#define FSR3UPSCALER_BIND_UAV_FARTHEST_DEPTH                        6
#define FSR3UPSCALER_BIND_UAV_CURRENT_LUMA                          7

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

struct PrepareInputsPass
{
#include "fsr3upscaler/ffx_fsr3upscaler_callbacks_msl.h"
#include "fsr3upscaler/ffx_fsr3upscaler_common.h"
#include "fsr3upscaler/ffx_fsr3upscaler_prepare_inputs.h"
};

[[max_total_threads_per_threadgroup(64)]]
kernel void fsr3_prepare_inputs(
    constant Fsr3UpscalerConstants&           cb                                        [[buffer(0)]],
    texture2d<FfxFloat32, access::sample>     r_input_color_jittered                    [[texture(0)]],
    texture2d<FfxFloat32, access::sample>     r_input_depth                             [[texture(1)]],
    texture2d<FfxFloat32, access::sample>     r_input_motion_vectors                    [[texture(2)]],
    texture2d<FfxUInt32,  access::read_write> rw_reconstructed_previous_nearest_depth   [[texture(3)]],
    texture2d<FfxFloat32, access::read_write> rw_dilated_motion_vectors                 [[texture(4)]],
    texture2d<FfxFloat32, access::read_write> rw_dilated_depth                          [[texture(5)]],
    texture2d<FfxFloat32, access::read_write> rw_farthest_depth                         [[texture(6)]],
    texture2d<FfxFloat32, access::read_write> rw_current_luma                           [[texture(7)]],
    uint3                                     dtid                                      [[thread_position_in_grid]])
{
    PrepareInputsPass pass = {
        cb,
        r_input_depth,
        r_input_color_jittered,
        r_input_motion_vectors,
        rw_farthest_depth,
        rw_current_luma,
        rw_reconstructed_previous_nearest_depth,
        rw_dilated_depth,
        rw_dilated_motion_vectors
    };

    pass.PrepareInputs(FfxInt32x2(dtid.xy));
}
