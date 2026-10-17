# Translation reduction pass

The target is 90 real game frames per second (11.11 ms per frame), with existing resolution unchanged. This pass reduces CPU work at the guest/native boundary. It does not establish that either game achieves that target.

## Implemented

- **Native frame waits:** OpenXR uses one notification-backed native call instead of repeatedly polling tracking every 250 microseconds. The same transport returns a coherent tracking, render-target and two-controller snapshot. Target changes, compositor pause and session exit wake the wait. Waits are bounded, stale poses do not become renderable frames, and legacy runtimes retain their existing path.
- **Correct display-period metadata:** display cadence is estimated from successive compositor-published tracking timestamps, using a median of up to eight intervals between 7 and 14 ms, with an 11,111,111 ns fallback. Missed ticks are excluded. Time spent rendering a slow game frame no longer changes the reported display period. This is an estimate from SDK timestamps, not a panel refresh-rate query.
- **FEX native dispatch:** native calls retain the original executable alias through the existing EC bitmap validation. Validated native targets branch to their executable mapping instead of depending on a fault to redirect a non-executable PE address. Both accepted and rejected paths restore the stack. Native translation helpers share validated range caches; unknown targets retain the authoritative lookup/fallback.
- **Cache indexing:** address hashing includes higher address bits to reduce collisions between aligned modules. Entry range validation and retirement/reuse behavior remain intact.

These changes are included in both native ARM64EC and legacy x64 OpenXR packages. The rebuilt FEX translator and offline compiler are packaged together with matching receipts. The native JIT core executable text is preserved. Existing render resolution, GPU completion signals and frame ownership are unchanged.

## Validation

The signed Release visionOS device build succeeded. Production bundle checks, code signature verification, native coherent-state/wait tests, production OpenXR transport/WaitFrame probes, controller contracts, persistent-cache tests and the CPU/GPU regression batch passed. The FEX patch was reapplied to the captured pre-change sources and compared byte-for-byte to the built sources. Packaged translator/compiler/OpenXR binaries match their build outputs.

The native tests cover real-pose wakeups, duplicate suppression, 100 publication races, timeout, resize, pause, exit and ABI rejection. WaitFrame probes cover zero guest polling on the native path, legacy fallback and display-period independence from slow game frames. The dispatch probe executes the production assembly normalization/branch-selection fragments and C++ helpers on ARM64 macOS, with boundary, unknown-address, retirement/reuse and concurrent immutable-table checks. It checks that the unchanged EC bitmap gate remains before native selection; it does not execute the complete Windows dispatcher.

Synthetic lookup measurements against the previous production C++ helper were 67.76 to 55.98 ns for mixed mapped/unmapped addresses (1.21x). Mapped hot lookup cases were about 33 to 1 ns. The existing assembly range-lookup probe measured 3.39 to 2.41 ns (1.40x). These are isolated microbenchmarks, not game FPS or end-to-end speedup estimates.

No game was launched, the app was not installed, and headset FPS/cache hit rates were not measured in this pass. The next gameplay run should confirm the one-time `native-frame-state enabled` runtime log, then compare fresh game-frame intervals, CPU time, GPU queue delay and stutters at the same resolution. Reprojected presentation rate must be reported separately from real game FPS.

Local build/test evidence and artifact digests are recorded in [the validation record](windows-vr-translation-reduction-validation.json). Build logs remain local under `.build-translation-pass/`.
