# Moss second-page freeze and BONEWORKS follow-up

The user identifies the reproducible trigger as flipping Moss's book to the second page. That transition may start different scene rendering, resource loading or shaders. The logs do not prove that textures/shaders/loading can be ruled out as triggers.

The user subsequently confirmed that Moss passes this exact transition and works after patch 0013's VR encoder-boundary repair. BONEWORKS still crashes. Follow-up performance work and DLL-startup evidence are recorded in `windows-vr-performance-target.md`; old unverified statements below describe earlier captures, not the current Moss outcome.

## Latest Moss evidence

### October 14 follow-up: physical failures persist

### Reproduction with query-state diagnostics

The new Moss capture contains a prior encoding-thread access violation in `d3d11.dll+0x1043d8`, symbolized against the exact staged ARM64EC DLL as `ArgumentEncodingContext::endPass()`. Its caller is `CommandChunk::encode` (`+0xf6884`), and the instruction loads the ID through a null `encoder_current`. All later stuck occlusion queries show begin/end `UINT64_MAX`, issued zero and samples zero: they have not executed on the encoding thread. Missing query readback is therefore downstream of this thread's failure in this capture. Observed guest GPU buffers complete (4,405/4,405); 617 copied frames precede the freeze.

The custom `WaitWindowsVRImage` extension inserted a standalone event encoder without invalidating the active D3D11 pass. `waitEvent` replaces `encoder_current` and ends the event; the D3D11 recording state still thinks its previous pass is active and emits a subsequent `endPass` against null. Frame submission likewise committed directly without closing the active pass. Both extension operations recorded commands without DXMT's context mutex.

Patch 0013 introduces a shared recording boundary that takes the context mutex, invalidates the current pass with deferred commit, records the operation, and commits only for frame submission. Image waits remain ordered commands; no wait is skipped, no query result is fabricated, and `endPass` retains its strict invariant. The mutex is released before waiting for submission's result. The production helper regression checks drawing on both sides of a standalone wait, closing a pass before submission, idle waits, and concurrent command recording. It passed normally. Thread Sanitizer execution crashed before producing a diagnostic on this host; no sanitizer success is claimed for this new regression.

BONEWORKS still faults in `std::basic_ofstream::open` at the corresponding new RVA `0xa772`, using the diagnostic OpenComposite module. The stderr construction records were absent from both collected logs, so absence cannot establish missing constructors. Patch 0004 now records those events directly via Win32 file I/O in `C:/windows-vr-runtime/opencomposite-init.txt`, without relying on C++ stream or stderr initialization. No BONEWORKS behavior repair is claimed yet.

Evidence: `/private/tmp/avpplay-transition-new-current.log` (BONEWORKS), `/private/tmp/avpplay-transition-new-previous.log` (Moss), `/private/tmp/avpplay-transition-new-launcher.log`, `/private/tmp/avpplay-d3d11-symbols.txt`, `/private/tmp/avpplay-encoder-boundary-build.log`, `/private/tmp/avpplay-openvr-file-diagnostics-build.log`, `/private/tmp/avpplay-encoder-boundary-app-build.log`. The page flip must be repeated with this repair before declaring it resolved.

The subsequent headset run still freezes, now at 1,948 submitted frames and completed sequence 10,056. Three occlusion queries remain pending for millions of polls while the observed GPU buffers complete. The earlier query publication and empty-tail repairs therefore do not establish the cause of the reproducible page transition. No relevant shader/pipeline error was found in this capture, but loading or new rendering can still trigger the failing query lifecycle.

Patch 0012 records each pending query's begin, end, issued and sample counters. This distinguishes commands that did not execute from readback completion that did not publish. It does not fabricate results or change readiness.

BONEWORKS still faults at OpenComposite's `std::basic_ofstream::open` (RVA `0xa4a2`), before submitting a VR frame. The loaded module identifier confirms that the rebuilt static DLL executed; static C++ linkage alone did not fix this failure. OpenComposite patch 0004 records entry into the logging translation-unit initializer, completed stream construction, process attach and the first logging call's object/vtable state. Missing constructors, initialization ordering and subsequent object corruption remain competing explanations pending a new capture.

Evidence: `/private/tmp/avpplay-transition-0.log`, `/private/tmp/avpplay-transition-1.log` (BONEWORKS), `/private/tmp/avpplay-transition-2.log` (Moss), `/private/tmp/avpplay-transition-diagnostics-build.log`. These diagnostics compiled successfully; neither physical failure is claimed resolved.

The signed diagnostic app was installed successfully (`/private/tmp/avpplay-transition-diagnostics-install.json`). The production package validator accepts the staged bundle and rejects stale hashes/missing DLLs; both x64 VR DLLs pass the C++ dependency check. The diagnostic patches are included in the corresponding preparation/build scripts.

The game's own `users/mobile/AppData/Local/Moss2/Saved/Logs` directory contains no log files. Its latest saved crash report is older (October 13), identifies Unreal 4.27.2 and an OpenXR access violation, and cannot establish the cause of the October 14 page freeze. That report is retained at `/private/tmp/avpplay-moss-engine-crash-oct13.xml`; it is not evidence of a new failure in this build.

The archived Moss run freezes at 793 submitted frames. There are 5,402 completed observed guest/application GPU buffers, zero reported failures and zero pending observed buffers. Owned transfer work also completes. The display keeps presenting the cached game picture and tracking the headset.

The added production diagnostics identify the stuck requests as D3D11 query type 1 (occlusion), with flags 0 and completion sequence 4288. Numerous query objects reach millions of unsuccessful GetData polls. This localizes the observed blocking path to query results; it does not by itself prove why those results are missing. No relevant shader/pipeline compilation error was found in this captured session.

## General query lifecycle defect and repair

DXMT previously created a visibility readback only when the current command chunk had visibility samples. A query can start in a chunk containing real samples and end in a later chunk containing none. Its final end sequence then exceeds the last published readback sequence, and GetData can remain pending although all GPU commands have finished.

Patch 0011 preserves the final completion barrier for pending queries even in an empty chunk. The zero-sample readback allocates no zero-length Metal buffer. It publishes the empty chunk's completed sequence while preserving all prior GPU sample contributions. Readbacks retire on DXMT's ordered finish thread after command completion. The pending query list is removed only after its readback retains the ended queries. The heap info is explicitly zero-initialized, including for architectures whose cleanup frees its memory field.

A small production FlushVisibilityQueries factory makes this lifecycle testable. The regression executes the actual query classes, actual readback destructor and actual flush factory; only the Metal allocation boundary is stubbed. A spanning query retains the exact earlier sample count of five, remains pending before retirement, and becomes ready after the empty tail retires. It also verifies that no empty Metal allocation occurs. Cross-thread publication checks pass under Thread Sanitizer. The D3D11 ARM64EC DLL rebuilt successfully.

No game-name condition, forced query success, fabricated visibility count, disabled occlusion, shader replacement or texture exception was added. The defect is confirmed in the implementation. Whether it fully resolves the physical second-page freeze remains unverified until that transition is repeated on the headset.

## BONEWORKS

The later BONEWORKS launch submits no VR frames. Its fault address resolves to std::basic_ofstream::open inside vrclient_x64.dll; the fault dereferences an invalid stream vtable. The package's x64 OpenComposite imported libc++.dll and libunwind.dll, while the loaded shared runtime is ARM64EC. The x64 OpenXR runtime had the same shared dependencies.

Both custom x64 VR libraries now link their C++ support internally with the LLVM-MinGW static-link option. Their exported interface contracts are unchanged. Import inspection confirms neither relies on the shared C++/unwind DLLs. This removes the cross-architecture standard-library boundary. It does not yet prove that every cause of BONEWORKS's startup failure is resolved. No logging was disabled and no null-pointer exception was swallowed.

The mandatory bundle check rejects reintroduced shared C++ imports in these x64 libraries. Original DLLs are retained in temporary baseline files; local build receipts and resource hashes describe the new artifacts. The DXMT shared package receipt is also updated and validated by the runtime's real package validator, preventing the previous launch-blocking stale hash.

## Launcher

The main screen now leads with the selected game, optional Steam artwork, readiness text and a large Play action. Steam library browsing and saved-game selection remain directly accessible. Existing imports, transfers, profile editing, reports and counters are retained on a separate options page. Errors and session controls remain visible on the main screen. Existing selection locks and launch validation remain active. English/German labels are retained. Signed compilation passed; physical visual/interactivity review remains pending.

## Validation limits

The signed app build, Wine bootstrap validation, actual DXMT package validator, x64 dependency checks and production input contracts passed. No headset game was launched by the agent. Reopen the launcher, enable JIT and repeat the exact second-page flip in Moss. Then retry BONEWORKS in a fresh app session. The resulting logs determine whether these repairs resolve the observed failures or expose another stage.

Evidence: `/private/tmp/avpplay-moss-freeze-latest-0.log`, `/private/tmp/avpplay-moss-freeze-latest-1.log`, `/private/tmp/avpplay-freeze-previous-1.log`, `/private/tmp/avpplay-empty-query-build.log`, `/private/tmp/avpplay-opencomposite-static-build.log`, `/private/tmp/avpplay-openxr-static-build.log`, `/private/tmp/avpplay-freeze-ui-build.log`, `/private/tmp/avpplay-freeze-ui-install.json`.
