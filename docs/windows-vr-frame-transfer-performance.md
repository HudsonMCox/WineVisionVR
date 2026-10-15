# Frame transfer performance pass

## Evidence

The headset's available launcher log predates the query-repair install. Two moving five-second Moss intervals show 29.14 and 29.73 guest FPS. The following interval includes a freeze at frame 796; it is not a steady FPS sample. Presentation command buffers averaged about 2.4 ms cumulatively in that run. Individual guest buffer durations cannot be summed into frame time because scheduling and dependencies can overlap.

The submitted image is a packed 3776×1792 texture with two 1888×1792 eye rectangles. A stereo snapshot requires approximately 54.1 MB of logical read-plus-write traffic per new frame (about 51.6 MiB). That is an estimate from dimensions and format, not measured physical DRAM traffic. Compression/caching may change physical bandwidth. Copies happen once per new guest frame, not once per headset refresh.

## Change

Previously, the presentation command read the guest images, copied them into owned snapshots, encoded presentation and released the guest lease only on completion of the whole command buffer. The guest's next reuse of those images waited on that release fence.

Now a separate `wvr.snapshot` buffer copies the ready eye rectangles into owned textures first. Its completion releases the guest lease. A following `wvr.presentation` buffer samples only those owned textures. Both buffers use the same Metal queue and are committed in order after their callbacks are installed. This preserves snapshot read/write ordering across display frames while removing presentation from the guest-image reuse dependency. It creates an opportunity for guest rendering/encoding to proceed sooner; it does not guarantee simultaneous GPU execution.

The renderer retains array slices, eye crops, sRGB format, original render-time tracking and generation validation. A failed snapshot allocation uses the prior direct-presentation path with the lease held until the last guest read. Copy errors invalidate the snapshot through a locked status flag; completion callbacks do not mutate renderer arrays off their executor. Guest resolution and visual sampling quality are unchanged.

This adds one command-buffer submission per copied guest frame. A physical comparison must establish whether reduced reuse stalls outweigh that submission overhead on M2. It does not remove the snapshot copies or establish a fourfold gain. Removing copies requires an explicit producer image pool/ownership contract; retaining a single game-owned render texture across repeated display frames can otherwise stall reuse or produce corruption.

## Diagnostics

GPU statistics now distinguish guest/application work, owned snapshot transfers and presentation, so copies are not misreported as guest rendering. Five-second render logs report display FPS, transferred-frame rate, estimated logical snapshot read/write MiB/s and mean CPU encoding duration. Transferred-frame rate is not generated-frame FPS or proof of game simulation rate. GPU duration summaries remain cumulative; compare appropriate windows and record actual submitted guest frames.

## Validation

- Signed visionOS device build and both-architecture Wine bootstrap verification passed.
- Simulator test uses the production native bridge and real Metal queues/events. The display is deliberately held pending. The copy completes, the native consumer fence advances, and the producer overwrites both eye images. Readback confirms the guest image actually changed while display was pending, but the owned left/right images retain the original colors. Array slices and crop offsets are covered.
- GPU observer test verifies separate guest/snapshot/presentation counts and unchanged buffer contents.
- No headset game was launched by the agent. Headset FPS, latency and freeze recovery remain pending.

Run the same Moss scene at the same settings for at least 60 seconds of movement, including the previous progression point. Keep loading, suspension and freezes separate from steady performance. Inspect `render-performance`, `gpu-timing`, submitted-frame deltas and pending-query warnings together before selecting the next optimization.

Evidence: `/private/tmp/avpplay-performance-0.log`, `/private/tmp/avpplay-frame-transfer-test.log`, `/private/tmp/avpplay-transfer-gpu-statistics-test.log`, `/private/tmp/avpplay-transfer-performance-build.log`, `/private/tmp/avpplay-transfer-performance-install.json`.

## Package validation follow-up

The subsequent launcher rejection was caused by the earlier D3D11 query repair changing its DLL while the shared DXMT profile still listed the old hash. Modern DXMT validates this closure for D3D11 as well as D3D12. The profile now records the current DLL hash and an explicit local integration override; the historical full-build receipt is preserved. A mandatory build check executes the production package-validation code on the assembled resources. Regression checks accept the repaired closure and reject a stale D3D11 hash or missing D3D12 DLL. Runtime checks remain enabled.
