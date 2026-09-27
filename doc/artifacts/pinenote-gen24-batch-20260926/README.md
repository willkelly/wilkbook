# Generation 24 batch deployment — wkelly PineNote, 2026-09-26

Attended cable-free trial explicitly invoked with `I invoke the trial!!`.
Source: `a24c5e1` on `batch/integration`, PR #87. Deployment used the existing
`make deploy DEVICE=pinenote-os2 FLAVOR=book-state-device-reader KEEP=8`, with
the `guix time-machine -C channels.scm` profile first on PATH, `WILKBOOK_UART`
unset, TMPDIR under `/tmp/opencode`, and `timeout --kill-after=15s 600`.

- Source: generation 23, `/gnu/store/x3qqz8r52pdh7jzghzfj8l44gfrqkncb-system`,
  boot `6caf4f3c-4c06-439f-88aa-8acec877a8cf`, cold-booted and pinned fallback.
- Target: generation 24, `/gnu/store/13cg7sg6waa3ahj3ivxhmkagia0kbwi1-system`,
  derivation `/gnu/store/9b3clfd0pxfrdz1s5dbr8miqjfpc10ww-system.drv`.
- Target boot: `7d56208a-02f4-4a1c-9386-ef61cd7d0859`.
- Both kernel Images: SHA-256
  `5435c84efda8fbed092ac22becfde2cb1a3d82298a3549cfbdfebf6d4cbca2f9`.
- Result: exit 0; 28/488 paths transferred; health passed; 24 promoted;
  nothing pruned, pins 10/16/18/23 retained. No recovery intervention.
- Prior suspend setting restored byte-for-byte to `enabled=1`.

`deploy.log` preserves deploy output with the device address replaced by
`<device-address>`. `postflight.log` contains mounts, identities, health,
services and kernel signatures. `authority-stop.log` holds selected Shepherd
stop/start lines; `cleanup-excerpt.log` holds the authority's bounded-cleanup
and new-ready lines, reopened database fd, and verified suspend restoration.

The new target helper stopped the authority itself; no manual authority stop
was used. Successful handoff exercised its runtime-cleanup and mounted-data
read-only gates. No deliberate refusal or fault was injected. Root remains
best-effort; absence of journal recovery does not prove clean-root kexec.
This is kexec-only, not DTB qualification. The operator subsequently confirmed
all three requested checks: reading/page turns; notebook existing strokes,
drawing, Refresh and close/reopen; power-button/cover suspend/wake. No cycle
count or timing was measured. Process-restart persistence and targeted
notebook/broker edge cases remain unqualified. This completes the third
successful cable-free session; new sessions await the operator's policy
review. See `doc/status.md` for the living record.
