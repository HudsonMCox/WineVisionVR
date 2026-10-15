#!/usr/bin/env bash
# Real GPU/fence ownership test; does not start Wine or a game.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
DEVICE="${1:-booted}"
BUILD="$(mktemp -d "${TMPDIR:-/tmp}/avpplay-frame-transfer.XXXXXX")"
SDK="$(xcrun --sdk xrsimulator --show-sdk-path)"
xcrun --sdk xrsimulator clang++ -target arm64-apple-xros27.0-simulator -isysroot "$SDK" -std=c++20 -fobjc-arc \
  -I "$ROOT/windows-vr-native/include" \
  "$ROOT/windows-vr-native/Sources/WindowsVRCompositorBridge.mm" \
    "$ROOT/windows-vr-native/Sources/WindowsVRGuestFoveation.mm" \
  "$ROOT/windows-vr-native/Tests/SimulatorFrameTransferProbe.mm" \
  -framework QuartzCore -framework Foundation -framework Metal -framework CoreFoundation -o "$BUILD/probe"
xcrun simctl spawn "$DEVICE" "$BUILD/probe" 2>&1 | tee "$BUILD/results.log"
echo "Frame transfer result: $BUILD/results.log"
