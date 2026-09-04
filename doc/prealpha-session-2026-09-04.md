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
   pruned). Record the built system path and confirm its kernel is the
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
3. **Page turns, camera-free.** Push `optics-inject.lua`, create
   `/run/optics-inject.fifo`, start it under `setsid`, wait for
   `/run/optics-inject.pid`; `herd stop reader-session`, `herd start
   reader-session` so KOReader enumerates the injector; forty `KEY 158`
   turns three seconds apart, the EBC IRQ delta per turn logged; then
   `QUIT` and confirm the uinput device is gone. Verdicts: thread count
   still 2, `dmesg` diff clean of `WARNING:`, `workqueue lockup`,
   `Unbalanced pm_runtime`, `rockchip.ebc.*error`.
4. **Driver rebind ×5.** With `reader-session` stopped:
   `echo fdec0000.ebc > /sys/bus/platform/drivers/rockchip-ebc/unbind`,
   then `bind`, verify `.../fdec0000.ebc/drm/card*` exists, record
   thread count, `VmallocUsed`, `runtime_status` after each cycle. The
   signal is accumulation across cycles (the audit's item 2 is the
   failed-probe path, which a clean rebind does not take; this is the
   regression guard for what the rebind does take). Restart the reader.
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
   teardown, pinned); the proof of the notice is a trial from the fixed
   generation, not from 14.*
6. **Suspend rig, KOReader path weighted.** `wifi-cycle.sh koreader-idle
   120`, then `wifi-cycle-host.sh 15 45 300` (settle 300 s so KOReader's
   idle timer wins every cycle), then `koreader-idle 900`. Verdicts from
   the device report: `koreader-initiated` should now be most of the
   transactions; `on pid=` and `associated within` counts equal; zero
   `Wi-Fi restore failed`; cyttsp5 `Validation of the wakeup response
   failed` count over `PM: suspend entry` count (R6); no `rxctl`/`attach
   failed`.
7. **R3 and R4 over SSH.** SNTP: the timesync daemon's log shows one
   sync after association and the `wakealarm` readback survives it
   (R3). Profile: the seeded settings present, fonts present (R4).
8. **Wrap-up.** `autosuspend.conf` back to `enabled=1`, reader running,
   `health` clean, `dmesg` diff and `pm-ground-truth.sh` saved as
   `/root/*-1.txt`, everything pulled to the workstation.

## Operator half (eyes, hands, UART)

1. UART capture and the menu watcher armed before anything reboots.
2. **Visual pass on generation 14**: the 32×32 dither on a grey image
   or gradient (patch 14's second-half load: the blue-noise pattern must
   not repeat every 16 pixels), text edges on a real page, ghosting
   after twenty real turns, rotation flash in all four orientations.
3. Pen: strokes, fast scribble, erase, settling after pen-up.
4. Cover close and open; power button; suspend immediately after a turn
   and during pen activity (R5's hardware half).
5. **Cold boot with the UART**: `reboot`, the watcher picks os2,
   generation 14 boots cold — the only proof a device-tree change is
   live (patch 13 is already proven this way on generation 10).
6. **The os1 rescue (#51)**: let a boot land on os1, run
   `rescue-generation.sh list` and `log` read-only, then `promote` of
   the already-promoted generation (a no-op), pick os2 at the menu,
   confirm the reader returns. Only then is it a recovery path.
7. R1 (clock reads local), R2 (open the manuals book, time the first
   open), R7 (leave it asleep overnight, panel intact in the morning).

## What the tag needs, in order

1. Unattended half green, with the notice fired and the rig's
   KOReader-initiated count no longer thin.
2. The adversarial review's blockers closed.
3. Operator half run, at least items 1–5.
4. CHANGELOG, alpha-checklist and alpha-expectations true for the
   candidate (branch `prealpha-docs`).
5. The candidate merged to main through one PR, tagged
   `v0.3.0-prealpha` at the merge commit, the tag pushed to both remotes.

Standing exclusions from this session, recorded so nobody expects them:
the audit's item 2 (probe/remove resource lifetime) is not in the
candidate; the optics-rig ghosting measurement needs the camera; the
watchdog reset-time discrepancy stays open.
