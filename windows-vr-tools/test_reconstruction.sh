#!/usr/bin/env bash
# Real Mac Metal probes and production transport tests; no Wine or game launch.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
BUILD="${1:-$ROOT/.build-reconstruction-check}"
mkdir -p "$BUILD"
xcrun --sdk macosx clang++ -std=c++20 -O2 -fobjc-arc \
  -DWVR_SOURCE_AIR_WRITER=0 -DWVR_GUEST_FOVEATION_TEST=1 -Wl,-export_dynamic \
  -I "$ROOT/windows-vr-native/include" \
  "$ROOT/windows-vr-native/Sources/WindowsVRCompositorBridge.mm" \
  "$ROOT/windows-vr-native/Sources/WindowsVRGuestFoveation.mm" \
  "$ROOT/windows-vr-native/Sources/WindowsVRReconstruction.mm" \
  "$ROOT/windows-vr-native/Tests/ReconstructionProbe.mm" \
  -framework Foundation -framework Metal -framework QuartzCore -framework CoreFoundation \
  -o "$BUILD/reconstruction-probe"
for variant in plain srgb array array-srgb; do
  printf 'Reconstruction GPU case: %s\n' "$variant"
  "$BUILD/reconstruction-probe" "$variant"
done
python3 -I -S "$ROOT/windows-vr-openxr/tests/test_depth_projection.py"
python3 -I -S "$ROOT/windows-vr-openxr/tests/test_depth_submission.py"
python3 -I -S "$ROOT/windows-vr-openxr/tests/test_depth_pending_lifetime.py" \
  --dxmt "${WVR_DXMT_SOURCE:-$ROOT/.build-performance/dxmt}"
