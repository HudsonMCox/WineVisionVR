#!/usr/bin/env bash
# Synthetic Metal test only. Does not launch Wine or a game, or claim real gaze validation.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
BUILD="$(mktemp -d "${TMPDIR:-/tmp}/winevision-guest-foveation.XXXXXX")"
SDK="$(xcrun --sdk xrsimulator --show-sdk-path)"
xcrun --sdk xrsimulator clang++ -target arm64-apple-xros27.0-simulator -isysroot "$SDK" -std=c++20 -fobjc-arc -DWVR_GUEST_FOVEATION_TEST=1 \
 -I "$ROOT/windows-vr-native/include" "$ROOT/windows-vr-native/Sources/WindowsVRGuestFoveation.mm" \
 "$ROOT/windows-vr-native/Sources/WindowsVRCompositorBridge.mm" "$ROOT/windows-vr-native/Tests/SimulatorGuestFoveationProbe.mm" \
 -Wl,-export_dynamic -framework Foundation -framework Metal -framework CoreFoundation -framework QuartzCore -o "$BUILD/probe"
xcrun simctl spawn "${1:-booted}" "$BUILD/probe" 2>&1 | tee "$BUILD/results.log"
