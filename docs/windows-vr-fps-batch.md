# FPS batch — October 15, 2026

This batch implements 17 changes across the shared compositor, native bridge,
and D3D11 query path. Eye resolution stays at 1888×1792. It preserves the working
native JIT/compiler framework, the BONEWORKS logger repair, query/encoder fixes,
and owned stereo snapshots. These are source-confirmed reductions in work;
their combined effect on game FPS requires a user headset run.

| # | Change | Cost removed or bounded |
|---|---|---|
| 1 | Per-frame autorelease pool in the long-running render task | Temporary Objective-C/Metal objects retire each iteration, even when the task does not suspend. |
| 2 | Stack head/eye/projection/FOV publication buffer | Growing arrays, matrix-to-array intermediates, and nested heap-buffer marshalling each refresh. |
| 3 | Stack controller matrix publication | Two controller pose arrays per refresh, plus unavailable-state arrays. |
| 4 | Packed ABI matrix loads | Temporary Float arrays when decoding imported C matrix tuples. |
| 5 | Snapshot-owned guest eye transforms | Two guest eye inversions are computed for each fresh image instead of every repeated display refresh. |
| 6 | Per-eye projection cache and reuse | Unchanged projection inversions and repeated compositor projection queries for tracking, depth, and reprojection. Capture retains its own projection. |
| 7 | Presentation pipeline prewarming | First-use compilation of 2D/array BGRA8-sRGB/depth32 pipelines inside the timed rendering loop. Other formats retain keyed lazy creation. |
| 8 | Persistent transfer-failure state | Per-transfer status-object and NSLock allocation. A failure from an earlier in-flight copy also remains observable. |
| 9 | Direct snapshot collection reuse | Repeated local collection retain/assignment; replacements are reserved and published only after successful copy encoding. GPU copies remain. |
| 10 | Lazy, rate-limited bridge trace formatting | String formatting for calls that tracing has already disabled or rate-limited. The bounded trace remains available. |
| 11 | Fixed six-ticket completion window | Per-frame tree-node allocations and redundant Metal consumer-event writes when contiguous progress has not advanced. Backpressure remains six tickets. |
| 12 | Bounded tracking-history lookup | Scanning unused pose slots and scanning beyond the first exact timestamp match. Approximate-match tolerance and original tie order remain. |
| 13 | Fixed GPU timing slots | Per-command unordered-map node allocation/free, with the same 4096-record bound and overflow reporting. |
| 14 | GPU timing report formatting outside the statistics lock | Commit/completion callbacks no longer wait for report string formatting; counters and window retirement are snapshotted under the lock. |
| 15 | Constant presentation depth in vertex output | Per-fragment explicit depth export. The same finite reverse-Z plane is rasterized. |
| 16 | Timewarp matrix multiply in the fullscreen vertex shader | Matrix multiply at every output pixel. Interpolated homogeneous coordinates retain the per-pixel perspective divide, source bounds, filtering, opacity, crop, and eye slice. |
| 17 | Confirmed completed D3D11 event results | Native shared-event reads on repeated successful GetData calls. Pending polls still read the exact GPU event on every call; reissue invalidates completion. |

The first six changes concern repeated display work. Changes 15–16 reduce the
full-resolution presentation pass; they do not reduce game rendering resolution
or introduce generated frames. Changes 10–14 reduce bridge/diagnostic overhead.
Some are small bookkeeping improvements; none individually promises a target FPS.

A related correctness fix makes the presentation loop use the drawable's actual
view count. Monocular capture previously entered a two-eye loop despite having
only one target. Capture still reads owned snapshots and never acquires another
guest frame or publishes headset targets.

## Verification

`windows-vr-tools/test_fps_batch.py` runs synthetic CPU and actual Mac Metal GPU
checks without starting Wine or a game. Set `DEVELOPER_DIR` to full Xcode, then
run the script from the repository. It records logs and results under
`.build-fps-batch/checks` by default. Its baseline shader is extracted from commit
`adfdf25`; `--baseline-renderer` accepts an explicit saved source instead.

- 18,000 cached eye reprojections match the previous matrix formula. Tests cover
  asymmetric/changing projections, head rotation/translation and packed C-style
  Float tuples.
- Ticket retirement covers all 720 six-ticket completion permutations, duplicate
  completions, the uint64 boundary and 100,000 sequential completions under
  Address/Undefined Behavior Sanitizers. A static assertion ties the bridge's
  submission bound to the fixed window's capacity.
- Actual old/new production shaders produce identical color and depth for 4,096
  tested pixels across 2D/array eyes and eight cases: crop/scale, zero/nonzero
  depth, translated and projective timewarp, rotation, negative homogeneous w,
  and out-of-view sampling. This is a correctness test, not a GPU benchmark.
- Production bridge checks cover generations, queue drops, pause/restart,
  incomplete producer frames, missing tracking and original render-pose retention.
- An ownership probe overwrites the guest texture while presentation is delayed;
  the owned stereo copy retains the original colors, slices and crop.
- GPU timing checks use eight concurrent queues and 256 additional submissions,
  verify unchanged GPU output and complete counts, and retire windows once.
- The production D3D11 GetData harness makes 250,000 pending polls with 250,000
  exact GPU reads and one flush request. After observed completion, 10,000
  repeated successful reads require zero additional GPU reads. Reissue, the
  existing DONOTFLUSH threshold and timestamp-disjoint output still pass.
- Existing exact-event-order, query-publication, readback and encoder-boundary
  checks pass, including query publication under ThreadSanitizer.

The installed visionOS 27 simulator also runs the production shader and native
bridge probes. It is additional synthetic coverage; neither simulator nor host
GPU tests establish headset frame rate. Build, installation and artifact hashes
are recorded in [the validation record](windows-vr-fps-batch-validation.json).

## Remaining performance evidence

The last user Moss: Book II log predates this batch and the preceding flush
coalescing repair. It showed approximately 20.6–29.1 fresh transfers/s in selected
sustained windows while the display presented at roughly 90 Hz through cached
rotational reprojection. Those values are not a post-change result.

Pending-event polling still crosses the native Metal bridge. The batch caches
only a positive completion already observed for that query issue. It never waits
for whole-command-buffer retirement, synthesizes query results, or skips pending
GPU progress reads. A remaining busy GPU wait must be separated from simulation
CPU cost before attributing the frame budget to game code.

Test the same Moss scene/settings with JIT for 60–90 seconds, including a heavy
moment, then try BONEWORKS in a fresh session. Compare fresh-transfer FPS and p95
intervals, CPU encode time, guest/snapshot/presentation queue delay and GPU time,
and memory/thermal progression. Keep first-run shader compilation separate from
sustained gameplay. No game was launched by the agent, no post-batch game FPS
has been measured, and 120 FPS remains an unproven target.
