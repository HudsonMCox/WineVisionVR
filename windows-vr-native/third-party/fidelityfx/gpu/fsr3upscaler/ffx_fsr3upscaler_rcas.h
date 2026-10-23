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

#define GROUP_SIZE  8
#define FSR_RCAS_DENOISE 1

#include "ffx_core.h"

#if FFX_HALF && defined(__XBOX_SCARLETT) && defined(__XBATG_EXTRA_16_BIT_OPTIMISATION) && (__XBATG_EXTRA_16_BIT_OPTIMISATION == 1)
    #define FSR_RCAS_PREFER_PAIRED_VERSION 1
#else
    #define FSR_RCAS_PREFER_PAIRED_VERSION 0
#endif

void WriteUpscaledOutput(FFX_MIN16_U2 iPxHrPos, FfxFloat32x3 fUpscaledColor)
{
    StoreUpscaledOutput(FFX_MIN16_I2(iPxHrPos), fUpscaledColor);
}

#if FSR_RCAS_PREFER_PAIRED_VERSION
    #define FSR_RCAS_HX2 1
    FfxFloat16x4 FsrRcasLoadHx2(FfxInt16x2 p)
    {
        return FfxFloat16x4(LoadRCAS_Input(p));
    }
    void FsrRcasInputHx2(FFX_PARAMETER_INOUT FfxFloat16x2 FFX_PARAMETER_REF r, FFX_PARAMETER_INOUT FfxFloat16x2 FFX_PARAMETER_REF g, FFX_PARAMETER_INOUT FfxFloat16x2 FFX_PARAMETER_REF b)
    {
        FfxFloat32 e = Exposure();
        r = FfxFloat16x2(r * e);
        g = FfxFloat16x2(g * e);
        b = FfxFloat16x2(b * e);
    }

	#include "fsr1/ffx_fsr1.h"
	
	void CurrFilterPaired(FFX_MIN16_U2 pos)
    {
        FfxFloat16x2 cr;
        FfxFloat16x2 cg;
        FfxFloat16x2 cb;
        FsrRcasHx2(cr, cg, cb, pos, RCASConfig());
		FfxFloat32 InvExposure = 1.0f / Exposure();
		cr = FfxFloat16x2(cr * InvExposure);
        cg = FfxFloat16x2(cg * InvExposure);
        cb = FfxFloat16x2(cb * InvExposure);
		WriteUpscaledOutput(pos, FfxFloat16x3(cr.x, cg.x, cb.x)); //TODO: fix type
        pos.x += 8;
        WriteUpscaledOutput(pos, FfxFloat16x3(cr.y, cg.y, cb.y)); //TODO: fix type
    }	
#else
    #define FSR_RCAS_F 1
    FfxFloat32x4 FsrRcasLoadF(FfxInt32x2 p)
    {
        FfxFloat32x4 fColor = LoadRCAS_Input(p);

        fColor.rgb *= Exposure();

        return fColor;
    }
    void FsrRcasInputF(FFX_PARAMETER_INOUT FfxFloat32 FFX_PARAMETER_REF r, FFX_PARAMETER_INOUT FfxFloat32 FFX_PARAMETER_REF g, FFX_PARAMETER_INOUT FfxFloat32 FFX_PARAMETER_REF b) {}

#if defined(FFX_MSL)
    #define FSR_RCAS_LIMIT (0.1875f)

    void FsrRcasF(
        FFX_PARAMETER_OUT FfxFloat32 FFX_PARAMETER_REF pixR,
        FFX_PARAMETER_OUT FfxFloat32 FFX_PARAMETER_REF pixG,
        FFX_PARAMETER_OUT FfxFloat32 FFX_PARAMETER_REF pixB,
        FfxUInt32x2 ip,
        FfxUInt32x4 con)
    {
        FfxInt32x2 sp = FfxInt32x2(ip);
        FfxFloat32x3 b = FsrRcasLoadF(sp + FfxInt32x2( 0,-1)).rgb;
        FfxFloat32x3 d = FsrRcasLoadF(sp + FfxInt32x2(-1, 0)).rgb;
        FfxFloat32x3 e = FsrRcasLoadF(sp).rgb;
        FfxFloat32x3 f = FsrRcasLoadF(sp + FfxInt32x2( 1, 0)).rgb;
        FfxFloat32x3 h = FsrRcasLoadF(sp + FfxInt32x2( 0, 1)).rgb;

        FfxFloat32 bR = b.r; FfxFloat32 bG = b.g; FfxFloat32 bB = b.b;
        FfxFloat32 dR = d.r; FfxFloat32 dG = d.g; FfxFloat32 dB = d.b;
        FfxFloat32 eR = e.r; FfxFloat32 eG = e.g; FfxFloat32 eB = e.b;
        FfxFloat32 fR = f.r; FfxFloat32 fG = f.g; FfxFloat32 fB = f.b;
        FfxFloat32 hR = h.r; FfxFloat32 hG = h.g; FfxFloat32 hB = h.b;

        FsrRcasInputF(bR, bG, bB);
        FsrRcasInputF(dR, dG, dB);
        FsrRcasInputF(eR, eG, eB);
        FsrRcasInputF(fR, fG, fB);
        FsrRcasInputF(hR, hG, hB);

        FfxFloat32 bL = bB * 0.5f + (bR * 0.5f + bG);
        FfxFloat32 dL = dB * 0.5f + (dR * 0.5f + dG);
        FfxFloat32 eL = eB * 0.5f + (eR * 0.5f + eG);
        FfxFloat32 fL = fB * 0.5f + (fR * 0.5f + fG);
        FfxFloat32 hL = hB * 0.5f + (hR * 0.5f + hG);

        FfxFloat32 nz = 0.25f * bL + 0.25f * dL + 0.25f * fL + 0.25f * hL - eL;
        FfxFloat32 maxL = max(max(max(bL, dL), eL), max(fL, hL));
        FfxFloat32 minL = min(min(min(bL, dL), eL), min(fL, hL));
        nz = ffxSaturate(abs(nz) * ffxApproximateReciprocalMedium(maxL - minL));
        nz = -0.5f * nz + 1.0f;

        FfxFloat32 mn4R = min(min(bR, dR), min(fR, hR));
        FfxFloat32 mn4G = min(min(bG, dG), min(fG, hG));
        FfxFloat32 mn4B = min(min(bB, dB), min(fB, hB));
        FfxFloat32 mx4R = max(max(bR, dR), max(fR, hR));
        FfxFloat32 mx4G = max(max(bG, dG), max(fG, hG));
        FfxFloat32 mx4B = max(max(bB, dB), max(fB, hB));

        FfxFloat32x2 peakC = FfxFloat32x2(1.0f, -4.0f);

        FfxFloat32 hitMinR = min(mn4R, eR) * (1.0f / (4.0f * mx4R));
        FfxFloat32 hitMinG = min(mn4G, eG) * (1.0f / (4.0f * mx4G));
        FfxFloat32 hitMinB = min(mn4B, eB) * (1.0f / (4.0f * mx4B));
        FfxFloat32 hitMaxR = (peakC.x - max(mx4R, eR)) * (1.0f / (4.0f * mn4R + peakC.y));
        FfxFloat32 hitMaxG = (peakC.x - max(mx4G, eG)) * (1.0f / (4.0f * mn4G + peakC.y));
        FfxFloat32 hitMaxB = (peakC.x - max(mx4B, eB)) * (1.0f / (4.0f * mn4B + peakC.y));
        FfxFloat32 lobeR = max(-hitMinR, hitMaxR);
        FfxFloat32 lobeG = max(-hitMinG, hitMaxG);
        FfxFloat32 lobeB = max(-hitMinB, hitMaxB);
        FfxFloat32 lobe = max(-FSR_RCAS_LIMIT, min(max(max(lobeR, lobeG), lobeB), 0.0f)) * asfloat(con.x);

        lobe *= nz;

        FfxFloat32 rcpL = ffxApproximateReciprocalMedium(4.0f * lobe + 1.0f);
        pixR = (lobe * bR + lobe * dR + lobe * hR + lobe * fR + eR) * rcpL;
        pixG = (lobe * bG + lobe * dG + lobe * hG + lobe * fG + eG) * rcpL;
        pixB = (lobe * bB + lobe * dB + lobe * hB + lobe * fB + eB) * rcpL;
    }
#else
    #include "fsr1/ffx_fsr1.h"
#endif

    void CurrFilter(FFX_MIN16_U2 pos)
    {
        FfxFloat32x3 c;
        FsrRcasF(c.r, c.g, c.b, pos, RCASConfig());

        c /= Exposure();

        WriteUpscaledOutput(pos, c);
    }

#endif // #if FSR_RCAS_PREFER_PAIRED_VERSION

void RCAS(FfxUInt32x3 LocalThreadId, FfxUInt32x3 WorkGroupId, FfxUInt32x3 Dtid)
{
    // Do remapping of local xy in workgroup for a more PS-like swizzle pattern.
    FfxUInt32x2 gxy = ffxRemapForQuad(LocalThreadId.x) + FfxUInt32x2(WorkGroupId.x << 4u, WorkGroupId.y << 4u);
#if FSR_RCAS_PREFER_PAIRED_VERSION
    CurrFilterPaired(FFX_MIN16_U2(gxy));
    gxy.y += 8u;
    CurrFilterPaired(FFX_MIN16_U2(gxy));
#else
    CurrFilter(FFX_MIN16_U2(gxy));
    gxy.x += 8u;
    CurrFilter(FFX_MIN16_U2(gxy));
    gxy.y += 8u;
    CurrFilter(FFX_MIN16_U2(gxy));
    gxy.x -= 8u;
    CurrFilter(FFX_MIN16_U2(gxy));
#endif
}
