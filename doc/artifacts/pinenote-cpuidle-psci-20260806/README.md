# cpuidle on rk3566, and where the awake power actually goes (2026-08-06)

Two results, one of which closes a long-standing question.

1. **CPU idle-states work on rk3566 — and save 2.1 mA.** First cpuidle
   driver ever to register on this SoC, and it is not the awake-power
   lever anyone assumed.
2. **92% of the awake draw is an irreducible static floor.** Stripping the
   reader, the radio, the USB gadget and the display accounts for 14 mA of
   177.5. There is almost nothing to break down.

Together these end the awake-side optimisation question: schedule deep
sleep well, because nothing else on this board is worth much.

## 1. cpuidle: it works, it just doesn't matter

`pinenote/patches/linux-pinenote-7.0-cpuidle-psci.patch` adds an
`idle-states` node with Rockchip's own parameter from `rk3588s.dtsi`
(same Cortex-A55), `arm,psci-suspend-param = <0x0010000>` — StateID 0,
bit[16] PowerDown, affinity level 0.

**It registered and is used heavily:**

```
current_driver:   psci_idle      <- was "none" on BOTH slots, always
state0: WFI        latency=1us    residency=1us
state1: cpu-sleep  latency=220us  residency=1000us

cpu0: cpu-sleep 72.06% of wall     cpu2: cpu-sleep 55.98%
cpu1: cpu-sleep 70.10%             cpu3: cpu-sleep 31.19%
```

**And it changes nothing.** Same boot, same book, same frontlight, same
900 s window, toggling only `state1/disable`:

```
A: cpu-sleep ENABLED     172.7 mA    32,635 entries
B: cpu-sleep DISABLED    174.8 mA         0 entries
```

**2.1 mA, ~1.2% — noise.** The cores are genuinely powered down 31–72% of
wall time and total draw does not move. So **CPU core power is a
negligible share of this board's awake draw.** That is now measured, not
inferred.

No core ever failed to wake; all four stayed online across every run. The
firmware accepts the parameter and honours it.

## 2. Domain teardown: the floor is 92% of the total

Cumulative teardown, 300 s per stage, book open, frontlight 0, unplugged:

```
0 baseline (reader + book, wifi up)   177.5 mA   (baseline)
1 - KOReader stopped                  173.4 mA   delta  -4.1
2 - orientation bridge stopped        175.4 mA   delta  +2.0
3 - wlan0 down                        165.1 mA   delta -10.3
4 - usb gadget unbound                163.1 mA   delta  -2.0
5 - fbcon unbound + fb blanked        163.1 mA   delta  +0.0
```

| domain | cost | share of 177.5 |
|---|---|---|
| Wi-Fi | 10.3 mA | 5.8% |
| KOReader | 4.1 mA | 2.3% |
| USB gadget | 2.0 mA | 1.1% |
| orientation bridge | ~0 (the +2.0 is noise) | — |
| panel / fbcon | **0.0 mA** | 0% |
| **irreducible floor** | **163.1 mA** | **91.9%** |

Two details worth keeping:

- **The panel costs 0.0 mA.** Blanking fb0 and unbinding fbcon changed
  nothing: e-ink holds its image at zero power and an idle EBC drives
  nothing. The display really is free when static.
- **Wi-Fi's 10.3 mA (5.8%) independently reproduces the ~6% measured on
  2026-08-02** by a different method. Two methods agreeing is worth more
  than either alone.

Set against deep suspend at 20.6 mA: the **142 mA** between the awake
floor and suspend is rails and domains that suspend switches off and
Linux cannot reach while running.

## Corrections this run forced

- **The 205.7 mA "os2 awake baseline" from 2026-08-05 was inflated.**
  Phase B above — the pre-patch behaviour, WFI only — measured 174.8 mA,
  which is exactly the awake-idle figure recorded on 2026-08-02. The
  205.7 window was almost certainly taken too soon after boot, while
  KOReader and Wi-Fi were still settling. **The os1-vs-os2 comparison
  built on it (232.5 vs 205.7) should not be quoted**; os1's number may
  be inflated the same way and both want re-measuring with a settling
  period.
- **Same-boot back-to-back A/B is the trustworthy method.** Cross-boot
  single windows are not: they carry boot-to-boot variation and
  post-boot settling. Where a runtime toggle exists (`state1/disable`
  here), use it.

## Method notes, including two self-inflicted failures

- **Do not runtime-suspend the disk you are running from.** Stage 6 was
  `echo auto > .../fe310000.mmc/power/control` on the controller hosting
  the rootfs. It wedged the device and needed a PMIC long-press. The log
  stops cleanly after stage 5, which is how we know. Stages that only
  stop userspace or radios are recoverable; that one was not.
- **Do not drive a teardown over the link it tears down.** Stage 3 downs
  `wlan0`, which is the SSH path. The script is detached and writes each
  stage to disk as it goes, so nothing was lost — but visibility was, and
  `ip link set wlan0 up` at the end restores the link without
  reassociating, so it could not come back on its own either. Drive this
  from serial, or leave the radio for last.
- **`/tmp` on os2 is real ext4 and survives a reboot to os1.** That is
  how stages 0–5 were recovered after the wedge: boot os1, mount p6
  `ro,noload`, read. Booting os2 would have destroyed it (Guix wipes
  `/tmp` on its own boot).
- **`scaling_cur_freq` read over SSH is a lie** — it showed 1.8 GHz while
  the governor was idling the CPU, because the shell itself ramps it.
  Already recorded on 2026-08-02; re-encountered here. Use
  `time_in_state`.

## Where the remaining 163 mA plausibly lives

None of it is reachable by stopping software, so these are hardware
configuration questions rather than scheduling ones:

- **`vdd_cpu` sits at 1100–1150 mV in `fast` opmode** — forced PWM rather
  than auto/PFM. On the RK817 that is real quiescent draw at light load,
  and it is a regulator property, not a workload.
- **DDR frequency / DVFS** — no DMC driver in play (already on the
  after-everything list).
- **Always-on rails and peripheral clocks with no consumer** —
  `clk_summary` enable counts would identify them.

## Reproduce

`cpuidle-accept.sh` — does the driver register, is the state entered, do
all cores survive.  Note it does **not** measure power.
`cpuidle-ab.sh` — the same-boot A/B; the honest way to cost an idle state.
`domain-teardown.sh` — the attribution above. **Delete its stage 6 (mmc
runtime PM) before rerunning**, and drive it from serial.
`idle-drain.sh` — a single labelled window, for cross-slot comparisons.
