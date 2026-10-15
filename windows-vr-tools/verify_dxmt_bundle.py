#!/usr/bin/env python3
"""Run the production DXMT package validator on assembled resources before signing.

The native dispatch eligibility is supplied by the linked headset runtime; this
host probe checks the identical package-file contract, without running Wine.
"""
import argparse
import os
import platform
import json
from pathlib import Path
import shutil
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser()
parser.add_argument('resources', type=Path)
parser.add_argument('--test', action='store_true', help='also verify rejection of stale hashes and missing DLLs')
args = parser.parse_args()
source = (root / 'windows-runtime-plugin/WindowsVRRuntimePlugin.mm').read_text()
def function(signature):
    start = source.index(signature)
    brace = source.index('{', start)
    end, depth = brace + 1, 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end]

code = '''#import <Foundation/Foundation.h>
#import <CommonCrypto/CommonDigest.h>
#include <string>
#include <vector>
#include <cstdio>
#include <cstdint>
#include <climits>
static NSURL *testResources;
bool IsModernDXMTNativeProfile() { return true; }
'''
for signature in ['bool IsContainedPath(', 'bool ReadPEInfo(', 'bool IsARM64ECPE(', 'bool SHA256File(', 'bool ValidateD3D12Package(']:
    code += function(signature).replace('[NSBundle mainBundle].resourceURL', 'testResources') + '\n'
code += '''int main(int argc, char **argv) { @autoreleasepool {
    if (argc != 2) return 1;
    testResources = [NSURL fileURLWithPath:[NSString stringWithUTF8String:argv[1]] isDirectory:YES];
    return ValidateD3D12Package() ? 0 : 2;
} }
'''
with tempfile.TemporaryDirectory(prefix='wvr-package-') as directory:
    work = Path(directory)
    cpp, exe = work / 'verify.mm', work / 'verify'
    cpp.write_text(code)
    native_env = os.environ.copy()
    for key in ['SDKROOT', 'XROS_DEPLOYMENT_TARGET', 'IPHONEOS_DEPLOYMENT_TARGET', 'TVOS_DEPLOYMENT_TARGET', 'WATCHOS_DEPLOYMENT_TARGET', 'MACOSX_DEPLOYMENT_TARGET']:
        native_env.pop(key, None)
    subprocess.run(['xcrun', '--sdk', 'macosx', 'clang++', '-target', platform.machine() + '-apple-macos14.0', '-std=c++20', '-fobjc-arc',
                    '-Wno-deprecated-declarations', str(cpp), '-framework', 'Foundation', '-o', str(exe)], check=True, env=native_env)
    def valid(resources):
        return subprocess.run([str(exe), str(resources.resolve())], check=False).returncode == 0
    if not valid(args.resources):
        raise SystemExit('error: DXMT graphics package fails the production runtime validator; check DLL hashes, architecture and capability receipt.')
    if args.test:
        fixture = work / 'Resources'
        (fixture / 'Runtime/arm64ec-windows').mkdir(parents=True)
        (fixture / 'WindowsVR/D3D12Experimental').mkdir(parents=True)
        receipt = 'WindowsVR/D3D12Experimental/AVPPLAY_DXMT_D3D12_PROFILE.json'
        for rel in [receipt, 'WindowsVR/GraphicsCapabilities.json', *['Runtime/arm64ec-windows/' + name for name in ['d3d11.dll','d3d12.dll','dxgi.dll','winemetal.dll']]]:
            shutil.copy2(args.resources / rel, fixture / rel)
        assert valid(fixture)
        path = fixture / receipt
        original = path.read_bytes()
        data = json.loads(original)
        data['guestArtifactsSha256']['d3d11.dll'] = '0' * 64
        path.write_text(json.dumps(data))
        assert not valid(fixture), 'stale D3D11 hash must block the shared graphics closure'
        path.write_bytes(original)
        (fixture / 'Runtime/arm64ec-windows/d3d12.dll').unlink()
        assert not valid(fixture), 'missing D3D12 DLL must remain blocked'
        print('PASS: actual runtime validator accepts the package and rejects stale hashes/missing DLLs')
    else:
        print('DXMT graphics package verified with the production runtime validator.')
