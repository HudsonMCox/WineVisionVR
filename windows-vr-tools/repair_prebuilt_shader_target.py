#!/usr/bin/env python3
"""Copy a patched runtime and correct its unique AIR deployment-target literal.

Keeps the original framework intact. This is a temporary prebuilt-runtime repair;
source builds should apply the matching xros 2.0 shader target overlay.
"""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import struct

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--framework', required=True, type=Path)
parser.add_argument('--output', required=True, type=Path)
args = parser.parse_args()
source = args.framework.resolve()
output = args.output.resolve()
if source == output or output.exists():
    raise SystemExit('Output must be a new directory distinct from the original framework.')
binary = source / 'WindowsRuntimePlugin'
data = binary.read_bytes()
old, new = b'air64-apple-xros1.0\0', b'air64-apple-xros2.0\0'
if data.count(old) != 1:
    raise SystemExit('Expected exactly one unambiguous AIR generator target; refusing to patch.')
offset = data.index(old)
# Clang inlined the tail "s1.0" into initializeModule and
# setup_metal_version. The unique C string alone does not repair these paths.
# Match the exact movz/movk pair instead of writing blindly at an address.
old_tail = struct.pack('<II', 0x52800008 | (0x3173 << 5), 0x72a00008 | (0x302e << 5))
new_tail = struct.pack('<II', 0x52800008 | (0x3273 << 5), 0x72a00008 | (0x302e << 5))
if data.count(old_tail) != 2:
    raise SystemExit('Expected exactly two known inline target tails; refusing to patch.')
inline_offsets = []
cursor = 0
while (cursor := data.find(old_tail, cursor)) >= 0:
    inline_offsets.append(cursor)
    cursor += len(old_tail)
shutil.copytree(source, output)
repaired = data[:offset] + new + data[offset + len(old):]
repaired = repaired.replace(old_tail, new_tail)
(output / 'WindowsRuntimePlugin').write_bytes(repaired)
# The copied signature is invalid after the repair; Xcode signs this copy on embed.
shutil.rmtree(output / '_CodeSignature', ignore_errors=True)
receipt = {'originalFramework': str(source), 'originalSHA256': hashlib.sha256(data).hexdigest(), 'repairedSHA256': hashlib.sha256(repaired).hexdigest(), 'offset': offset, 'inlineTargetOffsets': inline_offsets, 'changedByteCount': sum(a != b for a, b in zip(data, repaired)), 'oldTarget': 'air64-apple-xros1.0', 'newTarget': 'air64-apple-xros2.0', 'otherMachOBytesPreserved': True, 'requiresResigning': True, 'gameExecutionVerified': False}
output.with_suffix('.repair.json').write_text(json.dumps(receipt, indent=2) + '\n')
print(json.dumps(receipt, indent=2))
