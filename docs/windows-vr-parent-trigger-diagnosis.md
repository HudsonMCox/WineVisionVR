# Moss trigger binding repair and BONEWORKS startup evidence

The user confirmed that head movement is much better and the presentation feels smoother after matching ALVR's distant color-plane treatment. Triggers still produced no response.

The subsequent OpenXR trace identifies the fault precisely:

- Touch profile selected; `leftgrab` and `rightgrab` are boolean actions.
- Their sources are `/user/hand/left/input/trigger` and `/user/hand/right/input/trigger`, without a leaf component.
- Both were logged `mapped=0`, and game-facing reads were `active=0`.
- At sync count 1024 both physical triggers were `1.00`; at count 1792 both again were `1.00`.

The runtime incorrectly accepted component-root suggestions but recognized only `/value` or `/click` during sampling. It now resolves root trigger/squeeze/grip paths to analog values, thresholds them at 0.5 for boolean actions, and returns analog values for float actions. Explicit click and touch bindings retain their separate behavior. This is a shared component resolution fix rather than special handling of Moss action names.

The native contract test executes production sampling and game-facing snapshot helpers for the exact Moss paths on both hands, with released, partially pressed, fully pressed, held and released states. It also verifies float root bindings and that touch/click paths are not mistaken for analog roots. Passed. Cross-build of the x64 guest DLL, signed visionOS build and Wine bootstrap packaging check passed. Physical trigger behavior needs the next headset run.

## BONEWORKS

Launcher logs identify two accepted BONEWORKS (Steam app 823500, option 0) launches:

- 23:52:58: runtime accepted; ntdll startup observed at 23:53:03; no VR frames by 23:53:23.
- 23:54:16: runtime accepted; ntdll startup observed at 23:54:21; no VR frames by 23:54:41.

The user reports returning to the launcher after 20–30 seconds. No system app-crash report matches these attempts. This does not rule out a guest-only exit or another startup failure. No Unity Player.log was found. The launcher cleared the BONEWORKS runtime log when Moss was launched afterward, so a precise game failure cannot be attributed from the surviving evidence.

The log lifecycle now preserves the last three runtime logs (`Documents/madeira-log.previous-1.txt` through `previous-3.txt`) before beginning a new session. Failed rotation is reported and does not deliberately truncate the old log. Numeric fields that pass the existing Steam report allowlist are also persisted to the launcher log; they were previously sent only to NSLog. The launcher records a changed Steam failure message once. This will preserve startup failure evidence through the next Moss run. BONEWORKS compatibility remains unresolved.

Resolution and head-motion settings are unchanged in this update.

Evidence: `/private/tmp/avpplay-trigger-next-launcher.log`, `/private/tmp/avpplay-trigger-next-runtime.log`, `/private/tmp/avpplay-trigger-next-openxr.log`, `/private/tmp/avpplay-boneworks-crash-list.json`, `/private/tmp/avpplay-boneworks-player-list.json`.
Validation/build: `windows-vr-openxr/tests/test_input_contract.py`, `/private/tmp/avpplay-parent-trigger-build.log`, `/private/tmp/avpplay-parent-trigger-install.json`.
