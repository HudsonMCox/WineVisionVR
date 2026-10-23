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

/// @defgroup MSLCore MSL Core
/// Metal Shading Language core defines and functions (Target: Metal 3 / MSL 3.0)
///
/// @ingroup FfxGPU

#if defined(FFX_MSL) && defined(FFX_GPU)

#include <metal_stdlib>
using namespace metal;

//==============================================================================================================================
//                                                  MSL PARAMETER & TYPE DEFINITIONS
//==============================================================================================================================

// NOTE: HLSL "out"/"inout" parameter qualifiers are prefix tokens, whereas MSL requires a reference
// declarator ('&') after the type (e.g. "thread FfxFloat32x3& fHistoryColor"), which a prefix macro
// cannot produce. FFX_PARAMETER_OUT and FFX_PARAMETER_INOUT expand to the "thread" address space
// qualifier here; the ~24 fsr3upscaler/*.h (and ffx_core_portability.h) parameter declarations must
// add '&' after the type under FFX_MSL.
#ifndef FFX_PARAMETER_IN
#define FFX_PARAMETER_IN
#endif
#ifndef FFX_PARAMETER_OUT
#define FFX_PARAMETER_OUT       thread
#endif
#ifndef FFX_PARAMETER_INOUT
#define FFX_PARAMETER_INOUT     thread
#endif
#ifndef FFX_PARAMETER_UNIFORM
#define FFX_PARAMETER_UNIFORM
#endif
/// Reference marker placed after the type of out/inout parameters in the shared headers.
#define FFX_PARAMETER_REF &

/// Boolean and 32-bit scalar/vector type aliases.
typedef bool     FfxBoolean;

typedef float    FfxFloat32;
typedef float2   FfxFloat32x2;
typedef float3   FfxFloat32x3;
typedef float4   FfxFloat32x4;

typedef uint     FfxUInt32;
typedef uint2    FfxUInt32x2;
typedef uint3    FfxUInt32x3;
typedef uint4    FfxUInt32x4;

typedef int      FfxInt32;
typedef int2     FfxInt32x2;
typedef int3     FfxInt32x3;
typedef int4     FfxInt32x4;

/// Matrix type aliases.
#define FfxFloat32Mat4 float4x4
#define FfxFloat32Mat3 float3x3
typedef float4x4 FfxFloat32x4x4;
typedef float3x4 FfxFloat32x3x4;
typedef float3x3 FfxFloat32x3x3;
typedef float2x2 FfxFloat32x2x2;

/// 16-bit scalar/vector type aliases.
typedef half     FfxFloat16;
typedef half2    FfxFloat16x2;
typedef half3    FfxFloat16x3;
typedef half4    FfxFloat16x4;

typedef ushort   FfxUInt16;
typedef ushort2  FfxUInt16x2;
typedef ushort3  FfxUInt16x3;
typedef ushort4  FfxUInt16x4;

typedef short    FfxInt16;
typedef short2   FfxInt16x2;
typedef short3   FfxInt16x3;
typedef short4   FfxInt16x4;

/// HLSL min16* types mapped to their 32-bit equivalents in this 32-bit core section.
typedef FfxFloat32   min16float;
typedef FfxFloat32x2 min16float2;
typedef FfxFloat32x3 min16float3;
typedef FfxFloat32x4 min16float4;

typedef FfxUInt32    min16uint;
typedef FfxUInt32x2  min16uint2;
typedef FfxUInt32x3  min16uint3;
typedef FfxUInt32x4  min16uint4;

typedef FfxInt32     min16int;
typedef FfxInt32x2   min16int2;
typedef FfxInt32x3   min16int3;
typedef FfxInt32x4   min16int4;

/// FFX_MIN16_* and FFX_16BIT_* type aliases (mapped to 32-bit types when FFX_HALF is off).
#if FFX_HALF
typedef half     FFX_MIN16_F;
typedef half2    FFX_MIN16_F2;
typedef half3    FFX_MIN16_F3;
typedef half4    FFX_MIN16_F4;

typedef short    FFX_MIN16_I;
typedef short2   FFX_MIN16_I2;
typedef short3   FFX_MIN16_I3;
typedef short4   FFX_MIN16_I4;

typedef ushort   FFX_MIN16_U;
typedef ushort2  FFX_MIN16_U2;
typedef ushort3  FFX_MIN16_U3;
typedef ushort4  FFX_MIN16_U4;

typedef half     FFX_16BIT_F;
typedef half2    FFX_16BIT_F2;
typedef half3    FFX_16BIT_F3;
typedef half4    FFX_16BIT_F4;

typedef short    FFX_16BIT_I;
typedef short2   FFX_16BIT_I2;
typedef short3   FFX_16BIT_I3;
typedef short4   FFX_16BIT_I4;

typedef ushort   FFX_16BIT_U;
typedef ushort2  FFX_16BIT_U2;
typedef ushort3  FFX_16BIT_U3;
typedef ushort4  FFX_16BIT_U4;

typedef half     FFX_F16_t;
typedef half2    FFX_F16_t2;
typedef half3    FFX_F16_t3;
typedef half4    FFX_F16_t4;

typedef short    FFX_I16_t;
typedef short2   FFX_I16_t2;
typedef short3   FFX_I16_t3;
typedef short4   FFX_I16_t4;

typedef ushort   FFX_U16_t;
typedef ushort2  FFX_U16_t2;
typedef ushort3  FFX_U16_t3;
typedef ushort4  FFX_U16_t4;
#else // !FFX_HALF
typedef FfxFloat32   FFX_MIN16_F;
typedef FfxFloat32x2 FFX_MIN16_F2;
typedef FfxFloat32x3 FFX_MIN16_F3;
typedef FfxFloat32x4 FFX_MIN16_F4;

typedef FfxInt32     FFX_MIN16_I;
typedef FfxInt32x2   FFX_MIN16_I2;
typedef FfxInt32x3   FFX_MIN16_I3;
typedef FfxInt32x4   FFX_MIN16_I4;

typedef FfxUInt32    FFX_MIN16_U;
typedef FfxUInt32x2  FFX_MIN16_U2;
typedef FfxUInt32x3  FFX_MIN16_U3;
typedef FfxUInt32x4  FFX_MIN16_U4;

typedef FfxFloat32   FFX_16BIT_F;
typedef FfxFloat32x2 FFX_16BIT_F2;
typedef FfxFloat32x3 FFX_16BIT_F3;
typedef FfxFloat32x4 FFX_16BIT_F4;

typedef FfxInt32     FFX_16BIT_I;
typedef FfxInt32x2   FFX_16BIT_I2;
typedef FfxInt32x3   FFX_16BIT_I3;
typedef FfxInt32x4   FFX_16BIT_I4;

typedef FfxUInt32    FFX_16BIT_U;
typedef FfxUInt32x2  FFX_16BIT_U2;
typedef FfxUInt32x3  FFX_16BIT_U3;
typedef FfxUInt32x4  FFX_16BIT_U4;

typedef FfxFloat32   FFX_F16_t;
typedef FfxFloat32x2 FFX_F16_t2;
typedef FfxFloat32x3 FFX_F16_t3;
typedef FfxFloat32x4 FFX_F16_t4;

typedef FfxInt32     FFX_I16_t;
typedef FfxInt32x2   FFX_I16_t2;
typedef FfxInt32x3   FFX_I16_t3;
typedef FfxInt32x4   FFX_I16_t4;

typedef FfxUInt32    FFX_U16_t;
typedef FfxUInt32x2  FFX_U16_t2;
typedef FfxUInt32x3  FFX_U16_t3;
typedef FfxUInt32x4  FFX_U16_t4;
#endif // FFX_HALF

#ifndef TYPEDEF_MIN16_TYPES
#define TYPEDEF_MIN16_TYPES(Prefix)           \
typedef FFX_MIN16_F     Prefix##_F;           \
typedef FFX_MIN16_F2    Prefix##_F2;          \
typedef FFX_MIN16_F3    Prefix##_F3;          \
typedef FFX_MIN16_F4    Prefix##_F4;          \
typedef FFX_MIN16_I     Prefix##_I;           \
typedef FFX_MIN16_I2    Prefix##_I2;          \
typedef FFX_MIN16_I3    Prefix##_I3;          \
typedef FFX_MIN16_I4    Prefix##_I4;          \
typedef FFX_MIN16_U     Prefix##_U;           \
typedef FFX_MIN16_U2    Prefix##_U2;          \
typedef FFX_MIN16_U3    Prefix##_U3;          \
typedef FFX_MIN16_U4    Prefix##_U4;
#endif

#ifndef TYPEDEF_16BIT_TYPES
#define TYPEDEF_16BIT_TYPES(Prefix)           \
typedef FFX_16BIT_F     Prefix##_F;           \
typedef FFX_16BIT_F2    Prefix##_F2;          \
typedef FFX_16BIT_F3    Prefix##_F3;          \
typedef FFX_16BIT_F4    Prefix##_F4;          \
typedef FFX_16BIT_I     Prefix##_I;           \
typedef FFX_16BIT_I2    Prefix##_I2;          \
typedef FFX_16BIT_I3    Prefix##_I3;          \
typedef FFX_16BIT_I4    Prefix##_I4;          \
typedef FFX_16BIT_U     Prefix##_U;           \
typedef FFX_16BIT_U2    Prefix##_U2;          \
typedef FFX_16BIT_U3    Prefix##_U3;          \
typedef FFX_16BIT_U4    Prefix##_U4;
#endif

#ifndef TYPEDEF_FULL_PRECISION_TYPES
#define TYPEDEF_FULL_PRECISION_TYPES(Prefix)  \
typedef FfxFloat32      Prefix##_F;           \
typedef FfxFloat32x2    Prefix##_F2;          \
typedef FfxFloat32x3    Prefix##_F3;          \
typedef FfxFloat32x4    Prefix##_F4;          \
typedef FfxInt32        Prefix##_I;           \
typedef FfxInt32x2      Prefix##_I2;          \
typedef FfxInt32x3      Prefix##_I3;          \
typedef FfxInt32x4      Prefix##_I4;          \
typedef FfxUInt32       Prefix##_U;           \
typedef FfxUInt32x2     Prefix##_U2;          \
typedef FfxUInt32x3     Prefix##_U3;          \
typedef FfxUInt32x4     Prefix##_U4;
#endif

//==============================================================================================================================
//                                                      MSL CORE MACROS
//==============================================================================================================================

#define DECLARE_SRV_REGISTER(regIndex) regIndex
#define DECLARE_UAV_REGISTER(regIndex) regIndex
#define DECLARE_CB_REGISTER(regIndex)  regIndex
#define FFX_DECLARE_SRV(regIndex)      [[texture(DECLARE_SRV_REGISTER(regIndex))]]
#define FFX_DECLARE_UAV(regIndex)      [[texture(DECLARE_UAV_REGISTER(regIndex))]]
#define FFX_DECLARE_CB(regIndex)       [[buffer(DECLARE_CB_REGISTER(regIndex))]]

/// A define for abstracting select functionality.
/// Note: metal::select(a, b, c) has reversed argument order (c ? b : a) compared to HLSL 2021 select(cond, a, b),
/// so we pass condition last: metal::select(false_val, true_val, cond).
#define FFX_SELECT(cond, arg1, arg2) metal::select((arg2), (arg1), (cond))

/// A define for abstracting shared memory between shading languages.
#define FFX_GROUPSHARED threadgroup

/// A define for abstracting compute memory barriers between shading languages.
#define FFX_GROUP_MEMORY_BARRIER threadgroup_barrier(mem_flags::mem_threadgroup)

/// A define for abstracting compute atomic additions between shading languages.
/// Note: Target variable 'x' in MSL must be atomic_uint / atomic_int in device or threadgroup address space.
#define FFX_ATOMIC_ADD(x, y) atomic_fetch_add_explicit(&(x), y, memory_order_relaxed)

/// A define for abstracting compute atomic additions returning previous value.
#define FFX_ATOMIC_ADD_RETURN(x, y, r) ((r) = atomic_fetch_add_explicit(&(x), y, memory_order_relaxed))

/// A define for abstracting compute atomic OR between shading languages.
#define FFX_ATOMIC_OR(x, y) atomic_fetch_or_explicit(&(x), y, memory_order_relaxed)

/// A define for abstracting compute atomic min between shading languages.
#define FFX_ATOMIC_MIN(x, y) atomic_fetch_min_explicit(&(x), y, memory_order_relaxed)

/// A define for abstracting compute atomic max between shading languages.
#define FFX_ATOMIC_MAX(x, y) atomic_fetch_max_explicit(&(x), y, memory_order_relaxed)

/// A define added to accept static markup on constants/functions.
/// In MSL, program-scope constants ("FFX_STATIC const ...") must reside in the 'constant' address space.
#define FFX_STATIC static constant

/// A define for abstracting loop unrolling between shading languages.
#define FFX_UNROLL

/// Comparison operator macros.
#define FFX_GREATER_THAN(x, y)       x > y
#define FFX_GREATER_THAN_EQUAL(x, y) x >= y
#define FFX_LESS_THAN(x, y)          x < y
#define FFX_LESS_THAN_EQUAL(x, y)    x <= y
#define FFX_EQUAL(x, y)              x == y
#define FFX_NOT_EQUAL(x, y)          x != y

/// A define for abstracting matrix multiply operations between shading languages.
#define FFX_MATRIX_MULTIPLY(a, b) ((a) * (b))

/// A define for abstracting vector transformations between shading languages.
#define FFX_TRANSFORM_VECTOR(a, b) ((a) * (b))

/// A define for abstracting modulo operations between shading languages.
#define FFX_MODULO(a, b) (fmod(a, b))

/// Broadcast macros for 32-bit float vectors.
#define FFX_BROADCAST_FLOAT32(x)   FfxFloat32(x)
#define FFX_BROADCAST_FLOAT32X2(x) FfxFloat32x2(x)
#define FFX_BROADCAST_FLOAT32X3(x) FfxFloat32x3(x)
#define FFX_BROADCAST_FLOAT32X4(x) FfxFloat32x4(x)

/// Broadcast macros for 32-bit unsigned integer vectors.
#define FFX_BROADCAST_UINT32(x)    FfxUInt32(x)
#define FFX_BROADCAST_UINT32X2(x)  FfxUInt32x2(x)
#define FFX_BROADCAST_UINT32X3(x)  FfxUInt32x3(x)
#define FFX_BROADCAST_UINT32X4(x)  FfxUInt32x4(x)

/// Broadcast macros for 32-bit signed integer vectors.
#define FFX_BROADCAST_INT32(x)     FfxInt32(x)
#define FFX_BROADCAST_INT32X2(x)   FfxInt32x2(x)
#define FFX_BROADCAST_INT32X3(x)   FfxInt32x3(x)
#define FFX_BROADCAST_INT32X4(x)   FfxInt32x4(x)

/// Broadcast macros for min16 float vectors.
#define FFX_BROADCAST_MIN_FLOAT16(a)   FFX_MIN16_F(a)
#define FFX_BROADCAST_MIN_FLOAT16X2(a) FFX_MIN16_F2(a)
#define FFX_BROADCAST_MIN_FLOAT16X3(a) FFX_MIN16_F3(a)
#define FFX_BROADCAST_MIN_FLOAT16X4(a) FFX_MIN16_F4(a)

/// Broadcast macros for min16 unsigned integer vectors.
#define FFX_BROADCAST_MIN_UINT16(a)    FFX_MIN16_U(a)
#define FFX_BROADCAST_MIN_UINT16X2(a)  FFX_MIN16_U2(a)
#define FFX_BROADCAST_MIN_UINT16X3(a)  FFX_MIN16_U3(a)
#define FFX_BROADCAST_MIN_UINT16X4(a)  FFX_MIN16_U4(a)

/// Broadcast macros for min16 signed integer vectors.
#define FFX_BROADCAST_MIN_INT16(a)     FFX_MIN16_I(a)
#define FFX_BROADCAST_MIN_INT16X2(a)   FFX_MIN16_I2(a)
#define FFX_BROADCAST_MIN_INT16X3(a)   FFX_MIN16_I3(a)
#define FFX_BROADCAST_MIN_INT16X4(a)   FFX_MIN16_I4(a)

//==============================================================================================================================
//                                              HLSL INTRINSIC COMPATIBILITY SHIMS
//==============================================================================================================================

/// Convert 32-bit float to IEEE 754 binary16 bits in the lower 16 bits of a 32-bit uint.
inline FfxUInt32 f32tof16(FfxFloat32 x)
{
    return FfxUInt32(as_type<ushort>(half(x)));
}

inline FfxUInt32x2 f32tof16(FfxFloat32x2 x)
{
    return FfxUInt32x2(as_type<ushort2>(half2(x)));
}

inline FfxUInt32x3 f32tof16(FfxFloat32x3 x)
{
    return FfxUInt32x3(as_type<ushort3>(half3(x)));
}

inline FfxUInt32x4 f32tof16(FfxFloat32x4 x)
{
    return FfxUInt32x4(as_type<ushort4>(half4(x)));
}

/// Convert IEEE 754 binary16 bits in the lower 16 bits of a 32-bit uint to 32-bit float.
inline FfxFloat32 f16tof32(FfxUInt32 x)
{
    return float(as_type<half>(ushort(x)));
}

inline FfxFloat32x2 f16tof32(FfxUInt32x2 x)
{
    return float2(as_type<half2>(ushort2(x)));
}

inline FfxFloat32x3 f16tof32(FfxUInt32x3 x)
{
    return float3(as_type<half3>(ushort3(x)));
}

inline FfxFloat32x4 f16tof32(FfxUInt32x4 x)
{
    return float4(as_type<half4>(ushort4(x)));
}

/// Bitcast helpers matching HLSL asuint / asfloat.
inline FfxUInt32   asuint(FfxFloat32 x)   { return as_type<FfxUInt32>(x); }
inline FfxUInt32x2 asuint(FfxFloat32x2 x) { return as_type<FfxUInt32x2>(x); }
inline FfxUInt32x3 asuint(FfxFloat32x3 x) { return as_type<FfxUInt32x3>(x); }
inline FfxUInt32x4 asuint(FfxFloat32x4 x) { return as_type<FfxUInt32x4>(x); }
inline FfxUInt32   asuint(FfxInt32 x)     { return as_type<FfxUInt32>(x); }
inline FfxUInt32x2 asuint(FfxInt32x2 x)   { return as_type<FfxUInt32x2>(x); }
inline FfxUInt32x3 asuint(FfxInt32x3 x)   { return as_type<FfxUInt32x3>(x); }
inline FfxUInt32x4 asuint(FfxInt32x4 x)   { return as_type<FfxUInt32x4>(x); }
inline FfxUInt32   asuint(FfxUInt32 x)    { return x; }
inline FfxUInt32x2 asuint(FfxUInt32x2 x)  { return x; }
inline FfxUInt32x3 asuint(FfxUInt32x3 x)  { return x; }
inline FfxUInt32x4 asuint(FfxUInt32x4 x)  { return x; }

inline FfxFloat32   asfloat(FfxUInt32 x)   { return as_type<FfxFloat32>(x); }
inline FfxFloat32x2 asfloat(FfxUInt32x2 x) { return as_type<FfxFloat32x2>(x); }
inline FfxFloat32x3 asfloat(FfxUInt32x3 x) { return as_type<FfxFloat32x3>(x); }
inline FfxFloat32x4 asfloat(FfxUInt32x4 x) { return as_type<FfxFloat32x4>(x); }
inline FfxFloat32   asfloat(FfxInt32 x)    { return as_type<FfxFloat32>(x); }
inline FfxFloat32x2 asfloat(FfxInt32x2 x)  { return as_type<FfxFloat32x2>(x); }
inline FfxFloat32x3 asfloat(FfxInt32x3 x)  { return as_type<FfxFloat32x3>(x); }
inline FfxFloat32x4 asfloat(FfxInt32x4 x)  { return as_type<FfxFloat32x4>(x); }
inline FfxFloat32   asfloat(FfxFloat32 x)  { return x; }
inline FfxFloat32x2 asfloat(FfxFloat32x2 x){ return x; }
inline FfxFloat32x3 asfloat(FfxFloat32x3 x){ return x; }
inline FfxFloat32x4 asfloat(FfxFloat32x4 x){ return x; }

/// HLSL math and bit-manipulation shims (lerp, frac, mad, rcp, firstbithigh, firstbitlow, countbits, reversebits).
inline FfxFloat32   lerp(FfxFloat32 x, FfxFloat32 y, FfxFloat32 t)       { return mix(x, y, t); }
inline FfxFloat32x2 lerp(FfxFloat32x2 x, FfxFloat32x2 y, FfxFloat32 t)   { return mix(x, y, t); }
inline FfxFloat32x2 lerp(FfxFloat32x2 x, FfxFloat32x2 y, FfxFloat32x2 t) { return mix(x, y, t); }
inline FfxFloat32x3 lerp(FfxFloat32x3 x, FfxFloat32x3 y, FfxFloat32 t)   { return mix(x, y, t); }
inline FfxFloat32x3 lerp(FfxFloat32x3 x, FfxFloat32x3 y, FfxFloat32x3 t) { return mix(x, y, t); }
inline FfxFloat32x4 lerp(FfxFloat32x4 x, FfxFloat32x4 y, FfxFloat32 t)   { return mix(x, y, t); }
inline FfxFloat32x4 lerp(FfxFloat32x4 x, FfxFloat32x4 y, FfxFloat32x4 t) { return mix(x, y, t); }

inline FfxFloat32   frac(FfxFloat32 x)   { return fract(x); }
inline FfxFloat32x2 frac(FfxFloat32x2 x) { return fract(x); }
inline FfxFloat32x3 frac(FfxFloat32x3 x) { return fract(x); }
inline FfxFloat32x4 frac(FfxFloat32x4 x) { return fract(x); }

inline FfxFloat32   mad(FfxFloat32 a, FfxFloat32 b, FfxFloat32 c)       { return fma(a, b, c); }
inline FfxFloat32x2 mad(FfxFloat32x2 a, FfxFloat32x2 b, FfxFloat32x2 c) { return fma(a, b, c); }
inline FfxFloat32x3 mad(FfxFloat32x3 a, FfxFloat32x3 b, FfxFloat32x3 c) { return fma(a, b, c); }
inline FfxFloat32x4 mad(FfxFloat32x4 a, FfxFloat32x4 b, FfxFloat32x4 c) { return fma(a, b, c); }

inline FfxFloat32   rcp(FfxFloat32 x)   { return 1.0f / x; }
inline FfxFloat32x2 rcp(FfxFloat32x2 x) { return 1.0f / x; }
inline FfxFloat32x3 rcp(FfxFloat32x3 x) { return 1.0f / x; }
inline FfxFloat32x4 rcp(FfxFloat32x4 x) { return 1.0f / x; }

inline FfxUInt32   firstbithigh(FfxUInt32 x)   { return 31u - clz(x); }
inline FfxUInt32x2 firstbithigh(FfxUInt32x2 x) { return 31u - clz(x); }
inline FfxUInt32x3 firstbithigh(FfxUInt32x3 x) { return 31u - clz(x); }
inline FfxUInt32x4 firstbithigh(FfxUInt32x4 x) { return 31u - clz(x); }

inline FfxUInt32   firstbitlow(FfxUInt32 x)    { return ctz(x); }
inline FfxUInt32x2 firstbitlow(FfxUInt32x2 x)  { return ctz(x); }
inline FfxUInt32x3 firstbitlow(FfxUInt32x3 x)  { return ctz(x); }
inline FfxUInt32x4 firstbitlow(FfxUInt32x4 x)  { return ctz(x); }

inline FfxUInt32   countbits(FfxUInt32 x)      { return popcount(x); }
inline FfxUInt32x2 countbits(FfxUInt32x2 x)    { return popcount(x); }
inline FfxUInt32x3 countbits(FfxUInt32x3 x)    { return popcount(x); }
inline FfxUInt32x4 countbits(FfxUInt32x4 x)    { return popcount(x); }

inline FfxUInt32   reversebits(FfxUInt32 x)    { return reverse_bits(x); }
inline FfxUInt32x2 reversebits(FfxUInt32x2 x)  { return reverse_bits(x); }
inline FfxUInt32x3 reversebits(FfxUInt32x3 x)  { return reverse_bits(x); }
inline FfxUInt32x4 reversebits(FfxUInt32x4 x)  { return reverse_bits(x); }

//==============================================================================================================================
//                                                   32-BIT HELPER FUNCTIONS
//==============================================================================================================================

/// Convert FfxFloat32 to half (in lower 16-bits of output).
#define ffxF32ToF16 f32tof16

/// Pack 2x32-bit floating point values in a single 32bit value.
FFX_MSL_INLINE FfxUInt32 ffxPackHalf2x16(FfxFloat32x2 value)
{
    return ffxF32ToF16(value.x) | (ffxF32ToF16(value.y) << 16);
}

/// Broadcast a scalar value to a 2-dimensional floating point vector.
FFX_MSL_INLINE FfxFloat32x2 ffxBroadcast2(FfxFloat32 value)
{
    return FfxFloat32x2(value, value);
}

/// Broadcast a scalar value to a 3-dimensional floating point vector.
FFX_MSL_INLINE FfxFloat32x3 ffxBroadcast3(FfxFloat32 value)
{
    return FfxFloat32x3(value, value, value);
}

/// Broadcast a scalar value to a 4-dimensional floating point vector.
FFX_MSL_INLINE FfxFloat32x4 ffxBroadcast4(FfxFloat32 value)
{
    return FfxFloat32x4(value, value, value, value);
}

/// Broadcast a scalar value to a 2-dimensional signed integer vector.
FFX_MSL_INLINE FfxInt32x2 ffxBroadcast2(FfxInt32 value)
{
    return FfxInt32x2(value, value);
}

/// Broadcast a scalar value to a 3-dimensional signed integer vector.
FFX_MSL_INLINE FfxInt32x3 ffxBroadcast3(FfxInt32 value)
{
    return FfxInt32x3(value, value, value);
}

/// Broadcast a scalar value to a 4-dimensional signed integer vector.
FFX_MSL_INLINE FfxInt32x4 ffxBroadcast4(FfxInt32 value)
{
    return FfxInt32x4(value, value, value, value);
}

/// Broadcast a scalar value to a 2-dimensional unsigned integer vector.
FFX_MSL_INLINE FfxUInt32x2 ffxBroadcast2(FfxUInt32 value)
{
    return FfxUInt32x2(value, value);
}

/// Broadcast a scalar value to a 3-dimensional unsigned integer vector.
FFX_MSL_INLINE FfxUInt32x3 ffxBroadcast3(FfxUInt32 value)
{
    return FfxUInt32x3(value, value, value);
}

/// Broadcast a scalar value to a 4-dimensional unsigned integer vector.
FFX_MSL_INLINE FfxUInt32x4 ffxBroadcast4(FfxUInt32 value)
{
    return FfxUInt32x4(value, value, value, value);
}

FFX_MSL_INLINE FfxUInt32 ffxBitfieldExtract(FfxUInt32 src, FfxUInt32 off, FfxUInt32 bits)
{
    FfxUInt32 mask = (1u << bits) - 1;
    return (src >> off) & mask;
}

FFX_MSL_INLINE FfxUInt32 ffxBitfieldInsert(FfxUInt32 src, FfxUInt32 ins, FfxUInt32 mask)
{
    return (ins & mask) | (src & (~mask));
}

FFX_MSL_INLINE FfxUInt32 ffxBitfieldInsertMask(FfxUInt32 src, FfxUInt32 ins, FfxUInt32 bits)
{
    FfxUInt32 mask = (1u << bits) - 1;
    return (ins & mask) | (src & (~mask));
}

/// Interprets the bit pattern of x as an unsigned integer.
FFX_MSL_INLINE FfxUInt32 ffxAsUInt32(FfxFloat32 x)
{
    return as_type<FfxUInt32>(x);
}

FFX_MSL_INLINE FfxUInt32x2 ffxAsUInt32(FfxFloat32x2 x)
{
    return as_type<FfxUInt32x2>(x);
}

FFX_MSL_INLINE FfxUInt32x3 ffxAsUInt32(FfxFloat32x3 x)
{
    return as_type<FfxUInt32x3>(x);
}

FFX_MSL_INLINE FfxUInt32x4 ffxAsUInt32(FfxFloat32x4 x)
{
    return as_type<FfxUInt32x4>(x);
}

/// Interprets the bit pattern of x as a floating-point number.
FFX_MSL_INLINE FfxFloat32 ffxAsFloat(FfxUInt32 x)
{
    return as_type<FfxFloat32>(x);
}

FFX_MSL_INLINE FfxFloat32x2 ffxAsFloat(FfxUInt32x2 x)
{
    return as_type<FfxFloat32x2>(x);
}

FFX_MSL_INLINE FfxFloat32x3 ffxAsFloat(FfxUInt32x3 x)
{
    return as_type<FfxFloat32x3>(x);
}

FFX_MSL_INLINE FfxFloat32x4 ffxAsFloat(FfxUInt32x4 x)
{
    return as_type<FfxFloat32x4>(x);
}

/// Compute the inverse of a value.
FFX_MSL_INLINE FfxFloat32 ffxReciprocal(FfxFloat32 x)
{
    return 1.0f / x;
}

FFX_MSL_INLINE FfxFloat32x2 ffxReciprocal(FfxFloat32x2 x)
{
    return 1.0f / x;
}

FFX_MSL_INLINE FfxFloat32x3 ffxReciprocal(FfxFloat32x3 x)
{
    return 1.0f / x;
}

FFX_MSL_INLINE FfxFloat32x4 ffxReciprocal(FfxFloat32x4 x)
{
    return 1.0f / x;
}

/// Compute the inverse square root of a value.
FFX_MSL_INLINE FfxFloat32 ffxRsqrt(FfxFloat32 x)
{
    return rsqrt(x);
}

FFX_MSL_INLINE FfxFloat32x2 ffxRsqrt(FfxFloat32x2 x)
{
    return rsqrt(x);
}

FFX_MSL_INLINE FfxFloat32x3 ffxRsqrt(FfxFloat32x3 x)
{
    return rsqrt(x);
}

FFX_MSL_INLINE FfxFloat32x4 ffxRsqrt(FfxFloat32x4 x)
{
    return rsqrt(x);
}

/// Compute the linear interpolation between two values: (1 - t) * x + t * y.
FFX_MSL_INLINE FfxFloat32 ffxLerp(FfxFloat32 x, FfxFloat32 y, FfxFloat32 t)
{
    return mix(x, y, t);
}

FFX_MSL_INLINE FfxFloat32x2 ffxLerp(FfxFloat32x2 x, FfxFloat32x2 y, FfxFloat32 t)
{
    return mix(x, y, t);
}

FFX_MSL_INLINE FfxFloat32x2 ffxLerp(FfxFloat32x2 x, FfxFloat32x2 y, FfxFloat32x2 t)
{
    return mix(x, y, t);
}

FFX_MSL_INLINE FfxFloat32x3 ffxLerp(FfxFloat32x3 x, FfxFloat32x3 y, FfxFloat32 t)
{
    return mix(x, y, t);
}

FFX_MSL_INLINE FfxFloat32x3 ffxLerp(FfxFloat32x3 x, FfxFloat32x3 y, FfxFloat32x3 t)
{
    return mix(x, y, t);
}

FFX_MSL_INLINE FfxFloat32x4 ffxLerp(FfxFloat32x4 x, FfxFloat32x4 y, FfxFloat32 t)
{
    return mix(x, y, t);
}

FFX_MSL_INLINE FfxFloat32x4 ffxLerp(FfxFloat32x4 x, FfxFloat32x4 y, FfxFloat32x4 t)
{
    return mix(x, y, t);
}

/// Clamp a value to a [0..1] range.
FFX_MSL_INLINE FfxFloat32 ffxSaturate(FfxFloat32 x)
{
    return saturate(x);
}

FFX_MSL_INLINE FfxFloat32x2 ffxSaturate(FfxFloat32x2 x)
{
    return saturate(x);
}

FFX_MSL_INLINE FfxFloat32x3 ffxSaturate(FfxFloat32x3 x)
{
    return saturate(x);
}

FFX_MSL_INLINE FfxFloat32x4 ffxSaturate(FfxFloat32x4 x)
{
    return saturate(x);
}

/// Compute the fractional part of a decimal value (x - floor(x)).
FFX_MSL_INLINE FfxFloat32 ffxFract(FfxFloat32 x)
{
    return x - floor(x);
}

FFX_MSL_INLINE FfxFloat32x2 ffxFract(FfxFloat32x2 x)
{
    return x - floor(x);
}

FFX_MSL_INLINE FfxFloat32x3 ffxFract(FfxFloat32x3 x)
{
    return x - floor(x);
}

FFX_MSL_INLINE FfxFloat32x4 ffxFract(FfxFloat32x4 x)
{
    return x - floor(x);
}

/// Rounds to the nearest integer (nearest even integer if equidistant).
FFX_MSL_INLINE FfxFloat32 ffxRound(FfxFloat32 x)
{
    return rint(x);
}

FFX_MSL_INLINE FfxFloat32x2 ffxRound(FfxFloat32x2 x)
{
    return rint(x);
}

FFX_MSL_INLINE FfxFloat32x3 ffxRound(FfxFloat32x3 x)
{
    return rint(x);
}

FFX_MSL_INLINE FfxFloat32x4 ffxRound(FfxFloat32x4 x)
{
    return rint(x);
}

/// Compute the maximum of three values.
FFX_MSL_INLINE FfxFloat32 ffxMax3(FfxFloat32 x, FfxFloat32 y, FfxFloat32 z)
{
    return max(x, max(y, z));
}

FFX_MSL_INLINE FfxFloat32x2 ffxMax3(FfxFloat32x2 x, FfxFloat32x2 y, FfxFloat32x2 z)
{
    return max(x, max(y, z));
}

FFX_MSL_INLINE FfxFloat32x3 ffxMax3(FfxFloat32x3 x, FfxFloat32x3 y, FfxFloat32x3 z)
{
    return max(x, max(y, z));
}

FFX_MSL_INLINE FfxFloat32x4 ffxMax3(FfxFloat32x4 x, FfxFloat32x4 y, FfxFloat32x4 z)
{
    return max(x, max(y, z));
}

FFX_MSL_INLINE FfxUInt32 ffxMax3(FfxUInt32 x, FfxUInt32 y, FfxUInt32 z)
{
    return max(x, max(y, z));
}

FFX_MSL_INLINE FfxUInt32x2 ffxMax3(FfxUInt32x2 x, FfxUInt32x2 y, FfxUInt32x2 z)
{
    return max(x, max(y, z));
}

FFX_MSL_INLINE FfxUInt32x3 ffxMax3(FfxUInt32x3 x, FfxUInt32x3 y, FfxUInt32x3 z)
{
    return max(x, max(y, z));
}

FFX_MSL_INLINE FfxUInt32x4 ffxMax3(FfxUInt32x4 x, FfxUInt32x4 y, FfxUInt32x4 z)
{
    return max(x, max(y, z));
}

/// Compute the median of three values.
FFX_MSL_INLINE FfxFloat32 ffxMed3(FfxFloat32 x, FfxFloat32 y, FfxFloat32 z)
{
    return max(min(x, y), min(max(x, y), z));
}

FFX_MSL_INLINE FfxFloat32x2 ffxMed3(FfxFloat32x2 x, FfxFloat32x2 y, FfxFloat32x2 z)
{
    return max(min(x, y), min(max(x, y), z));
}

FFX_MSL_INLINE FfxFloat32x3 ffxMed3(FfxFloat32x3 x, FfxFloat32x3 y, FfxFloat32x3 z)
{
    return max(min(x, y), min(max(x, y), z));
}

FFX_MSL_INLINE FfxFloat32x4 ffxMed3(FfxFloat32x4 x, FfxFloat32x4 y, FfxFloat32x4 z)
{
    return max(min(x, y), min(max(x, y), z));
}

FFX_MSL_INLINE FfxInt32 ffxMed3(FfxInt32 x, FfxInt32 y, FfxInt32 z)
{
    return max(min(x, y), min(max(x, y), z));
}

FFX_MSL_INLINE FfxInt32x2 ffxMed3(FfxInt32x2 x, FfxInt32x2 y, FfxInt32x2 z)
{
    return max(min(x, y), min(max(x, y), z));
}

FFX_MSL_INLINE FfxInt32x3 ffxMed3(FfxInt32x3 x, FfxInt32x3 y, FfxInt32x3 z)
{
    return max(min(x, y), min(max(x, y), z));
}

FFX_MSL_INLINE FfxInt32x4 ffxMed3(FfxInt32x4 x, FfxInt32x4 y, FfxInt32x4 z)
{
    return max(min(x, y), min(max(x, y), z));
}

/// Compute the minimum of three values.
FFX_MSL_INLINE FfxFloat32 ffxMin3(FfxFloat32 x, FfxFloat32 y, FfxFloat32 z)
{
    return min(x, min(y, z));
}

FFX_MSL_INLINE FfxFloat32x2 ffxMin3(FfxFloat32x2 x, FfxFloat32x2 y, FfxFloat32x2 z)
{
    return min(x, min(y, z));
}

FFX_MSL_INLINE FfxFloat32x3 ffxMin3(FfxFloat32x3 x, FfxFloat32x3 y, FfxFloat32x3 z)
{
    return min(x, min(y, z));
}

FFX_MSL_INLINE FfxFloat32x4 ffxMin3(FfxFloat32x4 x, FfxFloat32x4 y, FfxFloat32x4 z)
{
    return min(x, min(y, z));
}

FFX_MSL_INLINE FfxUInt32 ffxMin3(FfxUInt32 x, FfxUInt32 y, FfxUInt32 z)
{
    return min(x, min(y, z));
}

FFX_MSL_INLINE FfxUInt32x2 ffxMin3(FfxUInt32x2 x, FfxUInt32x2 y, FfxUInt32x2 z)
{
    return min(x, min(y, z));
}

FFX_MSL_INLINE FfxUInt32x3 ffxMin3(FfxUInt32x3 x, FfxUInt32x3 y, FfxUInt32x3 z)
{
    return min(x, min(y, z));
}

FFX_MSL_INLINE FfxUInt32x4 ffxMin3(FfxUInt32x4 x, FfxUInt32x4 y, FfxUInt32x4 z)
{
    return min(x, min(y, z));
}

FFX_MSL_INLINE FfxUInt32 ffxAShrSU1(FfxUInt32 a, FfxUInt32 b)
{
    return FfxUInt32(FfxInt32(a) >> FfxInt32(b));
}

FFX_MSL_INLINE FfxUInt32 ffxPackF32(FfxFloat32x2 v)
{
    FfxUInt32x2 p = FfxUInt32x2(ffxF32ToF16(FfxFloat32x2(v).x), ffxF32ToF16(FfxFloat32x2(v).y));
    return p.x | (p.y << 16);
}

FFX_MSL_INLINE FfxFloat32x2 ffxUnpackF32(FfxUInt32 a)
{
    return f16tof32(FfxUInt32x2(a & 0xFFFF, a >> 16));
}

FFX_MSL_INLINE FfxUInt32x2 ffxPackF32x2(FfxFloat32x4 v)
{
    return FfxUInt32x2(ffxPackF32(v.xy), ffxPackF32(v.zw));
}

FFX_MSL_INLINE FfxFloat32x4 ffxUnpackF32x2(FfxUInt32x2 a)
{
    return FfxFloat32x4(ffxUnpackF32(a.x), ffxUnpackF32(a.y));
}

//==============================================================================================================================
//                                                          MSL HALF UNPACK/PACK
//==============================================================================================================================

FFX_MSL_INLINE FFX_MIN16_F2 ffxUint32ToFloat16x2(FfxUInt32 x)
{
    FfxFloat32x2 t = f16tof32(FfxUInt32x2(x & 0xFFFF, x >> 16));
    return FFX_MIN16_F2(t);
}

FFX_MSL_INLINE FFX_MIN16_F4 ffxUint32x2ToFloat16x4(FfxUInt32x2 x)
{
    return FFX_MIN16_F4(ffxUint32ToFloat16x2(x.x), ffxUint32ToFloat16x2(x.y));
}

FFX_MSL_INLINE FFX_MIN16_U2 ffxUint32ToUint16x2(FfxUInt32 x)
{
    FfxUInt32x2 t = FfxUInt32x2(x & 0xFFFF, x >> 16);
    return FFX_MIN16_U2(t);
}

FFX_MSL_INLINE FFX_MIN16_U4 ffxUint32x2ToUint16x4(FfxUInt32x2 x)
{
    return FFX_MIN16_U4(ffxUint32ToUint16x2(x.x), ffxUint32ToUint16x2(x.y));
}

FFX_MSL_INLINE FfxUInt32x2 ffxFloat16x4ToUint32x2(FFX_MIN16_F4 v)
{
    FfxUInt32x2 result;
    result.x = ffxF32ToF16(FfxFloat32(v.x)) | (ffxF32ToF16(FfxFloat32(v.y)) << 16);
    result.y = ffxF32ToF16(FfxFloat32(v.z)) | (ffxF32ToF16(FfxFloat32(v.w)) << 16);
    return result;
}

/// @brief Inverts the value while avoiding division by zero. If the value is zero, zero is returned.
FFX_MSL_INLINE FfxFloat32 ffxInvertSafe(FfxFloat32 v)
{
    FfxFloat32 s = FfxFloat32(sign(v));
    FfxFloat32 s2 = s * s;
    return s2 / (v + s2 - 1.0f);
}

FFX_MSL_INLINE FfxFloat32x2 ffxInvertSafe(FfxFloat32x2 v)
{
    FfxFloat32x2 s = FfxFloat32x2(sign(v));
    FfxFloat32x2 s2 = s * s;
    return s2 / (v + s2 - FfxFloat32x2(1.0f, 1.0f));
}

FFX_MSL_INLINE FfxFloat32x3 ffxInvertSafe(FfxFloat32x3 v)
{
    FfxFloat32x3 s = FfxFloat32x3(sign(v));
    FfxFloat32x3 s2 = s * s;
    return s2 / (v + s2 - FfxFloat32x3(1.0f, 1.0f, 1.0f));
}

FFX_MSL_INLINE FfxFloat32x4 ffxInvertSafe(FfxFloat32x4 v)
{
    FfxFloat32x4 s = FfxFloat32x4(sign(v));
    FfxFloat32x4 s2 = s * s;
    return s2 / (v + s2 - FfxFloat32x4(1.0f, 1.0f, 1.0f, 1.0f));
}

#define FFX_UINT32_TO_FLOAT16X2(x) ffxUint32ToFloat16x2(FfxUInt32(x))


//==== 16-bit and wave helpers ====


#if FFX_HALF

#define FFX_UINT32X2_TO_FLOAT16X4(x) ffxUint32x2ToFloat16x4(FfxUInt32x2(x))
#define FFX_UINT32_TO_UINT16X2(x)    ffxUint32ToUint16x2(FfxUInt32(x))
#define FFX_UINT32X2_TO_UINT16X4(x)  ffxUint32x2ToUint16x4(FfxUInt32x2(x))

/// Pack 2x16-bit floating point values in a single 32-bit unsigned integer.
///
/// @ingroup MSLCore
FFX_MSL_INLINE FfxUInt32 ffxPackF16(FfxFloat16x2 v)
{
    FfxUInt32x2 p = FfxUInt32x2(FfxUInt32(as_type<ushort>(v.x)), FfxUInt32(as_type<ushort>(v.y)));
    return p.x | (p.y << 16);
}

/// Unpack a 32-bit unsigned integer into 2x16-bit floating point values.
///
/// @ingroup MSLCore
FFX_MSL_INLINE FfxFloat16x2 ffxUnpackF16(FfxUInt32 a)
{
    return FfxFloat16x2(
        FfxFloat16(float(as_type<half>(ushort(a & 0xFFFFu)))),
        FfxFloat16(float(as_type<half>(ushort(a >> 16)))));
}

//------------------------------------------------------------------------------------------------------------------------------
FFX_MSL_INLINE FfxUInt32 FFX_MIN16_F2ToUint32(FFX_MIN16_F2 x)
{
    return FfxUInt32(as_type<ushort>(half(x.x))) + (FfxUInt32(as_type<ushort>(half(x.y))) << 16);
}

FFX_MSL_INLINE FfxUInt32x2 FFX_MIN16_F4ToUint32x2(FFX_MIN16_F4 x)
{
    return FfxUInt32x2(FFX_MIN16_F2ToUint32(x.xy), FFX_MIN16_F2ToUint32(x.zw));
}

FFX_MSL_INLINE FfxUInt32 FFX_MIN16_U2ToUint32(FFX_MIN16_U2 x)
{
    return FfxUInt32(x.x) + (FfxUInt32(x.y) << 16);
}

FFX_MSL_INLINE FfxUInt32x2 FFX_MIN16_U4ToUint32x2(FFX_MIN16_U4 x)
{
    return FfxUInt32x2(FFX_MIN16_U2ToUint32(x.xy), FFX_MIN16_U2ToUint32(x.zw));
}

#define FFX_FLOAT16X2_TO_UINT32(x)   FFX_MIN16_F2ToUint32(FFX_MIN16_F2(x))
#define FFX_FLOAT16X4_TO_UINT32X2(x) FFX_MIN16_F4ToUint32x2(FFX_MIN16_F4(x))
#define FFX_UINT16X2_TO_UINT32(x)    FFX_MIN16_U2ToUint32(FFX_MIN16_U2(x))
#define FFX_UINT16X4_TO_UINT32X2(x)  FFX_MIN16_U4ToUint32x2(FFX_MIN16_U4(x))

#if !defined(FFX_NO_16_BIT_CAST)
#define FFX_TO_UINT16(x)   as_type<FFX_MIN16_U>(FFX_MIN16_F(x))
#define FFX_TO_UINT16X2(x) as_type<FFX_MIN16_U2>(FFX_MIN16_F2(x))
#define FFX_TO_UINT16X3(x) as_type<FFX_MIN16_U3>(FFX_MIN16_F3(x))
#define FFX_TO_UINT16X4(x) as_type<FFX_MIN16_U4>(FFX_MIN16_F4(x))
#else
#define FFX_TO_UINT16(a)   FFX_MIN16_U(as_type<ushort>(half(FfxFloat32(a))))
#define FFX_TO_UINT16X2(a) FFX_MIN16_U2(FFX_TO_UINT16((a).x), FFX_TO_UINT16((a).y))
#define FFX_TO_UINT16X3(a) FFX_MIN16_U3(FFX_TO_UINT16((a).x), FFX_TO_UINT16((a).y), FFX_TO_UINT16((a).z))
#define FFX_TO_UINT16X4(a) FFX_MIN16_U4(FFX_TO_UINT16((a).x), FFX_TO_UINT16((a).y), FFX_TO_UINT16((a).z), FFX_TO_UINT16((a).w))
#endif // !defined(FFX_NO_16_BIT_CAST)

#if !defined(FFX_NO_16_BIT_CAST)
#define FFX_TO_FLOAT16(x)   as_type<FFX_MIN16_F>(FFX_MIN16_U(x))
#define FFX_TO_FLOAT16X2(x) as_type<FFX_MIN16_F2>(FFX_MIN16_U2(x))
#define FFX_TO_FLOAT16X3(x) as_type<FFX_MIN16_F3>(FFX_MIN16_U3(x))
#define FFX_TO_FLOAT16X4(x) as_type<FFX_MIN16_F4>(FFX_MIN16_U4(x))
#else
#define FFX_TO_FLOAT16(a)   FFX_MIN16_F(float(as_type<half>(ushort(FfxUInt32(a)))))
#define FFX_TO_FLOAT16X2(a) FFX_MIN16_F2(FFX_TO_FLOAT16((a).x), FFX_TO_FLOAT16((a).y))
#define FFX_TO_FLOAT16X3(a) FFX_MIN16_F3(FFX_TO_FLOAT16((a).x), FFX_TO_FLOAT16((a).y), FFX_TO_FLOAT16((a).z))
#define FFX_TO_FLOAT16X4(a) FFX_MIN16_F4(FFX_TO_FLOAT16((a).x), FFX_TO_FLOAT16((a).y), FFX_TO_FLOAT16((a).z), FFX_TO_FLOAT16((a).w))
#endif // !defined(FFX_NO_16_BIT_CAST)

//==============================================================================================================================
#define FFX_BROADCAST_FLOAT16(a)   FFX_MIN16_F(a)
#define FFX_BROADCAST_FLOAT16X2(a) FFX_MIN16_F2(a)
#define FFX_BROADCAST_FLOAT16X3(a) FFX_MIN16_F3(a)
#define FFX_BROADCAST_FLOAT16X4(a) FFX_MIN16_F4(a)

//------------------------------------------------------------------------------------------------------------------------------
#define FFX_BROADCAST_INT16(a)     FFX_MIN16_I(a)
#define FFX_BROADCAST_INT16X2(a)   FFX_MIN16_I2(a)
#define FFX_BROADCAST_INT16X3(a)   FFX_MIN16_I3(a)
#define FFX_BROADCAST_INT16X4(a)   FFX_MIN16_I4(a)

//------------------------------------------------------------------------------------------------------------------------------
#define FFX_BROADCAST_UINT16(a)    FFX_MIN16_U(a)
#define FFX_BROADCAST_UINT16X2(a)  FFX_MIN16_U2(a)
#define FFX_BROADCAST_UINT16X3(a)  FFX_MIN16_U3(a)
#define FFX_BROADCAST_UINT16X4(a)  FFX_MIN16_U4(a)

//==============================================================================================================================
/// Compute the absolute value of a 16-bit integer.
///
/// @ingroup MSLCore
FFX_MSL_INLINE FFX_MIN16_U ffxAbsHalf(FFX_MIN16_U a)
{
    return FFX_MIN16_U(abs(FFX_MIN16_I(a)));
}
FFX_MSL_INLINE FFX_MIN16_U2 ffxAbsHalf(FFX_MIN16_U2 a)
{
    return FFX_MIN16_U2(abs(FFX_MIN16_I2(a)));
}
FFX_MSL_INLINE FFX_MIN16_U3 ffxAbsHalf(FFX_MIN16_U3 a)
{
    return FFX_MIN16_U3(abs(FFX_MIN16_I3(a)));
}
FFX_MSL_INLINE FFX_MIN16_U4 ffxAbsHalf(FFX_MIN16_U4 a)
{
    return FFX_MIN16_U4(abs(FFX_MIN16_I4(a)));
}

//------------------------------------------------------------------------------------------------------------------------------
/// Clamp a 16-bit floating point value to [n, m].
///
/// @ingroup MSLCore
FFX_MSL_INLINE FFX_MIN16_F ffxClampHalf(FFX_MIN16_F x, FFX_MIN16_F n, FFX_MIN16_F m)
{
    return max(n, min(x, m));
}
FFX_MSL_INLINE FFX_MIN16_F2 ffxClampHalf(FFX_MIN16_F2 x, FFX_MIN16_F2 n, FFX_MIN16_F2 m)
{
    return max(n, min(x, m));
}
FFX_MSL_INLINE FFX_MIN16_F3 ffxClampHalf(FFX_MIN16_F3 x, FFX_MIN16_F3 n, FFX_MIN16_F3 m)
{
    return max(n, min(x, m));
}
FFX_MSL_INLINE FFX_MIN16_F4 ffxClampHalf(FFX_MIN16_F4 x, FFX_MIN16_F4 n, FFX_MIN16_F4 m)
{
    return max(n, min(x, m));
}

//------------------------------------------------------------------------------------------------------------------------------
/// Compute the fractional part of a 16-bit floating point value (x - floor(x)).
///
/// @ingroup MSLCore
FFX_MSL_INLINE FFX_MIN16_F ffxFract(FFX_MIN16_F x)
{
    return x - floor(x);
}
FFX_MSL_INLINE FFX_MIN16_F2 ffxFract(FFX_MIN16_F2 x)
{
    return x - floor(x);
}
FFX_MSL_INLINE FFX_MIN16_F3 ffxFract(FFX_MIN16_F3 x)
{
    return x - floor(x);
}
FFX_MSL_INLINE FFX_MIN16_F4 ffxFract(FFX_MIN16_F4 x)
{
    return x - floor(x);
}

//------------------------------------------------------------------------------------------------------------------------------
/// Linearly interpolate between two 16-bit floating point values.
///
/// @ingroup MSLCore
FFX_MSL_INLINE FFX_MIN16_F ffxLerp(FFX_MIN16_F x, FFX_MIN16_F y, FFX_MIN16_F a)
{
    return mix(x, y, a);
}
FFX_MSL_INLINE FFX_MIN16_F2 ffxLerp(FFX_MIN16_F2 x, FFX_MIN16_F2 y, FFX_MIN16_F a)
{
    return mix(x, y, a);
}
FFX_MSL_INLINE FFX_MIN16_F2 ffxLerp(FFX_MIN16_F2 x, FFX_MIN16_F2 y, FFX_MIN16_F2 a)
{
    return mix(x, y, a);
}
FFX_MSL_INLINE FFX_MIN16_F3 ffxLerp(FFX_MIN16_F3 x, FFX_MIN16_F3 y, FFX_MIN16_F a)
{
    return mix(x, y, a);
}
FFX_MSL_INLINE FFX_MIN16_F3 ffxLerp(FFX_MIN16_F3 x, FFX_MIN16_F3 y, FFX_MIN16_F3 a)
{
    return mix(x, y, a);
}
FFX_MSL_INLINE FFX_MIN16_F4 ffxLerp(FFX_MIN16_F4 x, FFX_MIN16_F4 y, FFX_MIN16_F a)
{
    return mix(x, y, a);
}
FFX_MSL_INLINE FFX_MIN16_F4 ffxLerp(FFX_MIN16_F4 x, FFX_MIN16_F4 y, FFX_MIN16_F4 a)
{
    return mix(x, y, a);
}

//------------------------------------------------------------------------------------------------------------------------------
/// Compute the maximum of three 16-bit floating point values.
///
/// @ingroup MSLCore
FFX_MSL_INLINE FFX_MIN16_F ffxMax3Half(FFX_MIN16_F x, FFX_MIN16_F y, FFX_MIN16_F z)
{
    return max(x, max(y, z));
}
FFX_MSL_INLINE FFX_MIN16_F2 ffxMax3Half(FFX_MIN16_F2 x, FFX_MIN16_F2 y, FFX_MIN16_F2 z)
{
    return max(x, max(y, z));
}
FFX_MSL_INLINE FFX_MIN16_F3 ffxMax3Half(FFX_MIN16_F3 x, FFX_MIN16_F3 y, FFX_MIN16_F3 z)
{
    return max(x, max(y, z));
}
FFX_MSL_INLINE FFX_MIN16_F4 ffxMax3Half(FFX_MIN16_F4 x, FFX_MIN16_F4 y, FFX_MIN16_F4 z)
{
    return max(x, max(y, z));
}

//------------------------------------------------------------------------------------------------------------------------------
/// Compute the minimum of three 16-bit floating point values.
///
/// @ingroup MSLCore
FFX_MSL_INLINE FFX_MIN16_F ffxMin3Half(FFX_MIN16_F x, FFX_MIN16_F y, FFX_MIN16_F z)
{
    return min(x, min(y, z));
}
FFX_MSL_INLINE FFX_MIN16_F2 ffxMin3Half(FFX_MIN16_F2 x, FFX_MIN16_F2 y, FFX_MIN16_F2 z)
{
    return min(x, min(y, z));
}
FFX_MSL_INLINE FFX_MIN16_F3 ffxMin3Half(FFX_MIN16_F3 x, FFX_MIN16_F3 y, FFX_MIN16_F3 z)
{
    return min(x, min(y, z));
}
FFX_MSL_INLINE FFX_MIN16_F4 ffxMin3Half(FFX_MIN16_F4 x, FFX_MIN16_F4 y, FFX_MIN16_F4 z)
{
    return min(x, min(y, z));
}

//------------------------------------------------------------------------------------------------------------------------------
/// Compute the median of three 16-bit floating point values.
///
/// @ingroup MSLCore
FFX_MSL_INLINE FFX_MIN16_F ffxMed3Half(FFX_MIN16_F x, FFX_MIN16_F y, FFX_MIN16_F z)
{
    return max(min(x, y), min(max(x, y), z));
}
FFX_MSL_INLINE FFX_MIN16_F2 ffxMed3Half(FFX_MIN16_F2 x, FFX_MIN16_F2 y, FFX_MIN16_F2 z)
{
    return max(min(x, y), min(max(x, y), z));
}
FFX_MSL_INLINE FFX_MIN16_F3 ffxMed3Half(FFX_MIN16_F3 x, FFX_MIN16_F3 y, FFX_MIN16_F3 z)
{
    return max(min(x, y), min(max(x, y), z));
}
FFX_MSL_INLINE FFX_MIN16_F4 ffxMed3Half(FFX_MIN16_F4 x, FFX_MIN16_F4 y, FFX_MIN16_F4 z)
{
    return max(min(x, y), min(max(x, y), z));
}

//------------------------------------------------------------------------------------------------------------------------------
/// Compute the median of three 16-bit signed integer values.
///
/// @ingroup MSLCore
FFX_MSL_INLINE FFX_MIN16_I ffxMed3Half(FFX_MIN16_I x, FFX_MIN16_I y, FFX_MIN16_I z)
{
    return max(min(x, y), min(max(x, y), z));
}
FFX_MSL_INLINE FFX_MIN16_I2 ffxMed3Half(FFX_MIN16_I2 x, FFX_MIN16_I2 y, FFX_MIN16_I2 z)
{
    return max(min(x, y), min(max(x, y), z));
}
FFX_MSL_INLINE FFX_MIN16_I3 ffxMed3Half(FFX_MIN16_I3 x, FFX_MIN16_I3 y, FFX_MIN16_I3 z)
{
    return max(min(x, y), min(max(x, y), z));
}
FFX_MSL_INLINE FFX_MIN16_I4 ffxMed3Half(FFX_MIN16_I4 x, FFX_MIN16_I4 y, FFX_MIN16_I4 z)
{
    return max(min(x, y), min(max(x, y), z));
}

//------------------------------------------------------------------------------------------------------------------------------
/// Compute the reciprocal of a 16-bit floating point value.
///
/// @ingroup MSLCore
FFX_MSL_INLINE FFX_MIN16_F ffxReciprocalHalf(FFX_MIN16_F x)
{
    return FFX_MIN16_F(1.0f) / x;
}
FFX_MSL_INLINE FFX_MIN16_F2 ffxReciprocalHalf(FFX_MIN16_F2 x)
{
    return FFX_MIN16_F2(1.0f) / x;
}
FFX_MSL_INLINE FFX_MIN16_F3 ffxReciprocalHalf(FFX_MIN16_F3 x)
{
    return FFX_MIN16_F3(1.0f) / x;
}
FFX_MSL_INLINE FFX_MIN16_F4 ffxReciprocalHalf(FFX_MIN16_F4 x)
{
    return FFX_MIN16_F4(1.0f) / x;
}

//------------------------------------------------------------------------------------------------------------------------------
/// Compute the reciprocal square root of a 16-bit floating point value.
///
/// @ingroup MSLCore
FFX_MSL_INLINE FFX_MIN16_F ffxReciprocalSquareRootHalf(FFX_MIN16_F x)
{
    return rsqrt(x);
}
FFX_MSL_INLINE FFX_MIN16_F2 ffxReciprocalSquareRootHalf(FFX_MIN16_F2 x)
{
    return rsqrt(x);
}
FFX_MSL_INLINE FFX_MIN16_F3 ffxReciprocalSquareRootHalf(FFX_MIN16_F3 x)
{
    return rsqrt(x);
}
FFX_MSL_INLINE FFX_MIN16_F4 ffxReciprocalSquareRootHalf(FFX_MIN16_F4 x)
{
    return rsqrt(x);
}

//------------------------------------------------------------------------------------------------------------------------------
/// Clamp a 16-bit floating point value to [0..1].
///
/// @ingroup MSLCore
FFX_MSL_INLINE FFX_MIN16_F ffxSaturate(FFX_MIN16_F x)
{
    return saturate(x);
}
FFX_MSL_INLINE FFX_MIN16_F2 ffxSaturate(FFX_MIN16_F2 x)
{
    return saturate(x);
}
FFX_MSL_INLINE FFX_MIN16_F3 ffxSaturate(FFX_MIN16_F3 x)
{
    return saturate(x);
}
FFX_MSL_INLINE FFX_MIN16_F4 ffxSaturate(FFX_MIN16_F4 x)
{
    return saturate(x);
}

//------------------------------------------------------------------------------------------------------------------------------
/// Arithmetic right shift on 16-bit integers interpreted as signed, returned as unsigned.
///
/// @ingroup MSLCore
FFX_MSL_INLINE FFX_MIN16_U ffxBitShiftRightHalf(FFX_MIN16_U a, FFX_MIN16_U b)
{
    return FFX_MIN16_U(FFX_MIN16_I(a) >> FFX_MIN16_I(b));
}
FFX_MSL_INLINE FFX_MIN16_U2 ffxBitShiftRightHalf(FFX_MIN16_U2 a, FFX_MIN16_U2 b)
{
    return FFX_MIN16_U2(FFX_MIN16_I2(a) >> FFX_MIN16_I2(b));
}
FFX_MSL_INLINE FFX_MIN16_U3 ffxBitShiftRightHalf(FFX_MIN16_U3 a, FFX_MIN16_U3 b)
{
    return FFX_MIN16_U3(FFX_MIN16_I3(a) >> FFX_MIN16_I3(b));
}
FFX_MSL_INLINE FFX_MIN16_U4 ffxBitShiftRightHalf(FFX_MIN16_U4 a, FFX_MIN16_U4 b)
{
    return FFX_MIN16_U4(FFX_MIN16_I4(a) >> FFX_MIN16_I4(b));
}
#endif // FFX_HALF

//==============================================================================================================================
//                                                          MSL WAVE
//==============================================================================================================================
#if defined(FFX_WAVE)
// Where 'x' must be a compile time literal.
FFX_MSL_INLINE FfxFloat32 ffxWaveXorF1(FfxFloat32 v, FfxUInt32 x)
{
    return simd_shuffle_xor(v, ushort(x));
}
FFX_MSL_INLINE FfxFloat32x2 ffxWaveXorF2(FfxFloat32x2 v, FfxUInt32 x)
{
    return simd_shuffle_xor(v, ushort(x));
}
FFX_MSL_INLINE FfxFloat32x3 ffxWaveXorF3(FfxFloat32x3 v, FfxUInt32 x)
{
    return simd_shuffle_xor(v, ushort(x));
}
FFX_MSL_INLINE FfxFloat32x4 ffxWaveXorF4(FfxFloat32x4 v, FfxUInt32 x)
{
    return simd_shuffle_xor(v, ushort(x));
}
FFX_MSL_INLINE FfxUInt32 ffxWaveXorU1(FfxUInt32 v, FfxUInt32 x)
{
    return simd_shuffle_xor(v, ushort(x));
}
FFX_MSL_INLINE FfxUInt32x2 ffxWaveXorU1(FfxUInt32x2 v, FfxUInt32 x)
{
    return simd_shuffle_xor(v, ushort(x));
}
FFX_MSL_INLINE FfxUInt32x3 ffxWaveXorU1(FfxUInt32x3 v, FfxUInt32 x)
{
    return simd_shuffle_xor(v, ushort(x));
}
FFX_MSL_INLINE FfxUInt32x4 ffxWaveXorU1(FfxUInt32x4 v, FfxUInt32 x)
{
    return simd_shuffle_xor(v, ushort(x));
}
FFX_MSL_INLINE FfxBoolean ffxWaveIsFirstLane()
{
    return simd_is_first();
}
FFX_MSL_INLINE FfxUInt32 ffxWaveLaneIndex()
{
#if defined(FFX_MSL_SIMD_LANE_ID)
    return FfxUInt32(FFX_MSL_SIMD_LANE_ID);
#else
    return simd_prefix_exclusive_sum(FfxUInt32(1));
#endif
}
FFX_MSL_INLINE FfxBoolean ffxWaveReadAtLaneIndexB1(FfxBoolean v, FfxUInt32 x)
{
    return simd_shuffle(ushort(v), ushort(x)) != 0;
}
FFX_MSL_INLINE FfxUInt32 ffxWavePrefixCountBits(FfxBoolean v)
{
    return simd_prefix_exclusive_sum(FfxUInt32(v));
}
FFX_MSL_INLINE FfxUInt32 ffxWaveActiveCountBits(FfxBoolean v)
{
    return simd_sum(FfxUInt32(v));
}
FFX_MSL_INLINE FfxUInt32 ffxWaveReadLaneFirstU1(FfxUInt32 v)
{
    return simd_broadcast_first(v);
}
FFX_MSL_INLINE FfxUInt32x2 ffxWaveReadLaneFirstU2(FfxUInt32x2 v)
{
    return simd_broadcast_first(v);
}
FFX_MSL_INLINE FfxBoolean ffxWaveReadLaneFirstB1(FfxBoolean v)
{
    return simd_broadcast_first(ushort(v)) != 0;
}
FFX_MSL_INLINE FfxUInt32 ffxWaveOr(FfxUInt32 a)
{
    return simd_or(a);
}
FFX_MSL_INLINE FfxUInt32 ffxWaveMin(FfxUInt32 a)
{
    return simd_min(a);
}
FFX_MSL_INLINE FfxFloat32 ffxWaveMin(FfxFloat32 a)
{
    return simd_min(a);
}
FFX_MSL_INLINE FfxUInt32 ffxWaveMax(FfxUInt32 a)
{
    return simd_max(a);
}
FFX_MSL_INLINE FfxFloat32 ffxWaveMax(FfxFloat32 a)
{
    return simd_max(a);
}
FFX_MSL_INLINE FfxUInt32 ffxWaveSum(FfxUInt32 a)
{
    return simd_sum(a);
}
FFX_MSL_INLINE FfxFloat32 ffxWaveSum(FfxFloat32 a)
{
    return simd_sum(a);
}
FFX_MSL_INLINE FfxUInt32 ffxWaveLaneCount()
{
#if defined(FFX_MSL_SIMD_SIZE)
    return FfxUInt32(FFX_MSL_SIMD_SIZE);
#else
    return 32u;
#endif
}
FFX_MSL_INLINE FfxBoolean ffxWaveAllTrue(FfxBoolean v)
{
    return simd_all(v);
}
FFX_MSL_INLINE FfxFloat32 ffxQuadReadX(FfxFloat32 v)
{
    return quad_shuffle_xor(v, ushort(1));
}
FFX_MSL_INLINE FfxFloat32x2 ffxQuadReadX(FfxFloat32x2 v)
{
    return quad_shuffle_xor(v, ushort(1));
}
FFX_MSL_INLINE FfxFloat32 ffxQuadReadY(FfxFloat32 v)
{
    return quad_shuffle_xor(v, ushort(2));
}
FFX_MSL_INLINE FfxFloat32x2 ffxQuadReadY(FfxFloat32x2 v)
{
    return quad_shuffle_xor(v, ushort(2));
}

#if FFX_HALF
FFX_MSL_INLINE FfxFloat16x2 ffxWaveXorFloat16x2(FfxFloat16x2 v, FfxUInt32 x)
{
    return simd_shuffle_xor(v, ushort(x));
}
FFX_MSL_INLINE FfxFloat16x4 ffxWaveXorFloat16x4(FfxFloat16x4 v, FfxUInt32 x)
{
    return simd_shuffle_xor(v, ushort(x));
}
FFX_MSL_INLINE FfxUInt16x2 ffxWaveXorUint16x2(FfxUInt16x2 v, FfxUInt32 x)
{
    return simd_shuffle_xor(v, ushort(x));
}
FFX_MSL_INLINE FfxUInt16x4 ffxWaveXorUint16x4(FfxUInt16x4 v, FfxUInt32 x)
{
    return simd_shuffle_xor(v, ushort(x));
}
#endif // FFX_HALF
#endif // #if defined(FFX_WAVE)

#endif // #if defined(FFX_MSL) && defined(FFX_GPU)
