# PineNote power management: evidence first

This document defines the first, **read-only** power-management slice.  It is
instrumentation discovery, not a suspend policy, battery-life estimate, or a
claim about final4's idle drain.  The companion `pinenote/tools/power` Guile
tool emits versioned S-expressions on stdout, accepts a fake root for offline tests, and
only reads an explicit allowlist.  It never reads waveform or VCOM calibration
data and never writes sysfs, procfs, debugfs, or tracefs.

## Safe measurement boundary

The five evidence domains stay separate:

1. **Awake idle:** snapshot after a stable, specified workload; compare CPU,
   IRQ, runtime-PM, wake-source, and gauge counters.
2. **Reader/display activity:** bracket known page turns or refresh intervals;
   do not infer panel energy from counters alone.
3. **Suspend/resume:** capture before/after evidence and console signatures.
   The first actual suspend remains outside this slice.
4. **Wake attribution:** compare named wakeup-source and IRQ counters, then
   confirm suspected wakes on a human-observed UART session.
5. **Gauge accuracy:** compare a future exposed gauge against controlled charge
   state over time; percentage alone is not a battery-life measurement.

Read-only snapshots and deltas are safe over SSH because they neither change
runtime PM nor request suspend.  Any suspend/resume, wake-policy experiment,
trace enablement, radio/service change, or power-cycle needs a human on UART.
The recorder opens no output files; save stdout with trusted host-side shell
redirection. Reports include MAC addresses, selected process command lines,
and mount information, so keep them outside the repository (normally under
`/tmp/opencode`) and sanitize them before sharing.

## E-reader suspend contract

The production target is suspend-to-RAM with appliance behavior, not merely a
successful `echo mem`. Linux `freeze` is suspend-to-idle; `s2idle` names that
same system-suspend mode, while `deep` is the platform suspend mode. Only a
measured `deep` result can support a multi-day battery target. The current
product verdict remains **unsupported**: the exact disabled
`suspend_policy.lua` is bound to `device.lua`'s sole `canSuspend` field, there
is no idle or cover-triggered autosuspend, and no unsupervised code may write
`/sys/power/state`.

The eventual suspend operation needs one serialized transaction, but the
current EBC path makes its static sleep-screen phase explicitly unavailable:

1. Inhibit new page turns, refresh-policy work, and duplicate power/cover
   requests. A held wake key must not become an immediate post-resume action.
2. Ask KOReader to persist reading position, annotations, settings, and document
   sidecars through its normal save path; fail visibly if the checkpoint fails.
3. A future EBC contract must retain caller-painted content or atomically accept
   off-screen content and report refresh completion. The current `rockchip_ebc`
   disable path overwrites the panel with `off_screen` (normally the
   white/default buffer) and exposes no userspace refresh-completion contract;
   therefore a static sleep cover is blocked and this transaction is not
   currently implementable.
4. Park idlewasher/deep-clean timers and finish or cancel any pending waveform
   restoration. Save both frontlight channels and set both to zero.
5. Save whether networking was enabled, stop reconnect activity, disable Wi-Fi,
   and require it to be down. Do not enable wake-on-network. Initial deep-sleep
   qualification refuses USB-data and charging cases rather than combining
   them with the first suspend result.
6. Flush storage, capture the pre-suspend evidence record, select exactly one
   test mode, and request suspend once.
7. On resume, identify the wake source, quarantine the triggering input frame,
   validate storage/input/orientation/EBC health, and force one full EBC refresh
   before restoring frontlight. Wi-Fi restoration is stateful and asynchronous;
   reading must never wait for association or DHCP.
8. Capture post-resume evidence. An early wake, failed phase, missing refresh,
   or invalid service state leaves the reader visibly awake, disables suspend
   for the rest of that boot, and records the failure. Automatic retry is
   bounded; the initial hardware campaign performs no automatic retry at all.

This follows the public cross-reader pattern, with platform-specific ownership:
Kindle delegates screensaver, Hall/button events, and delayed hibernation to
Amazon's `powerd`; Kobo saves state, paints, disables Wi-Fi/frontlight, uses
`wakeup_count`, and bounds unexpected-wake retries; reMarkable leaves suspend
to `xochitl` where that service owns the platform; and PocketBook delegates
sleep/power-off to InkView. These are verified open-source integration
behaviors, not vendor current or resume-latency measurements. E Ink's
bistability lets the front plane retain an image without continuous power, but
does not power down the controller, framebuffer, CPU, inputs, radio, or light.
Relevant references are E Ink's
[front-plane description](https://www.eink.com/tech/detail/How_it_works), Linux's
[sleep-state contract](https://docs.kernel.org/admin-guide/pm/sleep-states.html),
[device wake policy](https://docs.kernel.org/driver-api/pm/devices.html#sys-devices-power-wakeup-files),
KOReader's [generic suspend transaction](https://github.com/koreader/koreader/blob/d542cee1044c198945651e8230f7fd3d0bea64c8/frontend/device/generic/device.lua#L456-L491),
its [Kobo wake guard](https://github.com/koreader/koreader/blob/dab8e448f3425010f1740da465a7a7fc41882f0a/frontend/device/kobo/device.lua#L1200-L1265),
[Kindle powerd integration](https://github.com/koreader/koreader/blob/dab8e448f3425010f1740da465a7a7fc41882f0a/frontend/device/kindle/device.lua#L640-L706),
[reMarkable ownership split](https://github.com/koreader/koreader/blob/dab8e448f3425010f1740da465a7a7fc41882f0a/frontend/device/remarkable/device.lua#L140-L155),
and [PocketBook InkView path](https://github.com/koreader/koreader/blob/dab8e448f3425010f1740da465a7a7fc41882f0a/frontend/device/pocketbook/device.lua#L343-L357).

### Trigger and wake policy

Qualification starts with an explicit, human-issued command only. DT wake
annotations are limited to the cover switch and RK817 PMIC path; this does not
prove runtime wake policy, physical routing, or which PMIC child event woke the
system. Cover-close suspend is explicitly blocked while the current EBC path
cannot retain a sleep cover or report its completion. Automatic idle suspend,
RTC alarms, touch/pen wake, MMC wake, USB wake, and network wake remain disabled
or out of scope until independently attributed. A reasonable later inactivity
default is 15 minutes with a 2--4 second post-resume refractory window, but no
timer is enabled during qualification.

### Platform paths: PSCI versus BSP SIP

CPU idle and system suspend are separate. Missing RK3566 `cpu-idle-states`
prevents PSCI deep CPU-idle states and can increase awake-idle consumption, but
does not itself block PSCI `SYSTEM_SUSPEND`. Conversely, `deep` appearing in
`mem_sleep` means Linux registered a platform suspend operation; it does not
prove DDR retention, wake routing, or successful resume.

There are two firmware contracts to distinguish before testing:

- An upstream TF-A stack can implement system suspend directly through PSCI
  `SYSTEM_SUSPEND`; it does not require the downstream full suspend-mode driver.
- A BSP-style TF-A stack uses Rockchip's private SIP calls and requires the
  matching `rk_suspend_driver`/`rockchip_pm_config` kernel path and DT policy.

Inventory the deployed BL31/TF-A, DDR firmware, and U-Boot before choosing a
path. PineNotes with the problematic factory batch-2 boot stack are not eligible
for a suspend test merely because Linux advertises `deep`. Boot-firmware repair,
if needed, is a separate user-present project and never part of an os2 image
deployment.

### Offline qualification gate

`make suspend-check` runs positive and negative fixtures. Against a built image,
run:

```sh
guix shell dtc python luajit -- \
  pinenote/scripts/preflight/inspect-pinenote-suspend-gates.sh \
  /path/to/kernel/.config /path/to/rk3566-pinenote-v1.2.dtb \
  pinenote/packages/koreader-device/frontend/device/pinenote/suspend_policy.lua \
  pinenote/packages/koreader-device/frontend/device/pinenote/device.lua
```

The gate requires exact suspend/freezer/debug config lines, exactly the approved
two effectively enabled DT wake declarations with their verified identities, and
the exact disabled policy module. A restricted LuaJIT harness evaluates
`device.lua` with injected false and true policy values and requires its returned
class to follow both. It reports CPU idle-state presence without conflating it
with system suspend.
Passing proves none of TF-A/U-Boot, DDR retention, runtime wake policy, physical
wake routing, RK817/TPS65185 behavior, EBC rail state, resume, or current draw.
The 2026-07-20 built 7.0.11 kernel and generated DTB pass this offline gate;
suspend remains unsupported.

Before adding a real coordinator, table-driven host tests must cover checkpoint
failure, refresh-barrier failure, frontlight save/off/restore, Wi-Fi teardown
failure, unsupported mode, aborted entry, duplicate resume, held-key
quarantine, failed EBC refresh, bounded retry, and a durable failure record.
QEMU may validate orchestration and service ordering with an injected fake
backend, but the real `/sys/power/state` write must remain unavailable there.

Current blockers after that gate passes:

- no userspace coordinator yet performs the transaction above, and it remains
  blocked until EBC can retain caller-painted content or atomically accept
  off-screen content with a completion report;
- the deployed stable BSP-ATF/DDR/U-Boot contract is identified, but its
  required Linux `rockchip_sip`/`rockchip_pm_config` driver and DT policy have
  not yet been forward-ported or qualified;
- the EBC driver has system/runtime PM callbacks and special post-suspend
  refresh bookkeeping, but sleep-screen retention and a refresh-completion
  barrier are not proven;
- the known-working downstream stack also carries TPS65185 standby/resume
  register restoration and explicit RK817 regulator suspend states. Their
  necessity with the installed BSP ATF and current mainline regulator drivers
  must be resolved by source comparison and UART evidence before `deep`, not
  copied blindly;
- cover and RK817 wake properties are compiled in, but physical wake routing
  and PMIC child-event attribution are unproven.

### Supervised qualification ladder

Do not combine the telemetry deployment, CPU-idle work, boot-firmware changes,
or suspend orchestration into one verdict. RK817 telemetry is now qualified;
after boot firmware is identified, test one mode per UART-observed case:

1. Linux PM test facility -- a freezer-only `pm_test` dry run, restoring
   `pm_test` to `none` afterwards;
2. one real `s2idle` case -- wake-source and orchestration validation, not a
   battery target;
3. `deep` -- platform suspend, DDR retention, wake, display, and current target.

Each case records exact image and firmware identity, charger/USB/network/light
state, start voltage/current/temperature, dwell, wake stimulus, UART from entry
through recovery, `suspend_stats`, wake-source/IRQ deltas, reader/storage/input
health, post-resume battery telemetry, and the full-refresh result. Stop at the
first unexplained failure. A missing resume marker, wake storm, invalid storage
or telemetry, or absent display repair triggers the documented cold recovery;
do not issue blind repeated wake/suspend commands. Compare repeated unplugged
awake and deep-suspend intervals under equivalent conditions before making a
battery-life claim. Charger insertion/removal, charging suspend, USB, Wi-Fi,
cover, and power-button cases are separate matrix rows.

## Preliminary final4 read-only finding (2026-07-20)

These are single-session observations, not an idle-drain baseline.  The device
reported `/sys/power/state` as `freeze mem` and `/sys/power/mem_sleep` as
`s2idle [deep]`.  EBC runtime PM was `suspended`, `control=auto`, with a
2000-ms autosuspend delay; during one 12-s no-refresh interval only suspended
time advanced.  Wi-Fi was associated and SSH active, frontlight was zero, and
the USB gadget UDC was unavailable.

`wakeup_sources` named `serial0-0`, `ws8100_pen`, `gpio-keys`, `mmc1`, `mmc0`,
`alarmtimer.4.auto`, `rk808-rtc.3.auto`, `rk805-pwrkey.2.auto`, `0-0020`,
`autosleep`, and `deleted`.  In that snapshot only `ws8100_pen` had
`active_count=1`, `event_count=1`, and `wakeup_count=0`.  Runtime wakeup was
observed enabled for gpio-keys, rk805-pwrkey, rk808-rtc, alarmtimer, and I2C
`0-0020`; this is live evidence, not an inference from the carried patch.

The only visible power supply was `ws8100_pen`; its `status`, `present`, and
`capacity` reads returned `Bad message`. No RK817 battery supply appeared.
The live DT lacked the PineNote `simple-battery` profile and RK817 charger
child, so `CONFIG_CHARGER_RK817=y` alone could not create useful gauge
telemetry. KOReader's battery fallback may therefore display 100 while useful
gauge telemetry is absent.

The SSH-perturbed 12-s delta had IRQ29 `fdd40000.i2c` +12,230 (about
1,019/s), with its IRQ thread about 2.6% CPU in a 5-s `top` sample; IRQ61
`dw-mci` +424 (about 35/s), and SC7A20 +12 (1/s).  EBC, touch, pen, and Wi-Fi
host-wake were flat.  IRQ29 is a priority investigation target, not root
caused.  The governor was `schedutil`; no `cpu*/cpuidle/state*` entries were
exposed although boot logged `cpuidle: using governor menu`.  This does not
distinguish config, DT, PSCI, or RT causes; inspect resolved config and live DT
before drawing one.

The live `policy0` is `cpufreq-dt` with `schedutil`, a 408000..1800000 kHz
range, 171000-ns transition latency, and 1,323,783 recorded transitions after
about 5.5 hours.  The TCS4525 `vdd_cpu` regulator at I2C0 `0-001c` shares the
bus with the observed high-rate IRQ29 activity.  Recording policy transition
counts alongside IRQ29 is therefore the next read-only correlation test; it is
not a causal conclusion or a request to tune frequency, voltage, or I2C.

A subsequent recorder-backed, SSH-perturbed 22-second interval measured IRQ29
`fdd40000.i2c` +27,072 (about 1,230/s) alongside policy0
`stats/total_trans` +1,508 (about 68.5/s), or roughly 18 IRQs per transition.
IRQ61 rose +1,002, SC7A20 +23, and wakeup-source counters were unchanged.
This strongly implicates cpufreq-dt/TCS4525 DVFS traffic in the observed I2C0
load, but is not causal proof: both may respond to shared workload.

The short governor A/B then provided causal evidence for the interrupt source.
Each condition was bracketed by recorder snapshots with frontlight zero,
Wi-Fi up, and the reader unchanged; a shell trap restored `schedutil` before
the session ended.  These windows were SSH-instrumented and measure CPU time,
not energy:

| governor | elapsed | transitions/s | IRQ29/s | CPU busy | wake changes |
| --- | ---: | ---: | ---: | ---: | ---: |
| schedutil | 32 s | 57.22 | 1027.13 | 2.67% | 0 |
| powersave | 33 s | 0 | 0 | 2.92% | 0 |
| conservative | 31 s | 2.13 | 30.94 | 1.09% | 0 |
| ondemand | 31 s | 8.32 | 60.97 | 1.04% | 0 |

Under `schedutil`, 1,831 transitions produced 32,868 IRQ29 events (17.95 per
transition); under `powersave`, both counts were exactly zero.  This proves the
high-rate I2C0 interrupts are generated by DVFS transitions through the
TCS4525 CPU-regulator path, not the RK817's approximately eight-second gauge
poll.  It does **not** prove which governor minimizes energy: a fixed 408 MHz
CPU may spend longer on work, and the tablet currently exposes no usable main
battery current/charge telemetry.  `conservative` is the leading adaptive
candidate, but no governor change is persisted yet.

The bounded live-DT scan found exactly
`/sys/firmware/devicetree/base/gpio-keys/switch-cover/wakeup-source` and
`/sys/firmware/devicetree/base/i2c@fdd40000/pmic@20/wakeup-source`.  In
contrast, `/sys/firmware/devicetree/base/cpus/idle-states` is absent despite
resolved `CONFIG_CPU_IDLE=y` and `CONFIG_ARM_PSCI_CPUIDLE=y`.  That accounts
for the absent cpuidle sysfs states. The inherited upstream RK3566 DTS/DTSI
also has no CPU idle-state nodes, which narrows this to missing platform DT
description rather than a final4-only runtime disappearance; adding states
still requires RK3566 firmware/PSCI validation and is not part of this slice.

The live DT also has no `simple-battery`, `monitored-battery`, design-capacity,
voltage-limit, current-limit, sense-resistor, or OCV profile property.  The
missing DTS battery enablement is the next measurement blocker to evaluate
against upstream rather than a runtime probe-order issue.

## Accepted conditional RK817 telemetry plan

The exact upstream DTS-only battery enablement is accepted for a supervised
first `os2` boot after its source and generated-DTB checks pass. This is not
charger tuning, a calibration claim, or a governor policy change: the RK817
driver, its resolved config, and the existing `schedutil` governor remain
unmodified. The driver is expected to initialize and poll its gauge at roughly
eight-second intervals, and its first probe can program charge limits and
persistent gauge state; this boundary requires a human on UART, with `os1`
untouched as rescue and preferably with external power unplugged initially.

The next image’s role is telemetry qualification, not a power-management
policy experiment. On that supervised boot, accept the enablement only if both
the battery and charger supplies appear; the reported design capacity and
charge/voltage/current limits equal the DTS profile; and unplugged then plugged
samples show coherent current, voltage, and status over multiple polls spaced
at least eight seconds apart. Also require no PMIC probe errors or unexpected
heating. Capacity remains provisional until a controlled full charge/discharge
cycle establishes that the gauge tracks reality. Do not change governor or
charging policy based on these initial observations.

### Hardware result (2026-07-24)

The 2026-07-20 telemetry image passed its first os2 boot on 2026-07-24. Both
`rk817-battery` and `rk817-charger` appeared with the exact compiled profile.
Its 4,000,000-uAh capacity fields are DTS inputs, not measured usable capacity.
Across multiple gauge polls, unplugging changed charger `online` and voltage to
zero and settled the battery at `Discharging`, -198 to -203 mA; `charge_now`
and voltage declined. Replugging changed the battery to `Charging/Standard`,
+108 to +116 mA, and increasing `charge_now`. The first immediate unplugged
sample still carried positive current before the next gauge poll, so consumers
must not treat one transition-edge sample as settled state. No PMIC, charger,
regulator, or abnormal thermal condition appeared during this boot window.

A detached recorder captured a cable-free 61-second interval with both
frontlights at zero, Wi-Fi associated, USB not attached, and no serial or SSH
traffic during the dwell. `charge_now` fell 3,440 uAh, an interval-equivalent
about 203 mA at roughly 4.1 V. EBC remained runtime-suspended for the full
interval and no wakeup-source counters changed. Policy0 recorded 2,828
transitions and I2C0 IRQ29 recorded 50,922 events (18.0 per transition), so the
earlier SSH-perturbed DVFS attribution reproduces cable-free. Full evidence is
under `/tmp/opencode/pinenote-power-20260724/`. This short near-full-battery
interval qualifies the telemetry mechanism; it is not a representative
low-power baseline, battery-life estimate, or reason to persist a governor
change. No suspend state was requested.

### Cable-free governor energy A/B (2026-07-24/25)

With usable coulomb telemetry, the earlier IRQ-only governor result can now be
tested against energy. A detached ABBA runner held Wi-Fi associated and both
frontlights at zero, changed only policy0's governor, waited 15 seconds, and
recorded four untouched three-minute cable-free intervals. A shell trap restored
the original `schedutil`; reader and orientation processes remained stable.

| run | governor | interval-equivalent current | IRQ29/s | transitions/s | CPU busy |
| --- | --- | ---: | ---: | ---: | ---: |
| A1 | schedutil | 201.84 mA | 843.41 | 46.78 | 1.77% |
| B1 | powersave | 178.36 mA | 4.50 | 0 | 1.22% |
| B2 | powersave | 184.09 mA | 4.48 | 0 | 1.25% |
| A2 | schedutil | 205.26 mA | 875.04 | 48.59 | 1.91% |

The repeated means are 203.55 mA for `schedutil` and 181.23 mA for `powersave`,
a 22.32-mA (10.97%) reduction in this static awake workload. Arch-timer IRQs
also fell from 539--560/s to 187--193/s. EBC stayed runtime-suspended for each
complete interval and wakeup-source counters did not change. The approximately
4.5 residual I2C0 IRQs/s under `powersave` now include active RK817 gauge
polling; they are distinct from the removed DVFS storm. Full reports are under
`/tmp/opencode/pinenote-power-governor-abba-20260725/`.

This establishes an energy benefit for fixed-minimum frequency while the reader
is static; the realistic reader gate below supplies the page-turn/render and
production-governor verdict.

A second untouched, cable-free ABBA run compared fixed-minimum `powersave` with
adaptive `conservative` under the same Wi-Fi/frontlight conditions:

| run | governor | interval-equivalent current | IRQ29/s | transitions/s | CPU busy |
| --- | --- | ---: | ---: | ---: | ---: |
| A1 | powersave | 181.72 mA | 4.60 | 0 | 1.20% |
| B1 | conservative | 180.32 mA | 8.90 | 3.18 | 0.68% |
| B2 | conservative | 181.31 mA | 15.30 | 3.70 | 0.74% |
| A2 | powersave | 178.36 mA | 4.30 | 0 | 1.21% |

The repeated means are 180.82 mA for `conservative` and 180.04 mA for
`powersave`, only 0.78 mA (0.43%) apart and below what this short experiment can
resolve as a policy difference. `conservative` retained adaptive scaling while
limiting transitions to 3.2--3.7/s, making it the leading awake candidate. The
deterministic reader workload below validates that candidate. Measure Wi-Fi down
separately so radio and governor effects are not confounded. Full reports are
under
`/tmp/opencode/pinenote-power-conservative-abba-20260725/`.

The completed next rung reused the existing physical-reader workload rather than adding
an artificial CPU benchmark. `pinenote/tools/optics/recorder.py` and its
KOReader backend already open a deterministic 49-page test EPUB, inject real
forward/back page keys through persistent uinput, and harvest `[pn-refresh]`
issue timestamps. It ran over Wi-Fi/SSH with USB physically disconnected, not
over the charging ACM cable. A small power wrapper must counterbalance
`conservative`/`powersave`, bracket each complete card run with recorder
snapshots, preserve reader traces, and install an on-device timeout guard that
restores the original governor if the host disappears. Its latency boundary is
explicit: the current trace records refresh issue, not DSP completion or glass
settle. Camera analysis is required for visible settle latency. The completed
run clears the governor-persistence gate; measure Wi-Fi-down current in a
separate static ABBA so radio and rendering effects stay attributable.

### Reader-energy ABBA harness (hardware-run 2026-07-25)

`pinenote/tools/power/reader-energy.py` is the unplugged, SSH-only implementation
of that next rung. It runs `conservative,powersave,powersave,conservative`, drives
one complete existing deterministic optics card through KOReader per leg, and
uses the existing Guile collector for `before.scm`, `after.scm`, and `delta.scm`.
It rejects any manifest that is not the exact 49-page, three-stress-block card
and requires the EPUB's embedded manifest hash to bind those exact manifest
bytes. It records manifest/EPUB hashes, device/kernel/waveform identity, and the
actual dedicated KOReader profile/settings seeded for each run. Every injected
turn must succeed; two device-epoch anchors then require exactly 45 fresh,
parseable `[pn-refresh]` events whose timestamps match the 45 measured page
events in order. Stale, duplicate, malformed, missing, or mistimed traces fail
the leg. The per-leg raw trace and workload timing metadata are retained.
The harness refuses an attached RK817 charger before and after each leg and
requires both frontlight channels already be zero; it never changes either.

The successful hardware order was
`conservative,powersave,powersave,conservative`, all at 26 C:

| run | governor | charge used | elapsed | 45-page issue span | mean current |
| --- | --- | ---: | ---: | ---: | ---: |
| A1 | conservative | 12.900 mAh | 176 s | 163.7465 s | 263.86 mA |
| B1 | powersave | 15.652 mAh | 209 s | 189.2118 s | 269.60 mA |
| B2 | powersave | 16.168 mAh | 209 s | 189.5335 s | 278.49 mA |
| A2 | conservative | 13.244 mAh | 177 s | 164.7053 s | 269.37 mA |

Conservative averaged 13.072 mAh and 176.5 s per completed workload versus
15.910 mAh and 209.0 s for powersave: 17.8% less charge and 15.6% less elapsed
time. Aggregate charge/time also favors conservative, 266.62 versus 274.05 mA.
All legs had exactly 45 fresh trace events, with maximum issue-timing residual
0.2604 s. This is a two-leg-per-governor verdict for this defined reader
workload, not a universal battery-life estimate; the trace measures refresh
issue pacing, not camera-verified glass settle. Combined with the static tie,
it clears the awake-policy gate, and the forward-port defconfig now selects
`conservative` for the next image. Hardware readback of that boot default is
still required after deployment. Wi-Fi-down savings remain a separate ABBA.

The first hardware attempt found a lifecycle defect rather than yielding a
policy result: a failed prior-reader stop was ignored, so two KOReader processes
wrote the same truncated log. Preparation now requires the PID/cmdline-verified
reader to exit and uses a bounded, identity-checked `KILL` fallback before any
replacement launch. The corrected run completed all four legs.

The original governor is read before mutation. A device-side bounded watchdog is
installed and verified before the first write, and normal/error exits explicitly
restore and read back that governor before identity-checking and terminating the
watchdog's isolated process group. The watchdog itself verifies restoration if
the host disappears. Its 1800-second default is also the minimum accepted
fail-safe timeout. Expiry restores the original governor and invalidates the
leg; it is not a claim that arbitrarily slow SSH operations remain a valid
measurement. The harness stages and synchronizes KOReader before the
`before` snapshot, so deltas contain the 45 content turns plus final settle, not
EPUB/plugin transfer or reader restart. It rechecks the watchdog, candidate
governor, charger, and both existing frontlight levels around every workload.
The harness itself never persists a governor setting. Reports include sensitive
fields (MACs, command lines, mount data, and raw traces), so `--output` is
mandatory and must be an owner-only directory outside this repository. Do not
commit or share these artifacts unsanitized.

Offline dry-run/test command (no device or network):

```sh
make power-check
```

Hardware command shape (**USB physically disconnected**):

```sh
python3 pinenote/tools/power/reader-energy.py \
  --host root@PINENOTE --identity ~/.ssh/pinenote-root \
  --manifest /tmp/opencode/testcard/manifest.json \
  --epub /tmp/opencode/testcard/optics-testcard.epub \
  --output /tmp/opencode/pinenote-reader-energy-ABBA
```

This is the image's trusted key-only `root@HOST` maintenance endpoint, not a
claim that the harness narrows the image's existing reader sudo policy.
`HOST` is presently a hostname or IPv4 address only (no colon/scp-style form),
and the identity file must be a readable, owner-controlled regular private key.

### Live firmware/idle inventory (2026-07-24)

The running stack reports PSCI v1.1 with SMC calling convention v1.2; the DT
root-level PSCI node is `arm,psci-1.0` with `method = "smc"`. Linux nevertheless
reports cpuidle driver `none`, consistent with the absent DT idle-state nodes.
The 2026-07-25 offline comparison verified both local and NAS backup manifests,
then compared the exact installer-defined ranges with PNDeb/Pine64's
`stable_1056mhz` payload. Both are byte-identical: idblock SHA-256 `7a935efc…`
and U-Boot FIT SHA-256 `078f81dc…`. The backup therefore already contains the
stable payload, excluding the partially flashed post-October-2024 factory
failure; running its installer would rewrite identical bytes. The idblock
contains DDR firmware V1.10 (2020-02-18 resume build) and a 2021-12-03 SPL. The
FIT contains `U-Boot 2017.09-ge0ec1df #runner` built 2024-10-25, a primary ATF
segment built 2022-06-09 with Rockchip SIP and ultra-suspend paths, and OP-TEE
3.13 built 2023-06-07. This identifies the downstream BSP-ATF contract rather
than upstream TF-A 2.12+. Do not treat PSCI v1.1 or `[deep]` registration as a
resume verdict.

The 7.0 forward-port had also carried `CONFIG_ROCKCHIP_SUSPEND_MODE=y` despite
containing neither the downstream `rk_suspend_driver`/`rockchip_pm_config`
implementation nor its `rockchip-suspend` DT policy node. Upstream 7.0.11 has no
such Kconfig symbol, so the line was silently ignored and has now been removed;
it was not a working BSP-SIP suspend path. The known downstream path explicitly needs
BSP TF-A and programs center/ARM power-off, PMIC low power, PLL/oscillator
shutdown, 32-kHz clock, and GPIO wake through Rockchip private SIP calls. Decide
the firmware contract first; the installed stable firmware selects the BSP SIP
branch, whose Linux driver and DT policy are absent from wilkbook. Either port
and qualify that complete contract or replace the boot firmware through a
separately recovery-qualified upstream-TF-A project. Do not combine those
alternatives, and do not flash the stable installer as a fix because its bytes
are already installed.

The accepted first branch is the recoverable one: keep the verified stable BSP
firmware unchanged and forward-port Samuel Holland's complete `72127ca` Linux
SIP/config/DT contract to the os2 kernel as an explicit compatibility patch.
Before any transition, add a side-effect-free SIP/PSCI feature probe, mocked ABI
tests that pin every function ID and argument, compiled-DT policy assertions,
and a UART-observed os2 boot that only verifies binding/probes. Keep
`suspend_policy.lua` disabled throughout. Upstream TF-A remains the preferred
long-term direction only after maskrom/boot-ROM recovery and byte-exact
boot-firmware restoration are independently rehearsed; it is not mixed with
the BSP policy.

## External context to verify on hardware

The community [hrdl PineNote DTS](https://git.sr.ht/~hrdl/linux/tree/v6.19_ebc_custom/item/arch/arm64/boot/dts/rockchip/rk3566-pinenote.dtsi) marks the
hall sensor and RK817 PMIC as `wakeup-source`; RK3566 secure-firmware wake
gates also matter.  Community RK817 experience says the gauge polls roughly
every eight seconds and can report invalid values immediately after resume.
EBC also requires a visible post-resume refresh check.  These are hypotheses
and test prompts only: none is asserted for final4 until measured there.

The firmware comparison identifies the BSP Rockchip SIP contract and excludes
the factory batch-2 partial-flash failure. Before any future suspend attempt,
either supply and offline-prove its matching Linux driver/DT policy or complete
a separately recovery-qualified upstream-TF-A migration. The attempt must be
human-observed on UART with `os1` available, and acceptance requires a forced
full EBC refresh after resume in addition to wake-source and service-health
evidence.
