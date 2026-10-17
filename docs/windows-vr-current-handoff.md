# Current implementation handoff

Snapshot prepared 2026-10-16 for continued development. Target: Vision Pro M2, visionOS 27; M5 later. The resolution goal is 70% of native total pixel count, not 70% of each dimension.

## Included work

This checkpoint includes the accumulated CPU/translation and synchronization changes, FEX cache/native-dispatch patches, frame-state transport, DXMT batching/query-progress patches, ARM64EC guest packaging, foveation integration, explicit depth transport, reconstruction, and experimental Metal frame extrapolation. Dependency edits are represented by the checked-in patches and build scripts; ignored dependency checkouts are not the deliverable.

Start with [frame synthesis](windows-vr-frame-synthesis.md), [reconstruction](windows-vr-reconstruction.md), [translation reduction](windows-vr-translation-reduction.md), [CPU overhead](windows-vr-cpu-overhead.md), and [performance next steps](windows-vr-performance-next.md).

## Latest validation and device status

The latest Release visionOS app build succeeded and the app passed `codesign --verify --deep --strict` outside the sandbox. A prior sandbox check reported CSSMERR_TP_NOT_TRUSTED; the subsequent unsandboxed verification passed. Production runtime bundle validation passed. Native synthetic GPU probes passed for reconstruction/extrapolation, head-motion separation, depth projection, foveation, and frame-transfer ownership. The frame-transfer probe ran on macOS; the simulator attempt could not run because no simulator was booted. These are not game benchmarks.

The latest checkpoint has NOT been installed or tested in a game on the headset. Device Hub and both Xcode command-line device inventories no longer list the Vision Pro. A Mac appears on the headset's Remote Devices screen, but reconnection has not been established. The user requested a GitHub checkpoint and intends to restore device/JIT pairing later. Do not claim an installation, measured FPS improvement, game stability, or headset image quality for these changes.

Existing validation JSON files describe their individual historical stages; their artifact hashes are not automatically current after later edits. `windows-vr-frame-synthesis-validation.json` records the latest local evidence and source hashes for the synthesis pass. Its local log paths are evidence locations, not tracked files or portable build inputs.

## Rendering status and limitations

Advanced → Rendering experiments → Image reconstruction selects Standard (default), Metal spatial reconstruction, or Metal reconstruction + frame extrapolation. Recreate the immersive renderer for a changed selection. Source render scale is unchanged. Existing foveation remains in place.

The new backend uses frame-matched explicit scene depth when supplied, otherwise confidence-gated low-resolution stereo depth estimation. Predicted headset movement is separated from optical-flow object motion; unreliable forecasts fall back. It uses custom Metal algorithms: it does NOT include NVIDIA DLSS, NVIDIA weights, a trained neural reconstruction/FG model, or supported visionOS MetalFX temporal interpolation. Both eyes are still game-rendered. The system compositor's final depth attachment remains the distant fallback plane, despite depth-aware software reprojection. Output history/storage adds meaningful memory and GPU costs; headset profiling is required before enabling it by default or claiming a gain. 90 real game FPS is a goal, not an established result.

Explicit OpenVR depth conversion was cross-built for x64 and ARM64EC. Embedded guest HLSL conversion shaders still require execution validation; native Metal tests do not establish that those guest shaders work in games. See the synthesis document for unsupported projection/depth cases and fallback behavior.

## Continue safely

The user intends further source development without game testing for now. Do not launch a game or represent static/synthetic checks as headset validation. Keep correctness fallbacks, exact frame/depth ownership, and head-pose coordinate handling intact when optimizing. Before physical validation, reconnect the headset, restore StikDebug pairing/JIT as necessary, build/sign with the local account, install, and ask the user to reproduce gameplay.

Generated Xcode projects, compiled apps/DLL staging, downloaded dependencies/toolchains, Wine prefixes, game content, and signing/pairing credentials remain excluded according to the existing ignore rules. Regenerate and stage through the repository build tools; do not commit local credentials or ignored caches. Local dependency/toolchain paths may need updating on another machine. The latest local app was built from `visionos-windows-vr/VisionOSWindowsVRPrebuilt.xcodeproj`, scheme `VisionOSWindowsVR`, Release, generic/platform=visionOS. Refer to the build scripts and patch manifests for dependency preparation.
