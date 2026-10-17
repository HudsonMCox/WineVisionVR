#!/usr/bin/env bash
# Actual macOS Metal device; no Wine/game launch, no real gaze claim.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
BUILD="$(mktemp -d "${TMPDIR:-/tmp}/winevision-foveation.XXXXXX")"
xcrun --sdk macosx clang++ -std=c++20 -O2 -fobjc-arc -DWVR_GUEST_FOVEATION_TEST=1 \
 -I "$ROOT/windows-vr-native/include" "$ROOT/windows-vr-native/Sources/WindowsVRGuestFoveation.mm" \
 "$ROOT/windows-vr-native/Sources/WindowsVRCompositorBridge.mm" "$ROOT/windows-vr-native/Tests/SimulatorGuestFoveationProbe.mm" \
 -Wl,-export_dynamic -framework Foundation -framework Metal -framework CoreFoundation -framework QuartzCore -o "$BUILD/probe"
"$BUILD/probe"
"$BUILD/probe" unused mrt
"$BUILD/probe" unused stencil
"$BUILD/probe" unused srgb
if [[ -n "${1:-}" ]]; then "$BUILD/probe" "$1"; fi
python3 - "$ROOT" "$BUILD" <<'PY'
from pathlib import Path
import sys
root,build=map(Path,sys.argv[1:])
s=(root/'visionos-windows-vr/Sources/Rendering/WindowsVRCompositorScene.swift').read_text()
(build/'presentation.metal').write_text(s.split('private static let spatialShaderSource = """',1)[1].split('"""',1)[0])
PY
xcrun --sdk macosx clang++ -std=c++20 -O2 -fobjc-arc "$ROOT/windows-vr-native/Tests/LayeredFoveatedPresentationProbe.mm" -framework Foundation -framework Metal -o "$BUILD/layered"
"$BUILD/layered" "$BUILD/presentation.metal"
echo "GPU checks: $BUILD"

xcrun --sdk macosx clang++ -std=c++20 -O2 -fobjc-arc -DWVR_GUEST_FOVEATION_TEST=1 \
 -I "$ROOT/windows-vr-native/include" "$ROOT/windows-vr-native/Sources/WindowsVRGuestFoveation.mm" \
 "$ROOT/windows-vr-native/Sources/WindowsVRCompositorBridge.mm" "$ROOT/windows-vr-native/Tests/StereoAtlasFoveationProbe.mm" \
 -Wl,-export_dynamic -framework Foundation -framework Metal -framework CoreFoundation -framework QuartzCore -o "$BUILD/atlas"
"$BUILD/atlas"
