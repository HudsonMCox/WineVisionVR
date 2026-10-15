# Performance target and current evidence — October 14, 2026

## Target

User target: 80–90 FPS, with at least 80 FPS in heavy moments, at approximately 70% of Vision Pro native resolution. Keep real guest simulation/render FPS, generated frames, and compositor presentation FPS separate. A real 90 FPS frame budget is 11.11 ms; 80 FPS is 12.5 ms. Generated presentation at 80–90 FPS still requires a stable underlying frame rate and acceptable input latency. No generated frames are implemented or counted as game frames.

The exact 70% resolution metric is pending clarification: 70% width/height implies 49% of the reference pixel count; 70% pixel count implies approximately 83.7% width/height. Reference dimensions must be recorded explicitly. A compositor eye viewport is not automatically the physical panel's native resolution, especially with foveation. Current Moss eye images are 1888×1792 each (6,766,592 pixels for both eyes), matching the current uniform compositor view dimensions. Do not label that as 70% panel resolution.

## Successful Moss baseline

The user confirms that the exact second-page transition now works after patch 0013's VR encoder-boundary repair. Preserve that lifecycle and synchronization contract.

The captured tail of the successful run has 13–22 fresh transfers per second, with the native display presenting around 88–90 times per second. Earlier game activity produces more frames; this tail alone must not represent every scene. Overall 823 process-CPU samples report median 643%, p95 845%, maximum 1147%. These aggregate counters are not evidence that the game simulation alone consumes that CPU time. Selected hot-thread snapshots put most samples in a game query-polling caller and its ARM64EC backend/bridge path. The polling frequently waits on genuine GPU completion.

GPU statistics previously reported cumulative mean durations per command buffer: guest around 7.7 ms, snapshot around 2.35 ms, presentation around 3.4 ms late in the run. Do not sum guest-buffer means into GPU frame time or treat them as GPU utilization: buffers overlap, multiple buffers belong to a frame, and shared-device contention affects their lifetimes. Stable headset presentation is rotational reprojection of real cached frames, not 90 FPS simulation or scene-motion frame generation.

Evidence: `/private/tmp/avpplay-moss-success-guest.log`, `/private/tmp/avpplay-working-moss-launcher.log`.

## First measured optimization candidate

Patch 0014 replaces native Metal shared-event reads in each D3D11 event-query poll with a guest-local atomic completion fence. The ordered finish thread publishes the command chunk's event sequence only when Metal reports that buffer completed. It is conservative: an event inside a chunk can become visible later than its GPU signal, but never earlier than actual completion. Failed or merely scheduled buffers do not publish progress. Occlusion and timestamp result publication remain unchanged. No sleep, artificial success, fabricated query value, title-specific condition, skipped wait, or lock bypass is added.

The production-fence regression verifies pending/failed retirement, real completion publication, monotonic ordered progress and visibility of associated results across threads. The production visibility-query regression also passes. Physical CPU/FPS benefit is pending comparison in the same Moss scene; removing bridge calls does not by itself prove a rendering bottleneck is fixed.

## Instrumentation for the next decision

The native Metal observer now reports recent-window execution time and commit-to-GPU-start queue delay for guest, presentation and snapshot work, retaining original cumulative counters. All timestamp differences use the host mach absolute-time domain used by Metal GPU timestamps. Window counts retire once. A synthetic simulator GPU test validates stage classification, unchanged GPU output, finite/nonnegative queue delays and window reset.

The compositor reports median and p95 fresh-transfer intervals separately from display refresh and mean CPU encode time. This measures arrival pacing, not game simulation CPU time. Loading, scene changes, headset suspension and menu time need separate interpretation.

## Next optimization sequence

1. Compare patch 0014 with the recorded baseline at identical resolution, game scene/settings and similar thermal conditions. Read event polling CPU cost, frame-interval p95, guest work submission cadence and GPU queue delays.
2. If GPU work arrives late with the GPU available, sample the specific translated game/backend threads and optimize their dominant calls, synchronization or data conversions. The current evidence does not justify rewriting broad translation subsystems or concluding an unavoidable CPU ceiling.
3. If work remains queued on a busy GPU, reduce measured rendering/transfer/presentation work. Add SDK foveation first to correctly mapped compositor passes, preserving uniform guest source images, then investigate identifiable guest eye passes and compatible postprocessing. Presentation foveation alone does not reduce guest scene shading.
4. Set a precisely defined resolution target and compare its pixel cost. Avoid raising resolution during the CPU A/B comparison. Spatial reconstruction is available; the current installed visionOS SDK does not expose MetalFX temporal scaling or frame interpolation. A separate supported temporal backend requires real per-eye scene depth, motion vectors, jitter and reset state.
5. Consider scene-motion frame generation only after a stable real-frame baseline and those inputs exist. Current constant presentation depth and rotational reprojection cannot provide occlusion-correct game motion interpolation. Record real/generated/presented rates independently and compare input latency.

Neither 80–90 real FPS nor frame generation is achieved by this pass. No universal-game FPS guarantee is made.

The signed optimization/diagnostic build passed and was installed successfully (`/private/tmp/avpplay-cpu-cache-app-build.log`, `/private/tmp/avpplay-cpu-cache-install.json`). The production event fence, existing visibility-query publication, VR encoder-boundary contracts, real package validator and synthetic simulator Metal observer checks passed. Current eye resolution and existing profile settings are preserved for the physical comparison.

## BONEWORKS status

The direct initialization file records first logging calls with phase zero and a null stream vtable, without either stream-construction marker or process-attach marker. This narrows the failure to DLL startup/global initialization or inconsistent object storage; it is not a reason to bypass the logger. The next DLL uses a forwarding entry wrapper that records notification entry and return before/after the original CRT startup, preserving every argument and return value. No manual constructor calls or BONEWORKS workaround are introduced. Its startup fault remains unresolved pending that trace.

Evidence: `/private/tmp/avpplay-boneworks-init.txt`, `/private/tmp/avpplay-working-moss-current.log`.
