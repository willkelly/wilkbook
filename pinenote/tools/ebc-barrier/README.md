# ebc-barrier — supervised, reversible EBC sleep-frame test

`pinenote-ebc-sleep-frame-test` is a separately invoked diagnostic artifact,
not a reader feature or suspend implementation.  It extracts the exact
`rockchip_ebc_drm.h` barrier ABI from the forward-port patch at build time and
uses it to prove a framebuffer publication has reached the EBC worker.

```sh
guix shell gcc-toolchain python -- make -C pinenote/tools/ebc-barrier check
```

The command is inert for `--help` and malformed arguments.  `--run` requires
effective UID 0; this is an operational safety gate, not an authorization
boundary, because the current reader image deliberately grants its maintenance
user passwordless sudo.  It fails closed on unreadable or truncated process
metadata and refuses when a live process has `reader.lua` as an exact cmdline
argument, checking both before setup and immediately before framebuffer
mutation.  This remains defense in depth rather than mutual exclusion: run
`herd stop reader-session` first.  The command also requires an interactive
`/dev/tty`.  It snapshots exactly `line_length * yres_virtual` bytes from
`/dev/fb0`, including stride padding and off-screen storage, validates the
visible virtual-offset rectangle, paints a deterministic XRGB8888 card in that
rectangle, calls `fsync`, and does a strict SUBMIT/WAIT pair on the EBC's DRM
card node (resolved by `DRIVER=rockchip-ebc` in
`/sys/class/drm/cardN/device/uevent` — the index is not stable across images:
panfrost takes card0 on the direct-mode image).  Only after that succeeds does
it accept Enter from the
tty; it then clears its cleanup arm, restores the exact snapshot, fsyncs, and
performs one final strict barrier.  SIGINT, SIGTERM, and SIGHUP only interrupt
the acknowledgement: they remain blocked during setup and restoration, while
`pselect` atomically unmasks them for the tty wait.  A signal already pending
when acknowledgement begins therefore interrupts without a check/read race,
and that path still restores once.  The bounded host test covers both a pending
signal and one delivered while the wait is blocked.

There are no retries.  A failure before the first completed barrier does not
attempt restoration or a further hardware start; a restore failure is reported
as reboot-terminal uncertainty.  It records the first cleanup failure without
masking an earlier acknowledgement or restore failure.  The command opens only `fb0`, the EBC card
node, and `tty` (plus read-only proc and sysfs inspection); it never requests suspend or writes
power state, firmware, partitions, boot configuration, input, frontlight, or
network state.  It is packaged in the reader image but has no service,
autostart, import, or production suspend wiring.

## Supervised hardware procedure

The single authoritative campaign procedure, acceptance criteria, and stop
conditions are in `doc/hardware-deploy.md` under **EBC barrier campaign (one
supervised run)**. Follow that section without substitution; in particular,
do not use the legacy `pinenote-ebc-test --draw-smoke` and do not request
suspend.
