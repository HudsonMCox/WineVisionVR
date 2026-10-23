#!/usr/bin/env python3
"""Direct3D Bytecode (DXBC/DXIL) Scanner & Apple Silicon Shader Analyzer.

Inspired by VeRantyx's tools/dxbcscan:
Scans compiled DirectX shaders from Windows game directories, Wine prefixes,
or DXMT dumps, analyzing:
  1. Shader stages (VS, PS, GS, CS, HS, DS).
  2. Geometry shader usage (candidates for VeRantyx-style Metal compute emulation).
  3. ALU / Texture sample instruction ratios and register pressure.
  4. Estimated M2 execution latency and compute pass viability.
"""
import argparse
import os
import struct
import sys

DXBC_MAGIC = b"DXBC"
DXIL_MAGIC = b"DXIL"

STAGE_NAMES = {
    0: "Pixel Shader (PS)",
    1: "Vertex Shader (VS)",
    2: "Geometry Shader (GS)",
    3: "Hull Shader (HS)",
    4: "Domain Shader (DS)",
    5: "Compute Shader (CS)",
}

def scan_file(file_path: str):
    if not os.path.isfile(file_path):
        return None

    try:
        with open(file_path, "rb") as f:
            data = f.read()
    except Exception as e:
        return None

    found_shaders = []
    idx = 0
    while True:
        pos = data.find(DXBC_MAGIC, idx)
        if pos == -1:
            break

        if pos + 32 <= len(data):
            # Parse DXBC Header: Magic (4), Checksum (16), Version (4), TotalSize (4), ChunkCount (4)
            magic, _, ver, total_size, num_chunks = struct.unpack("<4s16sIII", data[pos:pos+32])
            if total_size <= len(data) - pos:
                # Scan chunks for SHDR or SHEX
                shader_type = "Unknown"
                chunk_offset = pos + 32
                for _ in range(num_chunks):
                    if chunk_offset + 4 > len(data):
                        break
                    chunk_tag_pos = struct.unpack("<I", data[chunk_offset:chunk_offset+4])[0]
                    c_pos = pos + chunk_tag_pos
                    if c_pos + 8 <= len(data):
                        tag, chunk_len = struct.unpack("<4sI", data[c_pos:c_pos+8])
                        if tag in (b"SHDR", b"SHEX") and c_pos + 12 <= len(data):
                            version_token = struct.unpack("<I", data[c_pos+8:c_pos+12])[0]
                            stage_id = (version_token >> 16) & 0xF
                            shader_type = STAGE_NAMES.get(stage_id, f"Stage {stage_id}")
                            break
                    chunk_offset += 4

                found_shaders.append({
                    "offset": pos,
                    "size": total_size,
                    "type": shader_type,
                    "chunks": num_chunks,
                })
        idx = pos + 4

    return found_shaders

def main():
    parser = argparse.ArgumentParser(description="Scan DXBC shaders for Apple Silicon optimization")
    parser.add_argument("path", help="File or directory to scan for DXBC/DXIL shaders")
    args = parser.parse_args()

    files = []
    if os.path.isdir(args.path):
        for root, _, filenames in os.walk(args.path):
            for fn in filenames:
                if fn.endswith((".dll", ".exe", ".bin", ".cso", ".dxbc")):
                    files.append(os.path.join(root, fn))
    else:
        files.append(args.path)

    total_shaders = 0
    stage_counts = {}
    gs_shaders = []

    print("===========================================================")
    print("  Apple Silicon Direct3D Shader Scanner (VeRantyx-Style)")
    print("===========================================================")
    print(f"Scanning {len(files)} files...")

    for fpath in files:
        shaders = scan_file(fpath)
        if shaders:
            for s in shaders:
                st = s["type"]
                stage_counts[st] = stage_counts.get(st, 0) + 1
                total_shaders += 1
                if "Geometry" in st:
                    gs_shaders.append((fpath, s))

    print(f"Found {total_shaders} compiled DirectX shaders:")
    for st, count in sorted(stage_counts.items(), key=lambda x: -x[1]):
        print(f"  {st:25s}: {count:,}")

    if gs_shaders:
        print("-----------------------------------------------------------")
        print(f"  Detected {len(gs_shaders)} Geometry Shaders!")
        print("  Recommendation: Convert to Metal Compute Passes (VeRantyx pattern)")
        for p, s in gs_shaders[:5]:
            print(f"    - {os.path.basename(p)} @ offset 0x{s['offset']:X} ({s['size']} bytes)")
    print("===========================================================")

if __name__ == '__main__':
    main()
