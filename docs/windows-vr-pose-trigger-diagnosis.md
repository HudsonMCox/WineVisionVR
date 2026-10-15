# Head motion, triggers and performance — 2026-10-13

The latest successful headset run used 1888 × 1792 per eye. From 23:44:10.594 to 23:45:10.694 it submitted 1655 new game frames over 60.1 seconds: **27.54 FPS**. Tracking advanced at **90 Hz**. Median runtime CPU use during this interval was **591%**. The presentation queue dropped zero frames, so the slow production of new game images precedes compositor consumption.

A separate 54-second process-wide freeze occurred from approximately 23:43:16 to 23:44:10. The runtime freeze watchdog, audio wake-delay logs and compositor logs agree on this interval. Its cause is not established. It must not be silently included in the steady FPS average or attributed to GPU load without evidence.

CPU sampling repeatedly shows substantial activity in ARM64EC/FEX and D3D11 regions. The sampled guest PC `0x700e8cb740` maps to bundled d3d11.dll RVA `0x65740`, in the immediate context End/query code's exception-handling region. Native PC `0x700cd4f640` maps to a libarm64ecfex.dll copy at RVA `0xa640`. These locations narrow profiling toward graphics/translation interoperation, but stale guest PCs while executing native callees are not sufficient to diagnose repeated exceptions or prescribe a runtime patch. No GPU timing evidence currently separates guest GPU cost from this CPU work.

## Head motion repair

ALVR's `ALVRClient/Renderer.swift:updateGameStateForVideoFrame` removes translation from the recorded and current head transforms for color-only rotational reprojection. Its `ALVRClient/Shaders.metal:videoFrameVertexShaderCommon` places the video plane at 500 metres. Our rotational transform follows the same general principle, but wrote depth corresponding to a plane only one metre away. This invites positional system reprojection as though the whole game were a nearby flat screen.

The repair presents synthetic color-plane depth at 500 metres, bounded to half the compositor far range and beyond its near plane. Depth stays strictly positive in reverse-Z; clearing it to zero previously caused physical invisibility. Fresh guest frames still provide scene translation. This does not implement scene-dependent positional timewarp, which requires real guest depth.

Separately, `xrLocateSpace` now honors its requested time using the same pending/active tracking snapshots as `xrLocateViews`. Previously it always read the latest tracking, allowing space and view poses for one predicted frame to disagree.

## Trigger diagnosis

The physical trigger reaches the guest runtime: the captured `sync-actions count=1536` line contains right trigger `1.00`, with the session focused. Therefore missing physical discovery alone does not explain the report of no in-game trigger response. The previous trace did not include source paths or returned action values, so the final fault is not yet established.

The update logs each suggested action name, type and source path once at setup, and logs a bounded sample of actual action-state returns (name, type, hand, active status, value, change status and binding count). This closes the diagnostic gap without inventing button mappings. Native tests exercise the production action-snapshot helper with a full right trigger, both right-hand and null-subaction queries, an unbound left-hand query, and a non-focused session; they pass.

## Validation

- Production input/action-state contract tests: passed.
- x64 guest DLL cross-build: passed.
- Production MSL simulator GPU probe: passed color, 2D/array sampling, rotational warp and nonzero `0.0002` depth writes, with zero-depth negative control.
- Signed visionOS build and Wine bootstrap check: passed.
- Headset installation: succeeded (`/private/tmp/avpplay-pose-trigger-install.json`).
- No headset game launched by the agent. Physical head-motion improvement and trigger root cause require the next captured run.
