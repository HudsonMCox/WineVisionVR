#!/usr/bin/env bash
# Build the pinned Madeira Dock host; never launches Steam or runs tests.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE="${AVPPLAY_MADEIRA_STEAM_SOURCE:-${AVPPLAY_SOURCE_CACHE_ROOT:-$ROOT/third-party}/madeira}"
: "${AVPPLAY_LLVM_MINGW_ROOT:?Set AVPPLAY_LLVM_MINGW_ROOT to the extracted pinned LLVM-MinGW bundle}"
DOCK="$SOURCE/madeira-dock"
EXPECTED=72558e416a390f3669457930f09a389e54f49556
[[ -f "$DOCK/src/main.c" ]] || { echo "Fetch Madeira's pinned madeira-dock submodule first." >&2; exit 1; }
[[ "$(git -C "$DOCK" rev-parse HEAD)" == "$EXPECTED" ]] || { echo "Madeira Dock source revision mismatch." >&2; exit 1; }
git -C "$DOCK" diff --quiet HEAD -- || { echo "Madeira Dock has modified tracked sources." >&2; exit 1; }
LLVM_MINGW="$AVPPLAY_LLVM_MINGW_ROOT/bin" bash "$SOURCE/build/madeira-dock/build.sh"
python3 - "$SOURCE" "$ROOT" "$EXPECTED" <<'PY'
import hashlib, json, pathlib, shutil, sys
source, root, revision = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2]), sys.argv[3]
out = root / 'visionos-windows-vr/Resources/arm64ec-windows'
out.mkdir(parents=True, exist_ok=True)
for name in ('dockhost.exe', 'dock-notices.txt'):
    shutil.copy2(source / 'app/Madeira/arm64ec-windows' / name, out / name)
(out / 'dock-build.json').write_text(json.dumps({
    'schemaVersion': 1, 'sourceURL': 'https://github.com/willfaust/madeira-dock',
    'revision': revision, 'target': 'x86_64-w64-mingw32', 'testsRun': False,
    'sha256': hashlib.sha256((out / 'dockhost.exe').read_bytes()).hexdigest()
}, indent=2) + '\n')
PY
