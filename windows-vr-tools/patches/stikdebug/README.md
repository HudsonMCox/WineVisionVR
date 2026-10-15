# Installed visionOS helper integration

`0001-keep-established-jit-session.patch` applies to the locally ported StikDebug
helper used for this project. Its checkout is based on upstream commit
`8a7fc130b033dc1803313269ec3f9388cb63b7c7`, with existing visionOS and diagnostics
changes. It is not a standalone patch against the unmodified upstream tree.

The patch replaces the unconditional 120-second script limit with a setup
deadline. Only successfully prepared and read-back-verified JIT memory disables
that deadline, and the state belongs to the same debug-proxy session. It is
cleared on session exit so another attachment cannot inherit readiness.

The helper was compiled and signed for the paired headset. Game execution and
sustained debugger service remain to be confirmed by the user.
