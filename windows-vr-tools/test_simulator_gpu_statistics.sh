#!/usr/bin/env bash
# Verify observer classification with synthetic GPU work, without running a game.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
DEVICE="${1:-booted}"
BUILD="$(mktemp -d "${TMPDIR:-/tmp}/avpplay-gpu-statistics.XXXXXX")"
SDK="$(xcrun --sdk xrsimulator --show-sdk-path)"
xcrun --sdk xrsimulator clang++ -target arm64-apple-xros27.0-simulator -isysroot "$SDK" \
  -std=c++20 -fobjc-arc -DWVR_SOURCE_AIR_WRITER=0 -I "$ROOT/windows-vr-native/include" \
  "$ROOT/windows-vr-native/Sources/WindowsVRMetalDiagnostics.mm" \
  "$ROOT/windows-vr-native/Tests/SimulatorGPUStatisticsProbe.mm" \
  -framework Foundation -framework Metal -o "$BUILD/probe"
xcrun simctl spawn "$DEVICE" "$BUILD/probe" 2>&1 | tee "$BUILD/results.log"
echo "GPU statistics result: $BUILD/results.log"
