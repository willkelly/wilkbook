# Cover wake, attributed to an IRQ (2026-08-15)

**The cover wakes the device through GPIO0, and we can now name the
interrupt.** This closes the observation open since 2026-08-09
(`doc/power-management.md`, "Open question: the cover wakes it, and it
should not") from anecdote to hardware attribution.

Device: author's PineNote, os2, image `9a08803e…`. Operator at the
device; agent reading over SSH. No UART, no reboot, no writes.

## Method

A paired A/B, each round a real suspend confirmed by
`/sys/power/suspend_stats/success` incrementing, with
`/sys/power/pm_wakeup_irq` read immediately after resume.
`pm_wakeup_irq` names the interrupt that ended the last suspend.

| round | suspended by | woken by | `suspend_success` | `pm_wakeup_irq` |
|---|---|---|---|---|
| baseline | — | — | 170 | 30 |
| 1 (control) | power button | power button | **171** | **30** |
| 2 | **cover close** | **cover open** | **172** | **63** |

```
30:  rockchip_gpio_irq   3 Level  rk817     <- PMIC: pwrkey, RTC, charger
63:  rockchip_gpio_irq  23 Edge   cover
```

IRQ 63 is labelled `cover` by the kernel, on hwirq **23** = `gpio0`
pin 23 = **RK_PC7**, matching the live DT
(`/proc/device-tree/gpio-keys/switch-cover/gpios` = phandle, `23`,
`ACTIVE_LOW`) and matching what this repo has always said the cover is
wired to.

Round 2's sleep was ~8 s (`resumed after 8s` in the daemon log,
preceded by `cover closed -- suspending on request`), so the hourly RTC
backstop cannot account for it — and would have reported IRQ 30 in any
case.

## What this settles

**The rails model is incomplete, and now demonstrably so.** GPIO0's pad
supply is `pmuio1`/`pmuio2` ← `vcc_3v3_pmu` (LDO_REG6), which the
production configuration marks `regulator-off-in-suspend`, and bl31's
banner confirms the rails reach the PMIC (`pmic: 0x14, 0x00`). A pad on
a dead supply should not deliver an edge. It did.

Of the candidates in `doc/power-management.md`, this leaves **1** (the
rail does not actually drop) and **2** (the PMU wake detector is not on
the pad supply — GPIO0 is the PMU bank and `RKPM_SLP_PMUALIVE_32K` is
set in `cfg 0x5ec`, so alive-domain logic may see a level change with
the IO supply down). Candidate 2 fits without requiring the measured
4.64 mA to be wrong.

**Candidate 4 is refuted.** "Measurement artifact — the backstop woke it
earlier and e-ink retained the image" was added to that document earlier
the same day, on the reasoning that the 2026-08-09 observation carried
no artifact directory and no log check. It does not survive an 8-second
sleep with a named, cover-labelled IRQ. Removed rather than left
standing.

## A control that earned its place

Round 1 was run to validate the instrument before trusting it, and it
immediately falsified a working assumption: **`gpio-keys` incremented on
a power-button wake** (189 → 190), so it does not count cover
actuations.

| | `suspend_success` | `gpio-keys` | difference |
|---|---|---|---|
| baseline | 170 | 189 | 19 |
| after round 1 | 171 | 190 | 19 |

It increments exactly once per suspend/resume cycle — the driver
re-reading `SW_LID` on resume — with a constant offset. An earlier
reading of the same counter as "the cover actuated 189 times in six
days, against 2 daemon-actioned closes" was therefore **wrong**; about
170 of those are resumes, leaving ~19 real actuations, which sits
comfortably beside 2. `pm_wakeup_irq`, not the wakeup counters, is the
discriminator that works.

## Consequence for the pen (issue #9)

The standing reason the pen cannot be a wake source is that GPIO0 is
unpowered in suspend. **That premise is now known to be wrong for at
least one GPIO0 pin.** The pen is `gpio0 RK_PB5` and its node carries no
`wakeup-source` (confirmed live: `/proc/device-tree/spi-gpio/bluetooth@0`
has no such property, and `ws8100_pen` shows `wakeup=0`). Whether
RK_PB5 behaves like RK_PC7 is untested — but it is now a question worth
testing rather than one closed by the model.

## Not established

- **Why** the edge is delivered. Candidates 1 and 2 are both live; this
  measured the effect, not the mechanism.
- Whether `vcc_3v3_pmu` actually drops. Reading it from
  `/sys/class/regulator` post-resume cannot answer that — sysfs reports
  the restored runtime state.
- Whether every GPIO0 pin behaves this way, or only RK_PC7.
- Round 2 deviated from the plan: the operator suspended via the cover
  rather than the power button, so it is a cover→cover cycle rather
  than button→cover. That strengthens the wake attribution (the wake
  leg is what mattered) but means no button-suspend/cover-wake pairing
  was taken.
