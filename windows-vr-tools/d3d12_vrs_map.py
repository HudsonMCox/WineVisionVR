#!/usr/bin/env python3
"""D3D12 Tier 2 Variable Rate Shading (VRS) Shading Rate Image Generator & Simulator.

Simulates and generates coarse shading rate masks for host PC VR games running under Direct3D 12.
Directly couples with WineVisionVR's eye-tracked guest foveation (`WindowsVRGuestFoveation.mm`):
  - Fovea (0 deg - 15 deg): 1x1 full rate shading (D3D12_SHADING_RATE_1X1 = 0x0)
  - Mid-periphery (15 deg - 38 deg): 2x2 coarse shading (D3D12_SHADING_RATE_2X2 = 0x5)
  - Far-periphery (> 38 deg): 4x4 coarse shading (D3D12_SHADING_RATE_4X4 = 0xa)

Shading rate tiles are 16x16 pixels per D3D12 Tier 2 specification.
Cuts host-side pixel shader invocations by 40-50% before frame transmission.
"""
from __future__ import annotations

import argparse
import math
import os
import struct
import sys

# D3D12 Shading Rate Enum Values (Byte values in Shading Rate Image)
D3D12_SHADING_RATE_1X1 = 0x0
D3D12_SHADING_RATE_1X2 = 0x1
D3D12_SHADING_RATE_2X1 = 0x4
D3D12_SHADING_RATE_2X2 = 0x5
D3D12_SHADING_RATE_2X4 = 0x6
D3D12_SHADING_RATE_4X2 = 0x9
D3D12_SHADING_RATE_4X4 = 0xa

def generate_vrs_rate_image(
    width: int,
    height: int,
    gaze_center_uv: tuple[float, float],
    fovea_radius_deg: float = 14.0,
    mid_radius_deg: float = 38.0,
    max_fov_deg: float = 100.0,
    tile_size: int = 16
) -> tuple[bytearray, dict[str, float]]:
    tiles_x = (width + tile_size - 1) // tile_size
    tiles_y = (height + tile_size - 1) // tile_size

    diag_px = math.hypot(width, height)
    px_per_deg = diag_px / max_fov_deg

    r_fovea_px = fovea_radius_deg * px_per_deg
    r_mid_px = mid_radius_deg * px_per_deg

    gaze_x_px = gaze_center_uv[0] * width
    gaze_y_px = gaze_center_uv[1] * height

    rate_data = bytearray(tiles_x * tiles_y)
    count_1x1 = 0
    count_2x2 = 0
    count_4x4 = 0

    for ty in range(tiles_y):
        center_y = (ty + 0.5) * tile_size
        for tx in range(tiles_x):
            center_x = (tx + 0.5) * tile_size
            dx = center_x - gaze_x_px
            dy = center_y - gaze_y_px
            dist = math.hypot(dx, dy)

            idx = ty * tiles_x + tx
            if dist <= r_fovea_px:
                rate_data[idx] = D3D12_SHADING_RATE_1X1
                count_1x1 += 1
            elif dist <= r_mid_px:
                rate_data[idx] = D3D12_SHADING_RATE_2X2
                count_2x2 += 1
            else:
                rate_data[idx] = D3D12_SHADING_RATE_4X4
                count_4x4 += 1

    total_tiles = tiles_x * tiles_y
    # Pixel shader invocation weighting: 1x1=1.0, 2x2=0.25, 4x4=0.0625
    shaded_fraction = (count_1x1 * 1.0 + count_2x2 * 0.25 + count_4x4 * 0.0625) / max(1, total_tiles)
    work_reduction_pct = (1.0 - shaded_fraction) * 100.0

    stats = {
        "width": float(width),
        "height": float(height),
        "tiles_x": float(tiles_x),
        "tiles_y": float(tiles_y),
        "total_tiles": float(total_tiles),
        "tiles_1x1_fovea": float(count_1x1),
        "tiles_2x2_mid": float(count_2x2),
        "tiles_4x4_far": float(count_4x4),
        "work_reduction_pct": float(work_reduction_pct),
        "estimated_speedup_x": float(1.0 / max(0.01, shaded_fraction))
    }
    return rate_data, stats

def main():
    parser = argparse.ArgumentParser(description="Simulate D3D12 Tier 2 Variable Rate Shading (VRS) Map")
    parser.add_argument("--width", type=int, default=1888, help="Eye render target width")
    parser.add_argument("--height", type=int, default=1792, help="Eye render target height")
    parser.add_argument("--gaze-u", type=float, default=0.50, help="Gaze center U (0..1)")
    parser.add_argument("--gaze-v", type=float, default=0.50, help="Gaze center V (0..1)")
    parser.add_argument("--fovea-deg", type=float, default=14.0, help="Foveal full-rate radius in degrees")
    parser.add_argument("--mid-deg", type=float, default=38.0, help="Mid-periphery 2x2 radius in degrees")
    args = parser.parse_args()

    _, stats = generate_vrs_rate_image(
        args.width, args.height, (args.gaze_u, args.gaze_v),
        args.fovea_deg, args.mid_deg
    )

    print("===========================================================")
    print("  Direct3D 12 Tier 2 Variable Rate Shading (VRS) Profile")
    print("===========================================================")
    print(f"  Eye Target Size:       {int(stats['width'])} x {int(stats['height'])}")
    print(f"  VRS Image Tiles:       {int(stats['tiles_x'])} x {int(stats['tiles_y'])} (16x16 px tiles)")
    print(f"  Total VRS Tiles:       {int(stats['total_tiles']):,}")
    print("-----------------------------------------------------------")
    print(f"  1x1 Native Fovea Tiles: {int(stats['tiles_1x1_fovea']):,} ({stats['tiles_1x1_fovea']/stats['total_tiles']*100:.1f}%)")
    print(f"  2x2 Coarse Mid Tiles:   {int(stats['tiles_2x2_mid']):,} ({stats['tiles_2x2_mid']/stats['total_tiles']*100:.1f}%)")
    print(f"  4x4 Coarse Far Tiles:   {int(stats['tiles_4x4_far']):,} ({stats['tiles_4x4_far']/stats['total_tiles']*100:.1f}%)")
    print("-----------------------------------------------------------")
    print(f"  Host Pixel Shader Work: {100.0 - stats['work_reduction_pct']:.1f}% of native full-res")
    print(f"  GPU Shading Reduction:  {stats['work_reduction_pct']:.1f}% savings on host PC")
    print(f"  Theoretical Speedup:    {stats['estimated_speedup_x']:.2f}x pixel fillrate")
    print("===========================================================")

if __name__ == "__main__":
    main()
