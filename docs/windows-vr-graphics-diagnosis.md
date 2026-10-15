# Vision Pro graphics investigation

Motion/controller update (2026-10-13): the depth repair was confirmed visible
by the user. The following run showed about 27 submitted game frames per second
and continuously updating tracked head positions. The compositor had been
redrawing cached colors at the latest anchor without retaining the render pose,
which makes the image follow the display instead of reprojecting the game view.

The new build retains bounded historical tracking metadata on each frame lease,
locks OpenXR view location to the matching wait/begin snapshot, and rotationally
reprojects every new or cached image into the current eye projection. An
unfinished guest GPU frame remains queued; it cannot insert a long event wait on
the display command queue. PNG/color readbacks now require `WVRFrameCapture`;
ordinary diagnostic logging remains available.

Controller discovery covers both visionOS 27 spatial accessories and legacy
spatial GCController devices, updates when devices connect/disconnect, and polls
complete current input snapshots so held buttons do not disappear on frames with
no new transition. The app declares controller user interaction. Physical input
and motion remain to be verified on the headset; the simulator tests cover
ready-frame scheduling, immutable pose retention and shader reprojection. See
[the motion/controller validation receipt](windows-vr-motion-controller-validation.json).

Rotational reprojection does not raise the Windows game's actual render rate.
Scene-dependent translation still needs fresh game frames or guest composition
depth; no 90 FPS game performance or synthetic six-degree-of-freedom reconstruction
is claimed.


Latest update (2026-10-13, late device run): game frames now reach the final
compositor color texture. The 22:13 capture shows the game UI; diagnostics report
matching eye targets, opaque output alpha and thousands of tracked device anchors.
Earlier statements below about no submitted frames describe earlier builds.

The remaining presentation pass wrote no content depth and cleared every depth
texture to zero after writing game color. The repair binds each eye's matching
color/depth target and writes opaque color with a projection-derived finite-plane
reverse-Z depth in one pass. It also predicts the device anchor at presentation
time, separately from controller anchor time. This follows the color/depth
presentation contract described in [Apple's WWDC session](https://developer.apple.com/videos/play/wwdc2024/10092/).

The actual production shaders passed simulator GPU checks for ordinary and array
sources, crop/scaling, zero-alpha input, and stored depth. A negative control
produced valid RGB with zero depth, showing why the color PNG alone does not prove
valid display presentation. See [the test receipt](windows-vr-presentation-depth.json).
The signed build was installed; visible headset output still requires user
verification. Per-pixel guest scene depth remains a separate extension; this pass
uses an explicit finite focal plane for the current color-only stereo stream.


Target: Vision Pro M2, visionOS 27. Updated 2026-10-13.

## Latest startup regression and linkage correction

The run beginning at 15:52:55 uses the new app bundle and launches Steam's
`dockhost.exe`; it does not reach Moss. StikDebug verifies the 640 MiB JIT arena
successfully. FEX `ProcessInit` returns success, but `ThreadInit` faults before
publishing an emulated thread state. The native PC and fault address are zero;
the caller is `libc++.dll+0xcad00`, an ARM64EC exit thunk. Its indirect branch
loads a null dispatch target. Wine exits this pseudo-process with `0xc0000005`.
There are no OpenXR negotiation, frame, shader-failure or audio-underrun events
in this run. Their absence does not verify the graphics repair: startup stops
before those subsystems run.

The rebuilt FEX module had changed from the working module's static C++ runtime
to shared libc++. Export/import name validation did not verify cross-image
ARM64EC dispatch after relocation. The build preparation now explicitly links
`libc++.a`, `libc++abi.a` and `libunwind.a` together, retaining the source lifecycle
repair. The earlier static recipe omitted libc++abi; the complete static
library set links successfully. The new DLL imports only
ntdll/ucrtbase, preserves every previously packaged FEX export, and resolves all
imports against the packaged DLLs. Headset execution remains user-verified.

## General source correction (2026-10-13)

The per-shader `optnone` experiment was rejected and removed. The current
source helper finishes CFG simplification with common-instruction hoisting and
sinking enabled, using the locked LLVM implementation and its legality checks.
The same final cleanup is in the modern DXMT source profile (patch 0009).
It preserves normal Metal backend optimization, resource bindings, discard
operations and coverage-mask values; it has no game-name or shader-hash cases.

For the first reproducible offline crash, both sides of a branch called
`air.discard_fragment`, then joined at a coverage-mask PHI. A diagnostic changing
only that diamond to one discard operation plus a selection compiled, while the
original failed. This isolates a sufficient trigger for that captured failure;
it does not identify the proprietary compiler's precise internal defect.
Full common-instruction cleanup through the shared source helper compiled all
**eight** captured pipelines, including both captured shader stages and their
complete original pipeline descriptors, for `applegpu_g14g`. Earlier standard
CFG cleanup lacked those optional common-instruction transformations. Neither
changing clip-distance encoding nor adding the shader convergence attribute
resolved the first failure. The clip-distance correlation was not causal proof.

[Compilation receipts](windows-vr-cfg-compilation.json) record the captured and
re-emitted library hashes. All verification was offline compilation; the agent
executed no shaders and launched no games. Captured game-derived inputs remain
local, outside source-distribution artifacts.

The new prebuilt app specification excludes the game-specific binary archive.
Its source AIR adapter performs the correction before ordinary Metal pipeline
compilation. An on-device game run must establish whether the headset compiler
accepts the generated pipelines and whether frames reach the compositor; offline
success does not establish visible rendering, FPS or corrected audio.

The separate FEX lifecycle patch stops context-dependent callbacks before
process/context teardown. Its atomic state outlives both the callback-disabling
destructor and all context owners, avoiding reads from destroyed lifetime state.
The rebuilt guest DLL retains every packaged FEX export; every imported symbol
was checked against the packaged DLLs, and libc++/libunwind match the ARM64EC
compiler toolchain. Execution of this repair remains unverified.

OpenXR negotiation now validates structure versions/sizes and both ends of the
supported interface/API range. It records the negotiated callback address and
logs invalid function-lookup arguments before returning a validation failure.
The last game log stopped at negotiation; it contained no instance/session/frame
trace, so that remaining startup boundary is not yet explained.

The signed build targets visionOS 27. The native Wine/JIT framework and its JIT
script are preserved; the guest FEX DLL and OpenXR DLL are source-built updates.

## Earlier exact-pipeline archive experiment


The source-writer run captured both libraries and the complete descriptor for
the first failing pipeline: vertex `vs_33f64be7_206fda3da6543c1366a428e0448d5f7306973096`
and fragment `ps_31dc7ebb_09294cb027c6533290aba4a0ddbac736ab3dd05e`.
It uses four samples, RG11B10Float color and Depth32Float_Stencil8 depth/stencil.
The captured module already has the corrected xros target and SDK metadata.
The pipeline still failed on-device, but the exact captured inputs and settings
compiled successfully with the offline M2 compiler. No shaders were executed.

Apple's `metal-tt` then produced an `applegpu_g14g` binary archive. The launcher
loads that archive through MTLBinaryArchive and uses it only when shader input
hashes and the captured descriptor match. It requests
MTLPipelineOptionFailOnBinaryArchiveMiss, so this known failing pair cannot
silently re-enter runtime compilation when an archive lookup fails. Errors
request a session exit and remain visible to the launcher.

The generated archive and its local index live under the ignored `dist` tree;
they contain game-derived binaries and are not source-distribution artifacts.
This is coverage for one known pipeline, not proof that every game pipeline
or VR session works. The device compiler differs from the offline compiler;
the precise internal compiler defect has not been established.

The diagnostic now captures up to 16 distinct failed pipeline descriptors,
bounded to 16 MiB of exported data. The in-memory shader-input cache remains
bounded to 16 MiB. OpenXR also logs bounded function-lookup and extension-query
events to locate a separate failure between negotiation and instance creation.

Audio traces showed roughly 636 ms late wakes and buffer underruns during the
failure period. This supports starvation during graphics/debugger faults; it
does not establish that all audio failures share that cause.


## Earlier installed source writer

The installed update links a source-built AIR writer in WindowsVRNativeBridge.
`windows-vr-tools/build_air_writer.sh` builds the patched DXMT writer and the
adapter in `windows-vr-native/shader-compiler`, using the locked LLVM 15 source
compiled for visionOS 27. The adapter recognizes generated single-module DXMT
libraries, parses and verifies their IR, replaces the shader target and SDK
flag, then re-emits the library through the corrected source writer. It does
not change shader control flow. Unrelated libraries pass through unchanged;
invalid generated AIR produces an error instead of using a bad library.

The working JIT/Wine runtime is copied unchanged, rather than relinked or
further binary-patched. The embedded runtime's executable-section SHA-256 and
the bundled JIT script match the originals. An export list keeps the new LLVM
implementation private to NativeBridge, separate from the existing runtime's
compiler symbols. The signed app builds for visionOS 27 and was installed;
game execution and visible frames remain unverified by the agent.

This supersedes the earlier statement that installing the source corrections
requires a full JIT runtime rebuild. The shader-library loading boundary permits
an isolated source component. Findings below describe prior runs.

## Earlier no-video run

The 02:53 run reached `Moss2-Win64-Shipping.exe`. It logged seven failed render
pipeline compilations with `AGXMetalG14G` code 2, followed by GPU address faults
and rejected command buffers. The system GPU reports at 02:53:26 and 02:54:29
name WineVision VR and report BIF0 page faults/GPU reset reasons. These reports
establish GPU resets, not a confirmed full headset reboot or a screenshot bug.
The compiler crash again reached `llvm::PHINode::removeIncomingValue` in the
fragment compiler. The available OpenXR trace still stops at negotiation;
there are no logged instance, session, or frame submissions.

The diagnostics originally hooked only
`newRenderPipelineStateWithDescriptor:error:`, but the runtime actually calls
`newRenderPipelineStateWithDescriptor:options:reflection:error:`. Therefore the
first-failure export and exit request did not run. Both overloads are now covered
in the compiled diagnostic build, including the options used for compilation.
This correction is included in the installed source-writer update. Its operation
during game execution remains unverified.

All eight captured fragment shaders compile offline for `applegpu_g14g` after
source re-emission, with synthetic vertex interfaces matching their inputs.
The compiler produced no diagnostics for these cases. The results are recorded
in `windows-vr-fragment-compilation.json`. This narrows the failure to the actual
runtime inputs/pipeline/driver environment; it does not reproduce or validate
the game's full pipeline. The source-writer update installs the corrections
at library loading without replacing the working JIT runtime.

## Subsequent startup stall

The next user run (02:34 local time) did not reach graphics initialization or
produce a pipeline-failure capture. Wine started `dockhost.exe` and allocated
the native thread stack and FEX arena, but the trace did not proceed to loading
the guest ntdll. StikDebug confirmed the 640 MiB JIT pool was prepared. There
is no verified explanation for the intervening stall yet.

The log's Thumper identity came from a hardcoded Wine bridge fallback, not
evidence that Thumper was selected. `MadeiraDock.configure` now supplies the
required `MADEIRA_DOCK_SESSION=1`, and cleanup clears it. The launcher also
reconciles the selected game against the active manifest on every restoration;
an old in-memory selection cannot silently survive changing saved entries.

The installed helper's watchdog previously interrupted every script after 120
seconds, including an established Madeira JIT service. The helper patch in
`windows-vr-tools/patches/stikdebug` keeps that deadline for setup only. Verified
arena preparation is tracked per debug-proxy session; after setup, the service
continues until the script returns or the target exits. This fixes a lifecycle
defect, but does not establish the cause of the earlier startup stall. Both
updates compile and are signed; no game was launched by the agent.

## Observed failure

The headset's Metal compiler service crashes in its fragment optimizer
(`llvm::PHINode::removeIncomingValue`, reached through
`AGCModule<AGX::Impl::FragmentProgramKey>::compileLLVMObject`). The app then
continues processing graphics work without the required pipeline. The captured
run contains CPU and memory pressure and audio underruns. This supports a link
between the repeated graphics failures and lag, but does not rule out an
independent audio scheduling problem.

Earlier container errors (`unable to copy bitcode`) disappeared after correcting
the xros shader target and library wrapper. That repair did **not** resolve the
fragment compiler crash or produce visible game frames. The available OpenXR
trace records loader negotiation, but no instance/session/frame calls; there is
not yet evidence that this run reached VR frame submission.

## Source corrections

The locked DXMT source is `e94c312f5c054263acf261cfa109edf13e757587`, with LLVM
`8dfdcc7b7bf66834a761bd8de445840ef68e4d1a` (15.0.7). The preparation script
applies patches 0002 through 0008 in order.

- Patch 0003 uses the AIR shader minimum `air64-apple-xros2.0`. This is separate
  from the app's visionOS 27 deployment target.
- Patch 0007 derives AIR/Metal version tags from the module, wraps bitcode before
  calculating hashes and sizes, reports malformed metadata, and verifies the
  generated IR after optimization.
- Patch 0008 records the actual xros SDK version instead of the macOS SDK version.

The matching host LLVM tools were compiled with tests disabled. All 32 captured
modules passed structural IR verification, and the patched source writer
successfully re-emitted all 32 libraries. **These are compiler checks, not proof
of M2 GPU compilation, game execution, or correct pixels.** No speculative PHI
lowering transform is included.

The installed app still uses the prebuilt runtime with its existing JIT repairs.
It does not yet contain a full native runtime rebuild of patches 0007 and 0008.
Before replacing that runtime, its JIT changes must be represented in source;
absolute-address patches cannot be carried into a differently linked binary.

## Required next evidence

The launcher stores the first AGX compiler-service render failure in
`Documents/WindowsVR/CompilerFailures/<session UUID>/`:

- `render-pipeline.json`: function names, attachment formats and blending,
  sample count, buffer mutability, topology, vertex layouts, and other captured
  pipeline properties.
- `vertex.metallib` and `fragment.metallib`: the exact library inputs associated
  with the failed functions, when present in the bounded 16 MiB capture cache.

Capture success is explicit in the JSON; missing libraries must not be replaced
with guessed shaders. The cache is bounded and cleared after the first export.
The launcher requests a cooperative session exit on compiler-service failure.
This is diagnostic containment, not a graphics compatibility fix.

Use the complete bundle to produce an Apple `.mtlp-json` pipeline script and
compile with the installed Metal toolchain's `air-nt`, targeting
`applegpu_g14g` and xros 27. This compilation does not execute the game or GPU
shader. Reproduce the failure before changing control flow, and compare the
original capture with the source-corrected output.

`windows-vr-tools/reemit_captured_air.cpp` is the offline source-writer fixture.
Compile it together with the patched `src/airconv/metallib_writer.cpp`, using the
locked LLVM host libraries and generated `wvr_metallib_platform.h`. Its input is
the captured library's AIR bitcode section; it writes a corrected container
without changing shader control flow. `inspect_metallib.py` reports the section
offsets and lengths needed to extract that input.

Acceptance requires successful offline compilation of the failing pipeline,
failure handling that prevents invalid subsequent draw/dispatch commands, a
native rebuild preserving the JIT integration, and user-confirmed headset frames
and sustained audio. None of those remaining execution outcomes is claimed here.
