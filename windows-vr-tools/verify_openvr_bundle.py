#!/usr/bin/env python3
"""Reject architecture-dependent shared C++ imports in the x64 OpenVR bridge."""
from pathlib import Path
import struct
import sys

def imports(path, expected_machine=0x8664):
    data = path.read_bytes()
    def unpack(fmt, offset):
        return struct.unpack_from(fmt, data, offset)
    if data[:2] != b'MZ':
        raise ValueError('not a PE image')
    pe, = unpack('<I', 0x3c)
    if data[pe:pe + 4] != b'PE\0\0':
        raise ValueError('invalid PE signature')
    machine, count = unpack('<HH', pe + 4)
    optional_size, = unpack('<H', pe + 20)
    optional = pe + 24
    if machine not in (0x8664, 0xA641) or unpack('<H', optional)[0] != 0x20b:
        raise ValueError(f'guest must be PE32+ machine 0x{expected_machine:04x}')
    sections = []
    for n in range(count):
        offset = optional + optional_size + n * 40
        virtual_size, rva, raw_size, raw = unpack('<IIII', offset + 8)
        sections.append((rva, raw_size, raw))
    def file_offset(rva):
        for base, size, raw in sections:
            if base <= rva < base + size:
                return raw + rva - base
        raise ValueError('import RVA lies outside section data')
    # LLVM ARM64EC images retain an AMD64 COFF header for x64 loader
    # interoperability. Identify their CHPE metadata, as the runtime does.
    arm64ec = machine == 0xA641
    if machine == 0x8664 and optional_size >= 200 and unpack('<I', optional + 108)[0] > 10:
        load_rva, load_size = unpack('<II', optional + 192)
        if load_rva and load_size >= 0xd0:
            load = file_offset(load_rva)
            if unpack('<I', load)[0] >= 0xd0:
                metadata_va = unpack('<Q', load + 0xc8)[0]
                image_base = unpack('<Q', optional + 24)[0]
                image_size = unpack('<I', optional + 56)[0]
                if image_base <= metadata_va < image_base + image_size:
                    version = unpack('<I', file_offset(metadata_va - image_base))[0]
                    arm64ec = version in (1, 2)
    if arm64ec != (expected_machine == 0xA641):
        raise ValueError('guest architecture does not match the selected x64/ARM64EC profile')
    import_rva, import_size = unpack('<II', optional + 120)
    if not import_rva:
        return []
    offset = file_offset(import_rva)
    names = []
    for n in range(import_size // 20):
        descriptor = unpack('<IIIII', offset + n * 20)
        if not any(descriptor):
            return names
        start = file_offset(descriptor[3])
        end = data.index(b'\0', start, min(start + 256, len(data)))
        names.append(data[start:end].decode('ascii').lower())
    raise ValueError('unterminated import table')

if __name__ == '__main__':
    import argparse
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('dll', type=Path)
    parser.add_argument('--architecture', choices=['x64', 'arm64ec'], default='x64')
    args = parser.parse_args()
    path = args.dll
    try:
        dependencies = imports(path, 0xA641 if args.architecture == "arm64ec" else 0x8664)
        forbidden = set(dependencies) & {'libc++.dll', 'libc++abi.dll', 'libunwind.dll', 'libstdc++-6.dll'}
        if forbidden:
            raise ValueError('shared C++ imports can resolve to the ARM64EC runtime: ' + ', '.join(sorted(forbidden)))
    except (ValueError, OSError, struct.error) as error:
        raise SystemExit('error: OpenVR dependency closure invalid: ' + str(error))
    print(f'OpenVR {args.architecture} dependency closure verified (self-contained C++ runtime).')
