# Performance, foveation and DLSS compatibility plan

The subsequent [Metal frame synthesis implementation](windows-vr-frame-synthesis.md) adds OpenVR depth forwarding and an experimental colour-only stereo-depth/optical-flow backend. The shadow-validation path described below remains separate; it is not the selectable display backend.

Target: Vision Pro M2, visionOS 27; M5 is a later hardware target. This is a development plan, not a claim that temporal reconstruction, foveation or frame generation is implemented or physically validated.

## Current evidence and changes

The latest Moss run stops at 806 submitted guest frames. The GPU observer reports 5,494 completed guest/application command buffers, no failures and no pending observed buffers. The render thread continues polling D3D11 GetData. The moving portion of the run is about 27 game FPS; the separate display loop and rotational reprojection are not additional game frames. A long process-wide pause is excluded from that measurement. The FEX alias cache microbenchmark improved substantially, but the headset run did not establish a game FPS improvement.

This pass repairs unsynchronized timestamp/visibility query result publication in DXMT. The original production helpers produce Thread Sanitizer race reports; the repaired helpers pass the same test with real results and chunk boundaries. This is a confirmed code defect, not yet proof of the Moss freeze's cause. Exponentially spaced GetData warnings identify the pending query type, pointer, poll count, flags and event completion sequence if the freeze persists. No GPU result is synthesized or query disabled.

The compositor now clears and draws each eye in one pass. It previously stored cleared color/depth attachments and loaded them in a second pass. This removes two empty render passes per normal stereo presentation and their attachment store/load traffic. Shared attachments retain preceding eyes. Physical FPS and GPU-time improvements remain unmeasured.

BONEWORKS's Unity log reports OpenVR error 110, PathRegistryNotFound. Prefix preparation now writes the user's openvrpaths.vrpath pointing to the stable bundled OpenComposite runtime, alongside the existing OpenXR registry registration. It refreshes app-container symlinks after reinstalls and preserves external-driver/config/log entries. [Valve's registry implementation](https://github.com/ValveSoftware/openvr/blob/master/src/vrcore/vrpathregistry_public.cpp) defines this discovery mechanism. This repair needs another physical BONEWORKS startup attempt; later failures may remain.

## 1. Reliability and measured FPS

First reproduce the Moss progression point and BONEWORKS startup with the installed repair. Collect query warnings, guest frame counts, GPU completions/errors and thread samples. If a query remains pending, trace that specific query's End, encoder issuance, command completion and readback publication. Repair the missing transition rather than forcing success. Recheck menu press/release and pause/resume; check haptic start, replacement and stop on each controller.

Then compare three equal-duration runs in the same scene, with identical guest resolution, game settings and thermal conditions. Record actual guest FPS, median and p95 frame intervals, CPU hot threads and frame-correlated GPU timestamps. Mean duration of individual command buffers cannot be summed into GPU frame time because buffers overlap. Keep loading, headset suspension and frozen intervals separate.

Optimize the measured limiting stage: FEX hot paths and synchronization for CPU limits; pipeline/encoder transitions, resource copies and submission batching for GPU/driver limits. Batching must preserve query flushing, resource hazards and producer-ready events. Preserve the owned stereo snapshot that prevents the game from modifying a displayed image. Avoid resolution changes while attributing the effect of these repairs.

## 2. SDK foveation of the presentation pass

Use Compositor Services' supportsFoveation, supportedLayouts with foveation options, and the drawable's current rasterizationRateMaps. Apple supplies maps only with foveation enabled. The render pass consumes the map corresponding to the actual attachment/eye layout. [Apple's capability documentation](https://developer.apple.com/documentation/compositorservices/layerrenderer/capabilities/supportsfoveation) and [drawable maps](https://developer.apple.com/documentation/compositorservices/layerrenderer/drawable/rasterizationratemaps) describe the contract.

Keep guest eye textures uniformly sampled initially. Distinguish logical screen/view dimensions from the map's physical texture dimensions. Apply the rate map to drawing, preserve crop/slice coordinates, reprojection, opaque alpha and valid depth. Do not infer guest target size from the foveated physical allocation. Use per-frame system maps without requiring raw gaze data or introducing the remote-streaming entitlement. ALVR's local Renderer.swift is a reference for attaching maps to presentation passes.

Validate with a stereo grid, eye/crop/viewport changes, head movement and peripheral inspection, then the same game scene. Guard supported layouts and quality settings. The earlier render-quality override caused an unsupported-configuration abort with foveation disabled; do not repeat it.

This reduces presentation shading/bandwidth. It does **not** retroactively reduce the game's uniformly rendered pixels or its translated CPU work.

## 3. Foveation inside guest rendering

A larger GPU gain requires a DXMT integration for identifiable per-eye render targets, with variable-rate rendering before expensive scene shading. Establish eye/resource identity and frame ownership at OpenXR/OpenComposite swapchain submission; arbitrary offscreen textures are not automatically eye targets.

Translate compatible passes to Metal rate maps while preserving logical dimensions, depth, sampling, derivatives, MSAA and shader resource coordinates. Audit subsequent compute and postprocessing passes that assume uniform rasterization. Expand/resolve compressed results where those passes require it. Start with a supported stereo scene and conservative fixed foveation, then evaluate how system-provided maps can be safely associated with guest rendering timing. A title/pass that cannot meet the coordinate contract keeps uniform rendering. Validate visual quality and query correctness before enabling a game profile.

## 4. DLSS calls to a Metal reconstruction backend

[CodeWeavers documents DLSS powered by MetalFX](https://support.codeweavers.com/en_US/advanced-settings-in-crossover-mac-26), active when the game enables DLSS and uses D3DMetal or DXMT. It is an API-compatibility route, not execution of NVIDIA's proprietary model, and it is not a feature supplied to every game automatically.

The installed XROS SDK headers explicitly mark MTLFXTemporalScaler and MTLFXFrameInterpolator unavailable on visionOS. MetalFX spatial scaling is available. A GPU capability table or an M5 upgrade does not override this platform restriction. Retain existing fail-closed temporal support checks in windows-vr-ngx; never advertise support and then return empty output.

The existing NGX overlay is a scaffold for an older pinned DXMT compatibility ABI, not a universal official NGX implementation. Before enabling a title, verify its actual export signatures, parameter ABI and graphics API; add a supported visionOS temporal backend, with documented licensing, rather than copying a macOS-only framework.

For each supported evaluation, unwrap the real color, depth, motion-vector and output resources through DXMT. Translate jitter, exposure, motion-vector scale/direction, render/output sizes, reset and camera-cut semantics. Maintain separate histories for each eye and reset on resource recreation, recentering or discontinuities. Our current constant presentation depth cannot substitute for scene depth. OpenXR color-only submission does not provide motion vectors; these inputs must come from the game's reconstruction call or an explicit engine integration.

Games without DLSS can use spatial upscaling after rendering, or a separate temporal integration if their scene data is available. Spatial scaling can improve presentation quality; it improves game FPS only when the game renders fewer pixels and its bottleneck is GPU work. It cannot fix translation costs, query stalls or missing inputs.

## 5. Frame generation last

MetalFX frame interpolation is also unavailable in the installed visionOS SDK. A future supported implementation must consume real scene motion/depth and handle independent eye histories, HUDs, disocclusion and display-time pose. Keep generated-frame count separate from real simulation FPS. Compare latency and stereo stability against the already functioning rotational reprojection; increased displayed-frame count alone is insufficient. Do not enable frame generation before stable real frames and head/controller timing.

## Acceptance

- Moss crosses the reproducible freeze point repeatedly; BONEWORKS initializes VR and reaches gameplay.
- Game-required menu actions press and release correctly. OS-reserved Home controls remain system controls.
- Vibration is isolated per hand, respects duration, replaces previous pulses, stops promptly and recovers after interruption/reconnection.
- Any claimed FPS gain comes from equal-setting physical runs, with frame-time and latency results.
- Foveation preserves stereo pose, color/depth, sampling and stable guest swapchain dimensions.
- Unsupported temporal/NGX/FG requests report unsupported before use. No universal-game compatibility claim.
