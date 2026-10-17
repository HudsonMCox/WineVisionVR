# Depth-fed stereo and temporal reconstruction validation

The subsequent [Metal frame synthesis implementation](windows-vr-frame-synthesis.md) adds OpenVR depth forwarding and an experimental colour-only stereo-depth/optical-flow backend. The shadow-validation path described below remains separate; it is not the selectable display backend.

The first reconstruction stage is implemented as an opt-in validation path. It carries explicitly submitted scene depth through the D3D11 translation layer, reconstructs views on Metal, maintains owned frame history and measures the results against original images. Normal stereo output remains on screen. Resolution, game simulation rate and game eye rendering are unchanged.

## Use

In the launcher's advanced options, open **Rendering experiments** and enable **Validate depth reconstruction**, then start a fresh game session. The switch adds GPU work and applies when a new immersive renderer is created. Reconstruction diagnostics are written to `Documents/launcher-log.txt` even when the general diagnostics switch is off.

A game must enable and submit `XR_KHR_composition_layer_depth` for this capture path. The D3D11 runtime supports D32_FLOAT depth swapchains, array slices, subrectangles, independent color/depth resolutions, asymmetric frusta, reversed depth and infinite near/far planes. Each frame carries its exact ID, timestamp, target generation, eye transforms, projection and depth range. The selected released depth image is checked alongside the color image.

Ordinary OpenVR color submissions through the current OpenComposite implementation do not provide this scene-depth metadata. Such runs continue through the existing rendering path and report `missingDepth`; enabling validation does not create depth or enable YORO for those games. D3D12 accepts the optional composition-depth hint while retaining its color submission path; D3D12 depth capture is not enabled by this implementation. Unreconstructable tracking and rejected native capture preserve the normal color frame.

## Ownership and compatibility

An optional D3D11 Ext4 interface carries depth without changing the published Ext2/Ext3 vtables. A separately versioned 464-byte fixed-width record uses the existing Winemetal carrier and installed source dispatch hook. Existing Unix-call slots, counts and legacy frame records are unchanged. Color and depth resources share the frame's completion ticket. Pending submissions retain all four native Metal textures through commit; acquired leases then own their corresponding depth metadata until the consuming GPU command buffer completes. Queue drops and legacy submissions cannot inherit old depth metadata.

D3D11, DXGI, D3D12 and D3D10 core are rebuilt together because they share internal DXMT context layouts. Their public exports are unchanged. Color-only submissions do not perform null-depth retain calls across the Wine/native boundary. The native Wine/JIT core and its executable text are preserved. Source preparation applies `0024-dxmt-explicit-scene-depth.patch` and copies the matching shared headers.

## Reconstruction and history

The Metal implementation uses deterministic forward projection. A first pass chooses the nearest target-view depth, a second chooses a stable source pixel for equal-depth collisions, and a gather pass produces the reconstructed color and validity. The nearest-depth comparison uses target-view distance, so reversed window-space depth does not reverse visibility. Uncovered pixels have zero validity; this stage does not invent hidden detail or fill holes.

Two owned snapshots of source eye 0 retain logical color, depth, camera metadata and frame identity. Snapshot copies execute on the same command queue as reconstruction, so later reuse of a guest image does not overwrite history. Queue changes, generation changes, repeated/backward frame identity, gaps over 100 ms and missing depth invalidate history. GPU diagnostic results are epoch-tagged so old callbacks cannot republish metrics after invalidation.

Stereo validation reconstructs eye 1 from eye 0. Temporal validation reconstructs the current source-eye view from the prior owned source-eye snapshot. Both use real depth. Temporal validation currently models camera motion; moving objects and virtual-world motion need reliable game motion vectors. The log explicitly reports `motionVectors=unavailable` and `generatedDisplayFrames=0`.

Validation samples every 30 acquired depth frames by default; history is maintained for every acquired depth frame while validation is enabled. Coverage reports the fraction reconstructed, and MSE measures color error only over valid pixels. Coverage and error must be assessed together. The debug output API exposes the last sample for GPU readback, with validity in alpha.

## Foveation and next gates

Reconstruction consumes the logical color/depth images after translated foveated rendering has resolved them. Existing SDK-provided eye maps, foveation shaders, shading rates and layered presentation are unchanged. No raw gaze data is inferred. This stage measures compatibility with that path; it does not yet choose a combined high-quality source region for both eyes.

Second-eye scene-render suppression, disocclusion patching, motion-vector-driven frame generation and synthesized display frames remain disabled. The next gates are reliable depth provision for the actual target games, stereo quality near hands and edges, per-eye high-quality-region coverage, motion-vector provenance/units/jitter, and headset GPU cost. These determine whether suppressing real rendering work is worthwhile.

The installed visionOS SDK declares `MTLFXFrameInterpolatorDescriptor` unavailable on visionOS in `MetalFX.framework/Headers/MTLFXFrameInterpolator.h`. Therefore this build uses custom Metal validation and does not link or claim a working MetalFX frame interpolator for the headset.

## Validation

Run `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer bash windows-vr-tools/test_reconstruction.sh` on the Metal-capable development Mac. The pending-resource probe uses the prepared DXMT overlay; set `WVR_DXMT_SOURCE` if it is in a different location. The script never launches Wine or a game. The exact embedded shader also compiles separately to AIR against the visionOS 27 SDK.

The real Metal probe traverses the installed carrier hook, submits color and depth, acquires a real lease and checks stereo/temporal output pixels. It covers sRGB, array slices and subrectangles, independent depth resolution, deterministic disocclusion holes, owned history after game image reuse, malformed/stale metadata, a long-gap reset and missing-depth fallback. Its synthetic shifted-plane case has 96.875% coverage with zero error over covered pixels; this is a controlled correctness result, not game image quality.

Production OpenXR EndFrame probes cover exact frame/eye identities, image release rules, regions, disabled extensions, malformed ranges/chains, tracking-loss fallback, reversed/infinite projections and D3D12 color preservation. The production pending submission method and actual WMT reference template are exercised under UBSan/bounds to check four-texture ownership across transfer, rejection and completion. Existing frame waits, controller contracts, CPU/GPU presentation/transfer tests and the real Metal foveation suite pass.

The signed visionOS build, packaged binary identities, source hashes and local evidence are recorded in [the validation record](windows-vr-reconstruction-validation.json). No game has been launched, no app installed, and no headset FPS, latency, actual-game depth availability or visual quality is established in this pass.
