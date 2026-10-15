# Startup failure: Wine loader files overwritten by a folder resource

The 2026-10-13 22:53 device run never reached the game. It started
`AVPPlaySteam/dockhost.exe`, then the Wine process thread called `pthread_exit`
less than a second later. The launcher kept waiting because that fatal exit
bypassed the runtime bridge's normal running-state cleanup. Compositor counters
stayed at zero submitted frames. Both PSVR2 controllers were connected, tracked,
and publishing changing physical input during this run.

Symbolication of the recorded `__wine_main+0x2288` return address identifies the
`fatal_error("failed to load %s error %x\n", ...)` call in `load_ntdll`. The built
app contained `Runtime/arm64ec-windows/ntdll.dll`, but not
`arm64ec-windows/ntdll.dll`, which the bootstrap loader opens relative to the app.

The Xcode project copied four bootstrap DLLs individually, then also copied the
entire `Resources/arm64ec-windows` folder into the same destination. That folder
contained only Steam helper files. An incremental folder copy deleted the loader
DLLs; a different copy order had let earlier builds work.

The source and prebuilt project specifications now copy the Steam executable and
its notices/receipt individually. Both specifications explicitly package the
bootstrap DLLs. An always-run build check verifies that both architectures have
nonempty `ntdll.dll` and `apisetschema.dll` at their required root paths and that
they match the corresponding runtime files.

The verifier rejected the broken app. The corrected signed build passed the
verifier. An incremental helper-resource update is also checked before installing.
A fresh headset launch remains necessary to confirm Windows startup; this check
does not run a game or change the JIT implementation.
