# Rung 3 `deep` on os2 — hard hang, no wake (2026-08-02)

Operator-authorised override of the "rung 2 must pass acceptance first"
rule, on the correct premise that **deep is already hardware-proven on
this device**: the os1 oracle ran a real deep cycle on 2026-08-01 (rc=0,
panel worked on glass, PG `0x00→0xfa`, VCOM `0x8f` survived a SLEEP
reset). So bl31, DDR retention and the rail path are known good. What was
untested was *our stack* across deep.

## Result: the device entered deep and never woke

The evidence file ends at the suspend write and nothing after it ever
ran:

```
[01:38:15] CONTROL PASS: 38 frames before any suspend
[01:38:17] post-blank: crtc_active=0 irq=1277
[01:38:21] gadget UDC blanked: []
[01:38:22] alarm armed=1785634761 now=1785634701 (+60s absolute epoch)
[01:38:22] --- RUNG 3: echo mem > /sys/power/state  (mode=deep)
```

`rung3.err` is **0 bytes** — no error was ever written. There is no
`dmesg-post.txt`, no `gates-post-resume.txt`, no `COMPLETE`. The `+60 s`
RTC alarm did not wake it; SSH never returned; the operator recovered by
power-cycling to os1.

Everything up to the suspend was healthy and is captured here: the
control probe painted 38 frames (one full pass) seconds earlier, VCOM
read `8f`, the CRTC blanked `1→0`, and the gadget was quiesced.

**Evidence survived the power cut** because Guix's `%base-file-systems`
declares no `/tmp`, so os2's `/tmp` is on the ext4 root, not a tmpfs. It
was recovered from os1 by mounting `/dev/mmcblk0p6` **read-only**
(`ro,noload`) and unmounted cleanly afterwards. Worth remembering: an
os2 hang is not an evidence loss.

## What this establishes

- **Deep is not a display problem.** It never reached resume, so none of
  the fbdev damage-path work is implicated.
- **The hardware and firmware are exonerated** by the os1 precedent on
  the same device, same bl31, same DDR.
- **The divergence is our kernel stack** (7.0.11 + our DT/defconfig +
  PREEMPT_RT) versus os1's 6.12 BSP kernel.

## Leading hypothesis (consistent with the design, not yet proven)

os1's BSP kernel configures the Rockchip platform suspend mode through
the BSP SIP call before entering deep; **our tree deliberately compiles
that out** — activation is hard-off, and the DT carries no
`rockchip-suspend` policy node at all (the production OF parser refuses
to bind any DT that does, and that refusal is forbidden-token-pinned).
So bl31 receives no suspend-mode configuration and no wake-source
arming, and PSCI `SYSTEM_SUSPEND` enters a state the RTC cannot bring
back.

If that is right, this run converts "activation may be required for
deep" from a design assumption into a **measured** one: deep provably
hangs without it. That is exactly what the dormant BSP SIP stack in
`doc/power-management.md` exists to supply, and it is the strongest
evidence yet for why. It does **not** authorise activation — the
reviewed active DT policy, real coordinator providers, and the
rail-kill wake-collision question are all still open.

Alternative explanations not excluded by this single run: RTC alarm not
actually armed in firmware across deep, a wake-source routing gap
(`vcc_3v3_pmu` feeds `pmuio1/2`, the GPIO0 bank carrying every external
wake), or a hang on the *entry* path that never reached a sleep state at
all. Distinguishing these needs a UART on the next attempt — this run
was console-free by protocol, which is why there is no entry trace.

## Standing consequence

**Do not retry deep console-free.** The console-free protocol works for
s2idle because it always came back; deep did not, so the only
observation channel left was on-disk evidence that stops at the suspend
write. A UART capture through entry is the minimum for the next attempt,
and the ladder rule should be read as "deep needs a console", not merely
"deep needs rung 2 green".

## Files

`ladder.log`, `ladder-deep.sh` (the exact script), `gates-pre.txt`,
`drm-pre/blanked.txt`, `gt-pre.txt`, `tps-pre.txt` (VCOM `8f`),
`dmesg-pre.txt`, `rung3.err` (empty).
