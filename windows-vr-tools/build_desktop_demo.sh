#!/usr/bin/env bash
# Build the small app-owned x64 Windows desktop smoke test. Does not run Wine.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
: "${AVPPLAY_LLVM_MINGW_ROOT:?Set the pinned LLVM-MinGW toolchain directory}"
COMPILER="$AVPPLAY_LLVM_MINGW_ROOT/bin/x86_64-w64-mingw32-clang"
[[ -x "$COMPILER" ]] || { echo "Missing x64 Windows compiler: $COMPILER" >&2; exit 1; }
SOURCE="$ROOT/visionos-windows-vr/Examples/desktop-demo"
OUTPUT="${AVPPLAY_DESKTOP_DEMO_OUTPUT:-$ROOT/visionos-windows-vr/Resources/DesktopDemo}"
mkdir -p "$OUTPUT"
"$COMPILER" -O2 -Wall -Wextra -Werror -municode -mwindows \
    "$SOURCE/main.c" -o "$OUTPUT/desktop-demo.exe" -luser32 -lgdi32
cp "$SOURCE/manifest.json" "$OUTPUT/manifest.json"
python3 - "$SOURCE" "$OUTPUT" <<'PY'
import hashlib, json, pathlib, struct, sys
source, output = map(pathlib.Path, sys.argv[1:])
binary = (output / 'desktop-demo.exe').read_bytes()
assert binary[:2] == b'MZ'
offset = struct.unpack_from('<I', binary, 0x3c)[0]
assert binary[offset:offset+4] == b'PE\0\0'
assert struct.unpack_from('<H', binary, offset+4)[0] == 0x8664
sha = lambda path: hashlib.sha256(path.read_bytes()).hexdigest()
(output / 'build.json').write_text(json.dumps({
    'target': 'x86_64-w64-mingw32', 'presentation': 'desktop',
    'sourceSha256': sha(source / 'main.c'),
    'manifestSha256': sha(output / 'manifest.json'),
    'executableSha256': sha(output / 'desktop-demo.exe'),
    'executed': False
}, indent=2) + '\n')
print(f'Built x64 Windows desktop test: {output / "desktop-demo.exe"}; not executed.')
PY
