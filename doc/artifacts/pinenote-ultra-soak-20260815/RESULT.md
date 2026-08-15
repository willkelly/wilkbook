# Ultra-suspend soak — 6.17 days unplugged, measured (2026-08-15)

**The end-to-end standby measurement.** `doc/alpha-checklist.md` §4 says
alpha "may ship a disappointing number. It may not ship an unmeasured
one." This is the number.

Device: author's PineNote, os2 (`/dev/mmcblk0p6`), `pinenote-reader`,
Linux 7.0.11 `PREEMPT_RT`. Image: the promoted ultra build (`9a08803e…`).
Harvested read-only over SSH; nothing on the device was written or
restarted, and the soak was still running at harvest.

## Headline

| | |
|---|---|
| Window | 2026-08-08 23:57:41 → 2026-08-15 04:01:04 UTC (**148.1 h, 6.17 d**) |
| Suspend cycles | **170 success, 0 fail** (`/sys/power/suspend_stats`) |
| Charge consumed | 3,848,844 → 2,358,464 µAh = **1490.4 mAh** |
| **Idle standby** | **5.47 mA median** (119 backstop segments; mean 5.50, range 4.46–13.09) |
| **Overall, as actually used** | **10.07 mA** — includes the operator's real reading |
| Projected from 4000 mAh | **30.5 days** idle standby · **16.6 days** as used |

Never plugged in: **zero** charge increases across 170 samples, so the
gauge series is monotonic and no charger event contaminates it.

## What this confirms, and what it corrects

**Ultra suspend is reliable.** 170 consecutive suspend/resume cycles with
zero failures over six days, unattended. That is the property the R10/R11
work was chasing and R12 demonstrated three times; this extends it by two
orders of magnitude in sample count.

**The projection was pessimistic, and the arithmetic can be retired.**
R12 measured 4.64 mA over a 40-minute bracket containing no backstop
wake, and `doc/power-management.md` reasoned from it to "~36 days of pure
suspend; with backstop-wake overhead, roughly ~28 effective". Measured
idle standby is **5.47 mA → 30.5 days**, so:

- the hourly RTC backstop costs **5.47 − 4.64 ≈ 0.83 mA**, i.e. ~0.83 mAh
  per wake — noticeably cheaper than the ~1.3 mAh/wake the 36→28
  estimate implied. The post-`626cb02` behaviour (a backstop wake
  re-suspends after a ~20 s settle instead of burning a fresh idle
  period) is doing its job;
- **the >30-day desired outcome is met on measurement, not on paper** —
  but only just, and only for a device that is not being read.

**Reading is the dominant term, and it roughly halves the figure.**
Idle standby projects 30.5 days; the same device *as actually used* over
these six days projects 16.6 days. The gap is ~4.6 mA of average draw
from awake time. Against the 156.9 mA awake floor that implies roughly a
3 % awake duty cycle — order of 40 minutes of reading per day. Treat that
duty figure as indicative: it assumes the awake floor, and real reading
(page turns, frontlight) draws more.

**So quote two numbers, not one.** "Suspend >30 days" is defensible for
suspend. It is not what a reader who actually reads will observe.

## Detail worth keeping

From the 170-resume log:

- **132 of 170 sleeps were backstop-length** (3596–3597 s), i.e. the
  device spent most of the window idle and self-managing.
- **27 power taps** requested suspend manually, and **4 more taps were
  correctly ignored inside the 2 s post-resume grace** — the guard that
  stops the wake press from immediately re-suspending is firing in the
  field, not just in the harness.
- **2 cover-close suspends** in six days. Set against 27 power taps, that
  quantifies what `doc/alpha-expectations.md` describes qualitatively as
  a fussy magnetic switch: the cover works, and it is not what anyone
  actually uses.
- **3 × `EBC still active after ~10s wait -- proceeding anyway`.** The
  idle gate timed out three times and suspended regardless. No suspend
  failed, so this cost nothing here, but it is the loud-not-silent
  logging `dmc.scm` argues for, and it is the one line in this log that
  deserves follow-up.

## What this does not prove

- Nothing about a device that is **charging**, or about the gauge's
  accuracy in absolute terms — this is a delta between two `charge_now`
  readings from the same gauge, which is the right way to use it, but it
  inherits whatever systematic error the gauge has.
- Nothing about **cold storage** (weeks untouched); the longest single
  observation here is one backstop hour.
- The **13.09 mA outlier** among idle segments is unexplained. Median
  5.47 and mean 5.50 are tight, so it is one segment, not a trend — but
  it was not investigated.
- The device was **not** at 100 % when the window opened
  (3,848,844 of 4,000,000 µAh ≈ 96 %), so the day figures are
  projections from the measured rate, not an observed run to empty.
