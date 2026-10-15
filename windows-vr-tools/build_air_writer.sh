#!/usr/bin/env bash
# Compile the corrected DXMT writer as an isolated visionOS-native adapter.
# This builds compiler code only; it does not run tests, shaders, or games.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
: "${AVPPLAY_AIR_DXMT_SOURCE:?Set the patched DXMT source directory}"
: "${AVPPLAY_AIR_LLVM_SOURCE:?Set the locked LLVM source directory}"
: "${AVPPLAY_AIR_LLVM_BUILD:?Set the visionOS LLVM build directory}"
: "${AVPPLAY_AIR_PLATFORM_HEADER:?Set the generated xros platform header}"
OUTPUT="${AVPPLAY_AIR_OUTPUT:-$ROOT/dist/windows-vr-air-writer-foveation}"
[[ ! -e "$OUTPUT" ]] || { echo "Choose a fresh AVPPLAY_AIR_OUTPUT; output already exists." >&2; exit 1; }
[[ -f "$AVPPLAY_AIR_DXMT_SOURCE/src/airconv/metallib_writer.cpp" && -f "$AVPPLAY_AIR_PLATFORM_HEADER" ]] || exit 1
[[ "$(git -C "$AVPPLAY_AIR_LLVM_SOURCE" rev-parse HEAD)" == 8dfdcc7b7bf66834a761bd8de445840ef68e4d1a ]] || { echo "LLVM revision mismatch." >&2; exit 1; }
mkdir -p "$(dirname "$OUTPUT")"
STAGE="$(mktemp -d "$(dirname "$OUTPUT")/.air-writer.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
cp "$AVPPLAY_AIR_PLATFORM_HEADER" "$STAGE/wvr_metallib_platform.h"
SDK="$(xcrun --sdk xros --show-sdk-path)"
FLAGS=(-target arm64-apple-xros27.0 -isysroot "$SDK" -std=c++20 -O2
       -fvisibility=hidden -fvisibility-inlines-hidden -fno-exceptions -fno-rtti
       -DDXMT_VISIONOS=1 -I"$STAGE"
       -I"$AVPPLAY_AIR_DXMT_SOURCE/src/airconv"
       -I"$AVPPLAY_AIR_LLVM_SOURCE/llvm/include" -I"$AVPPLAY_AIR_LLVM_BUILD/include")
xcrun clang++ "${FLAGS[@]}" -c "$ROOT/windows-vr-native/shader-compiler/WindowsVRAIRWriter.cpp" -o "$STAGE/adapter.o"
xcrun clang++ "${FLAGS[@]}" -c "$AVPPLAY_AIR_DXMT_SOURCE/src/airconv/metallib_writer.cpp" -o "$STAGE/writer.o"
archives=()
for name in ScalarOpts AggressiveInstCombine InstCombine TransformUtils Core BitReader BitWriter Support Analysis ProfileData Symbolize DebugInfoPDB DebugInfoMSF DebugInfoDWARF Object TextAPI MCParser MC DebugInfoCodeView Remarks BitstreamReader BinaryFormat Demangle; do
    archive="$AVPPLAY_AIR_LLVM_BUILD/lib/libLLVM$name.a"
    [[ -f "$archive" ]] || { echo "Missing visionOS archive: $archive" >&2; exit 1; }
    archives+=("$archive")
done
xcrun --sdk xros libtool -static -o "$STAGE/libWindowsVRAIRWriter.a" "$STAGE/adapter.o" "$STAGE/writer.o" "${archives[@]}"
python3 - "$ROOT" "$STAGE" "$AVPPLAY_AIR_DXMT_SOURCE" "$AVPPLAY_AIR_LLVM_BUILD" "$OUTPUT" <<'PY'
import hashlib,json,pathlib,sys
root,stage,dxmt,llvm,output=map(pathlib.Path,sys.argv[1:])
files=[root/'windows-vr-native/shader-compiler/WindowsVRAIRWriter.cpp',root/'windows-vr-native/shader-compiler/WindowsVRAIRWriter.h',root/'windows-vr-native/shader-compiler/WindowsVRAIRCanonicalization.h',root/'windows-vr-native/shader-compiler/WindowsVRAIRFoveation.h',dxmt/'src/airconv/metallib_writer.cpp',dxmt/'src/airconv/metallib_writer.hpp',stage/'wvr_metallib_platform.h',stage/'libWindowsVRAIRWriter.a',llvm/'CMakeCache.txt']
receipt={'platform':'visionOS','deploymentTarget':'27.0','llvmRevision':'8dfdcc7b7bf66834a761bd8de445840ef68e4d1a','status':'compiled-not-execution-tested','filesSha256':{str(output.resolve()/p.name) if p.parent == stage else str(p):hashlib.sha256(p.read_bytes()).hexdigest() for p in files}}
(stage/'build-receipt.json').write_text(json.dumps(receipt,indent=2)+'\n')
PY
mv "$STAGE" "$OUTPUT"
trap - EXIT
echo "Built source AIR writer at $OUTPUT; no tests or games were run."
