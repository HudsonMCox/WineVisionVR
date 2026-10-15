# Controller input, visibility and image quality — 2026-10-13

The captured headset session published changing PSVR controller button bits, trigger and grip values, with both controllers connected and tracked (`flags=7`). The bridge was queried thousands of times. This establishes working host input; it does not establish that the game consumed correct action state.

The guest runtime had concrete compatibility defects:

- Left Touch-layout X/Y click bindings were absent.
- Float thumbstick X/Y bindings returned no value. OpenComposite's legacy controller actions use these separate float axes.
- Boolean actions bound to analog trigger/squeeze values returned inactive/false. OpenComposite uses these bindings for trigger/grip clicks.
- Multiple actions sharing one input source were rejected, although OpenComposite binds both analog and digital grip actions to squeeze/value.
- Suggestions from every interaction profile were merged, and the last suggested profile was reported as current. OpenComposite suggests Touch before its simple-controller fallback.
- No initial interaction-profile-change event was emitted when attaching action sets.

The repair keeps per-profile suggestions, selects the Touch layout preferentially for PSVR Sense, and activates only that profile's bindings. The other suggested layouts remain fallback candidates. Bindings cannot be changed after attachment. Native contract tests execute the production helper functions with synthetic physical input, including shared-source suggestions and a later simple-controller suggestion. Guest action synchronization now emits bounded diagnostic snapshots for the next headset run.

The immersive scene requests `.upperLimbVisibility(.hidden)` and `.persistentSystemOverlays(.hidden)`, matching ALVR's compositor scene policy. Apple describes these APIs as hiding upper limbs/accessories and the home indicator: https://developer.apple.com/videos/play/wwdc2025/289/ . This is a system visibility request, not custom mask geometry. Physical visibility remains to be verified.

## Resolution and stutter

The session used 1888 × 1792 pixels per eye, with matching guest and destination rectangles. There is no logged extra downscale in this run. Guest submissions rose from 127 at 23:20:42 to 2568 at 23:22:22, approximately 24.4 game frames/sec; head tracking continued near 90 updates/sec. Most display frames reuse a reprojected prior game image. Runtime samples show about 440–480% CPU utilization and a roughly 4.3 GB memory footprint. These observations establish slow game production, but do not distinguish all CPU/GPU bottlenecks.

The attempted **Sharper rendering** option was withdrawn after the next headset run crashed before renderer initialization. Both 23:35 and 23:36 runs stopped immediately after opening the immersive space. The 23:36 system crash report shows SIGABRT on the main thread in `-[CPImmersiveScene layer]`, with `Layer configuration not supported %@`.

The attempted configuration set `maxRenderQuality` while `isFoveationEnabled=false`. Apple explicitly documents this as an unsupported render-quality configuration, and requires both configuration and runtime quality overrides to be guarded by foveation. The repair removes both overrides and the unsupported toggle, restoring the previous uniform-eye configuration and viewport-based guest dimensions. Controller mapping and visibility changes remain. Existing stored sharper-rendering preferences are no longer read. Higher-resolution support remains unfinished; it requires a correctly mapped foveated compositor or another supported resolution path, rather than this invalid setting.

References: https://developer.apple.com/documentation/compositorservices/defining-layer-renderer-quality and https://developer.apple.com/documentation/compositorservices/layerrendererconfigurationerror .

Crash report: `/private/tmp/avpplay-233620.ips` (incident A67E32E6-2D62-4FFC-A0E1-4D10062B9719). The game never started in this failing run; the runtime log is from the earlier successful session.

## Validation

- `python3 windows-vr-openxr/tests/test_input_contract.py`: passed production mapping, hand isolation, value-change detection, multiple actions per source, profile selection and attachment checks.
- LLVM-MinGW x64 OpenXR DLL build: passed; four pre-existing compiler warnings remain.
- Signed visionOS Debug app build: passed, including Wine bootstrap bundle verification.
- The updated x64 guest DLL is staged in the app bundle. The runtime creates a fresh per-launch mapping to this bundled DLL, so an old prefix does not pin the old version.
- No headset game was launched by the agent. End-to-end game input, visibility, sharpness and frame rate remain unverified.

Logs: `/private/tmp/avpplay-input-launcher.log`, `/private/tmp/avpplay-input-runtime.log`, `/private/tmp/avpplay-input-openxr.log`, `/private/tmp/avpplay-input-quality-build.log`.
