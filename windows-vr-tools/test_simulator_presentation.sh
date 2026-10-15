#!/usr/bin/env bash
# Test the production MSL color/depth pass using the simulator's actual GPU.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
DEVICE="${1:-booted}"
BUILD="$(mktemp -d "${TMPDIR:-/tmp}/avpplay-presentation.XXXXXX")"
python3 - "$ROOT" "$BUILD" <<'PY'
from pathlib import Path
import sys
root, build = map(Path, sys.argv[1:])
source = (root / 'visionos-windows-vr/Sources/Rendering/WindowsVRCompositorScene.swift').read_text()
shader = source.split('private static let spatialShaderSource = """', 1)[1].split('"""', 1)[0]
(build / 'presentation.metal').write_text(shader)
PY
xcrun --sdk xrsimulator clang++ -target arm64-apple-xros27.0-simulator \
  -std=c++20 -fobjc-arc "$ROOT/windows-vr-native/Tests/SimulatorPresentationProbe.mm" \
  -framework Foundation -framework Metal -o "$BUILD/probe"
xcrun simctl spawn "$DEVICE" "$BUILD/probe" "$BUILD/presentation.metal" 2>&1 | tee "$BUILD/results.log"
echo "Presentation result: $BUILD/results.log"
