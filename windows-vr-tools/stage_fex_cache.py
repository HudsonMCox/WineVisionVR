#!/usr/bin/env python3
"""Build/stage or verify the FEX compiler, launcher and matching translator."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
from stage_resources import is_arm64ec_pe
from verify_openvr_bundle import imports

ROOT = Path(__file__).resolve().parents[1]
NAMES = ("FEXOfflineCompiler64.exe", "WindowsVRCacheLauncher.exe")

def sha(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()

def verify(output, runtime):
    receipt = json.loads((output / "AVPPLAY_FEX_CACHE_RECEIPT.json").read_text())
    if receipt.get("schemaVersion") != 1 or receipt.get("cacheFormat") != 3:
        raise SystemExit("Invalid FEX cache receipt schema")
    expected = receipt.get("filesSha256", {})
    if set(expected) != set(NAMES):
        raise SystemExit("FEX cache helper closure is incomplete")
    for name, digest in expected.items():
        path = output / name
        if path.is_symlink() or not path.is_file() or not is_arm64ec_pe(path) or sha(path) != digest:
            raise SystemExit(f"FEX cache helper is missing, changed or not ARM64EC: {name}")
        if set(imports(path, 0xA641)) & {"libc++.dll", "libc++abi.dll", "libunwind.dll", "libstdc++-6.dll"}:
            raise SystemExit(f"FEX cache helper requires an unbundled/shared C++ runtime: {name}")
    translator = runtime / "arm64ec-windows/xtajit64.dll"
    if not is_arm64ec_pe(translator) or sha(translator) != receipt.get("translatorSha256"):
        raise SystemExit("FEX cache compiler does not match the packaged translator")
    print("Verified native FEX cache compiler, launcher and matching translator (format 3)")

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--runtime", type=Path, required=True)
    parser.add_argument("--fex-build", type=Path)
    parser.add_argument("--llvm-mingw", type=Path)
    parser.add_argument("--verify", action="store_true")
    args = parser.parse_args()
    if not args.verify:
        if not args.fex_build or not args.llvm_mingw:
            parser.error("staging needs --fex-build and --llvm-mingw")
        args.output.mkdir(parents=True, exist_ok=True)
        lib = args.llvm_mingw / "arm64ec-w64-mingw32/lib"
        command = [str(args.llvm_mingw / "bin/arm64ec-w64-mingw32-clang++"),
                   "-std=c++20", "-O2", "-static", "-nostdlib++", "-municode",
                   "-Wl,--file-alignment=4096,/mllvm:-align-loops=1",
                   str(ROOT / "windows-runtime-plugin/cache/WindowsVRCacheLauncher.cpp"),
                   "-o", str(args.output / NAMES[1])]
        command += [str(lib / name) for name in ("libc++.a", "libc++abi.a", "libunwind.a", "libmingwex.a", "libucrtbase.a")]
        subprocess.run(command, check=True)
        shutil.copy2(args.fex_build / "Bin/FEXOfflineCompiler.exe", args.output / NAMES[0])
        translator = args.runtime / "arm64ec-windows/xtajit64.dll"
        if sha(translator) != sha(args.fex_build / "Bin/libarm64ecfex.dll"):
            raise SystemExit("Stage the freshly built translator before its compiler")
        receipt = {"schemaVersion": 1, "cacheFormat": 3, "architecture": "arm64ec",
                   "translatorSha256": sha(translator),
                   "filesSha256": {name: sha(args.output / name) for name in NAMES},
                   "sourcesSha256": {str(path.relative_to(ROOT)): sha(path) for path in (
                       ROOT / "windows-runtime-plugin/patches/0004-fex-persistent-code-cache.patch",
                       ROOT / "windows-runtime-plugin/patches/0005-fex-native-dispatch-fastpath.patch",
                       ROOT / "windows-runtime-plugin/cache/WindowsVRCacheLauncher.cpp",
                       ROOT / "windows-runtime-plugin/cache/WindowsCommandLine.h")}}
        (args.output / "AVPPLAY_FEX_CACHE_RECEIPT.json").write_text(json.dumps(receipt, indent=2, sort_keys=True) + "\n")
    verify(args.output, args.runtime)

if __name__ == "__main__":
    main()
