# Performance target and current evidence — October 15, 2026

## Target

Latest user target: work toward **90 real FPS without changing resolution**, superseding the earlier 120 FPS research target. The frame budget is **11.11 ms**. This is not an achieved or guaranteed rate. Continue pacing delivery to the actual compositor and distinguish CPU translation, GPU work and display cadence. The October 16 translation pass is documented in [the translation reduction report](windows-vr-translation-reduction.md).

Keep real guest simulation/render FPS, generated frames, and compositor presentation FPS separate. No generated frames are implemented or counted as game frames. Existing physical captures below concern **Moss**, not an established Moss 2 baseline. Headset pairing has been restored. The new build still needs a physical Moss 2 run to establish performance, thermal stability and frame-time percentiles.

The user clarified that the target is 70% total pixel count, equivalent to approximately 83.7% width/height for an unchanged aspect ratio. Reference dimensions must be recorded explicitly. A compositor eye viewport is not automatically the physical panel's native resolution, especially with foveation. Current Moss eye images are 1888×1792 each (6,766,592 pixels for both eyes), matching the current uniform compositor view dimensions. Do not label that as 70% panel resolution.

## Successful Moss baseline

The user confirms that the exact second-page transition now works after patch 0013's VR encoder-boundary repair. Preserve that lifecycle and synchronization contract.

The captured tail of the successful run has 13–22 fresh transfers per second, with the native display presenting around 88–90 times per second. Earlier game activity produces more frames; this tail alone must not represent every scene. Overall 823 process-CPU samples report median 643%, p95 845%, maximum 1147%. These aggregate counters are not evidence that the game simulation alone consumes that CPU time. Selected hot-thread snapshots put most samples in a game query-polling caller and its ARM64EC backend/bridge path. The polling frequently waits on genuine GPU completion.

GPU statistics previously reported cumulative mean durations per command buffer: guest around 7.7 ms, snapshot around 2.35 ms, presentation around 3.4 ms late in the run. Do not sum guest-buffer means into GPU frame time or treat them as GPU utilization: buffers overlap, multiple buffers belong to a frame, and shared-device contention affects their lifetimes. Stable headset presentation is rotational reprojection of real cached frames, not 90 FPS simulation or scene-motion frame generation.

Evidence: `/private/tmp/avpplay-moss-success-guest.log`, `/private/tmp/avpplay-working-moss-launcher.log`.

## Retired completion-cache optimization

The whole-command-chunk completion cache introduced as patch 0014 was removed after the immersive-exit report. It did not preserve event progress semantics. An event can signal before a later command in the same buffer waits for work that depends on the game observing that event. Requiring whole-buffer retirement can then prevent the game from advancing. Numerical conservatism (never reporting an event early) was insufficient to establish liveness. The earlier cache test did not exercise this ordering case.

The production path again checks the actual Metal shared-event value. A replacement production-query regression verifies that an issued event becomes signaled while its containing chunk remains pending, and that the next event remains pending until its own signal. Any future polling cache must publish exact GPU signal progress independently of later commands or chunk retirement. No claim of CPU/FPS benefit is retained for the removed design.

The immersive closure was recorded at 18:07:29 with the app/runtime still active. A separate Wine `NtPowerInformation` fault at approximately 18:07:38 passes null to `CFNumberGetValue`; its later timestamp does not prove it caused the earlier closure. Lifecycle logs now persist renderer pause, invalidation and task cancellation. Physical resolution of the closure remains to be verified after installation.

## Instrumentation for the next decision

The native Metal observer now reports recent-window execution time and commit-to-GPU-start queue delay for guest, presentation and snapshot work, retaining original cumulative counters. All timestamp differences use the host mach absolute-time domain used by Metal GPU timestamps. Window counts retire once. A synthetic simulator GPU test validates stage classification, unchanged GPU output, finite/nonnegative queue delays and window reset.

The compositor reports median and p95 fresh-transfer intervals separately from display refresh and mean CPU encode time. This measures arrival pacing, not game simulation CPU time. Loading, scene changes, headset suspension and menu time need separate interpretation.

## Next optimization sequence

1. Restore stable immersive rendering with exact event progress and repeat the same scene/settings. Read lifecycle transitions, event polling CPU cost, frame-interval p95, submission cadence and GPU queue delays before attempting another cache.
2. If GPU work arrives late with the GPU available, sample the specific translated game/backend threads and optimize their dominant calls, synchronization or data conversions. The current evidence does not justify rewriting broad translation subsystems or concluding an unavoidable CPU ceiling.
3. If work remains queued on a busy GPU, reduce measured rendering/transfer/presentation work. Add SDK foveation first to correctly mapped compositor passes, preserving uniform guest source images, then investigate identifiable guest eye passes and compatible postprocessing. Presentation foveation alone does not reduce guest scene shading.
4. Set a precisely defined resolution target and compare its pixel cost. Avoid raising resolution during the CPU A/B comparison. Spatial reconstruction is available; the current installed visionOS SDK does not expose MetalFX temporal scaling or frame interpolation. A separate supported temporal backend requires real per-eye scene depth, motion vectors, jitter and reset state.
5. Consider scene-motion frame generation only after a stable real-frame baseline and those inputs exist. Current constant presentation depth and rotational reprojection cannot provide occlusion-correct game motion interpolation. Record real/generated/presented rates independently and compare input latency.

Neither the previous 80–90 real FPS goal, the new 120 FPS goal, nor frame generation is achieved by this pass. No universal-game FPS guarantee is made.

The signed optimization/diagnostic build passed and was installed successfully (`/private/tmp/avpplay-cpu-cache-app-build.log`, `/private/tmp/avpplay-cpu-cache-install.json`). The production event fence, existing visibility-query publication, VR encoder-boundary contracts, real package validator and synthetic simulator Metal observer checks passed. Current eye resolution and existing profile settings are preserved for the physical comparison.

## BONEWORKS status

The direct initialization file records first logging calls with phase zero and a null stream vtable, without either stream-construction marker or process-attach marker. This narrows the failure to DLL startup/global initialization or inconsistent object storage; it is not a reason to bypass the logger. The next DLL uses a forwarding entry wrapper that records notification entry and return before/after the original CRT startup, preserving every argument and return value. No manual constructor calls or BONEWORKS workaround are introduced. Its startup fault remains unresolved pending that trace.

Evidence: `/private/tmp/avpplay-boneworks-init.txt`, `/private/tmp/avpplay-working-moss-current.log`.

## Distribution feasibility

Apple's [App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/) allow PC emulator game downloads (4.7), but require permission for exposing native platform capabilities to hosted software (4.7.2), alongside public API and executable-code rules (2.5.1/2.5.2). Emulator eligibility is not permission for debugger-enabled JIT. Our current StikDebug-dependent executable-memory setup is not an App Store distribution design. [Apple's platform security documentation](https://support.apple.com/guide/security/app-code-signing-process-sec7c917bf14/web) describes visionOS code-signing and executable-memory restrictions. A supported non-JIT runtime or an explicitly authorized Apple capability would need separate investigation. A paid developer account alone does not provide that capability. A streaming-client edition has a clearer potential review route under 4.2.7; approval is not guaranteed. Checked October 14, 2026.

## Event-ordering restoration build

The defective cache patch and its insufficient regression were removed. Exact-signal ordering, VR encoder boundaries, existing query publication and bundle validation pass. A signed generic visionOS build of **WineVision VR** succeeds (`/private/tmp/avpplay-immersive-repair-app-build.log`). Installation retry failed with CoreDevice error 4016: the headset is paired but unavailable, with no trusted remote developer-service connectivity. The new build has **not** been installed or physically verified (`/private/tmp/avpplay-exact-event-restoration-install.json`). Reconnect the existing device through Xcode Device Hub to finish deployment. No pairing reset or user settings change was made by the agent.

## Query efficiency pass while pairing is unavailable

Patch `0015-dxmt-query-readback-efficiency.patch` removes two source-confirmed costs without changing render dimensions, sample counts, query answers, GPU event reads or encoder boundaries:

- Completed occlusion/predicate/timestamp queries previously allocated and discarded a result object on every successful read, even after their result was cached. Allocate the next object only on the transition to completed. Subsequent reads reuse the cached scalar; the next issue still gets a fresh result object. In-flight old results retain their reference-counted ownership.
- Occlusion readback previously performed a sequentially consistent atomic read-modify-write for every sample. Sum the immutable samples locally and publish one atomic contribution before publishing the chunk's completion sequence. Keep the existing atomic ordering, empty-tail barriers and unsigned overflow behavior.

The production-method harness checks initial results, pending results, repeated completed reads, predicates, reissue, discarded in-flight queries, deferred queries, old-result ownership, multi-chunk publication, crop offsets, empty tails and overflow. It uses production `Rc` and query methods, with device/COM plumbing and logging stubbed. It is a CPU test, not a game or Metal GPU benchmark.

An Apple Clang 21 arm64 host A/B run reduced allocations for 10,000 cached reads from 10,000 to zero for each query type. The deliberately sample-heavy 256 × 65,536 readback benchmark took 89.911 ms before and 2.617 ms after (about 34× for **this summation workload only**). Actual benefit depends on how many samples/reads a game uses; this is not an FPS multiplier. Thread Sanitizer and Address/Undefined Behavior Sanitizer checks pass when run with full Xcode selected using `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`. The default command-line-tools sanitizer runtime failed even on a trivial startup probe; it was not counted as a pass. The full production `d3d11_query.cpp` also passes a visionOS SDK syntax check with the native compatibility headers; this is not an ARM64EC DLL build.

The patch is registered in the profile assembler. On October 15 the pinned LLVM-MinGW archive was verified, Wine import libraries were rebuilt from the clean pinned Wine source, and the production ARM64EC D3D11 target was compiled and Wine-builtin postprocessed. Its 351 normalized import/export entries match the previous DLL. The working native JIT framework and other graphics DLLs are preserved; no native LLVM compiler target was rebuilt. The actual DLL hash is recorded as an explicit integration override in both guest and graphics-package receipts, preserving the original full-build receipts. See [recorded checks](windows-vr-query-efficiency-validation.json) and [build inputs](windows-vr-query-efficiency-build.json).

Next work should follow the restored physical measurements, in this order:

1. Establish a separate Moss 2 baseline at unchanged eye dimensions, scene, settings and thermal state. Record fresh submissions and p50/p95/p99 frame intervals, CPU samples, guest/snapshot/presentation queue delays and GPU times. Averages alone cannot demonstrate consistent 120 FPS.
2. Separate guest simulation, translated calls, encoding, query waiting and GPU execution. Optimize the dominant measured path; a thread burning CPU polling a GPU fence is not proof of CPU-bound simulation. Preserve exact event progress rather than retrying the retired whole-buffer cache.
3. Measure upload/copy traffic and producer image reuse. Eliminate redundant transfers only through explicit resource ownership and GPU fences, preserving cached-frame reprojection and image contents. Never remove the snapshot copy while allowing its game-owned source to be overwritten.
4. Attribute shader compilation/pipeline creation spikes separately from sustained rendering. Evaluate cache/prewarm changes against first-run and warmed runs without weakening shader validation.
5. Revisit foveation or temporal reconstruction only once timings identify the GPU bottleneck and required per-eye inputs exist. Keep them separate from this unchanged-resolution CPU optimization comparison.

## October 15 delivery from WineVisionVR

Development now uses `HudsonMCox/WineVisionVR`; the old `avp-play` checkout is retained as a local dependency cache. Restored StikDebug pairing authenticates and connects its tunnel; the developer disk image is mounted. No pairing credentials are repository inputs.

The October 15 host comparison reports 87.832 ms before and 3.426 ms after for the same synthetic sample-heavy workload. Cached-read allocations remain 10,000 to zero per query type. Sanitized results are correctness checks and are not compared as timing benchmarks. These numbers do not establish a game FPS improvement. Resolution, GPU query answers, exact event reads and the encoder-boundary repair remain unchanged.

Headset validation: enable JIT, run the same Moss scene for 60–90 seconds, including the second-page transition, then close the app. Record which title was used (Moss or Moss 2). Compare fresh-frame intervals and guest/presentation/snapshot GPU queue times with the same resolution and settings; distinguish first-run shader compilation from sustained rendering. Actual frame rate, audio stability and immersive-space lifetime remain unverified until that run.

The signed Debug and optimized Release app builds pass. The Release app passes strict recursive signature verification and was installed successfully on the paired M2 headset running visionOS 27.2. The installed D3D11 SHA-256 matches the recorded ARM64EC build. Build output lives outside cloud-synced Documents because Finder metadata there prevented signing. No game was launched by the agent; headset FPS and stability validation remain pending.

## Shared frame-path batch — October 15

The follow-up [17-change FPS batch](windows-vr-fps-batch.md) reduces compositor
allocation/matrix work, native bridge and diagnostic bookkeeping, presentation
shader work, and repeated completed-event reads. It preserves 1888×1792 eye
resolution and exact pending GPU progress. The BONEWORKS startup logger repair
from commit `adfdf25` remains included. See the batch's validation record for
actual checks and installation status; no post-batch headset FPS is claimed.
