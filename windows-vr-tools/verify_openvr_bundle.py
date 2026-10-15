#!/usr/bin/env python3
"""Reject architecture-dependent shared C++ imports in the x64 OpenVR bridge."""
from pathlib import Path
import struct
import sys

def imports(path):
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
    if machine != 0x8664 or unpack('<H', optional)[0] != 0x20b:
        raise ValueError('OpenComposite must be an x64 PE32+ image')
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
    path = Path(sys.argv[1])
    try:
        dependencies = imports(path)
        forbidden = set(dependencies) & {'libc++.dll', 'libc++abi.dll', 'libunwind.dll', 'libstdc++-6.dll'}
        if forbidden:
            raise ValueError('shared C++ imports can resolve to the ARM64EC runtime: ' + ', '.join(sorted(forbidden)))
    except (ValueError, OSError, struct.error) as error:
        raise SystemExit('error: OpenVR dependency closure invalid: ' + str(error))
    print('OpenVR x64 dependency closure verified (self-contained C++ runtime).')
