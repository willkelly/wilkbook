# Auto-suspend soak — 2026-08-03, and why charging must inhibit it

Ran the deployed daemon unattended for ~12 minutes at `idle=60
backstop=240`, **with the charger plugged in**.

## Reliability: good

**8 suspend/resume cycles, all clean.** The service was still running
afterwards, the reader survived, charging continued normally (91% → 95%
across the soak), and `dmesg` gained no hazard lines — the only two
matches are the benign boot banners (`ignoring loglevel`, XFS's "no debug
enabled"). No wedge, no poison, no stuck thread.

That closes the "never soaked unattended" gap for the mechanism itself.

## But every sleep aborted after 5 seconds

```
      7 resumed after 5s
      1 resumed after 6s
```

`PM: suspend exit` lines are exactly 65 s apart — 60 s idle plus ~5 s
asleep — so the device was suspending correctly and being woken almost
immediately, over and over.

**The RTC is not the cause.** Checked live mid-soak: `since_epoch
1785724651`, `wakealarm 1785724871` — correctly 220 s in the future, as
armed. The arithmetic is right.

**The charger is.** The correlation is clean and spans the whole day:

| state | sleep durations |
| --- | --- |
| unplugged (all earlier testing) | 45 s, 60 s, 120 s, 2700 s — every one exact |
| plugged in (this soak) | 5–6 s, every time, 8/8 |

Every deep cycle before today's soak ran with `rk817-charger online=0`
(the battery A/B asserted it explicitly, and the pack was discharging all
session). The one thing that changed is external power.

## Why this matters more than convenience

Auto-suspending while charging is not merely pointless, it is **actively
harmful**: the device thrashes, suspending and resuming every 65 s
forever. Each cycle costs a resume, a display refresh and a Wi-Fi
re-association — plausibly *more* energy than simply staying awake, and it
makes the device unreachable in the gaps for no benefit.

So `suspend-while-charging?` defaulting to **#f** is required behaviour,
not a nicety. Will called this before we had the evidence; the soak found
the mechanism behind it.

## Not yet isolated

The correlation is strong but the *mechanism* is not pinned — we have not
identified which PMIC event fires. `/sys/kernel/debug/wakeup_sources`
counters did not climb (all read 1, stale from boot), so whatever wakes it
is not attributed there. The clean confirmation is to unplug and re-run
the identical soak; that is a 15-minute test whenever the UART cable is
back in the port.
