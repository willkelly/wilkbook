Two namespace setup failures preceded the successful post-freeze replay and are
retained verbatim.

Attempt 1 exited before the packet command because the read-only root had no
`/packet` mountpoint. `attempt-1-mountpoint.log` is the complete bwrap error.

Attempt 2 mounted the already-frozen packet successfully. The v6 complete mode
audit, positive exact capsule check, v5 preservation check, and required
private-clone BSG5 negative all passed. The full replay then stopped at its
first operation because the fresh tmpfs did not contain the script's fixed
`/tmp/opencode` parent. `attempt-2-evidence/` contains every file written before
that stop; `frozen-source-native-static.log` contains the exact mktemp error.
The empty `attempt-2-driver.log` is retained because all output had already
been directed into that evidence directory.

Neither setup failure evaluated Guix, lowered a derivation, built anything, or
changed the frozen v6 packet. The successful attempt differed only by creating
`/tmp/opencode` inside the private tmpfs before invoking the same packet command.
