# Stereo readiness and the capture-disabled freeze — October 15, 2026

## Readiness reset

The first Release run repeatedly published 1888×1792 stereo targets, then read zero target dimensions in the same cycle. Tracked headset poses were available to the renderer, while shared readiness repeatedly reported no published targets or pose. A brief readiness window let launch proceed, but the runtime subsequently rejected missing targets.

The renderer treated every drawable returned by `queryDrawables()` as a stereo headset drawable. Apple distinguishes `.builtIn` display targets from `.capture` targets; capture can be monocular. Rejecting a capture drawable called `wvr_compositor_pause_v1()`, invalidating the headset targets and clearing tracking/controller state.

Only the built-in display now publishes target dimensions and tracking and acquires a guest frame. It renders first regardless of drawable ordering. Capture uses the same owned GPU snapshot, its own viewport/projection/format, and the display anchor; it does not publish global state or acquire another lease. Monocular capture uses the left-eye snapshot and rotational reprojection; no scene-depth reconstruction is claimed. All queried drawables are still presented. Missing or unusable headset displays continue to invalidate readiness. The native readiness check remains enabled.

The router regression compiles the production implementation with Swift `-O` and exercises capture-before-display ordering, mono/stereo capture, stable readiness, one guest-frame consumption, missing/invalid displays, and balanced presentation. Existing synthetic compositor and presentation probes pass on the **Mac Metal GPU**; their legacy output labels say simulator, but no simulator or headset execution was used for these checks. The Release visionOS build passes. Headset confirmation of this routing repair is pending.

Display FPS accounting excludes capture presentations, which previously inflated the counter when both outputs were present. Layout changes log drawable target and view counts. App scene-phase transitions also log uptime and thermal state, without changing lifecycle behavior.

## Independent freeze with capture disabled

The next user run launched `Moss2-Win64-Shipping.exe` (Moss: Book II). At unchanged 1888×1792 eye dimensions, selected five-second windows report 20.6 and 25.2 fresh transfers/s with about 90 display presentations/s. Fresh-frame median intervals were 44.420 and 33.368 ms; p95 intervals were 46.367 and 47.732 ms. These are arrival intervals, not simulation timings or a controlled before/after FPS comparison.

At 01:13:30 local time, all process telemetry stops for about 53.9 seconds. The native runtime labels it an unexplained whole-process freeze; the user confirms the whole scene froze. At resumption, guest GPU counters show 2,449 submitted and 2,449 completed command buffers, zero GPU failures and no pending GPU work. Presentation and snapshot work had also completed. This does not establish a permanent GPU command deadlock, nor prove the process was suspended by visionOS or the debugger. The layer and ARKit are paused at resumption and the layer then invalidates.

The same guest log records an independent native null-pointer fault: `NtPowerInformation` calls `CFNumberGetValue` with a null argument. The pinned Wine Apple battery reader performs unchecked dictionary-property reads. Earlier occurrences precede successful gameplay, so this trace alone does **not** establish that the battery fault caused the later process-wide gap. The preserved JIT runtime still contains this defect; it is not repaired by the drawable change. No fabricated battery result, suppressed exception, or replacement GPU query answer is introduced.

The next headset run needs the routing layout and app activation logs correlated with the native freeze heartbeat and debugger session. A shader-specific or query-specific freeze cause is not established by these captures. The new Release app is intended to verify the readiness repair and narrow this separate freeze; it is not claimed to resolve all freezes or meet the FPS target.

Local evidence: `/private/tmp/winevision-startup-failure.log`, `/private/tmp/winevision-freeze-after-capture-off.log`, `/private/tmp/winevision-freeze-guest.log`, `/private/tmp/winevision-freeze-tunnel.log`, `/private/tmp/winevision-drawable-compositor-test.log`, `/private/tmp/winevision-drawable-presentation-test.log`, `/private/tmp/winevision-drawable-release-build.log`. Device logs and pairing credentials are not repository artifacts.

## Cooperative audio ownership

Both the Swift launcher and pinned `WineProcessBridge.m` used legacy exclusive playback activation. StikDebug's source starts a mixing background audio engine and a background-task lease to service debugger events while the game is active. Exclusive game audio can interrupt that engine. A helper that stops servicing an all-stop debugger can consequently block the whole target process; this is a plausible mechanism for the process-wide gap, not a proven attribution from these logs.

The host now requests playback with `mixWithOthers` and propagates audio-configuration errors. Source patch `0005-madeira-cooperative-audio-session.patch` makes the same change in the pinned Wine process bridge. The preserved JIT binary still calls the legacy setter, which clears category options, so a narrow host adapter translates that playback setter into the public options setter with mixing. Other legacy categories retain their original implementation; modern explicit-option calls remain untouched; real return values and errors propagate. No runtime binary instructions or JIT mappings are changed.

The simulator audio policy probe exercises installation/idempotence, real legacy playback calls, repeated resets, forwarding of other categories, real errors and preservation of modern options. This checks audio-session policy; it does not establish physical headset helper lifetime or resolve the battery fault. Run it with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer bash windows-vr-tools/test_simulator_audio_session.sh <booted-simulator-id>`.

## Delivery status

The final Release build and strict recursive signature verification pass. Installation retry is blocked by CoreDevice error 4016: the headset cannot currently provide trusted remote developer services or a power assertion. The repaired build has not yet been installed. The signed app is retained in persistent Xcode DerivedData under `WineVisionVR-Device/Build/Products/Release-xros/WineVision VR.app`; source and validation metadata are saved in WineVisionVR.
