# Translation performance follow-up

This pass preserves the current render resolution. Validation uses compile-only Windows targets, native Mac CPU tests and actual Metal GPU probes. No game was launched and no new headset FPS was measured.

## Implemented

- DXMT negotiates a borrowed, process-lifetime identity-map buffer once through the existing capability request. Uniform passes bind it through the ordinary Winemetal command list. Five base buffer binds, optional stream output and the identity map share one dispatch instead of five to seven. Legacy companions retain operation 3 fallback. Small render targets still receive their identity binding: skipping it would break transformed `SV_Position` shaders.
- The lazy GPU-progress registration retry now puts the shared event in `colorTexture`, matching the native contract, and validates page alignment and token like initial registration. The earlier retry used `commandBuffer`, so it could never succeed on the native handler.
- FEX launch defaults are applied in the app before Wine starts, including when linking the preserved runtime framework. Explicit environment/manifest overrides remain usable. Multiblock and silent logging are already upstream defaults. `MAXINST=512` is a tunable compilation-size candidate, not a measured optimum or loop-unrolling option.
- Persistent FEX machine-code caching is implemented and enabled by default. Patch `0004-fex-persistent-code-cache.patch` connects Windows image loading to cache registration and section activation. The native offline compiler generates translations in a separate process before the game starts. Cached code is copied into the dual-mapped executable pool, relocated through its writable alias, instruction-cache flushed, and only then published to the dispatcher. Serialization operates on a private snapshot rather than modifying live generated code.
- Cache format 3 checks bounds, version, payload checksum and a hash of the complete source PE. The scheduler regenerates stale files even if PE metadata has not changed. Cache directories are separated by translator/compiler binary hashes, host model and OS; resolved FEX options supply a per-executable configuration ID. Stable game mounts let recorded paths resolve on the next launch. Existing cache directories migrate without deleting their contents.
- Windows uses complete eager cache activation; `FEX_ENABLELAZYCODECACHINGWIP=0` selects that implementation. This flag is unrelated to background disk writes. Expensive instruction-by-instruction cache validation remains optional; file/source/identity validation is mandatory. An explicit `FEX_ENABLECODECACHINGWIP=0` process override retains the ordinary JIT path.
- LLVM-MinGW ARM64EC toolchain support and separate architecture build roots are added to the OpenVR/OpenXR build recipes. An experimental OpenComposite DLL and matching OpenXR DLL compiled successfully. The ARM64EC validator checks CHPE metadata rather than trusting the AMD64 header that hybrid images retain; it rejects architecture substitution in both directions.

The app now selects its source-built `WindowsVRLaunchAdapter.framework` through the signed `WVRRuntimePluginFramework` bundle setting. The adapter links the preserved Wine/FEX framework rather than relinking or replacing its JIT implementation. It chooses the bundled ARM64EC pair for x64 games, validates both DLL architectures and receipt hashes, and uses the same selection for direct launch and Steam's persistent OpenVR/OpenXR registry entries. The x64 pair remains available through a process-start `WVR_GUEST_RUNTIME_ARCH=x64` override. Invalid or incomplete native packages fail validation rather than silently changing architectures.

Both native DLLs are now packaged under `WindowsVR/Guest/arm64ec`. The assembler builds both architectures and creates the native pair receipt. Bundle verification checks that receipt as well as the usual shared graphics closure. Source builds use the source runtime plugin; prebuilt builds use the separately compiled adapter. They share the same launch implementation and profile selection.

This completes the mixed-architecture launch implementation, not its headset compatibility validation. No game was launched by the agent and no native-runtime FPS comparison has been measured.

## Reproducing ARM64EC builds

Set `LLVM_MINGW_ROOT` to the extracted LLVM-MinGW bundle. Use a distinct build directory for each architecture.

```sh
cmake -S windows-vr-openvr -B build/openvr-hybrid -G Ninja \
  -DWINDOWS_VR_USE_LLVM_MINGW=ON -DWINDOWS_VR_BUILD_ARM64EC=ON \
  -DWINDOWS_VR_ENABLE_D3D12=ON -DLLVM_MINGW_ROOT="$LLVM_MINGW_ROOT"
cmake --build build/openvr-hybrid --target package_opencomposite

cmake -S windows-vr-openxr -B build/openxr-arm64ec -G Ninja \
  -DCMAKE_TOOLCHAIN_FILE="$PWD/windows-vr-openxr/cmake/toolchains/llvm-mingw-arm64ec.cmake" \
  -DLLVM_MINGW_ROOT="$LLVM_MINGW_ROOT" -DCMAKE_BUILD_TYPE=Release
cmake --build build/openxr-arm64ec
```

These individual recipes stage separate files. The complete assembler packages both architectures, the matching FEX compiler and native launch helper; the app selects the ARM64EC runtime by default. They do not install an app.

## Validation

- Production batch-list setup executed with the actual Winemetal wire structures under ASan/UBSan: one dispatch, bounded seven-command capacity, terminated links, correct uniform/foveated/legacy and stream-output combinations.
- One million production pending query reads cause zero native calls; exact progress publication and native fallback remain intact. The test also checks the lazy-registration request contract.
- Real Metal foveation suite passes the identity-buffer capability handshake, stereo atlas, array slices, changing maps, color/alpha, depth, stencil, MRT, sRGB, stale/unsafe rejection and layered presentation checks.
- CPU/GPU compositor and frame-transfer regressions and 4096-pixel baseline comparison pass.
- Translation environment defaults and explicit overrides are exercised by `TranslationEnvironmentTests.swift`.
- D3D11 and DXGI rebuild with unchanged exports. Their package hashes and receipts are updated; the production package validator accepts the new closure and rejects stale hashes and missing DLLs.
- Both experimental ARM64EC DLLs compile with static C++ runtime linkage. Architecture checks reject using them as the x64 profile.

Local logs and artifact hashes are recorded under `.build-performance-next/`. New headset measurements are still needed to establish fresh game FPS, frame pacing and whether uniform bridge calls disappear. Display refresh/reprojection FPS must remain distinct from newly rendered game FPS. A global 80% StikDebug CPU threshold is not established by this validation, and helper CPU must be attributed separately from game-process CPU.

## Integrated launch checks

`windows-runtime-plugin/Tests/test_guest_package.py` executes the actual native selection and validation functions on real compiled DLLs, including valid ARM64EC, explicit x64, invalid override, stale hashes, wrong architecture and missing receipt. `visionos-windows-vr/Tests/Contracts/test_vr_registration.py` executes the real Swift registry and DLL mapping implementation for both architectures and repeated installation. A signed visionOS 27 build includes the adapter and native guest pair. Fifteen packaging unit tests also pass.

## Persistent cache operation

The packaged `WindowsVRCacheLauncher.exe` runs `FEXOfflineCompiler64.exe process-all`, waits for it to exit, then launches the original executable with correctly quoted arguments and returns its exit status. Compiler startup failure uses ordinary JIT execution. Compilation has a two-minute budget and finishes or terminates before gameplay so it cannot contend with the game for the shared JIT pool. Completed files are published with atomic replacement. Recording a first session supplies block maps; subsequent launches compile/reuse those recorded blocks. The first run is not a warm-cache benchmark, and generating newly recorded blocks can increase the next launch's loading time.

`windows-vr-tools/stage_fex_cache.py` builds the native launcher, stages the compiler and binds both to the packaged translator with a receipt. The app and build verifier check actual architectures and matching hashes. Source assembly builds the compiler from the same patched FEX tree as `xtajit64.dll`. The preserved native Wine/JIT framework remains unchanged; the guest FEX translator DLL is rebuilt.

`windows-runtime-plugin/Tests/test_fex_cache.py` executes the production bounds/checksum parser and source invalidation code, rejecting all truncated prefixes and single-byte payload corruptions of its fixture. The production codemap writer/parser also preserves cold/warm executable metadata and 1,000 dependencies across buffer flushes. Recorded NT paths are normalized for the compiler's Win32 file APIs. Windows argument tests include empty arguments, spaces, quotes, trailing backslashes and Unicode. These checks pass with UBSan/bounds. Apple's AddressSanitizer runtime deadlocked inside its own initializer before `main` on this Mac; this pass does not claim an ASan result. The production app validator also accepts the matching cache package and rejects a mismatched translator receipt or wrong helper architecture. The tracked patch applies to the pinned source and reproduces every modified build input.

The signed visionOS 27 app builds with caching enabled, and all 15 existing packaging tests pass. No game was launched or app installed in this pass. Actual cache hits, cache compiler operation under headset Wine, game compatibility and fresh-frame FPS still require headset validation; compilation and parser tests do not establish those results.
