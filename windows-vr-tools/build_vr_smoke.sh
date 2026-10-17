#!/usr/bin/env bash
# Build only the app-owned, Steam-free OpenVR/D3D11 scene. Never executes it.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
: "${AVPPLAY_LLVM_MINGW_ROOT:?Set the pinned LLVM-MinGW toolchain directory}"
ARCH="${AVPPLAY_VR_SMOKE_ARCH:-x64}"
case "$ARCH" in
    x64) TRIPLE=x86_64-w64-mingw32; RESOURCE_NAME=VRSmoke ;;
    x86) TRIPLE=i686-w64-mingw32; RESOURCE_NAME=VRSmokeX86 ;;
    *) echo "AVPPLAY_VR_SMOKE_ARCH must be x64 or x86." >&2; exit 1 ;;
esac
COMPILER="$AVPPLAY_LLVM_MINGW_ROOT/bin/$TRIPLE-clang"
SOURCE="$ROOT/visionos-windows-vr/Examples/vr-smoke"
OUTPUT="${AVPPLAY_VR_SMOKE_OUTPUT:-$ROOT/visionos-windows-vr/Resources/$RESOURCE_NAME}"
[[ -x "$COMPILER" ]] || { echo "Missing pinned compiler: $COMPILER" >&2; exit 1; }
mkdir -p "$OUTPUT"
"$COMPILER" -O2 -Wall -Wextra -Werror -municode -mwindows \
    -isystem "$ROOT/third-party/openvr/headers" "$SOURCE/main.c" \
    -o "$OUTPUT/vr-smoke.exe" -ld3d11 -ld3dcompiler -luser32 -ladvapi32
cp "$SOURCE/manifest.json" "$OUTPUT/manifest.json"
python3 - "$SOURCE" "$OUTPUT" "$ROOT" "$AVPPLAY_LLVM_MINGW_ROOT" "$ARCH" "$TRIPLE" <<'PY'
import hashlib,json,pathlib,struct,subprocess,sys
source,output,root,toolchain=map(pathlib.Path,sys.argv[1:5])
architecture,triple=sys.argv[5:7]
manifest=json.loads((source/'manifest.json').read_text())
if architecture=='x86':
    manifest.update(id='winevision.vr-smoke-x86',title='Built-in 32-bit VR test scene',guestArchitecture='x86')
(output/'manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
binary=(output/'vr-smoke.exe').read_bytes()
assert binary[:2]==b'MZ'
offset=struct.unpack_from('<I',binary,0x3c)[0]
assert binary[offset:offset+4]==b'PE\0\0' and struct.unpack_from('<H',binary,offset+4)[0]==(0x14c if architecture=='x86' else 0x8664)
inspection=subprocess.check_output([str(toolchain/'bin/llvm-readobj'),'--coff-imports',str(output/'vr-smoke.exe')],text=True)
(output/'imports.txt').write_text(inspection)
imports=[line.strip().split(': ',1)[1] for line in inspection.splitlines() if line.strip().startswith('Name: ')]
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
(output/'build.json').write_text(json.dumps({'target':triple,'architecture':architecture,'presentation':'immersiveVR','sourceSha256':sha(source/'main.c'),'manifestSha256':sha(output/'manifest.json'),'executableSha256':sha(output/'vr-smoke.exe'),'openvrHeaderSha256':sha(root/'third-party/openvr/headers/openvr_capi.h'),'compilerSha256':sha(toolchain/('bin/'+triple+'-clang')),'imports':imports,'executed':False},indent=2)+'\n')
print(f'Built app-owned {architecture} VR test scene: {output / "vr-smoke.exe"}; not executed.')
PY
