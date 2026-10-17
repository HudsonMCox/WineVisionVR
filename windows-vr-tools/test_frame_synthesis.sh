#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
BUILD="${1:-$ROOT/.build-frame-synthesis}"
mkdir -p "$BUILD"
xcrun --sdk macosx clang++ -std=c++20 -O2 -fobjc-arc \
 -DWVR_SOURCE_AIR_WRITER=0 -DWVR_GUEST_FOVEATION_TEST=1 -Wl,-export_dynamic \
 -I "$ROOT/windows-vr-native/include" \
 "$ROOT/windows-vr-native/Sources/WindowsVRCompositorBridge.mm" \
 "$ROOT/windows-vr-native/Sources/WindowsVRGuestFoveation.mm" \
 "$ROOT/windows-vr-native/Sources/WindowsVRFrameSynthesis.mm" \
 "$ROOT/windows-vr-native/Tests/FrameSynthesisProbe.mm" \
 -framework Foundation -framework Metal -framework QuartzCore -framework CoreFoundation \
 -o "$BUILD/frame-synthesis-probe"
"$BUILD/frame-synthesis-probe"
xcrun --sdk macosx clang++ -std=c++20 -fsanitize=undefined,bounds \
 "$ROOT/windows-vr-openvr/tests/DepthProjectionProbe.cpp" -o "$BUILD/depth-projection-probe"
"$BUILD/depth-projection-probe"
python3 - "$ROOT/windows-vr-native/Sources/WindowsVRFrameSynthesis.mm" "$BUILD/frame-synthesis.metal" <<'PY'
from pathlib import Path
import sys
text=Path(sys.argv[1]).read_text()
Path(sys.argv[2]).write_text(text.split('@R"metal(',1)[1].split(')metal"',1)[0])
PY
xcrun --sdk xros metal -target air64-apple-xros27.0 -c "$BUILD/frame-synthesis.metal" -o "$BUILD/frame-synthesis.air"
