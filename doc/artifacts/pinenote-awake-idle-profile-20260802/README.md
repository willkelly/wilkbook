# Awake-idle power breakdown — 2026-08-02

**Conclusion: awake-idle is a platform floor (~172 mA), not a leak. There
is nothing to micro-optimise. The lever is aggressive auto-suspend.**

## Measurements

| state | draw |
| --- | --- |
| awake idle, Wi-Fi up | 174.8 mA (900 s A/B) / 182.8 mA (480 s) |
| awake idle, Wi-Fi **down** | 171.6 mA |
| **Wi-Fi share** | **11.2 mA — 6 %** |
| deep suspend | 19.3 mA |

All with reader stopped, fbcon unbound, panel blanked, gadget quiesced,
charger offline.

## Where the power is not going

- **Not the CPU.** Over a 60 s detached window the CPUs were **98.9 % idle**
  (`idle=23736` of ~24000 jiffies; `user=118 sys=83`).
- **Not cpufreq.** `time_in_state` shows **96.4 % at 408 MHz**, the minimum.
  A live `scaling_cur_freq` read over ssh shows 1.8 GHz — that is the
  governor reacting to the ssh session itself. Measure detached.
- **Not Wi-Fi.** 6 %. Taking `wlan0` down drops SDIO interrupts from 25/s
  to 0/s and saves 11.2 mA.
- **Not the accelerometer.** Already at 1 Hz.

## Wakeups (60 s, detached)

```
179.4/s  arch_timer
 57.2/s  IPI5 IRQ work
 56.0/s  IPI0 Rescheduling
 44.1/s  fdd40000.i2c   (= i2c-0: rk817 PMIC + tcs4525 regulator)
 31.7/s  dw-mci         (SDIO/Wi-Fi)
```

`NO_HZ_IDLE=y`, `HZ=1000`. The i2c traffic is PMIC/regulator polling, not
the accelerometer.

## Why the floor exists

**Neither mainline nor the vendor defines CPU idle states for RK356x.**

- `arch/arm64/boot/dts/rockchip/rk356x-base.dtsi` (7.0.11) has
  `enable-method = "psci"` and a PSCI 1.0 node, but **no `idle-states`**
  and no `cpu-idle-states` property.
- **os1's booted BSP DTB has none either** — checked directly in the
  decompiled DT.

So `/sys/devices/system/cpu/cpu0/cpuidle/` does not exist and the current
driver is `none`: the cores only ever WFI, with the cluster powered and
clocked. Every one of those ~370 wakeups/s lands on a core that has no
low-power state to return to.

This is **not** something our tree removed. Our suspend gate forbids
`idle-states` in the DT, but upstream never provided them.

## What this means

The platform's power strategy is **suspend-based, not idle-based** — which
is exactly why os1 auto-deep-suspends on idle and why its battery lasts.
Chasing awake-idle would mean inventing PSCI idle-state parameters and
proving the firmware honours them: speculative, and bounded above by ~172
mA of SoC+DDR floor anyway.

Arithmetic that settles the priority, from a 4000 mAh charge:

| policy | daily draw | per charge |
| --- | --- | --- |
| never suspends | 24 h x 175 mA = 4200 mAh | **< 1 day** |
| 1 h use + 23 h deep | 175 + 23 x 19.3 = 619 mAh | **~6.5 days** |

**Auto-suspend is worth ~7x. Every other lever here is worth single-digit
percent.** That is the next piece of work, and it is userland policy
(idle detection, wake sources, resume-to-reading), not kernel tuning.
