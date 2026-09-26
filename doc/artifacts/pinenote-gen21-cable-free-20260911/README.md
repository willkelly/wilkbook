# Generation 21 — attended cable-free trial, 2026-09-11

wkelly's PineNote, os2. The operator invoked the then-required spelling
`I invote the trial!!` and corrected the future phrase to `I invoke the trial!!`
in the same conversation. No UART was connected to this flow. The operator
reported normal reader display, previous-note recovery and a saved edit
surviving close/reopen. No button/menu recovery was needed.

`evidence.txt` contains selected command output from the deploy and postflight;
the SSH timeout's private address is replaced with `[reader address]`. Note
contents, fonts and calibration data are not included. Full host logs for this
session were retained at `/tmp/opencode/pinenote-trial-20260911/` (temporary).
Device diagnostic backups are at
`/data/wilkbook/diagnostic-backups/gen20-before-gen21-20260911/`.

The source was generation 20, system `7wyr4smy…`; the target is generation 21,
system `iv1div03…`. The retained cold-booted fallback is pinned generation 16,
system `8czi9ry1…`; generation 10 also remains pinned. The target passed normal
deployer health and promotion, then a second health check after the operator
checks and suspend restoration. Final auto-suspend is `enabled=1`, with the
config verified byte-for-byte against the pre-session backup.

The host's local date was September 11 (UTC−06:00); device logs and UTC handoff
timestamps show September 12. The ten-minute host observation deadline was
not reached: deployment took 50 seconds. This is successful cable-free session
1 of 3 before policy review. It proves the packaged note on a kexec boot;
cold-boot/DTB, suspend/wake and physical-power-loss qualification remain open.
