#!/usr/bin/env python3
"""Prepare disposable simulator copies; these are experimental, never device artifacts."""
import argparse
import hashlib
import json
import plistlib
import shutil
import struct
import subprocess
from pathlib import Path


def run(*args):
    return subprocess.check_output(args, text=True, stderr=subprocess.STDOUT)


def binary(framework):
    with (framework / "Info.plist").open("rb") as stream:
        return framework / plistlib.load(stream)["CFBundleExecutable"]


def optional_metalfx(path):
    # This is permitted only when there are no references to MetalFX symbols.
    imports = run("nm", "-u", str(path))
    if any(name in imports for name in ("MTLFX", "MetalFX")):
        raise RuntimeError("Runtime references MetalFX symbols; a missing framework cannot be ignored")
    data = bytearray(path.read_bytes())
    if struct.unpack_from("<I", data)[0] != 0xFEEDFACF:
        raise RuntimeError("Expected a thin little-endian 64-bit Mach-O")
    count, command_bytes = struct.unpack_from("<II", data, 16)
    position, matches = 32, 0
    end = position + command_bytes
    if end > len(data):
        raise RuntimeError("Truncated Mach-O load commands")
    for _ in range(count):
        command, size = struct.unpack_from("<II", data, position)
        if size < 8 or position + size > end:
            raise RuntimeError("Invalid Mach-O load command")
        if command in (0xC, 0x80000018):
            if size < 24:
                raise RuntimeError("Truncated dylib command")
            offset = struct.unpack_from("<I", data, position + 8)[0]
            if not 24 <= offset < size:
                raise RuntimeError("Invalid dylib name offset")
            name = bytes(data[position + offset:position + size]).split(b"\0", 1)[0]
            if name == b"/System/Library/Frameworks/MetalFX.framework/MetalFX":
                struct.pack_into("<I", data, position, 0x80000018)
                matches += 1
        position += size
    if matches != 1 or position != end:
        raise RuntimeError("Expected exactly one MetalFX dependency and valid load commands")
    path.write_bytes(data)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("device_frameworks", type=Path, help="Frameworks directory in a device-built app")
    parser.add_argument("simulator_metal", type=Path, help="SDK-built libWindowsVRMetal.dylib")
    parser.add_argument("output", type=Path, help="New empty directory for experimental copies")
    args = parser.parse_args()
    source, metal, output = (p.resolve() for p in (args.device_frameworks, args.simulator_metal, args.output))
    if output.exists():
        raise RuntimeError("Output must not exist; original frameworks are never edited")
    if "VISIONOSSIM" not in run("xcrun", "vtool", "-show-build", str(metal)).upper():
        raise RuntimeError("WindowsVRMetal must be compiled for visionOS Simulator")
    inputs = {}
    for name in ("WindowsRuntimePlugin", "WindowsVRNativeBridge", "WindowsVRMetal"):
        framework = source / (name + ".framework")
        path = binary(framework)
        inputs[name] = hashlib.sha256(path.read_bytes()).hexdigest()
    output.mkdir(parents=True)
    for name in inputs:
        destination = output / (name + ".framework")
        shutil.copytree(source / destination.name, destination, symlinks=True)
        path = binary(destination)
        if name == "WindowsVRMetal":
            shutil.copyfile(metal, path)
            run("install_name_tool", "-id", "@rpath/WindowsVRMetal.framework/WindowsVRMetal", str(path))
        else:
            run("xcrun", "vtool", "-set-build-version", "visionossim", "27.0", "27.0", "-replace", "-output", str(path), str(path))
            if name == "WindowsRuntimePlugin":
                optional_metalfx(path)
        run("codesign", "--force", "--sign", "-", str(destination))
    receipt = {"experimentalSimulatorOnly": True, "sourceBinarySha256": inputs,
               "simulatorMetalSha256": hashlib.sha256(metal.read_bytes()).hexdigest(),
               "limitations": "Retagged device machine code is not a simulator-native runtime build or hardware performance test."}
    (output / "simulator-profile.json").write_text(json.dumps(receipt, indent=2) + "\n")
    print(output)


if __name__ == "__main__":
    main()
