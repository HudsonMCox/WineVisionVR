#!/usr/bin/env bash
# Compile and execute the real native bridge with synthetic Metal producer frames.
# This exercises the simulator GPU/bridge, not Wine, OpenXR or headset rendering.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
DEVICE="${1:-booted}"
BUILD="$(mktemp -d "${TMPDIR:-/tmp}/avpplay-simulator-compositor.XXXXXX")"
SDK="$(xcrun --sdk xrsimulator --show-sdk-path)"
xcrun --sdk xrsimulator clang++ -target arm64-apple-xros27.0-simulator \
    -isysroot "$SDK" -std=c++20 -fobjc-arc \
    -I "$ROOT/windows-vr-native/include" \
    "$ROOT/windows-vr-native/Sources/WindowsVRCompositorBridge.mm" \
    "$ROOT/windows-vr-native/Sources/WindowsVRGuestFoveation.mm" \
    "$ROOT/windows-vr-native/Tests/SimulatorCompositorProbe.mm" \
    -framework QuartzCore -framework Foundation -framework Metal -framework CoreFoundation \
    -o "$BUILD/compositor-probe"
xcrun simctl spawn "$DEVICE" "$BUILD/compositor-probe" 2>&1 | tee "$BUILD/results.log"
echo "Simulator result: $BUILD/results.log"
