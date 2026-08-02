# power — read-only PineNote power evidence

`test-power-capabilities.lua` proves the separate, unimported provider boundary
accepts only the exact capability set and forwards state/results/errors without
adding authority or no-op fallbacks. `test-power-coordinator.lua` exercises the isolated
`power_coordinator.lua` transaction with fake capabilities only. The coordinator
has no filesystem, FFI, subprocess, device-node, or sysfs authority and is not
imported by the production PineNote device target. It captures each successful
prepare provider's return state and passes it unchanged to its paired restore
provider. The only accepted host mode is `mem`, which is passed exactly once to
the requester; its prepare order is checkpoint, EBC, idlewasher, input,
frontlight, Wi-Fi, storage. After return it captures exactly one wake-source
attribution before restoring EBC, input, frontlight, idlewasher, and the final
non-blocking Wi-Fi handoff, then notifies the reader with that attribution. It
proves exact ordering, a durable prepared/failure-record boundary, permanent
poisoning after any failed stage or restore, and remains dormant and unimported.
Run both as part of `make activation-positive-check`; that composite
target also reruns the production activation-hard-off suspend preflight.

`power-snapshot.scm` records a versioned S-expression from an explicit root
(default `/`) and compares saved snapshots.  It uses only base Guile, never
executes external commands, and reads a bounded allowlist; waveform and VCOM
are explicitly excluded.  Missing files and failed reads are recorded as
`unavailable`, not treated as collection failures.

```sh
./power-snapshot.scm snapshot --phase awake --timestamp 100 --output - > /tmp/opencode/pinenote-power-before.scm
./power-snapshot.scm snapshot --phase awake --timestamp 110 --output - > /tmp/opencode/pinenote-power-after.scm
./power-snapshot.scm delta /tmp/opencode/pinenote-power-before.scm /tmp/opencode/pinenote-power-after.scm --output - > /tmp/opencode/pinenote-power-delta.scm
```

For a one-shot final4 collection without installing or writing the script on
the device, stream it to Guile and capture the report on the host (replace the
placeholder target):

```sh
guile -e '(@ (pinenote tools power power-snapshot) command-line-main)' -s /dev/stdin snapshot --phase awake --output - < power-snapshot.scm
# Over SSH: ssh DEVICE_PLACEHOLDER "/run/current-system/profile/bin/guile -e '(@ (pinenote tools power power-snapshot) command-line-main)' -s /dev/stdin snapshot --phase awake --output -" < power-snapshot.scm > /tmp/opencode/pinenote-power-snapshot.scm
```

`make check` builds a fake root and proves deterministic output, malformed-row
tolerance, unavailable values, schema/version fields, reset handling, and the
no-command mutation guard. The collector opens no output files: `--output -`
writes stdout, and every pathname is rejected. Use shell redirection on the
trusted host when a saved report is needed.

Reports contain MAC addresses, selected process command lines, and mount
information. Keep them under `/tmp/opencode` by default and do not commit or
share them without intentional sanitization.

## S-expression shape

Every compound snapshot section is a tagged record: for example,
`(system-power (record (state ...) (mem-sleep ...)))`, so consumers retrieve
the section then its field with `lookup`.  A delta domain is likewise
`(battery (domain (semantics signed-observation) (entries (...))))`; monotonic
domains use `monotonic-counter`, while gauge values use `signed-observation`.
Numeric delta keys use `(irq ID)`, `(name NAME)`, or
`(process PID STARTTIME)` for uniquely
identified dynamic records; anonymous ordered vectors (for example per-CPU
counter columns) retain numeric indices.  Duplicate identities deliberately
fall back to positional keys rather than being conflated; runtime devices also
retain their enclosing bus tag.

`system-power` also carries `dt-wakeup-sources`: an `available` record with a
sorted `paths` list of exact `wakeup-source` property paths found below the DT
base, without reading property contents.  `dt-cpu-idle-states` is either an
`available` record with immediate child `nodes`, or an explicit `absent`
record.

`fb-damage-gates.sh` is a read-only, device-side dump of every gate between a
userspace framebuffer write and an EBC frame: the fbdev suspended-state gate,
the plane→fb binding `drm_atomic_helper_dirtyfb()` requires, DRM-master
ownership, and fbcon binding. All four fail *silently and successfully*, so a
write probe can only ever report "still no frames" — which is why the
2026-08-01 post-resume dead-write window took a probe ladder and still did not
name its gate. The script opens no device node, on purpose: the first opener of
`/dev/dri/card0` becomes DRM master, and a diagnostic that opens the card
silently invalidates every `FBIOBLANK` and `set_par` it then attempts. Run it
once after resume, before anything else touches the display; read G1 first,
then G3, then G2, then G4. Analysis in `doc/power-management.md`
("Post-resume dead-write window").
