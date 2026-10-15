#!/usr/bin/env python3
"""Inspect captured Metal containers without executing a shader or game."""
import argparse
import hashlib
import json
from pathlib import Path
import struct


def inspect(path: Path) -> dict:
    data = path.read_bytes()
    if len(data) < 88 or data[:4] != b"MTLB":
        raise ValueError(f"{path}: missing or truncated Metal library header")
    platform, major, minor, kind, os_id, os_major, os_minor = struct.unpack_from("<HHHBBHH", data, 4)
    size, functions_offset, functions_size, public_offset, public_size, private_offset, private_size, bitcode_offset, bitcode_size = struct.unpack_from("<9Q", data, 16)
    sections = {"functions": (functions_offset, functions_size), "public": (public_offset, public_size), "private": (private_offset, private_size), "bitcode": (bitcode_offset, bitcode_size)}
    invalid = [name for name, (offset, length) in sections.items() if offset > len(data) or length > len(data) - offset]
    bitcode = data[bitcode_offset:bitcode_offset + bitcode_size] if "bitcode" not in invalid else b""
    return {"path": str(path), "sha256": hashlib.sha256(data).hexdigest(), "platform": hex(platform), "containerVersion": [major, minor], "libraryType": kind, "os": hex(os_id), "osVersion": [os_major, os_minor], "declaredFileSize": size, "actualFileSize": len(data), "fileSizeMatches": size == len(data), "sections": sections, "invalidSections": invalid, "bitcodeMagic": bitcode[:4].hex(), "bitcodeSHA256": hashlib.sha256(bitcode).hexdigest() if bitcode else None}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("paths", nargs="+", type=Path)
    args = parser.parse_args()
    results = []
    for path in args.paths:
        files = sorted(path.glob("*.metallib")) if path.is_dir() else [path]
        for file in files:
            try:
                results.append(inspect(file))
            except (OSError, ValueError, struct.error) as error:
                results.append({"path": str(file), "error": str(error)})
    print(json.dumps(results, indent=2))


if __name__ == "__main__":
    main()
