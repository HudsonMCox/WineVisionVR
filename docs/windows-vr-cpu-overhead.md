# CPU runtime overhead reduction

This pass targets CPU work in the OpenXR runtime surrounding game translation, at the existing resolution. Both ARM64EC and x64 guest DLLs include the changes. FEX code generation and the native JIT core are unchanged in this pass.

## Implemented

- Controller binding paths compile into per-hand numeric plans when a selected interaction profile changes. Repeated reads sample masks/analog sources directly, preserving binding-order ties, trigger thresholds, menu buttons, haptics, hand isolation and change timestamps. Numeric binding-path comparison detects replacements, including same-length and empty replacements, without reparsing strings or allocating in the unchanged path.
- Action sync validates all requested sets before publishing changes. Unchanged set lists and subaction filters reuse their existing vector/map storage; controller samples still refresh every sync. Invalid input leaves the previous action-set selection intact, and focus loss/recovery retains the previous contract.
- Sync visits only active action sets and resolves the hand filter once per set. Public handle checks and the action mutex remain in place.
- Unit-quaternion composition and relative poses use direct rotation/translation math instead of constructing and multiplying temporary matrices. Outputs are normalized to prevent drift along long pose chains. Non-unit inputs retain the previous matrix implementation. Tracking timestamps and pose sampling are unchanged.

## Evidence

`python3 -I -S windows-vr-openxr/tests/test_cpu_hotpaths.py` executes the production helpers against the previous implementation, using both UBSan/bounds and an optimized unsanitized build. It covers 50,000 action/hand cases across five action types, replacement/unknown/empty bindings, 10,000 unchanged syncs with no local action-storage allocations, invalid duplicate selection, empty selection, focus recovery, 60,000 random rigid-pose comparisons, non-unit fallback and 10,000 chained compositions. The existing input contract also passes, including profile selection, triggers, menus, haptic routing and stop behavior. Production frame-wait and frame-state transport regressions pass.

On this Mac, the optimized isolated probes measured action sampling at 407.85 to 11.78 ns/call and relative pose at 28.34 to 6.46 ns/call. The probes use indirect function pointers and the same inputs for both implementations. These are host microbenchmarks for selected helpers; they do not measure headset CPU utilization, complete action sync time, x86 instruction translation throughput or game FPS.

Both guest architectures compile, the signed Release visionOS device app builds, production package verification and strict code signature verification pass. Packaged OpenXR binaries match their build outputs, and the preserved native JIT executable text hash is unchanged. Existing resolution is unchanged. No app was installed and no game was launched in this pass.

The next headset measurement must compare real game frame intervals and CPU/GPU timing in the same scene. Reprojected display FPS remains separate from newly rendered game FPS; 90 real FPS has not been established.

[Validation record](windows-vr-cpu-overhead-validation.json) contains source/artifact hashes and local log digests. The preceding translation changes are documented in [translation reduction](windows-vr-translation-reduction.md).
