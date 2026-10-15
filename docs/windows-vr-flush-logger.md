# Event-query submission and OpenComposite startup repair

The October 15 user logs show two separate problems. Moss: Book II continues
producing frames, but event queries can be polled roughly 200,000–270,000 times
per frame. BONEWORKS fails during DLL initialization before gameplay begins.
This pass changes guest DLLs only and keeps the eye targets at 1888×1792.

## Event-query submission

DXMT's `GetData` checks the actual Metal shared-event value on every event-query
poll. A pending query without `DONOTFLUSH` then invokes `Flush`, including when
that query's commands have already been submitted. Each redundant call enters
the context's flush/locking path.

Patch `0016-dxmt-event-query-flush-coalescing.patch` records whether a query issue
has requested submission. The first eligible pending poll still flushes. Later
polls still read the exact GPU signal but skip duplicate submission requests.
`Issue` resets the flag. Timestamp-disjoint queries use the same lifecycle;
other query types keep their existing submission behavior. The existing
`DONOTFLUSH` stall threshold is preserved. This uses the existing immediate-context
threading contract, as do the query's state and stall counter.

An event depends on commands before its signal. Work recorded after submission
cannot make that already-submitted event complete sooner. Completion is never
inferred from the enclosing command buffer's retirement, and no synthetic query
result, timer, sleep or signal cache is introduced.

The production-method harness makes 250,000 pending polls in each version.
The baseline makes 250,000 flush calls; the repair makes one. Both read the GPU
signal 250,000 times. Tests also cover reissue, the `DONOTFLUSH` threshold,
timestamp-disjoint output and a signal becoming visible before chunk retirement.
This measures removed calls, not a game FPS speedup. The shared-event bridge
reads and the game's other CPU/GPU work remain.

## BONEWORKS initialization

The recorded construction trace reaches the CRT entry wrapper, then logs a first
stream use with phase zero and a null vtable, followed by CRT startup failure.
`Config.cpp` defines a global configuration object whose constructor logs.
`logging.cpp` previously defined a global `std::ofstream` in another translation
unit. C++ does not guarantee the stream is constructed before configuration.

Patch `0005-first-use-logger-lifetime.patch` moves the stream and its mutex into
one function-local static state. The first log call constructs that state before
using it. The mutex serializes opening, timestamp formatting, complete writes and
the explicit abort flush. The signal-safe descriptor path retains its existing
behavior. Normal CRT startup, errors and log messages are preserved.

A host harness compiles the actual logger storage, initialization and write
functions into a separate translation unit. Another unit logs from a global
constructor, matching the configuration path. The baseline crashes when that
unit initializes first. The repaired version passes both link orders with an
early message plus 8,000 concurrent messages, including ThreadSanitizer.
A production LLVM-MinGW x64 build also passes dependency-closure validation and
preserves the OpenVR exports. It retains the statically linked x64 C++ support.

## Packaging and validation

The ARM64EC D3D11 DLL preserves its normalized imports and exports. Only that
DLL and the two packaged copies of the x64 OpenComposite DLL are replaced.
The native JIT runtime, native compiler and D3D12 binaries are preserved.
Local receipts record the new artifact and patch hashes while retaining the
original full-build provenance. Package validation accepts the actual package
and rejects a stale hash and missing DLL.

The signed Release app targets visionOS 27. Regression checks cover exact event
ordering, query publication, query readback, encoder boundaries and logger
concurrency. Details and installation status are recorded in
[the validation record](windows-vr-flush-logger-validation.json).

No game was launched by the agent. Neither a post-change FPS gain nor complete
BONEWORKS compatibility is established by these host checks. Test Moss in the
same scene for about 60 seconds, then BONEWORKS in a fresh app session, enabling
JIT as usual. Subsequent logs should show whether BONEWORKS completes CRT
initialization and whether fresh game-frame intervals improve.
