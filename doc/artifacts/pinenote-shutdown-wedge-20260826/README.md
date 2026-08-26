# The 2026-08-26 shutdown wedge: shepherd restarts networking mid-halt

Post-mortem evidence for the hang described in `doc/status.md`
(2026-08-26, part 4). Harvested from the study image's own
`/var/log/messages` on p6, mounted `ro,noload` from os1 after the
power-button recovery, before the partition was overwritten by the next
deploy. SHA256 of the full source log at harvest:
`5cf3eaed57e03b142f6a997a0d1caccb5d8b6b7278934ab9ef2522cf8f3aa0c0`
(verified identical on-device and after transfer). `halt-window.log` is
the 66-line excerpt covering 05:01:27–05:02:05, redacted per the repo
rule that device/host LAN addresses never land in committed files
(`WORKSTATION` = the operator's build machine, `DEVICE-LAN` = the
device's address).

## What the log proves

1. **05:02:00** — an inbound ssh (the deploy script's reboot channel)
   is accepted; shepherd spawns transient `sshd-134`; the session auths
   and issues `sync; reboot`.
2. **05:02:01** — `Stopping service root...` / `Exiting shepherd...`:
   the halt begins. The teardown is FAST and clean: `reader-session`
   stops within the same second (fbcon restore logged),
   `orientation-bridge` in ~1 s (the SIGTERM-deafness fix working on
   device), `pinenote-ddr-boost` in 3 s.
3. **05:02:05** — the halt reaches `sshd-134` and kills it
   (`mm_reap: child terminated by signal 15`). That is the ssh session
   that ISSUED the reboot: its client, still connected because Guix's
   `reboot` blocks while the halt proceeds, exits nonzero.
4. **05:02:05, same second** — the deploy script misread that nonzero
   exit as "reboot command failed" and fired its `||` fallback ssh. The
   inetd-style listener, still armed mid-halt, ACCEPTS it (source port
   47688 vs the original 47678). Serving the new transient requires
   `networking` — which the halt stopped moments earlier — so shepherd
   **starts networking again**: dhcpcd relaunches as PID 6062.
5. `Service networking has been started.` is the **final line the
   system ever logged**. The halt never completed; the device sat in
   this state for hours (kernel alive — ping answered via the restarted
   dhcpcd, tty echoed — with userspace half-torn-down: no ssh listener,
   no getty respawn) until a power-button cycle.

## What this refutes and what it teaches

- The initial suspicion (the reader-session stop handler's
  `usleep`-starved PID 1 crawling through shutdown) is **refuted for
  this hang** — the service teardown took four seconds total.
- The wedge needed two ingredients: a client that reconnects after its
  reboot-issuing session dies, and a supervisor that accepts inetd
  connections and restarts their dependencies **during its own halt**.
  The first is fixed in the deploy tooling (one reboot attempt, exit
  status ignored, no reconnection until U-Boot appears on the UART —
  `doc/device-access.md`). The second is shepherd behavior worth
  reporting upstream (`doc/upstream-register.md` item 20).

## Files

- `halt-window.log` — the redacted 66-line halt window (05:01:27 to the
  final logged line).
