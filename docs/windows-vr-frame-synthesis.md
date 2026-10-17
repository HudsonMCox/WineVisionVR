# Metal reconstruction, depth provision and frame extrapolation

This is an experimental native Metal backend for Vision Pro M2 / visionOS 27. It is integrated into the production renderer, not a standalone image demo. It does not run NVIDIA DLSS, contain NVIDIA trained weights, or implement a learned super-resolution/frame-generation network. The existing NGX overlay remains separate and disabled on visionOS; this work does not change its incompatible parameter ABI or advertise unsupported MetalFX temporal APIs.

## Enable

Open **Advanced → Rendering experiments → Image reconstruction** and select:

- **Standard** (default): existing presentation and head-pose reprojection.
- **Metal spatial reconstruction**: bilinear spatial reconstruction with bounded local contrast enhancement. Depth estimation and optical flow are bypassed.
- **Metal reconstruction + frame extrapolation**: scene depth or stereo depth estimation, motion estimation, confidence-gated history reuse, and bounded object extrapolation on refreshes without a new game frame.

The choice applies when creating a new immersive renderer. The older shadow-validation option runs only in Standard mode, avoiding two reconstruction workloads at once. The render-scale setting is unchanged. Output can match larger compositor logical target dimensions, but no additional source detail is created by the spatial filter. This is not learned temporal super-resolution. Both original game eyes are still rendered, and foveated presentation remains active. Generated display jobs are distinct from real game/simulation frames.

## Research used

The implementation adopts bounded temporal reuse, depth-aware reprojection, hierarchical optical-flow search and explicit occlusion rejection. It is an engineering adaptation, not a reproduction of a paper's complete algorithm or benchmark:

- [HQEMU (2012)](https://www.iis.sinica.edu.tw/papers/dyhong/18239-F.pdf): hot-path overhead matters. Existing FEX multiblock/native dispatch/cache work remains; this pass avoids per-frame image allocations and duplicate full-resolution copies in the new native path. It does not add an unvalidated trace compiler or alter x86 memory ordering.
- [YORO (2025)](https://arxiv.org/abs/2506.15183): stereo geometry can reuse image information. Stereo matching now supplies estimated depth when explicit depth is unavailable. Second-eye game-render suppression is not enabled.
- [Weighted reservoir foveation (2025)](https://arxiv.org/html/2510.03964v1): useful high-quality history should not be discarded blindly. This backend reprojects and confidence-blends clamped history. It is not the paper's reservoir sampler and does not change the system's foveal region.
- [PatchEX (2025 publication)](https://doi.org/10.1145/3759247): extrapolation avoids waiting for a future real frame. The backend extrapolates estimated object motion, retaining the original image wherever evidence fails. It does not implement PatchEX's learned inpainting/shadow model or fabricate disoccluded geometry.
- [NVIDIA DLSS research](https://research.nvidia.com/labs/adlr/DLSS4/): separate colour/depth/motion/history provision from reconstruction and frame synthesis. Those data roles inform the backend; NVIDIA's transformer architecture, trained weights and execution kernels are not included. A real learned replacement still requires a portable trained model, integration and measured M2 quality/runtime costs. A compatibility DLL cannot supply that missing model.

## Depth sources

OpenComposite now enables `XR_KHR_composition_layer_depth` when available and handles OpenVR `Submit_TextureWithDepth`, including the combined pose/depth structure. It preserves the supplied perspective projection, normalized depth range, per-eye array slice and atlas rectangle. Finite, reversed and infinite depth conventions are decoded without sorting near/far. Atlas bounds select an image rectangle, not a narrower eye projection. Pose submissions compose the submitted head transform with the eye offset.

Single-sample 32-bit depth takes a copy path. D16, D24/stencil, D32/stencil and multisampled depth use a cached intermediate and deferred-context conversion to D32, restoring the immediate context's graphics state. Optional unsupported/malformed depth leaves colour available. Inverted/oblique depth submissions are not forwarded. Conversion shaders are compiled on first use in the guest; the Mac tests do not establish their execution on the headset. The incremental patch is `windows-vr-openvr/patches/0008-openvr-scene-depth.patch`, applied by both build variants.

The native backend consumes explicit, frame-matched depth when the acquired lease provides it. For ordinary colour-only submissions, it performs a 32-plane inverse-depth search at at most 192 pixels wide per eye, followed by local refinement and reciprocal depth checks. Search covers approximately 0.15–50 metres. Textureless, ambiguous and occluded pixels are invalid, rather than invented depths. These are estimates with limited accuracy, especially on transparent/reflected/repetitive surfaces. This fallback works downstream of either D3D11 or D3D12 colour submission and does not require identifying arbitrary engine depth buffers.

## Motion, ownership and scheduling

Two owned stereo snapshots supply three-level image pyramids. Bidirectional patch matching estimates backward motion after removing camera motion where trustworthy depth exists. Low-resolution Jacobians warp comparison patches and convert vectors between previous/current eye axes and between eyes. This matters during head roll: residual motion is stored in current-eye normalized UV, not reused in the previous image’s axes. Without depth, that path is accepted only for an effectively unchanged camera. Forward/backward and binocular motion checks reject inconsistent forecasts. History colour is clamped to the current local range before a small confidence-weighted blend.

The renderer samples the SDK-predicted display anchor immediately before synthesis and supplies that same anchor to Compositor Services. A small per-eye mapping pass applies rotation and, where depth is confident and the intersection converges, positional parallax. The full-resolution stage samples this map instead of solving depth intersections at every output pixel. Its output is already in the display pose, so the presenter skips its older rotational head warp. Missing/unstable depth retains rotational mapping. The final system depth attachment remains the existing distant fallback plane; this does not yet supply a full scene-depth attachment for the system’s last pose correction.

Fresh game frames use spatial/history reconstruction. Missing-frame refreshes may extrapolate object motion by at most one real-frame interval; tracked head motion is handled separately from estimated object motion. Prediction is shortened for low confidence and changes in object velocity. A gap over 100 ms falls back to ordinary cached presentation. There is no arbitrary prediction of game physics or simulation advancement. UI is not provided as a separate mask by colour-only games, and stereo/temporal edge artifacts still require physical validation.

The code reuses history, pyramids, depth, flow and three output slots. A busy output pool returns immediately and uses normal presentation. The native snapshots also supply the renderer's fallback cache, eliminating its second full-resolution stereo copy. All work is encoded on the presentation command queue; there is no full-frame CPU readback or GPU completion wait in the runtime hot path. Matrix setup is shared across pyramid levels and texture bindings are batched. Queue, target generation, nonmonotonic frame/time and tracking changes reset history. Completion handlers retain shared state instead of dereferencing a destroyed context.

Additional memory scales with two source histories and three stereo RGBA16F output pairs. At 1888×1792 outputs, output storage alone is approximately 155 MiB; this must be considered alongside game memory. The default stays Standard pending headset validation.

## Validation

Run:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer bash windows-vr-tools/test_frame_synthesis.sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer bash windows-vr-tools/test_reconstruction.sh
```

The new production Metal probe checks a known stereo plane, rejection of textureless depth, precedence of true submitted depth, nonzero object extrapolation in the correct direction, tracked-head parallax in the correct direction, suppression of false object motion from head-only movement, object-vector coordinates under head roll, output scaling, the spatial-only mode, stale/queue fallback and destruction with GPU work pending. The actual OpenVR projection decoder runs under UBSan/bounds. The exact embedded shaders compile to AIR for visionOS 27. The existing real Metal stereo/temporal/array/sRGB tests and production depth transport/ownership checks remain applicable.

These tests use synthetic scenes. They establish neither visual quality in Moss/BONEWORKS nor 90 real FPS, headset latency, guest shader-conversion execution or a working neural model. `synthesis` logs report real ingested frames, explicit versus estimated depth frames, generated display jobs, tracked-pose display jobs, pool fallbacks and GPU failures. Asynchronous reductions sample usable depth/motion coverage, with the exact `coverageFrameID`; a frame counted as estimated does not imply valid depth everywhere. `commandBufferGPUms` covers the entire command buffer, not isolated reconstruction cost.
