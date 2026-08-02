# Deep suspend WORKS — 2026-08-02

**Rung 3 PASS.** Platform `deep` suspend enters and resumes on the wilkbook
stack for the first time. Image
`d604ff98d454a5cd89c230363cace1eaf785b71ccfbbae0be03db7de477f78af`, system
`p4mpqkidq9g8ppdx0mfb9iadf44wpzz2-system`, kernel 7.0.11 + PREEMPT_RT.

## Result

```
[19:39:45] --- RUNG 3: echo mem > /sys/power/state  (mode=deep)
[19:40:50] RESUMED rc=0 asleep=60s
VERDICT control=46 A(blanked)=46 B(unblanked)=46 C(ioctl)=1 D(after-ioctl)=46
TPS VCOM pre=8f post=8f
```

Woke on the armed RTC alarm at +60 s. Every display probe painted a full
46-frame pass with `fb-rows-changed=120/120`; the `C(ioctl)=1` is a global
refresh, which costs exactly 1 IRQ by design.

## The fix, at the firmware boundary

2026-08-02, before activation — hung forever, never woke:

```
PM-STATE: mem (ultra: 0, mem: 1, cfg: 0x0), pmic: 0x14, 0x25
```

2026-08-02, after activation — same device, same firmware:

```
v2.3():v2.3-210-g4af361e4c:zwx
PM-STATE: mem (ultra: 0, mem: 1, cfg: 0x5ec), pmic: 0x14, 0x25
abcdeghij7
I/TC: Secondary CPU 1 initializing
I/TC: Secondary CPU 1 switching to normal world boot
[ 1459.950183] Restarting tasks: Starting
[ 1459.952490] PM: suspend exit
```

`cfg` is now `0x5ec` — the value measured from os1's booted DTB, delivered
through DT → parser → activation driver → `arm_smccc_smc(SUSPEND_MODE_CONFIG…)`.
The whole chain is evidence-backed end to end: values measured from a
working kernel, emitted sequence differentially verified against the BSP
emitter, and now firmware-accepted.

## Two independent proofs this was a *real* power-down

1. **The kernel monotonic clock froze.** Entry `[1458.872226]`, exit
   `[1459.952490]` — **1.08 s of kernel time across 60 s of wall time**,
   because the SoC lost power and the timer stopped. In every s2idle run
   the two matched exactly (45 s ↔ 45 s). Do not misread the short kernel
   delta as an early wake; it is the signature of success.
2. **OP-TEE re-initialised secondary CPUs on resume** (`I/TC: Secondary
   CPU 1 initializing`). The cores were genuinely off.

## Also confirmed

- **VCOM survived a real SLEEP reset**: `03: 8f` before and after,
  matching the 2026-08-01 os1 oracle finding at the strongest level.
- **The display is fully functional after resume** at both blanked and
  unblanked CRTC states — no dead-write window, no recovery needed.
- **The reader restored cleanly** (`herd start reader-session`, 1351 EBC
  IRQs, healthy).
- **No regression on the normal path** from activation being live.

## Open, and deliberately not claimed

- **Battery life is unmeasured.** A 60 s dwell proves the mechanism, not
  the multi-day standby target. That needs a long-dwell measurement under
  equivalent conditions (`doc/power-management.md` already requires
  comparing repeated intervals before any battery claim).
- **Only the RTC wake source is proven.** Power button, cover switch, and
  Wi-Fi wake are untested under `wakeup-config = <0x10>`.
- **TPS65185 `ENABLE` moved `2f → 20`** across the cycle — EBC rails down
  and *not* restored by our PM pair. The display works because runtime PM
  brings them back on demand, so this is not a defect on the evidence, but
  it is a difference from os1 (whose 6.12 driver rewrote `ENABLE` on
  resume) and is worth understanding before trusting long dwells.
- **Ultra-suspend remains unadopted.** This is baseline deep only; the
  rail-kill wake collision is untouched.
- One cycle. Repeat before treating it as reliable.

## Files

`ladder.log`, `ladder-deep.sh`, `uart-deep-trace.log` (the firmware
handoff), `gates-*.txt`, `drm-*.txt`, `gt-pre/post.txt`, `tps-pre/post.txt`,
`dmesg-pre/post.txt`.

---

# Reliability run — 5 cycles, and a real defect found

**Deep suspend is reliable: 5/5 cycles PASS**, dwells 30/30/30/30/120 s.
Every cycle: `rc=0`, wall time matched the armed dwell, the display painted
a full 46-frame pass with `fb-rows-changed=120/120`, and VCOM held at `8f`.

| cycle | dwell | wall | printk delta |
| --- | --- | --- | --- |
| 1 | 30 s | 30 s | 1.10 s |
| 2 | 30 s | 30 s | 1.09 s |
| 3 | 30 s | 30 s | 1.10 s |
| 4 | 30 s | 30 s | 1.09 s |
| 5 | **120 s** | 120 s | **1.09 s** |

The printk delta stays ~1.1 s regardless of dwell — the SoC powered down
every time, including the 2-minute one.

## Instrument trap: `/proc/uptime` is the WRONG clock for this

The harness first scored all five as FAIL, reporting `kernel ≈ wall` and
therefore "not a real deep". That was the harness, not the device:

- **`/proc/uptime` uses `ktime_get_boottime()`, which INCLUDES suspended
  time.** It can never show the freeze, so it always looks like nothing
  happened.
- **printk timestamps use `sched_clock`, which STOPS across suspend.** So
  does `CLOCK_MONOTONIC` (as opposed to `CLOCK_BOOTTIME`).

Use printk timestamps or `CLOCK_MONOTONIC`. This is the third instrument
trap in this program — after `dd`-vs-`mmap` damage and global-vs-partial
IRQ units — and the same lesson each time: **a measurement that contradicts
a working system is the measurement's fault until proven otherwise.**

## Defect found: SC7A20 accelerometer dies on deep resume

~28 s after the first deep resume:

```
[1493.636415] irq 71: nobody cared (try booting with the "irqpoll" option)
CPU: 0 UID: 0 PID: 186 Comm: irq/71-sc7a20-t Not tainted 7.0.11 #1 PREEMPT_{RT,LAZY}
Call trace:
 ... rockchip_irq_demux ... handle_level_irq ... irq_thread_fn
```

IRQ 71 is `sc7a20-trigger`, level-triggered on `rockchip_gpio_irq`. Across
deep the accelerometer loses the state that keeps its interrupt line
de-asserted; the handler cannot clear it, the line stays asserted, and the
kernel's spurious-IRQ protection disables the IRQ after ~100 k unhandled
events. Measured after: **rate 0/s** — the storm is over precisely because
the IRQ is now dead.

**Product impact: autorotation stops working after the first deep sleep,
until reboot.** Reading itself is unaffected — the reader, panel, touch and
pen are fine, and the disabled IRQ means no ongoing power drain. But for a
device meant to match commercial e-readers, orientation silently dying
after the first sleep is exactly the kind of regression that matters.

This is the **already-documented** `SC7A20 accelerometer resume` blocker
from `doc/power-management.md` (added 2026-08-01, noting hrdl's own
`v6.19_iio_accel` attempt is unfinished) — now reproduced on hardware with
a concrete signature rather than an anticipated risk. It is the next thing
to fix, and it is a *resume-init* problem: the driver needs to
re-initialise the device and clear/re-arm the interrupt on resume.

## Standing status after this session

- `deep` enters, sleeps, and resumes reliably (5/5, up to 120 s).
- Display, VCOM, reader all survive.
- Accelerometer does not. Fix before treating suspend as shippable.
- Battery life still unmeasured; only the RTC wake source proven.
