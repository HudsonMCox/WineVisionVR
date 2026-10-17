#!/usr/bin/env bash
# Experimental, opt-in 32-bit Wine/FEX/DXMT build. Does not install or run Wine.
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
runtime_root="${AVPPLAY_I386_RUNTIME_SOURCE:-}"
if [[ "${AVPPLAY_ALLOW_RUNTIME_BUILD:-0}" != 1 || "${AVPPLAY_BUILD_WINE_I386:-0}" != 1 ]]; then
    echo 'Set AVPPLAY_ALLOW_RUNTIME_BUILD=1 and AVPPLAY_BUILD_WINE_I386=1.' >&2; exit 1
fi
if [[ -z "$runtime_root" || "$runtime_root" != /* || ! -f "$runtime_root/AVPPLAY_SOURCE_PROVENANCE.json" ]]; then
    echo 'Set AVPPLAY_I386_RUNTIME_SOURCE to a separate prepared legacy Madeira source tree.' >&2; exit 1
fi
if [[ -n "${AVPPLAY_RUNTIME_SOURCE:-}" && "$(cd "$runtime_root" && pwd -P)" == "$(cd "$AVPPLAY_RUNTIME_SOURCE" && pwd -P)" && "${AVPPLAY_ALLOW_I386_ACTIVE_CANDIDATE:-0}" != 1 ]]; then
    echo 'The experimental i386 source must be separate from AVPPLAY_RUNTIME_SOURCE.' >&2; exit 1
fi
if [[ -f "$runtime_root/AVPPLAY_D3D12_SOURCE_PROVENANCE.json" ]] || grep -q '^#define WVR_DXMT_D3D12_PROFILE 1' "$runtime_root/build/ntdll-unix/virtual_ios.c"; then
    echo 'Modern DXMT rejects Madeira WOW64 pointers. Use a matching legacy Madeira source/native candidate.' >&2; exit 1
fi
if [[ -z "${AVPPLAY_LLVM_MINGW_ROOT:-}" || "$AVPPLAY_LLVM_MINGW_ROOT" != /* || ! -d "$AVPPLAY_LLVM_MINGW_ROOT" ]]; then
    echo 'Set AVPPLAY_LLVM_MINGW_ROOT to the pinned external LLVM-MinGW distribution.' >&2; exit 1
fi
for tool in i686-w64-mingw32-clang i686-w64-mingw32-strip aarch64-w64-mingw32-clang; do
    [[ -x "$AVPPLAY_LLVM_MINGW_ROOT/bin/$tool" ]] || { echo "Missing tool $tool" >&2; exit 1; }
done
for tool in bison meson ninja cmake; do
    command -v "$tool" >/dev/null || { echo "Missing host tool $tool" >&2; exit 1; }
done
bison_version="$(bison --version | awk 'NR == 1 {print $4}')"
bison_major="${bison_version%%.*}"
[[ "$bison_major" =~ ^[0-9]+$ ]] && (( bison_major >= 3 )) || { echo 'Wine requires bison 3 or newer.' >&2; exit 1; }
pinned_toolchain="$runtime_root/toolchains/llvm-mingw-20260421-ucrt-macos-universal"
created_link=0
if [[ -e "$pinned_toolchain" || -L "$pinned_toolchain" ]]; then
    [[ -d "$pinned_toolchain" ]] && [[ "$(cd "$pinned_toolchain" && pwd -P)" == "$(cd "$AVPPLAY_LLVM_MINGW_ROOT" && pwd -P)" ]] || { echo 'Existing candidate toolchain path has a different target.' >&2; exit 1; }
else
    mkdir -p "$(dirname "$pinned_toolchain")"
    ln -s "$AVPPLAY_LLVM_MINGW_ROOT" "$pinned_toolchain"
    created_link=1
fi
cleanup() { if (( created_link )); then rm -f "$pinned_toolchain"; fi; }
trap cleanup EXIT
export PATH="$AVPPLAY_LLVM_MINGW_ROOT/bin:$PATH"
export JOBS="${AVPPLAY_BUILD_JOBS:-4}"
# Build the native WoW64 half from the same Wine source in a separate tree.
# This must not race the generic aarch64 service build's configuration/cache.
helper_build="$runtime_root/wine/build-i386-wow64-aarch64"
if [[ ! -f "$helper_build/config.status" ]]; then
    mkdir -p "$helper_build"
    (cd "$helper_build" && ../configure --enable-archs=aarch64 --without-x --without-vulkan \
        --without-freetype --disable-tests)
fi
helper_targets=(
    dlls/ntdll/aarch64-windows/ntdll.dll
    dlls/wow64/aarch64-windows/wow64.dll
    dlls/wow64win/aarch64-windows/wow64win.dll
    dlls/kernel32/aarch64-windows/kernel32.dll
    dlls/kernelbase/aarch64-windows/kernelbase.dll
    dlls/user32/aarch64-windows/user32.dll
    dlls/gdi32/aarch64-windows/gdi32.dll
    dlls/win32u/aarch64-windows/win32u.dll
    dlls/advapi32/aarch64-windows/advapi32.dll
)
make -C "$helper_build" -j"$JOBS" "${helper_targets[@]}"
for target in "${helper_targets[@]}"; do
    output="$runtime_root/app/Madeira/aarch64-windows/$(basename "$target")"
    cp "$helper_build/$target" "$output.tmp"
    "$AVPPLAY_LLVM_MINGW_ROOT/bin/aarch64-w64-mingw32-strip" --strip-debug "$output.tmp"
    mv "$output.tmp" "$output"
done
python3 - "$runtime_root" "${helper_targets[@]}" <<'PYCORE'
import hashlib, json, sys
from pathlib import Path
root=Path(sys.argv[1]); targets=sys.argv[2:]
report={'schemaVersion':1,'status':'matching-arm64-wow64-core-built-not-device-tested',
        'sourceProvenanceSha256':hashlib.sha256((root/'AVPPLAY_SOURCE_PROVENANCE.json').read_bytes()).hexdigest(),
        'buildDirectory':'wine/build-i386-wow64-aarch64',
        'targets':{target:{'buildSha256':hashlib.sha256((root/'wine/build-i386-wow64-aarch64'/target).read_bytes()).hexdigest(),
                           'packagedSha256':hashlib.sha256((root/'app/Madeira/aarch64-windows'/Path(target).name).read_bytes()).hexdigest()}
                   for target in targets}}
(root/'build/aarch64-wow64-core-experimental.json').write_text(json.dumps(report,indent=2)+'\n')
PYCORE
if [[ "${AVPPLAY_I386_BUILD_PHASE:-all}" == wow64-helpers ]]; then
    echo 'Fresh matching aarch64 ntdll/wow64/wow64win helpers built.'
    exit 0
fi
if [[ "${AVPPLAY_I386_BUILD_PHASE:-all}" != all && "${AVPPLAY_I386_BUILD_PHASE:-all}" != wow64-closure ]]; then
    echo 'Unknown AVPPLAY_I386_BUILD_PHASE; use all, wow64-helpers, or wow64-closure.' >&2; exit 1
fi
# WoW64's native half can load additional ARM64 providers even when the game
# itself is i386. Build the actual Wine targets for the complete imports,
# delay-imports and export-forwarders closure; never borrow x86 DLLs.
python3 - "$runtime_root" "$repo_root" "$AVPPLAY_LLVM_MINGW_ROOT" "$JOBS" <<'PYCLOSURE'
import hashlib, json, re, shutil, subprocess, sys
from pathlib import Path
root, repo, toolchain = map(Path, sys.argv[1:4])
jobs = sys.argv[4]
sys.path.insert(0, str(repo/'windows-vr-tools'))
from verify_wine_imports import inspect_closure
farm = root/'app/Madeira/aarch64-windows'
build = root/'wine/build-i386-wow64-aarch64'
tools = {name:str(toolchain/'bin'/name) for name in ('llvm-readobj','llvm-objdump')}
makefile = (build/'Makefile').read_text()
# Index genuine configured targets rather than guessing a source module name.
targets = {}
for target in re.findall(r'^(dlls/[^/\s]+/aarch64-windows/[^\s:]+):', makefile, re.M):
    name = Path(target).name.casefold()
    if name.endswith(('.dll','.exe','.drv')):
        if name in targets and targets[name] != target:
            raise SystemExit('Ambiguous Wine ARM64 target: ' + name)
        targets[name] = target
built = []
for iteration in range(16):
    files = sorted(p for p in farm.iterdir() if p.suffix.casefold() in ('.dll','.exe','.drv'))
    missing = inspect_closure(files, tools, machine='arm64')
    if not missing:
        report = {'schemaVersion':1, 'status':'static-arm64-import-closure-verified',
                  'checkedFiles':len(files), 'missingDependencies':{}, 'builtProviders':built,
                  'scope':'Actual ARM64 Wine providers built for static imports, delay imports and export forwarders; dynamic loading and device execution remain untested'}
        (root/'build/aarch64-wow64-closure.json').write_text(json.dumps(report,indent=2)+'\n')
        print('Verified ARM64 WOW64 dependency closure across',len(files),'binaries')
        break
    unavailable = sorted(set(missing)-set(targets))
    if unavailable:
        raise SystemExit('No configured ARM64 Wine target for missing providers: ' + json.dumps({n:missing[n] for n in unavailable}))
    selected = [targets[name] for name in sorted(missing)]
    print('Building missing ARM64 providers:', ', '.join(sorted(missing)), flush=True)
    subprocess.run(['make','-C',str(build),'-j'+jobs,*selected], check=True)
    for name, target in zip(sorted(missing),selected):
        source = build/target
        output = farm/name
        temporary = output.with_name(output.name+'.tmp')
        shutil.copy2(source, temporary)
        subprocess.run([str(toolchain/'bin/aarch64-w64-mingw32-strip'),'--strip-debug',str(temporary)],check=True)
        temporary.replace(output)
        built.append({'name':name, 'sourceTarget':target,
                      'sha256':hashlib.sha256(output.read_bytes()).hexdigest(), 'requiredBy':missing[name]})
else:
    raise SystemExit('ARM64 dependency closure exceeded 16 expansion rounds')
PYCLOSURE
if [[ "${AVPPLAY_I386_BUILD_PHASE:-all}" == wow64-closure ]]; then
    echo 'Fresh ARM64 WOW64 helpers and complete static dependency closure built.'
    exit 0
fi
# Source archives have no .git metadata. Use the FEX revision pinned by the
# same upstream source tree's ARM64EC recipe instead of generating 0xHE,0xAD.
fex_hash="$(python3 - "$runtime_root/build/fex-arm64ec/build.sh" <<'PYHASH'
import re, sys
from pathlib import Path
hashes = set(re.findall(r'-DOVERRIDE_HASH=([0-9a-f]{40})\b', Path(sys.argv[1]).read_text()))
if len(hashes) != 1: raise SystemExit('Missing unambiguous pinned FEX revision')
print(hashes.pop())
PYHASH
)"
cmake -S "$runtime_root/FEX" -B "$runtime_root/FEX/build-wow64" -G Ninja -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_TOOLCHAIN_FILE="$runtime_root/FEX/Data/CMake/toolchain_mingw.cmake" \
    -DMINGW_TRIPLE=aarch64-w64-mingw32 -DFEX_IOS_HOST_BUILD=ON \
    -DCMAKE_C_FLAGS=-DFEX_IOS_HOST -DCMAKE_CXX_FLAGS=-DFEX_IOS_HOST -DCMAKE_ASM_FLAGS=-DFEX_IOS_HOST \
    -DENABLE_LTO=OFF -DENABLE_ASSERTIONS=OFF -DENABLE_JEMALLOC_GLIBC_ALLOC=OFF \
    -DBUILD_TESTING=OFF -DBUILD_FEXCONFIG=OFF -DTUNE_ARCH=generic -DTUNE_CPU=none \
    -DCMAKE_POLICY_VERSION_MINIMUM=3.5 -DOVERRIDE_VERSION="FEX-${fex_hash:0:7}" -DOVERRIDE_HASH="$fex_hash"
# Both scripts build their own architecture-specific trees; no working caches are reused.
bash "$runtime_root/build/fex-wow64/build.sh"
bash "$runtime_root/build/wine-i386/build.sh"
# The WOW64 translator uses the toolchain's native aarch64 C++ runtime.
for name in libc++.dll libunwind.dll; do
    cp "$AVPPLAY_LLVM_MINGW_ROOT/aarch64-w64-mingw32/bin/$name" "$runtime_root/app/Madeira/aarch64-windows/$name"
done
mkdir -p "$runtime_root/app/Madeira/legal"
cp "$AVPPLAY_LLVM_MINGW_ROOT/LICENSE.TXT" "$runtime_root/app/Madeira/legal/LLVM-MinGW-LICENSE.TXT"
# Keep authored smoke executables outside the packaged DLL farm.
fixture_dir="$runtime_root/build/i386-fixtures"
mkdir -p "$fixture_dir"
"$AVPPLAY_LLVM_MINGW_ROOT/bin/i686-w64-mingw32-clang" -O2 -g -nostdlib -Wl,--entry=_start \
    -o "$fixture_dir/hello-x86.exe" "$runtime_root/tests/x86/hello-x86.c" -lkernel32
python3 - "$runtime_root" "$repo_root" "$AVPPLAY_LLVM_MINGW_ROOT" <<'PY'
import hashlib, json, re, struct, subprocess, sys
from pathlib import Path
root, repo, toolchain = map(Path, sys.argv[1:])
farm = root / 'app/Madeira/i386-windows'
files = sorted(p for p in farm.iterdir() if p.is_file() and not p.name.startswith('.'))
required = {'ntdll.dll','kernel32.dll','kernelbase.dll','user32.dll','gdi32.dll','win32u.dll','apisetschema.dll','d3d11.dll','dxgi.dll','d3d10core.dll','winemetal.dll'}
names = {p.name.casefold() for p in files}
missing = sorted(required - names)
if missing: raise SystemExit('Missing required i386 files: ' + ', '.join(missing))
def machine(p):
    data = p.read_bytes()
    if len(data) < 64 or data[:2] != b'MZ': return None
    pe = struct.unpack_from('<I', data, 0x3c)[0]
    if pe + 6 > len(data) or data[pe:pe+4] != b'PE\0\0': return None
    return struct.unpack_from('<H', data, pe+4)[0]
def sha(p): return hashlib.sha256(p.read_bytes()).hexdigest()
imports_missing = []
for p in files:
    if p.suffix.casefold() == '.tlb': continue
    if machine(p) != 0x14c: raise SystemExit('Not i386 PE: ' + str(p))
    output = subprocess.run([str(toolchain/'bin/llvm-objdump'), '-p', str(p)], check=True, capture_output=True, text=True).stdout
    for name in re.findall(r'DLL Name:\s*(\S+)', output):
        if name.casefold().startswith(('api-ms-win-', 'ext-ms-win-')): continue
        if name.casefold() not in names: imports_missing.append([p.name, name])
if imports_missing: raise SystemExit('Missing i386 imports: ' + json.dumps(imports_missing))
for name in ('wow64.dll','wow64win.dll','xtajit.dll','ntdll.dll','libc++.dll','libunwind.dll'):
    p = root/'app/Madeira/aarch64-windows'/name
    if machine(p) != 0xaa64: raise SystemExit('Missing/wrong aarch64 WOW64 dependency: ' + str(p))
report = {'schemaVersion':1, 'status':'experimental-guest-components-built-not-device-tested',
          'requiresMatchingLegacyNativeArchive':True, 'runtimeSource':str(root),
          'wineI386FileCount':len(files), 'missingImports':imports_missing,
          'resourcesSha256':{p.name:sha(p) for p in files},
          'wow64Sha256':{name:sha(root/'app/Madeira/aarch64-windows'/name) for name in ('wow64.dll','wow64win.dll','xtajit.dll','ntdll.dll','libc++.dll','libunwind.dll')},
          'fixtureSha256':sha(root/'build/i386-fixtures/hello-x86.exe'),
          'buildScriptSha256':sha(repo/'windows-vr-tools/build_wine_i386_resources.sh'),
          'sourceProvenanceSha256':sha(root/'AVPPLAY_SOURCE_PROVENANCE.json')}
(root/'build/i386-resources-experimental.json').write_text(json.dumps(report, indent=2)+'\n')
print('Built i386 Wine/DXMT farm and aarch64 FEX WOW64 translator; validated PE architectures/import closure. Device execution remains untested.')
PY
