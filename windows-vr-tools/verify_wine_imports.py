#!/usr/bin/env python3
"""Check packaged PE imports and export forwarders without executing Windows code."""
import argparse
import json
import os
from pathlib import Path
import re
import shutil
import subprocess


# Exact private Win16/thunk exports from pinned Wine kernel32.spec. WoW64 has
# no 16-bit execution layer. These optional forwarded exports remain explicitly
# unsupported; ordinary imports and every other forwarder still require providers.
I386_KERNEL32_UNSUPPORTED_WIN16_EXPORTS = frozenset("""
VxDCall0 VxDCall1 VxDCall2 VxDCall3 VxDCall4 VxDCall5 VxDCall6 VxDCall7 VxDCall8 k32CharToOemA
k32CharToOemBuffA k32OemToCharA k32OemToCharBuffA k32LoadStringA k32wsprintfA k32wvsprintfA CommonUnimpStub
GetProcessDword DosFileHandleToWin32Handle Win32HandleToDosFileHandle DisposeLZ32Handle GlobalAlloc16
GlobalLock16 GlobalUnlock16 GlobalFix16 GlobalUnfix16 GlobalWire16 GlobalUnWire16 GlobalFree16 GlobalSize16
HouseCleanLogicallyDeadHandles GetWin16DOSEnv LoadLibrary16 FreeLibrary16 GetProcAddress16 AllocMappedBuffer
FreeMappedBuffer OT_32ThkLSF ThunkInitLSF LogApiThkLSF ThunkInitLS LogApiThkSL Common32ThkLS ThunkInitSL
LogCBThkSL ReleaseThunkLock RestoreThunkLock W32S_BackTo32 GetThunkBuff GetThunkStuff K32WOWCallback16
K32WOWCallback16Ex K32WOWGetVDMPointer K32WOWHandle32 K32WOWHandle16 K32WOWGlobalAlloc16 K32WOWGlobalLock16
K32WOWGlobalUnlock16 K32WOWGlobalFree16 K32WOWGlobalAllocLock16 K32WOWGlobalUnlockFree16
K32WOWGlobalLockSize16 K32WOWYield16 K32WOWDirectedYield16 K32WOWGetVDMPointerFix K32WOWGetVDMPointerUnfix
K32WOWGetDescriptor _KERNEL32_86 SSOnBigStack SSCall FT_PrologPrime QT_ThunkPrime PK16FNF GetPK16SysVar
GetpWin16Lock _CheckNotSysLevel _ConfirmSysLevel _ConfirmWin16Lock _EnterSysLevel _LeaveSysLevel _KERNEL32_99
_KERNEL32_100 AllocSLCallback FT_Exit0 FT_Exit12 FT_Exit16 FT_Exit20 FT_Exit24 FT_Exit28 FT_Exit32 FT_Exit36
FT_Exit40 FT_Exit44 FT_Exit48 FT_Exit4 FT_Exit52 FT_Exit56 FT_Exit8 FT_Prolog FT_Thunk FreeSLCallback
Get16DLLAddress K32Thk1632Epilog K32Thk1632Prolog MapHInstLS MapHInstLS_PN MapHInstSL MapHInstSL_PN
MapHModuleLS MapHModuleSL MapLS MapSL MapSLFix PrivateFreeLibrary PrivateLoadLibrary QT_Thunk SMapLS
SMapLS_IP_EBP_12 SMapLS_IP_EBP_16 SMapLS_IP_EBP_20 SMapLS_IP_EBP_24 SMapLS_IP_EBP_28 SMapLS_IP_EBP_32
SMapLS_IP_EBP_36 SMapLS_IP_EBP_40 SMapLS_IP_EBP_8 SUnMapLS SUnMapLS_IP_EBP_12 SUnMapLS_IP_EBP_16
SUnMapLS_IP_EBP_20 SUnMapLS_IP_EBP_24 SUnMapLS_IP_EBP_28 SUnMapLS_IP_EBP_32 SUnMapLS_IP_EBP_36
SUnMapLS_IP_EBP_40 SUnMapLS_IP_EBP_8 ThunkConnect32 UTRegister UTUnRegister UnMapLS UnMapSLFixArray
""".split())


def dependencies(imports, exports, *, importer=None, machine=None, unsupported_forwarders=None):
    names = {name.lower() for name in re.findall(r"^  Name: (.+)$", imports, re.M)}
    for target in re.findall(r"\(forwarded to ([^()\s]+)\)", exports):
        module, separator, symbol = target.rpartition(".")
        if separator:
            module = module.lower()
            if (machine == "i386" and importer and importer.casefold() == "kernel32.dll"
                    and module == "krnl386.exe16" and symbol in I386_KERNEL32_UNSUPPORTED_WIN16_EXPORTS):
                if unsupported_forwarders is not None:
                    unsupported_forwarders.append({"importer": importer, "target": target,
                                                   "reason": "Private Win16/thunk compatibility export; 16-bit execution is unsupported"})
                continue
            # LoadLibrary supplies .dll only when the module has no extension.
            # Forwarders may explicitly name .cpl, .acm or Wine's .exe16 modules.
            names.add(module if "." in module else module + ".dll")
    return names


def missing_dependencies(graph, available):
    missing = {}
    for importer, names in graph.items():
        for name in names:
            if name.startswith(("api-ms-", "ext-ms-")):
                continue  # Resolved through the separately verified apisetschema.dll.
            if name not in available:
                missing.setdefault(name, []).append(importer)
    return {name: sorted(importers) for name, importers in sorted(missing.items())}


def validate_pe_architecture(path, machine):
    from stage_resources import pe_machine
    actual = pe_machine(path)
    expected = {"i386": 0x14C, "arm64": 0xAA64}[machine]
    if actual != expected:
        raise ValueError(f"{path} has PE Machine {actual!r}; expected {machine} ({expected:#x})")


def inspect_closure(files, tools, extra_files=(), machine=None, reject_shared_cxx=False, unsupported_forwarders=None):
    graph = {}
    names = set()
    extras = set(extra_files)
    for path in [*files, *extra_files]:
        if path.is_symlink() or not path.is_file():
            raise ValueError(f"PE resource must be a regular file: {path}")
        key = path.name.casefold()
        if key in names:
            raise ValueError(f"PE dependency closure contains duplicate/case-colliding module: {path.name}")
        names.add(key)
        if machine:
            validate_pe_architecture(path, machine)
        imports = subprocess.check_output([tools["llvm-readobj"], "--coff-imports", str(path)], text=True)
        exports = subprocess.check_output([tools["llvm-objdump"], "-p", str(path)], text=True)
        graph[path.name] = dependencies(imports, exports, importer=path.name, machine=machine,
                                        unsupported_forwarders=unsupported_forwarders)
        if reject_shared_cxx and path in extras:
            forbidden = graph[path.name] & {"libc++.dll", "libc++abi.dll", "libunwind.dll", "libstdc++-6.dll"}
            if forbidden:
                raise ValueError(f"Guest bridge {path.name} requires architecture-dependent shared C++ libraries: {', '.join(sorted(forbidden))}")
    return missing_dependencies(graph, names)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("farm", type=Path)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--machine", choices=("i386", "arm64"), help="Require the actual PE Machine architecture of every binary")
    parser.add_argument("--extra-file", type=Path, action="append", default=[], help="Additional guest bridge DLL checked against this farm")
    parser.add_argument("--reject-shared-cxx", action="store_true", help="Require additional guest bridges to carry their own C++ runtime")
    args = parser.parse_args()
    toolchain = Path(os.environ.get("AVPPLAY_LLVM_MINGW_ROOT", "/nonexistent")) / "bin"
    tools = {}
    for name in ("llvm-readobj", "llvm-objdump"):
        candidate = toolchain / name
        tools[name] = str(candidate) if candidate.is_file() else shutil.which(name)
        if not tools[name]:
            parser.error(f"Set AVPPLAY_LLVM_MINGW_ROOT or provide {name} on PATH")
    files = sorted(p for p in args.farm.iterdir() if p.is_file() and
                   p.suffix.lower() in ((".dll", ".exe", ".drv", ".cpl", ".acm", ".ax", ".ocx", ".com") if args.machine == "i386" else (".dll", ".exe", ".drv")))
    if not files:
        parser.error("The PE resource directory is empty")
    unsupported = []
    try:
        missing = inspect_closure(files, tools, args.extra_file, args.machine, args.reject_shared_cxx, unsupported)
    except (ValueError, OSError, subprocess.CalledProcessError) as exc:
        parser.error(str(exc))
    result = {"checkedFiles": len(files) + len(args.extra_file), "missingDependencies": missing, "unsupportedWin16Forwarders": unsupported,
              "scope": "Static imports, delay imports and export forwarders; dynamic LoadLibrary names and runtime behavior are not proven",
              "tools": tools}
    if args.output:
        args.output.write_text(json.dumps(result, indent=2) + "\n")
    if missing:
        for name, parents in missing.items():
            print(f"error: Missing PE dependency {name}, referenced by {', '.join(parents)}")
        return 1
    print(f"Wine PE imports/supported forwarders verified across {len(files) + len(args.extra_file)} binaries.")
    if unsupported:
        print(f"Explicitly unsupported Win16 compatibility forwarders: {len(unsupported)} (i386 kernel32.dll to krnl386.exe16 only).")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
