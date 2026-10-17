#!/usr/bin/env python3
"""Synthetic host/GPU regression suite. Never launches Wine or a game."""
import argparse
import json
import os
from pathlib import Path
import struct
import subprocess

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--build', type=Path, default=Path('.build-fps-batch/checks'))
parser.add_argument('--baseline-renderer', type=Path)
args = parser.parse_args()
root = Path(__file__).resolve().parent.parent
build = args.build.resolve()
build.mkdir(parents=True, exist_ok=True)
env = os.environ.copy()
checks = {}


def run(name, command):
    with (build / (name + '.log')).open('w') as log:
        subprocess.run(command, cwd=root, env=env, stdout=log,
                       stderr=subprocess.STDOUT, check=True, timeout=90)
    checks[name] = 'pass'
    print(name + ': pass', flush=True)


clang = ['xcrun', '--sdk', 'macosx', 'clang++', '-std=c++20', '-O2']
include = str(root / 'windows-vr-native/include')
run('ticket-build', clang + ['-fsanitize=undefined', '-I', include,
    str(root / 'windows-vr-native/Tests/CompletionWindowTests.cpp'),
    '-o', str(build / 'tickets')])
run('tickets', [str(build / 'tickets')])
run('math-build', ['xcrun', '--sdk', 'macosx', 'swiftc', '-O',
    str(root / 'visionos-windows-vr/Sources/Rendering/WindowsVRPresentationMath.swift'),
    str(root / 'visionos-windows-vr/Tests/PresentationMathTests.swift'),
    '-o', str(build / 'math')])
run('math', [str(build / 'math')])

current = root / 'visionos-windows-vr/Sources/Rendering/WindowsVRCompositorScene.swift'
baseline = (args.baseline_renderer.read_text() if args.baseline_renderer else
    subprocess.check_output(['git', 'show',
        'adfdf25:visionos-windows-vr/Sources/Rendering/WindowsVRCompositorScene.swift'],
        cwd=root, text=True))
for label, text in [('baseline', baseline), ('patched', current.read_text())]:
    shader = text.split('private static let spatialShaderSource = """', 1)[1].split('"""', 1)[0]
    (build / (label + '.metal')).write_text(shader)

for name, probe, sources in [
    ('presentation', 'SimulatorPresentationProbe.mm', []),
    ('compositor', 'SimulatorCompositorProbe.mm', ['WindowsVRCompositorBridge.mm', 'WindowsVRGuestFoveation.mm']),
    ('frame-transfer', 'SimulatorFrameTransferProbe.mm', ['WindowsVRCompositorBridge.mm', 'WindowsVRGuestFoveation.mm']),
    ('gpu-statistics', 'SimulatorGPUStatisticsProbe.mm', ['WindowsVRMetalDiagnostics.mm'])
]:
    exe = build / name
    run(name + '-build', clang + ['-fobjc-arc', '-DWVR_SOURCE_AIR_WRITER=0', '-I', include,
        *[str(root / 'windows-vr-native/Sources' / s) for s in sources],
        str(root / 'windows-vr-native/Tests' / probe), '-framework', 'QuartzCore', '-framework', 'Foundation',
        '-framework', 'Metal', '-framework', 'CoreFoundation', '-o', str(exe)])
    if name == 'presentation':
        for label in ['baseline', 'patched']:
            run(name + '-' + label, [str(exe), str(build / (label + '.metal')),
                                     str(build / (label + '.bin'))])
    else:
        run(name, [str(exe)])

before = (build / 'baseline.bin').read_bytes()
after = (build / 'patched.bin').read_bytes()
assert len(before) == len(after) == 32768
color_difference = 0
depth_difference = 0.0
for row in range(len(before) // 128):
    offset = row * 128
    color_difference = max(color_difference, max(abs(a-b) for a, b in
        zip(before[offset:offset+64], after[offset:offset+64])))
    depth_difference = max(depth_difference, max(abs(a-b) for a, b in zip(
        struct.unpack_from('16f', before, offset+64),
        struct.unpack_from('16f', after, offset+64))))
assert color_difference <= 1 and depth_difference < 1e-6
checks['pixel-comparison'] = {'pixels': 4096, 'maxChannelDifference': color_difference,
                              'maxDepthDifference': depth_difference}
(build / 'results.json').write_text(json.dumps({
    'scope': 'macOS host CPU and real Metal GPU; no game or headset FPS measurement',
    'checks': checks}, indent=2) + '\n')
print('PASS: batch CPU/GPU checks and baseline/patched pixel comparison')
