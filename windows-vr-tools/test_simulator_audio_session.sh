#!/usr/bin/env bash
# Exercise the host's real audio policy adapter without Wine or a game.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
DEVICE="${1:-booted}"
BUILD="$(mktemp -d "${TMPDIR:-/tmp}/winevision-audio-session.XXXXXX")"
SDK="$(xcrun --sdk xrsimulator --show-sdk-path)"
xcrun --sdk xrsimulator clang++ -target arm64-apple-xros27.0-simulator \
    -isysroot "$SDK" -std=c++20 -fobjc-arc -I "$ROOT/windows-vr-native/include" \
    "$ROOT/windows-vr-native/Sources/WindowsVRAudioSession.mm" \
    "$ROOT/windows-vr-native/Tests/SimulatorAudioSessionProbe.mm" \
    -framework Foundation -framework AVFAudio -o "$BUILD/probe"
xcrun simctl spawn "$DEVICE" "$BUILD/probe" 2>&1 | tee "$BUILD/results.log"
echo "Audio policy result: $BUILD/results.log"
