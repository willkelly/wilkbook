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

## Attempt 2, with UART: the hypothesis is now measured

The second attempt ran with `console_suspend=N` and a live UART capture
at 1500000 (see "UART actually works" below). It hung identically — no
wake at +60 s, SSH dead, 200 s of silence — but this time the handoff was
captured (`uart-deep-entry-trace.log`):

```
[  439.643831] PM: suspend entry (deep)
[  439.648839] Freezing user space processes
[  439.651652] Freezing remaining freezable tasks completed (elapsed 0.001 seconds)
v2.3():v2.3-210-g4af361e4c:zwx
PM-STATE: mem (ultra: 0, mem: 1, cfg: 0x0), pmic: 0x14, 0x25
abcdeghij7
```

The last three lines are **bl31, not Linux** — the Rockchip BSP ATF
version banner, its own suspend-state report, and its per-stage progress
trace. So Linux hands off cleanly and the firmware is reached and runs
its sequence.

**`cfg: 0x0` is the finding.** bl31 reports its suspend configuration
word as zero: Linux sent it no suspend-mode configuration and no
wake-source arming, which is exactly what our tree does on purpose
(activation hard-off, no `rockchip-suspend` DT node, zero SIP calls).
bl31 powers the system down with nothing armed to bring it back.
`ultra: 0, mem: 1` confirms standard mem, not the ultra path.

This is firmware-sourced evidence, not inference. It does **not**
authorise activation — the reviewed active DT policy, real coordinator
providers, and the rail-kill wake-collision question all remain open —
but it removes the doubt about *why* deep hangs on our stack.

**Gap to close next time**: the trace jumps from freezing straight to
bl31, with no `PM: suspend devices took` or `Disabling non-boot CPUs`.
Runtime `console_suspend=N` stops *console* suspension but evidently not
the 8250 port's own `dev_pm_ops`; `no_console_suspend` on the kernel
command line is the documented way to hold the port up, and is now in
`pinenote-kernel-arguments`.

## Original leading hypothesis (now confirmed above)

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

Alternatives that attempt 1 could not exclude — and how attempt 2
resolved them: a hang on the *entry* path that never reached a sleep
state is **excluded** (bl31 was reached and ran its full sequence); the
suspend-mode/wake-arming gap is **confirmed** (`cfg: 0x0`). Still not
excluded: whether the RTC alarm would have been honoured had the
configuration been sent, and the wake-source routing question
(`vcc_3v3_pmu` feeds `pmuio1/2`, the GPIO0 bank carrying every external
wake). Both are downstream of the configuration gap and cannot be tested
until it is closed.

## Standing consequence

**Do not retry deep console-free.** Attempt 1 was console-free and its
on-disk evidence stops dead at the suspend write; attempt 2 with UART
produced the firmware trace that actually answered the question. The
ladder rule should be read as "deep needs a console", not merely "deep
needs rung 2 green" — and UART is now known to work, so there is no
excuse not to have one.

## Files

`ladder.log`, `ladder-deep.sh` (the exact script), `gates-pre.txt`,
`drm-pre/blanked.txt`, `gt-pre.txt`, `tps-pre.txt` (VCOM `8f`),
`dmesg-pre.txt`, `rung3.err` (empty).

## UART actually works — the console-free premise was false

`doc/power-management.md` recorded that "the USB-C serial cable
demonstrably receives nothing from ttyS2", and the whole console-free
protocol was built on it. **That is wrong**, and it was a test artifact.

Validated 2026-08-02, both directions, at 1500000 8N1:

```
HIRATE-ECHO-9876543210            <- direct write to /dev/ttyS2, x3
[  263.976407] HIRATE-KMSG-5555   <- kernel printk console, with timestamps
```

Two things defeated every earlier attempt:

1. **The device-side `/dev/ttyS2` termios defaults to 9600**, and on an
   8250 the console shares the port's divisor — so console output was
   leaving the device at 9600 while the host listened at 1500000. A
   marker written from the device arrives cleanly at 9600 with no other
   change. Set `stty -F /dev/ttyS2 1500000` on the device (agetty runs
   `--keep-baud`, so it will not stomp it).
2. **Every earlier test was a passive listen after boot**, when the
   console is idle. That cannot distinguish a dead cable from a quiet
   one. The test that works is a *controlled transmit*: write a known
   marker from the device and sweep the host baud rate.

Method worth reusing: sweep host bauds while the device repeatedly
transmits a distinctive marker, and grep for it. The 9600 hit was
unambiguous (3 markers sent, 3 received) where every passive capture had
produced only runs of `0x00` — a line held low, which reads as "broken
cable" and is not.

**Consequence**: the console-free protocol is no longer a necessity, only
an option. Deep in particular must never be retried without UART, since
its failure mode is a hang with no on-disk record past the suspend write.
