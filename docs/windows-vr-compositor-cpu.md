# Compositor and Metal CPU pass

This pass removes repeated CPU work in the native foveation bridge and the display-rate compositor. The game resolution, render quality, shader operations, GPU synchronization and guest frame ownership are unchanged. It does not establish headset CPU utilization or game FPS.

## Changes

- Array-texture slice views use an eight-entry cache per encode thread. Source texture identity and relative slice must match exactly. Both source and view references are weak, so the cache cannot keep old game resources alive. It reuses a view only while another real owner still holds it; an expired or evicted entry creates a fresh view through the original Metal API. Ordinary 2D textures retain their direct path, and invalid slices remain rejected.
- Foveation diagnostics include `sliceViewHits` and `sliceViewCreates`, allowing the next headset run to distinguish useful reuse from repeated view creation. Reuse is workload dependent: some GPU regression scenarios have zero hits, and the MRT scenario does reuse views. No universal hit rate is claimed.
- Stereo grouping uses a two-bit mask rather than allocating and filtering arrays of remaining/grouped eyes. It retains the same texture, depth texture, rate-map and slice identity rules and the original eye order, including grouping both slices of a shared layered target into one render encoder.
- Eye render plans reuse array capacity between refreshes. Their texture references are explicitly released immediately after encoding, so the reused storage does not retain a guest image through a pause or session transition.
- Width, height, pixel-format and source pairs use inline two-element storage. This removes four short-lived array buffers from each display refresh, including the snapshot-source mapping when reprojecting a prior game frame. Snapshot texture ownership remains separate from guest leases.

## Validation

`TextureSliceCacheProbe.mm` runs against real macOS Metal textures. It checks view identity, exact slice pixels, distinct nested parents, invalid inputs, eviction and weak source/view destruction. Its isolated live-view measurement was 851.79 ns for creating a view versus 39.97 ns for a cache hit. A cache miss still creates a view and adds lookup work; these numbers do not represent total renderer time or game FPS.

`PresentationGroupingTests.swift` executes the actual production grouping helper for all mono/stereo grouping relations and checks inline pair indexing, iteration and optional-source behavior. The real Metal foveation suite passes color/alpha/depth, MRT, stencil, sRGB, changing maps, unsafe/stale rejection, stereo atlas registration and layered presentation. The existing CPU/GPU regression batch also passes its presentation pixel comparison, compositor, frame-transfer, completion and GPU-statistics checks.

The signed device app is built without launching a game or installing it. Build, signature, package and preserved-JIT checks are recorded in [the validation record](windows-vr-compositor-cpu-validation.json). Local logs are under `.build-compositor-cpu-pass/`.

The next headset comparison should record the slice-view hit/create counters, compositor CPU encode time, real game-frame pacing and GPU queue delay in the same gameplay area. Display reprojection rate remains distinct from real game FPS. The preceding guest-runtime CPU pass is documented in [CPU overhead reduction](windows-vr-cpu-overhead.md).
