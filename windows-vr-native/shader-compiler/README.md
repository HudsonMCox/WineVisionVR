# Native AIR writer integration

This component uses the patched, locked DXMT `MetallibWriter` and LLVM 15 to
re-emit generated libraries at the Metal library-loading boundary. The original
native Wine/JIT framework remains unchanged. The guest FEX DLL's lifecycle
repair is built separately from source. This avoids applying
instruction or container-byte patches to that runtime.

Build visionOS LLVM libraries from the locked LLVM revision with tests disabled,
then invoke `windows-vr-tools/build_air_writer.sh` with:

- `AVPPLAY_AIR_DXMT_SOURCE`: DXMT source with patches 0002–0009 applied.
- `AVPPLAY_AIR_LLVM_SOURCE`: locked LLVM source checkout.
- `AVPPLAY_AIR_LLVM_BUILD`: visionOS 27 LLVM build directory.
- `AVPPLAY_AIR_PLATFORM_HEADER`: `wvr_metallib_platform.h`, generated from the
  actual xros compiler reference and SDK version.

The default output is `dist/windows-vr-air-writer-foveation`; choose a fresh
`AVPPLAY_AIR_OUTPUT` for another build. The prebuilt XcodeGen project links the
archive, enables `WVR_SOURCE_AIR_WRITER`, and restricts NativeBridge exports so
its compiler implementation cannot replace symbols in the original runtime.
It also requires an unmodified copy of the working runtime framework in
`dist/windows-vr-preserved-runtime/WindowsRuntimePlugin.framework`.

The adapter only handles the known single-module, xros DXMT container and
`airconv_generated.metal` modules. It verifies IR, sets the AIR minimum target
to xros 2.0 (separate from the app's visionOS 27 target), replaces the existing
SDK flag, and uses the corrected writer for versions, wrapping, hashes and
sizes. LLVM's CFG simplification merges legal common instructions across
branches before backend compilation. This removes duplicated discard branches
and their coverage-mask PHIs without removing discard behavior or disabling
optimization. The same cleanup is part of the source DXMT profile. It uses no
game names or shader hashes. Invalid generated libraries fail with an error;
unrelated libraries pass through.

All eight captured M2 render pipelines compile offline after this cleanup,
using both captured shader stages and the complete pipeline descriptors. An
additional diagnostic that changed only the first failing shader's duplicated
discard diamond also compiled. These checks establish compilation, not visible
game frames or performance. On-device execution is left to the user.

The foveation adapter also remaps D3D11 fragment positions through the system
rate-map decoder and binds identity maps on uniform passes. It is enabled only
after the matching native transport installs. D3D12 root-signature shaders are
excluded, and an existing fragment buffer 28 is a hard collision. See
`docs/windows-vr-guest-foveation.md` for the complete contract, coverage limits
and real Metal tests. The source transform is `WindowsVRAIRFoveation.h`.
