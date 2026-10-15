# Moss progression freeze and first FPS optimization

The user confirmed working triggers, improved head movement and smoother perceived presentation. The game then froze while music continued.

The captured run stops submitting at guest frame **1222**. All 1222 frames were acquired and completed; the queue is empty. Tracking and cached presentation continue for more than 130 seconds. This excludes an outstanding presentation lease or a backed-up headset frame queue as the immediate stall. Median moving game frame rate before the stall was approximately **26.1 FPS**.

Thread samples repeatedly show `RenderThread 2` running at 97–100% CPU in D3D11 `GetData` and its ARM64EC dispatch path. Audio continues on a separate thread. The exact query type and final reason for non-completion are not established. No synthetic query success, skipped occlusion result or forced frame advancement has been introduced.

## Measured CPU hotspot and repair

The bundled translator's `ios_ec_xlate_loop` scans the mapping registry newest-first after a single global last-hit cache misses. Samples repeatedly land in this loop. Inter-module calls evict the single entry; already translated executable-alias targets can also scan the entire PE-address table without finding a match.

The local integration patch adds separate 256-slot forward and reverse entry-pointer caches. Every hit checks the authoritative entry's current base and size. A retired size-zero entry misses; a reused entry is revalidated. Forward cache misses use the original full lookup. A direct executable-alias target can warm the reverse cache through a full reverse lookup, then remain unchanged on subsequent valid hits. Unknown targets preserve the previous untranslated result. No hard-coded JIT address band, fabricated mapping, new guest ABI or native JIT framework mutation is involved. The old FFS reverse mapping remains unchanged.

The user explicitly authorized local DXMT/FEX dependency fixes overriding their nested no-AI-contribution instructions. The change is stored as `windows-runtime-plugin/patches/0003-fex-image-alias-cache.patch` for reproducible integration builds; the original source checkout is preserved.

`windows-runtime-plugin/Tests/test_alias_cache.py` executes the actual production AArch64 lookup block on the Mac, with register-preserving wrappers. It compares boundaries, unknown addresses, retirement/reuse and both directions against the reference mapping result. Concurrent lookups with an immutable mapping registry also pass. The synthetic workload alternates 32 PE module addresses and their executable aliases among 180 mappings: approximately **80.48 ns to 1.97 ns per lookup (40.81×)**. This is a lookup microbenchmark, not a measured game FPS increase. Mapping mutation racing an active lookup retains the pre-existing registry publication behavior; the test does not claim to prove concurrent unload safety.

The ARM64EC FEX DLL was rebuilt and staged as `Runtime/arm64ec-windows/xtajit64.dll`. Its native-framework/JIT setup remains unchanged. The guest build receipt records an explicit integration override and the current DLL/patch hashes; the resource-stage hashes for changed runtime inputs are updated.

## GPU timing diagnostics

An opt-in diagnostic observer uses the public Metal command-buffer commit and completed-handler APIs. It records submissions, completions, failures, mean completed-buffer GPU duration and oldest pending submission. It separates labeled headset presentation buffers from guest/other application buffers. Pending record storage is bounded at 4096, and overflow is reported. It adds no waits, captures, image readbacks or scheduling changes. It observes the concrete command-buffer class discovered during installation; another class would need coverage before interpreting absent guest observations.

The renderer writes a timing summary every five seconds when `LaunchDiagnostics.enabled`. The visionOS simulator test creates real guest/presentation buffers, fills a Metal buffer, verifies unchanged GPU output and checks that both submission/completion counts are correct. Passed. The native AArch64 cache test, FEX cross-build, signed visionOS app build and Wine bootstrap validation passed.

The updated build is installed. No headset game was launched by the agent. The next physical run must measure game FPS and provide GPU progress during the freeze; the freeze's root cause is still unresolved.

Evidence and results: `docs/windows-vr-freeze-fps-validation.json`, `/private/tmp/avpplay-freeze-fps-{launcher,runtime,openxr}.log`, `/private/tmp/avpplay-alias-cache-test.log`, `/private/tmp/avpplay-gpu-stats-test.log`, `/private/tmp/avpplay-fps-cache-build.log`, `/private/tmp/avpplay-fps-cache-install.json`.

## Follow-up: query publication and BONEWORKS startup (October 14)

The next physical Moss run froze at frame 806 despite 5,494 completed observed guest/application GPU buffers, zero failures and zero pending observed work. Moving game FPS was approximately 27; no meaningful FPS increase from the alias cache was established. The renderer remained in the GetData S_FALSE retry path. This is not evidence of a compositor queue backlog or a host crash in that run.

The DXMT timestamp and visibility helpers publish plain shared fields from the finish thread while the game polls them. Testing the actual original classes with Thread Sanitizer reproduces data races. Patch `0010-dxmt-query-publication.patch` makes result/metadata publication atomic and adds exponentially spaced pending-query warnings. The same helper test passes with the patch; exact readback values, chunk offsets, empty queries and reset are checked. The ARM64EC D3D11 DLL rebuilt successfully and has identical import/export contracts to the previous DLL. Only that DLL is replaced; the preserved native JIT/runtime framework is unchanged. This corrects a confirmed defect but does not yet establish that the physical Moss freeze is resolved.

The actual BONEWORKS Unity log reports `VRInitError_Init_PathRegistryNotFound (110)` after Direct3D11 initialization. Stable prefix-user OpenVR registration now points at the bundled OpenComposite bridge, with app-container links refreshed on launch. The real Swift registration helper passes repeat-installation and configuration-preservation tests. BONEWORKS needs another physical launch to establish whether it gets past this discovery failure and whether later issues exist.

The signed repair, controller menu/haptic changes and merged presentation pass are installed. The agent did not launch a game. Detailed checks and the foveation/temporal-backend plan are in `windows-vr-query-menu-haptic-validation.json` and `windows-vr-performance-foveation-plan.md`.
