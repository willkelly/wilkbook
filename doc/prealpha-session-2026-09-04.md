# Pre-alpha test session, 2026-09-04 — for the `v0.3.0-prealpha` tag

The candidate is branch `prealpha-candidate` (main + PRs #66, #70, #67,
#69, plus the adversarial review's fixes, `doc/reviews/2026-09-04-adversarial-review.md`). This is the session that decides whether it is tagged: an
unattended half a subagent runs over SSH tonight, and an operator half
that needs eyes, hands and the UART. The inventory behind it (what each
tool needs and observes) is in the 2026-09-04 tooling review; the
per-PR evidence and gaps are in the PR analysis of the same morning.

## The accepted risk, stated first

There is no UART tonight. A kexec trial that succeeds never touches
U-Boot, so trials are safe; a trial that dies is reset by the watchdog
(patch 8) into U-Boot, whose default is **os1** with nobody at the
menu. Every step below that kexecs is therefore a step that can strand
the reader on stock Debian until the cable is back. The unattended half
kexecs three times (the generation-14 trial, the trial into generation
9 for the device-tree notice, the trial back), each into a kernel with
a boot record. `phase-seq.lua` (crashed the kernel once) and any
`reboot` are excluded. `rect_hint_batch=0` runs only on generation 14
and only after the store lineage shows patch 14 in that kernel; on any
earlier generation it is a kernel spin.

## Unattended half (subagent over SSH, generation 14)

0. **Deploy.** `make deploy DEVICE=pinenote-os2 FLAVOR=reader KEEP=7`
   from a worktree at the candidate commit, no convenience opt-in.
   Expect generation 14 promoted; generations 7–14 kept (nothing
   pruned). *Run with `KEEP=8` (2026-09-04): generation 14 promoted,
   7–14 kept, nothing pruned — `doc/status.md`.* Record the built system path and confirm its kernel is the
   candidate's derivation (`6rhnmj09…-linux-pinenote-7.1.8-pinenote.drv`,
   the rebuild after the adversarial review's braces fix — that lineage
   is the only proof patch 14 is in the running kernel; and read that
   derivation's build log for warnings in `rockchip_ebc*.c` first).
1. **Baseline.** `wilkbook-generation list`, `health`, `dmesg` saved to
   `/root/dmesg-0.txt`, `/sys/power/suspend_stats`, thread count
   `ps -eo comm | grep -c '^ebc-'` (expect 2), `grep Vmalloc
   /proc/meminfo`, `/sys/bus/platform/devices/fdec0000.ebc/power/runtime_status`,
   `pm-ground-truth.sh` to `/root/pmgt-0.txt` (read it: it names the
   one regmap it reads; never glob `registers`).
2. **Patch 14, behaviour.** Happy paths first: `belief-grab.lua
   --out-prefix /root/belief-0` (EXTRACT_FBS still returns 0 with valid
   pointers; three non-empty files), `rect-hints.lua --default 32 --rect
   0,0,100,100:32` (RECT_HINTS with a well-formed batch). Then the new
   guards, with a copy of `rect-hints.lua` that prints `ffi.errno()`:
   `echo 0 > /sys/module/rockchip_ebc/parameters/rect_hint_batch`, one
   well-formed call → expect failure with errno 22 (EINVAL) and a
   prompt return; restore `20`; a call with `num_rects` above 65536 →
   expect errno 7 (E2BIG). Then `dmesg` diff: no `WARNING:` from
   `rockchip_ebc_blit_neon` (the queue_work assertion must stay silent).
   *Run 2026-09-04 on generation 14: as expected — errno 22 in 0.000 s,
   errno 7, the happy paths unchanged, dmesg silent (`doc/status.md`).*
3. **Page turns, camera-free.** Push `optics-inject.lua`, create
   `/run/optics-inject.fifo`, start it under `setsid`, wait for
   `/run/optics-inject.pid`; `herd stop reader-session`, `herd start
   reader-session` so KOReader enumerates the injector; forty `KEY 158`
   turns three seconds apart, the EBC IRQ delta per turn logged; then
   `QUIT` and confirm the uinput device is gone. Verdicts: thread count
   still 2, `dmesg` diff clean of `WARNING:`, `workqueue lockup`,
   `Unbalanced pm_runtime`, `rockchip.ebc.*error`.
   *Run 2026-09-04: forty turns cost 0 IRQs — the restart had landed in
   the file manager, not the book; re-run with the book open, 47 frames
   per turn, verdicts clean (`doc/status.md`, `doc/testing.md`).*
4. **Driver rebind ×5.** With `reader-session` stopped:
   `echo fdec0000.ebc > /sys/bus/platform/drivers/rockchip-ebc/unbind`,
   then `bind`, verify `.../fdec0000.ebc/drm/card*` exists, record
   thread count, `VmallocUsed`, `runtime_status` after each cycle. The
   signal is accumulation across cycles (the audit's item 2 is the
   failed-probe path, which a clean rebind does not take; this is the
   regression guard for what the rebind does take). Restart the reader.
   *Run 2026-09-04: threads 2, runtime PM balanced, no warnings; one
   never-freed 228 kB LUT table per successful probe, resolved from
   source the same afternoon (`doc/status.md`).*
5. **Device-tree notice.** From generation 14, the RUNNING helper:
   `wilkbook-generation trial 9` — stderr must carry `NOTE: generation
   9's device tree differs from the booted gen-14's …` (generation 9's
   DTB lacks the sdio_pwrseq delay) and the second note (the running
   kernel was itself kexec'd). Wait for SSH (five-minute budget),
   `health` must say `booted_generation=9`. Back with generation 14's
   helper: `$(cat /boot/gen-14/system)/profile/bin/wilkbook-generation
   trial 14`; `health` must say 14 and `current_system` the candidate.
   If SSH never returns: stop; the reader is on os1 until the UART.
   *Run on generation 14 (2026-09-04): both trials booted, neither note
   arrived — the helper logged them after its own radio-off, so no ssh
   watcher could ever see them. Fixed in the candidate (notes before the
   teardown, pinned). The proof is two-part and neither part is anything
   generation 14 did: the first deploy of the fixed candidate from 14
   shows the model line and the kexec'd-kernel note only (its DTB is
   14's, so the "differs" note cannot fire); the "differs" note is
   proven by a hand-run `trial 9` from the fixed generation, whose DTB
   does differ. Both shown on generation 15 the same evening —
   `doc/status.md`.*
6. **Suspend rig, KOReader path weighted.** `wifi-cycle.sh koreader-idle
   120`, then `wifi-cycle-host.sh 15 45 300` (a workstation-side
   scratchpad wrapper, outside the repo, around the device's
   `wifi-cycle.sh`; settle 300 s so KOReader's idle timer wins every
   cycle), then `koreader-idle 900`. Verdicts from
   the device report: `koreader-initiated` should now be most of the
   transactions; `on pid=` and `associated within` counts equal; zero
   `Wi-Fi restore failed`; cyttsp5 `Validation of the wakeup response
   failed` count over `PM: suspend entry` count (R6); no `rxctl`/`attach
   failed`.
   *Run 2026-09-04, the cable out from the fourth transaction on: 32
   transactions, 28 KOReader-initiated, `on`/associated 32/31 (the one
   miss is the stale-settle button wake), 0/0/0 rebinds, retries and
   restore failures, R6 31 of 32, no `rxctl`/`attach failed`,
   `suspend_stats` 32/0 (`doc/status.md`).*
7. **R3 and R4 over SSH.** Clock: generation 14 ships the timesync
   service with no server (the privacy default, `pinenote/services/timesync.scm`),
   so the check is that it is inert — `/var/log/pinenote-timesync.log`
   holds one `no --server configured` line stamped with this boot's
   time (the log appends across boots) and nothing after it, `herd
   status pinenote-timesync` is stopped and disabled, and `date -u` and
   `rtc0/since_epoch` agree to within seconds (R3). The sync itself and the alarm re-arm need a
   generation built with `(servers …)` and are not part of tonight
   (R3s in `doc/glass-plan-2026-08.md`). Profile: the seeded settings
   present, fonts present (R4). *Run 2026-09-04: R3 inert as described
   (one line per boot in the log — it appends across boots — its stamp
   8 s after the kernel's `rk808-rtc: setting system clock` line, and
   the RTC and system clocks equal to the second); R4's seeds and
   KOReader's bundled fonts present.*
8. **Wrap-up.** `autosuspend.conf` back to `enabled=1`, reader running,
   `health` clean, `dmesg` diff and `pm-ground-truth.sh` saved as
   `/root/*-1.txt`, everything pulled to the workstation.

## Operator half (eyes, hands, UART)

The unattended half ran 2026-09-04 (results inline above and in
`doc/status.md`); the candidate on the device is **generation 15**
(347a7b1: the unattended half's two fixes on top of 14 — the notice
before the teardown, and the broker's stale settle deadline), and the
branch has since taken the tag-readiness review's userspace fixes
(bac9e4a: the deployer's own recovery path could abort under `set -e`
and orphaned its UART reader; the Wi-Fi script could start a second
supplicant over one that lost its interface; the broker's fallback
settle was measured from before the suspend). Those want a device too,
so the operator half now begins with a deploy. Open the book first: a
reader restart or boot lands in the library by design.

0. **Deploy the branch head as generation 16 with the UART attached**:
   `WILKBOOK_UART=/dev/ttyUSB0 make deploy DEVICE=pinenote-os2
   KEEP=8` from the branch. This is the first deploy ever to run the
   deployer's watcher path on glass (armed before the kexec, in its own
   process group, reaped after): expect the build to print
   `/gnu/store/8czi9ry1z0gph24n5yls7iiy83y4n0b8-system` (built from the
   branch head 2026-09-04 evening, `scratchpad/build-gen16.log`, kernel
   unchanged: `6rhnmj09…`), then the `== UART watcher armed on` line,
   the two device-tree notes, health, promote, generation 8 pruned —
   and afterwards `pgrep -f 'cat /dev/ttyUSB'` on the workstation must
   find nothing. Everything below is then on 16, the tag candidate.
   *Run 20:31 MDT: all of it as expected; the watcher's 32 kB capture of
   the trial kernel's boot console is in
   `doc/artifacts/pinenote-gen16-deploy-20260904/` (lossy — the raw
   `cat` drops bytes at 1.5 Mbaud; the menu-pick half of the watcher is
   still unexercised on glass).*
1. UART capture and the menu watcher armed before anything reboots.
2. **Visual pass on generation 15**: text edges on a real page,
   ghosting after twenty real turns, rotation flash in all four
   orientations. Patch 14's dither correction is **not on the reading
   route** (the reader draws Y4 through `default_hint=32`, no dither
   bit; the dithered route is hint 64 and FAST mode), so an ordinary
   page cannot show it. To look at it anyway: `rect-hints.lua --default
   64` for one screen of a grey gradient (the blue-noise pattern must
   not repeat every 16 pixels), then `--default 32` to restore. Optional.
3. Pen: strokes, fast scribble, erase, settling after pen-up.
4. Cover close and open; power button; suspend immediately after a turn
   and during pen activity (R5's hardware half). Then the bug the rig
   found, on the fixed broker: let the hourly backstop wake it (or set
   `backstop=60` in `autosuspend.conf` for the test), press the button
   to sleep it inside the settle window, wake it again with the button —
   it must stay awake.
5. **Cold boot with the UART** — *run 20:50 MDT: the watcher picked
   os2 in 8 s, ssh back in 41 s, generation 16 up with no kexec property
   and no GRF blacklist; capture in the artifacts directory* — `reboot`,
   the watcher picks os2, generation 16 boots cold — the tag candidate without a kexec in its
   lineage (patch 13's device-tree change is already proven live this
   way on generation 10; 15's tree is 14's, i.e. 10's plus nothing).
6. **The os1 rescue (#51)**: let a boot land on os1, run
   `rescue-generation.sh` (PR #51 — open against main, not in this
   tree, never run) `list` and `log` read-only, then `promote` of
   the already-promoted generation (a no-op), pick os2 at the menu,
   confirm the reader returns. Only then is it a recovery path.
7. R1 (clock reads local), R2 (open the manuals book, time the first
   open), R7 (leave it asleep overnight, panel intact in the morning).

## What the tag needs, in order

1. Unattended half green, with the notice fired and the rig's
   KOReader-initiated count no longer thin — **met 2026-09-04** (both
   notes shown on generation 15; 28 of the rig's 32 sleeps KOReader's
   own).
2. The adversarial review's blockers closed — **done** (B1 rebuilt as
   `6rhnmj09…`, B2 reworded; `doc/reviews/2026-09-04-adversarial-review.md`).
3. Operator half run, at least items 1–5 — **done** 2026-09-04
   evening: the generation-16 deploy with the watcher, page turns, pen,
   cover and button, all four rotations, the settle-window check of the
   broker fix (button sleep 7 s into the RTC wake's window, then a button
   wake that held — `suspend_stats` 5/0), and the cold boot of 16 with
   the menu picked by the watcher. Not run: #51, R1/R2/R7, the optics
   check; these stay in the CHANGELOG's known-broken list.
4. CHANGELOG, alpha-checklist, alpha-expectations, README's Status
   section, CLAUDE.md's "Where we are" and the kernel inventory true for
   the candidate — re-audited by review 2026-09-04 evening
   (`doc/status.md`), the blockers it found closed on the branch.
5. After the operator half: pull the two live-read artifacts from the
   device (`/root/turn-check.log`, the post-rig run, and a fresh
   `fb-damage-gates.sh` dump) into `doc/artifacts/`; set the date at
   both CHANGELOG placeholders in the branch's final commit; then the
   candidate merged to main through one PR, tagged `v0.3.0-prealpha` at
   the merge commit with the promoted generation's system path and
   kernel derivation in the tag message (`doc/release.md`), the tag
   pushed to both remotes.

Standing exclusions from this session, recorded so nobody expects them:
the audit's item 2 (probe/remove resource lifetime) is not in the
candidate; the optics-rig ghosting measurement needs the camera; the
watchdog reset-time discrepancy stays open.
