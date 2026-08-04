# PineNote power management: evidence first

This document defines the first, **read-only** power-management slice.  It is
instrumentation discovery, not a suspend policy, battery-life estimate, or a
claim about final4's idle drain.  The companion `pinenote/tools/power` Guile
tool emits versioned S-expressions on stdout, accepts a fake root for offline tests, and
only reads an explicit allowlist.  It never reads waveform or VCOM calibration
data and never writes sysfs, procfs, debugfs, or tracefs.

## Power program: targets, measured gaps, and ordering (2026-08-02)

Will's targets, and where we actually stand. All from a 4000 mAh charge
(`charge_full`), against measurements in
`doc/artifacts/pinenote-battery-ab-20260802/` and
`.../pinenote-awake-idle-profile-20260802/`.

| target | needs | measured | verdict |
| --- | --- | --- | --- |
| **~40 h active use** | ≤100 mA average | awake floor **171.6 mA** (23.3 h) | **not reachable awake** — reachable only by suspending between interactions |
| **a week idle, most of a charge left** | ≤6.0 mA to leave 75% | deep **19.3 mA** (leaves 19%) | **3.2x short** |

### The reframe that makes target 1 achievable

On e-ink, "active use" is mostly *a static page with nothing happening* —
the panel holds its image at zero power. So reading does not have to mean
*awake*. If the device suspends between page turns and wakes only to
render one:

| pattern | average | reading time |
| --- | --- | --- |
| page every 30 s, 2 s wake @ ~400 mA | 44.7 mA | ~90 h |
| page every 30 s, 1 s wake @ ~400 mA | 32.0 mA | ~125 h |

Both clear 40 h comfortably. **The 400 mA wake burst is an assumption, not
a measurement** — measuring the real energy of one wake+render+refresh
cycle is the first thing to do, because it sets everything here.

The binding constraint then becomes **resume latency, not power**: a 2 s
page turn is a bad reader, a 0.3 s one is a Kindle. Deep resume currently
costs ~1.1 s of kernel time before any repaint. That number is now a *user
experience* metric as much as a power one.

### Target 2 needs less suspend draw, not better scheduling

No amount of scheduling fixes 19.3 mA → 6 mA. That is the **ultra-suspend
/ rail-kill** payload we deliberately left unadopted (`ultra: 0` in every
bl31 `PM-STATE` line so far), and it is gated on the rail-kill wake
collision: `vcc_3v3_pmu` feeds `pmuio1/2`, the GPIO0 bank carrying every
external wake source. Turning those rails off is exactly what saves the
power *and* what could make the device unwakeable.

### Ordering

1. **Auto-suspend scheduling** — the enabling mechanism for both targets,
   and worth ~7x on its own. Userland policy: inactivity detection, wake
   sources (power button and cover are still unproven), resume-to-reading.
2. **Measure one wake+render+refresh cycle.** It sets whether
   suspend-between-page-turns is viable and what resume latency budget we
   have.
3. **Resume latency** — UX first, power second.
4. **Suspend draw 19.3 → <10 mA** — ultra-suspend, gated on the rail-kill
   wake question. This is what target 2 actually needs.

### Deferred: on-demand Wi-Fi (after everything else)

**Decided 2026-08-03: live with the power for now.** Worth doing later; the
device is usable without it.

The measured case for it, when we get there:

- **11.2 mA** off awake idle (6 %, measured by taking `wlan0` down).
- A large share of the **30 % resume-overhead gap** — the unplugged soak
  averaged 64.4 mA where the component model predicts 49.8 mA, and
  re-association is most of what happens between wake and usable.
- **Faster wake to a usable page**, which is the UX number that decides
  whether suspend-between-page-turns is viable.

Shape, reusing the charging-inhibit pattern so the device stays workable:

| state | Wi-Fi |
| --- | --- |
| on charger | on — development mode, always reachable |
| on battery | off; brought up on demand, dropped after a timeout |

This is how Kobo and Kindle behave, and KOReader already ships `NetworkMgr`
for exactly it. The catch specific to us is that **ssh is the development
channel**, so a default-off policy makes the device dark between user
interactions — hence tying it to charger state rather than switching it off
outright.

### Deferred: awake-idle floor research (after everything else)

Explicitly parked, not forgotten. The 171.6 mA awake floor has two known
contributors we chose not to pursue now, both large jobs with speculative
payoff and bad failure modes:

- **CPU idle states.** Hardware and firmware are capable (PSCI v1.1;
  `psci: CPU3 killed` proves firmware power-gates cores), and the kernel
  is fully configured (`CONFIG_CPU_IDLE=y`, `CONFIG_ARM_PSCI_CPUIDLE=y`,
  MENU+TEO governors). **The only missing piece is the DT `idle-states`
  description** — neither mainline `rk356x-base.dtsi` nor os1's BSP DTB
  has one. Writing it needs `arm,psci-suspend-param` values that are a
  firmware ABI we do not have. **Risk asymmetry: a wrong idle param wedges
  the device on every idle transition — hundreds per second — not once per
  suspend.**
- **DDR frequency scaling.** DDR runs at 1056 MHz always (confirmed in our
  own UART boot capture). `CONFIG_PM_DEVFREQ=y` with the ondemand governor
  is built, but **no devfreq device registers**: mainline has
  `rk3399_dmc.c` only, no RK356x DMC driver. `rockchip-dfi.c` supports
  rk356x but is a bandwidth *monitor*, not frequency control.

Cheap way to size the DDR half before ever investing: os1's BSP kernel
likely has the DMC driver — boot os1, run
`doc/artifacts/pinenote-awake-idle-profile-20260802/idle-profile.sh`, and
compare its awake-idle against our 171.6 mA. ~20 minutes, and it either
sizes the prize or closes the question permanently.

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
3. The EBC driver now carries a fixed-width generation barrier: SUBMIT returns a
   request ID with `-EINPROGRESS`, WAIT reports success only after the worker's
   global refresh and post-refresh bookkeeping, and any hardware/setup failure
   permanently poisons the instance until reboot. The verbatim host harness
   proves batching, playback-time submissions, legacy coalescing, caller/off-screen
   snapshots, and that late DSP_END cannot heal a timeout. A dormant LuaJIT ABI
   adapter and injected sleep-frame provider now exercise this boundary with
   fake operations, but `device.lua` imports neither and no production provider
   calls them, so production sleep-cover orchestration remains blocked.

   `pinenote-ebc-sleep-frame-test` is a separately packaged, supervised
   diagnostic that exercises only this framebuffer-publication and barrier
   boundary.  Root must first run `herd stop reader-session`; `--run` requires
   an interactive tty, snapshots every `line_length * yres_virtual` byte,
   paints a deterministic card, fsyncs and waits once, then restores only after
   explicit Enter and a second strict barrier.  It never requests suspend or
   writes `/sys/power/state`; it has no service, autostart, KOReader import, or
   production coordinator wiring.  Initial failures deliberately receive no
   implicit repair; a restore failure is reboot-terminal uncertainty.
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

The gate requires exact suspend/freezer/debug config, rejects enabled hidden activation,
exactly the approved two effectively enabled DT wake declarations with their
verified identities, and the exact disabled policy module. A restricted LuaJIT
harness evaluates `device.lua` with injected false and true policy values and
requires its returned class to follow both. It rejects CPU idle-state nodes and
references, any additional matching probe node, and every property or child
beneath the exact root probe node.
Passing proves none of TF-A/U-Boot, DDR retention, runtime wake policy, physical
wake routing, RK817/TPS65185 behavior, EBC rail state, resume, or current draw.
The 2026-07-20 built 7.0.11 kernel and generated DTB passed the then-current
gate. The current BSP compatibility build passes the expanded gate against its
packaged config and DTB; suspend remains unsupported.

The closed `power_capabilities.lua` constructor rejects missing, malformed, and
extra providers without inventing authority. The pure `power_coordinator.lua` host model accepts only the
explicit initial-qualification mode `mem`, then prepares in checkpoint, EBC
barrier, idlewasher, input quarantine, frontlight, Wi-Fi, and storage order.
It passes that one selected mode to its injected requester, captures one
unambiguous wake attribution while input is quarantined, and forwards each
prepare state unchanged to best-effort restore in the safe EBC, input,
frontlight, idlewasher, then final non-blocking Wi-Fi handoff order. The final
reader notification receives the attributed wake source. It uses durable prepared
and failure records, reentrancy, and permanent poisoning. Every capability is
injected; the module contains no filesystem, FFI, subprocess, device-node, or
sysfs authority and is not imported by the production device target. QEMU may
later validate service adapters, but the real `/sys/power/state` write must
remain unavailable there.

Current blockers after that gate passes:

- no production provider or userspace coordinator yet performs the host-proven
  transaction; a dormant LuaJIT barrier adapter and injected sleep-frame
  provider are host-proven and packaged with the recursively grafted PineNote
  device sources, but remain intentionally unimported by `device.lua`;
- the deployed stable BSP-ATF/DDR/U-Boot contract is identified, and its
  execution-capable Linux parser/model/executor/backend stack is now
  production-linked and offline-qualified. Activation and active DT policy
  remain deliberately absent, so firmware compatibility, execution ordering,
  wake, and resume still require the later supervised qualification ladder;
- the EBC driver has system/runtime PM callbacks, special post-suspend refresh
  bookkeeping, and a host-proven refresh-completion barrier. The separately
  invoked C diagnostic can now paint, wait, and restore under supervision, but
  production sleep-frame painting and coordinator wiring remain absent;
- the known-working downstream stack also carries TPS65185 standby/resume
  register restoration — **resolved 2026-08-01: required before `deep`,
  and now WRITTEN: the forward-port patch carries a snapshot/restore
  suspend-resume pair (dormant until the ladder reaches `deep`; VCOM
  never written; cache-through restore; structurally gated in
  `make suspend-check`, negative-tested; see
  `doc/kernel-forward-port.md`)** — and explicit
  RK817 regulator suspend states, whose adoption is now gated on the
  rail-kill wake-collision question (see the evidence pass below);
- **SC7A20 accelerometer resume — ROOT-CAUSED 2026-08-02, and now
  reproduced on hardware.** After the first real `deep` cycle:
  `irq 71: nobody cared (try booting with the "irqpoll" option)`,
  `Comm: irq/71-sc7a20-t`, level-triggered via `rockchip_irq_demux`. The
  kernel's spurious-IRQ protection then **disables the IRQ**, so
  autorotation is dead until reboot (measured rate afterwards: 0/s — the
  storm ends because the IRQ is gone). Reading is unaffected.

  Cause, read from the 7.0.11 source: the accelerometer is the **mainline**
  driver (`CONFIG_IIO_ST_ACCEL_3AXIS=m`, `st-accel-i2c`), and that driver
  has **no power management at all** — `struct i2c_driver st_accel_driver`
  carries no `.pm`, and there are **zero** occurrences of
  `pm_ops`/`suspend`/`resume` across `drivers/iio/common/st_sensors/`,
  `drivers/iio/accel/st_accel*`, or `include/linux/iio/common/st_sensors.h`.
  Across a power-down the sensor loses its configuration, nothing
  re-initialises it, its INT line stays asserted, the threaded handler
  cannot clear it, and the level IRQ storms until the kernel kills it.

  Fix shape: add `.pm` to the i2c driver — suspend disables the sensor,
  resume re-runs the probe-time initialisation
  (`st_sensors_init_sensor()`, which restores ODR, enable state and the
  DRDY/interrupt configuration). This is a genuine gap in a mainline
  driver rather than a defect in the EBC lineage, so it is
  upstream-reportable in its own right.

  **Status 2026-08-03: that patch is written, deployed, and NOT SUFFICIENT.**
  `st_sensors_pm_ops` is live in the running kernel and the storm still
  fires 0.7 s after resume. The reason is ordering the patch cannot reach:
  `resume_device_irqs()` runs at the **noirq** stage, *before* driver
  `.resume` callbacks. So IRQs are re-enabled while the sensor's level line
  is still asserted from having lost its configuration, the threaded
  handler runs and cannot clear it, and genirq disables the IRQ — all
  before `.resume` gets to reprogram anything.

  **Remaining fix: `disable_irq()` in `.suspend`, `enable_irq()` after the
  reinit in `.resume`**, so the handler cannot run until the device is
  programmed. Standard pattern; it is the piece the first attempt missed.

  *Timing note that misled the first reading of this*: printk timestamps
  freeze across deep suspend, so `PM: suspend entry` at 106.7 s and the
  storm at 108.9 s are 240 s apart in wall time, not 2 s. A trace that
  looks like "before the first suspend" may be well after a resume.

  **Confirmed inherent, not ours (Will, 2026-08-02): "it also breaks on
  os1 for sure."** os1 is stock Debian on the 6.12 BSP kernel running the
  same mainline `st-accel-i2c`, and it auto-deep-suspends on idle — so the
  defect reproduces on a completely different kernel and userland. That
  matches the source exactly (a driver with no `.pm` cannot survive a
  power-down on any distro) and means **every PineNote Linux image that
  suspends has broken autorotation after the first sleep.** It also
  explains why hrdl's `v6.19_iio_accel` branch exists. Nothing about our
  configuration is special, so no os1 verification trip is needed;
- cover and RK817 wake properties are compiled in, but physical wake routing
  and PMIC child-event attribution are unproven.

### Supervised qualification ladder

**First session run 2026-08-01** (`doc/status.md`, artifact
`pinenote-suspend-ladder-20260801.md`): rung 1 PASS; rung 2 suspend/wake
mechanics PASS (gadget quiesced, absolute-epoch RTC alarm, 24.7 s,
on-schedule wake) but **acceptance FAIL** — the `rockchip_ebc`
system-resume path never services damage again
(`plane_reset`/`ctx_release`/`ctx_free`, 0 frames for every subsequent
write incl. the reader's own repaint) and leaks one regulator enable per
cycle (vcom/v3p3/vposneg up; TPS `ENABLE` 0x3f; runtime-PM stuck
`suspended`). Reboot-only recovery. **Deep untested by rule.** The
display-side resume defect is now the program's gating blocker; the os1
oracle question (does stock 6.12 survive s2idle with a working panel?)
decides inherited-vs-ours and report-vs-fix.

**The resume defect is root-caused and fixed in-tree (2026-08-01,
afternoon)**: the DRM helper's active-gating skipped the park/unpark
bracket for our blanked fbdev CRTC while the resume commit still swapped
the refresh ctx — the never-parked worker kept the freed ctx and every
refresh silently no-oped (full analysis: `doc/driver-findings-report.md`,
2026-08-01 finding; fix description: `doc/kernel-forward-port.md`). The
fix makes the bracket unconditional and idempotent in the system PM
callbacks. Verified offline: three-analyst reconstruction + two
adversarial verifiers, all five hardware observations explained; host
suites green including the new `ebc-suspend-bracket-test`; full
cross-build green. **Two contract notes for the next session**: (a) a
system suspend racing an unwaited barrier generation now poisons on the
blank path too (previously only the active path) — by design, no
generation may be left behind a parked worker, and poison now logs one
line; (b) suspending with a blanked CRTC now runs the park-tail wash
(glass to white) before sleep — expected, matches the CRTC-disabled
invariant. Next-boot ladder retry: re-run rung 2 with the same
console-free protocol; also capture the pre-suspend blank/active state
explicitly (the blanked-at-suspend precondition was soundly inferred,
never directly measured), and grep resume dmesg for
`rockchip_ebc_resume` (new symmetric entry print).

Amendments from that session, now standing procedure:
- **Quiesce the USB gadget before any attempt** (blank
  `/sys/kernel/config/usb_gadget/pinenote-acm/UDC`; rebind after). An
  active ACM host session hard-vetoes suspend via dwc3.
- **Arm the RTC with absolute epoch** (`since_epoch` + N); the `+N`
  form returns EAGAIN on rk808-rtc.
- ~~**The procedure is console-free by necessity**: … the USB-C serial
  cable demonstrably receives nothing from ttyS2.~~ **RETRACTED
  2026-08-02 — the UART works.** That claim was a test artifact, and it
  cost two sessions of blind protocol. Validated in both directions at
  1500000 8N1 (direct `/dev/ttyS2` writes *and* kernel printk with
  timestamps). Two things had defeated it: (a) the device-side
  `/dev/ttyS2` termios defaults to **9600**, and on an 8250 the console
  shares the port's divisor, so console output was leaving at 9600 while
  the host listened at 1500000 — run `stty -F /dev/ttyS2 1500000` on the
  device (agetty uses `--keep-baud` and will not stomp it); (b) every
  earlier test was a **passive listen after boot**, when the console is
  idle, which cannot tell a dead cable from a quiet one. **Test method
  that works: transmit a known marker from the device while sweeping the
  host baud rate.** A passive capture yields runs of `0x00` — a line held
  low, which reads as "broken cable" and is not.
  The ACM-gadget half stands: it dies with suspend and vetoes it while
  attached, so quiesce it. Console-free is now an *option*, not a
  necessity — and **deep must never be run without UART**, since its
  failure mode is a hang with no on-disk record past the suspend write.
  For an entry trace, `no_console_suspend` is on the kernel command line
  (runtime `console_suspend=N` does not hold the 8250 port up through
  `dev_pm_ops`).
  **Capture fidelity caveat (measured 2026-08-02): the UART capture DROPS
  CHARACTERS under dense output.** A boot capture at 1500000 rendered
  `BSP suspend policy activated` as the fragment `pend policy activated`,
  with interleaved and truncated neighbours — the line was transmitted and
  the capture mangled it. **A missing line in a UART log is therefore not
  evidence it was never printed.** Confirm against on-disk `dmesg` before
  concluding anything from an absence. This is also why the dual-channel
  protocol matters: on-disk dmesg is lossless up to the freeze, UART covers
  the handoff past it, and the two stitched gaplessly on 2026-08-02.
  Enabling `no_console_suspend` increases suspend-phase console volume, so
  expect *more* drop risk exactly where the trace is most valuable — read
  the bl31 `PM-STATE` line carefully and re-run rather than trusting a
  partial.
- Evidence transfers off-device must be verified BEFORE device cleanup.
- **Read the gates before probing them, and hold no DRM node while you
  do.** Immediately after resume, before anything else touches the
  display, run `pinenote/tools/power/fb-damage-gates.sh` — it names
  which of the four silent gates is closed, which no sequence of write
  probes can. And note that the first opener of `/dev/dri/card0`
  *becomes* DRM master, which makes `FBIOBLANK` and `set_par` silently
  no-op: a diagnostic holding the card open invalidates its own
  recovery attempts. Close the DRM fd before probing fbdev recovery.
  (Added 2026-08-01; see "Post-resume dead-write window" below.)

Do not combine the telemetry deployment, CPU-idle work, boot-firmware changes,
or suspend orchestration into one verdict. RK817 telemetry is now qualified;
after boot firmware is identified, test one mode per UART-observed case.

Every case brackets with the proven acceptance instrument: run
`pinenote/scripts/preflight/pm-ground-truth.sh` on the device before the
attempt and after resume, and diff (variable lines: timestamp,
`charge_now`, TMST_VALUE `00:`). Validated live 2026-08-01, stable
across back-to-back runs. Decision table for the TPS65185 rows: VCOM1
must read the device calibration (`03: 8f`) after resume — the factory
default `7d` there means the NVM assumption failed, stop the ladder;
UPSEQ/DWNSEQ/INT_EN/ENABLE must match the pre-suspend capture — datasheet
defaults there mean the resume restoration did not run or did not stick:

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
`conservative` for the next image. Hardware readback of that boot default was
completed on 2026-07-25. Wi-Fi-down savings remain a separate ABBA.

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
branch. At that point its execution-capable Linux driver and DT policy were
absent from wilkbook; the activation-hard-off parser/model/executor/backend port
described below now closes the offline implementation slice. Active policy and
hardware qualification remain separate. Do not combine that BSP path with a
recovery-qualified upstream-TF-A project, and do not flash the stable installer
as a fix because its bytes are already installed.

The accepted first branch is the recoverable one: keep the verified stable BSP
firmware unchanged and forward-port Samuel Holland's `72127ca` Linux
SIP/config/DT contract to the os2 kernel as an explicit compatibility patch.
The production-linked, activation-hard-off MEM-policy stage is now complete
offline. It
pins every represented function ID and argument, validates policy through
compiled DT fixtures, and links the strict parser, typed model, generic
executor, and real narrow backend. A separate hidden activation object owns the
active platform driver and the only device-PM `.prepare`/executor edge;
exact-default-n Kconfig omits it from the PineNote candidate. This is an
execution-capable fail-closed subset, not the full Rockchip BSP or PineNote
ultra-suspend policy surface. Keep
`suspend_policy.lua` disabled throughout. Upstream TF-A remains the preferred
long-term direction only after maskrom/boot-ROM recovery and byte-exact
boot-firmware restoration are independently rehearsed; it is not mixed with
the BSP policy.

### BSP SIP compatibility milestone

The compatibility patch remains deliberately narrower than donor commit
`72127ca`. It preserves upstream's `0xff` power-domain subcommand unchanged.
Production links a composite parser/model/executor/backend core, but its only activation
object is gated by hidden `ROCKCHIP_SUSPEND_MODE_ACTIVATE`, which defaults to `n`
and is explicitly unset in the PineNote defconfig. The kernel source and
compiled DTB use only `compatible = "rockchip,pm-rk3568"` and `status =
"okay"`; host fixtures spell `name = "rockchip-suspend"` explicitly, then
reconstruct it after `dtc` strips that deprecated property, matching Linux OF's
live-node normalization. All three are metadata, not policy. The original parser
omitted `name`, so the 2026-07-26 activation-hard-off boot rejected it with
`-EINVAL` before binding; the corrected code was then host-validated and later
booted and bound in dormant activation-hard-off mode as recorded below.
With the correction, the policy-free node remains DORMANT with no firmware,
regulator, CPU, PSCI, MMIO, PM-callback, or runtime enablement action.

Production parsing is intentionally limited to MEM regulator lists. It rejects
mem-lite, mem-ultra, and virtual-poweroff properties because Linux 7.0 has no
real selector for the former and its regulator prepare/finish hooks provide no
transaction for the latter. Regulator phandles are retained as standard
consumer handles, deduplicated by provider identity, and changed only through
locked regulator-core wrappers. Exact prior suspend settings are restored in
reverse order on local failure, PM `.complete`, and unbind. The Kconfig core
requires `SUSPEND`, which supplies ARM64's `CPU_PM` dependency. The
CPU and modern PSCI methods stay candidate-linked for compile/link proof but
have no production caller while activation is off; even an internally fabricated
virtual-poweroff event list fails at regulator prepare before CPU/SIP/PSCI.

The separately extracted host harness represents the donor's typed contract:
exact RK3568 sleep/wake/PWM bits; controls `0x01..0x07` and `0x09`; repeated
GPIO-power records plus the `0xffff` terminator; three ordered regulator-state
lists; and the regulator-prepare, secondary-CPU-disable, `0x07(0,1)`, PSCI
system-suspend virtual-poweroff description. Control `0x08` is pinned but no
builder emits it. The donor treats any nonzero virtual-poweroff value as true;
the dormant model intentionally narrows that to `0` or `1` and rejects other
values. This is host-model fidelity, not an executable production policy.
Parsing and short-capacity failures leave caller-owned output unchanged.

`make rockchip-pm-check` compiles the verbatim model and injected-ops executor
under ASan/UBSan, builds
donor and maximal DTBs, parses the exact `rockchip,power-ctrl` and
`rockchip,regulator-*-in-*` schema, and feeds generated policy inputs into the C
tests. The compiled-DTB fixtures explicitly cover standard `compatible`,
`name`, and `status` metadata, while rejecting a `names` lookalike and every
policy property when activation is unavailable. Positive cases cover both an
explicit source `name` and source that omits it before host normalization
synthesizes the live-OF shape. It also validates the canonical full-index patch
and reads the supplied
applied source tree; mandatory negative mutations cover provider lifetime,
parser cleanup, unwind, status mapping, link ownership, and config. Adversarial
DT and source mutations prove fail-closed limits and the hard-off production boundary before `make suspend-check` and
`make kernel-drv`. This does not prove firmware compatibility, suspend, DDR
retention, wake, resume, EBC repair, or energy savings.

`make activation-positive-check` is the separate positive offline gate. It
runs the pure Lua coordinator suite, parses the compiled maximal synthetic DTB,
builds exact probe and MEM-prepare events, executes them through `fake_ops`, and
fails each MEM regulator action. Only successful fake mutations enter that same
transaction, pinning failure stop order, the exact reverse restore set and prior
values, permanent poison, and zero-action retry. The same composite command then reruns the unchanged
production suspend preflight, which requires activation unset, policy-free DT,
and `suspend_policy.lua` exactly false. Passing is fake-only implementation
evidence, not permission to enable activation or request suspend.

The corrected 2026-07-26 reader candidate completes the artifact half of this
milestone. Its ext4 image is
`/tmp/opencode/pinenote-rootfs-artifacts-bsp-pm-namefix-20260726/pinenote-reader-PNGuixRoot-20260726.ext4`,
SHA-256 `0c67785ff434bac66e3652e940c1d088e2c242cf6dfd132fc66fd8e2b8f97f4f`,
1,945,280,512 bytes (3,799,376 sectors), with rootfs-matched bundle
`/tmp/opencode/pinenote-reader-boot-bundle-bsp-pm-namefix-20260726`. The full
host/build/source/config/DT/package/rootfs/mock-helper ladder, generic ARM64
login smoke, QEMU rung 4, and visual rung 4v pass. Config, `System.map`, and both
PineNote Lua policy files were dumped from the ext4 image and revalidated: the
executor is linked, activation is omitted, and suspend remains exactly disabled.
At artifact-production time this was deployment evidence for a later manual os2
write from stock os1, not hardware compatibility, binding, or suspend evidence.
It was subsequently deployed and its metadata-only dormant bind is recorded
below. The replayable artifact-bound manifest is
`doc/artifacts/pinenote-reader-bsp-pm-namefix-20260726.md`.

**2026-07-25 hardware result:** the exact os2 image booted with the intended
7.0.11 PREEMPT_RT kernel, policy-free DT node, and `conservative` governor, but
the adapter logged `legacy SIP version probe failed` with `-EOPNOTSUPP` and did
not bind. No suspend state or suspend control was requested. The transport maps
raw signed firmware statuses `-1` and `-2` to that error, and the generic probe
message cannot identify whether `0x82000001` failed or whether it succeeded and
`0x8200000a` failed. Public Rockchip sources also show that these are private,
non-universal legacy IDs; in particular, historical AArch32 code used
`0x8200000a` to select a protocol with nonzero arguments, not as a universal
zero-argument AArch64 version query. The result therefore rejects the current
two-query discovery premise rather than proving the installed firmware lacks
the later suspend controls. The otherwise healthy boot is recorded in
`doc/status.md`. The maximal offline dormant Linux-side milestone described
above was complete at that point. The review-fix boot then exposed Linux OF's
synthesized `name` handling gap, making the corrected `namefix` bind boot below
necessary. Any later image that enables activation or adds policy must
separately reconcile the PineNote suspend-state/resume surface, pass the same
fail-closed offline gates, and remain non-suspending until the full qualification
ladder permits a supervised test.

**2026-07-26 live-OF correction:** the later activation-hard-off candidate
booted healthily but did not bind: Linux OF synthesized `name =
"rockchip-suspend"` beside the source/compiled-DTB metadata `compatible` and
`status`; the parser accepted only the latter two and returned `-EINVAL`. No
backend, firmware, regulator, CPU, or suspend operation occurred. This corrects
an implementation gap, not firmware compatibility. The exact `namefix` artifact
above subsequently booted from os2 and logged `DORMANT policy core bound;
activation compiled out`; sysfs confirmed the driver link and no suspend was
attempted. This proves metadata-only dormant binding, not active policy,
firmware compatibility, suspend, wake, resume, display repair, or energy use.

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

## Community ultra-suspend series (read 2026-07-31): the priced policy surface

hrdl's `v6.19_ultra_suspend` branch (three commits on top of
`v6.19_pinenote`: `af0f33629a`, `693fee1933`, `ee2c553f78`) is the first
community answer to PineNote deep suspend, and it lands squarely on the
BSP-ATF contract the 2026-07-24 firmware inventory identified. Read from
fetched source, not summarized from hearsay:

- **Mechanism** (`drivers/soc/rockchip/rockchip_pm_config.c`, fetched from
  the branch): the probe reads a new `rockchip,suspend-state-override` DT
  property (`:195`). In `pm_config_prepare()` the real
  `state = suspend_state - PM_SUSPEND_MEM` is computed first (`:254`);
  only then is `suspend_state` overridden (`:258`) and handed to
  `sip_smc_set_suspend_mode(LINUX_PM_STATE, …)` (`:261`). The regulator
  on/off list selection (`:272`/`:275`) still runs off real
  `PM_SUSPEND_MEM`. So the override is **purely a firmware-handshake
  change** — Rockchip `suspend_state=5` ("ultra") is requested from bl31
  while Linux-side suspend semantics stay `mem`.
- **DT policy payload**: three RK817 PMU rails flipped from on-in-suspend
  to off-in-suspend — `vcca_1v8_pmu` (LDO_REG1), `vdda_0v9_pmu`
  (LDO_REG3), `vcc_3v3_pmu` (LDO_REG6) — plus `sdmmc1` changed from
  `keep-power-in-suspend` to `cap-power-off-card`.
- **Claimed prize**: ~60 mW → ~11 mW suspend draw (~1 week → ~1.5 months
  of standby). **This is hrdl's own commit-message figure, unreplicated by
  anyone in our tree, and the branch is not known to be in daily use.**
  PNDeb's `pn_record_power_usage.py` (a systemd-sleep hook diffing
  `rk817-battery` `charge_now` across suspend) is the ecosystem's
  measurement protocol for exactly this claim, and is the natural
  verification method once a suspend exists to measure.

What this changes for our program — and what it does not:

- It does **not** remove a blocker. Activation, an active reviewed DT
  policy, real coordinator providers, production sleep-frame wiring, and
  the resume dependencies all still stand.
- It **re-prices** the program: the prize was previously unquantified;
  a claimed 5.5× standby extension is reader-defining if it replicates.
- It makes "PineNote-specific ultra-suspend dependencies" **concrete**:
  the whole policy surface is ~40 lines of DT we can model offline
  against the compiled-DTB fixtures, with activation hard-off, before any
  boot is spent.
- It **confirms peripheral resume is the unsolved part** — hrdl included.
  `693fee1933` carries an admitted `[HACK]` for cyttsp5 resume (on
  `!device_may_wakeup`, power-control the touch controller; on failure,
  toggle reset_gpio and swallow the error; the `cyttsp5_startup()` call is
  commented out).
- It **adds a blocker we did not have listed**: SC7A20 accelerometer
  resume. hrdl's `v6.19_iio_accel` attempt is visibly unfinished (the
  author's own "Still not enough…" comment). Our final4 autorotation
  state-replay validation covered service disable/re-enable, not a real
  system suspend.
- **TPS65185 resume gap, now confirmed on both sides**: the mainline
  7.0.11 `drivers/regulator/tps65185.c` we build (457 lines vanilla, 528
  as-built with our IIO hunk) has **no PM ops at all**, and our patch
  only adds the IIO temperature provider. See the evidence-settled
  verdict below.

### Evidence pass (2026-08-01): VCOM is NVM-safe, restoration is still required, and the rail payload collides with every wake source

Five evidence tasks (PNDeb/U-Boot source, TI datasheet SLVSAQ8G, RK3566
TRM/pin tables, our as-built DTS audit, and the m-weigand 6.12 driver)
plus a live register dump from the running device settled the open
questions. Live dump (i2c `3-0068`, regmap debugfs, EBC idle):
`TMST=0x17 ENABLE=0x2f VADJ=0x03 VCOM1=0x8f VCOM2=0x00 INT_EN1=0x7f
INT_EN2=0xff UPSEQ=e1/00 DWNSEQ=1e/00 TMST1/2=20/78 PG=0xfa REVID=0x66`.
The dump doubles as the proven acceptance instrument for the first
`deep` case (pre/post register compare).

**VCOM survives SLEEP — the display-corruption risk is retired by chip
NVM.** The chain, each link source-verified: the TPS65185 stores VCOM in
nonvolatile memory as its *power-up default* (datasheet §8.3.7.2 — the
PROG bit commits VCOM[8:0] "such that it becomes the new power-up
default"); SLEEP resets registers *to power-up defaults* (§8.4.1), so
VCOM comes back calibrated while everything else reverts to datasheet
defaults. The live VCOM1=0x8f (143 → −1.43 V) vs the factory default
0x7D proves the NVM was programmed. Who keeps it correct: the installed
U-Boot (`d6fdb09`, byte-verified 2026-07-25) reads the per-device mV
from vendor-storage record 17 and calls `tps65185_set_vcom_value`, which
**reads back first and returns without writing when the chip already
matches** ("Same as pmic default value, just return.") — a self-healing
NVM programmer that has been taking the no-op branch on this device.
Later u-boot-pinenote commits (`e0ec1df5a`, 2024-10-25) disable even
that "to make sure the vcom value flashed in the factory stays in the
chip" — community confirmation of the NVM model. Nothing in the PNDeb
userspace or the m-weigand kernel ever writes VCOM.

**Register restoration at resume is REQUIRED before `deep` — and the
known-working stack agrees.** The loss chain is fully verified: our DTS
already marks `vcc_3v3` off-in-suspend; GPIO3_A5 (the TPS65185 WAKEUP
pin) sits in **VCCIO5**, fed from `vcc_3v3` (RK3566 pin table: the GPIO3
bank straddles VCCIO5/VCCIO6, A5 is squarely VCCIO5; both fed from
`vcc_3v3` here); pad dies → WAKEUP deasserts → SLEEP → register reset.
The strongest template evidence: **stock os1's m-weigand 6.12 driver
carries exactly this fix** — `SIMPLE_DEV_PM_OPS` whose resume (a) sleeps
50 ms (`TPS65185_WAKEUP_DELAY_MS`, the documented window in which the
chip reloads its EEPROM after wake-from-SLEEP and writes would clobber
it), then (b) re-runs `tps65185_set_config` (UPSEQ/DWNSEQ from DT),
INT_EN1/2=0xff, and ENABLE — every register it ever programs, **never
VCOM** (deliberately: NVM). Our future mainline-driver hunk takes that
shape with one addition the old driver doesn't need: our regmap is
`REGCACHE_MAPLE`, so restoration must go through
`regcache_mark_dirty`+`regcache_sync` (or bypass the cache) — a naive
rewrite of cached values reaches nothing. Do not copy hrdl's
`pinenote-shared` hunk (restores only sequencing mainline never
programs, misses INT_EN/ENABLE, and its uncached write method is
defeated by our cache).

**The rail payload is where the prize lives, and on OUR tree it
collides with the entire wake path.** The consumer audit of the three
rails hrdl's ultra policy kills:

- `vcc_3v3_pmu` (LDO_REG6) feeds `pmuio1`/`pmuio2` — the **GPIO0 pad
  bank, which carries every external wake interrupt on this board**:
  the rk817 INT (pwrkey, RTC/alarmtimer, battery, charger), cyttsp5
  touch INT, ws8100 pen INT (its *only* wake path), Wacom INT, BT and
  Wi-Fi host-wake, and the hall cover switch. Killing it per DT means
  plausibly an unwakeable device — power key and RTC alarm included.
  It also feeds cyttsp5's `vdd` (our patch-added supply), mechanically
  explaining hrdl's admitted cyttsp5 resume `[HACK]`.
- `vcca_1v8_pmu` (LDO_REG1) feeds VCCIO4 (the Wi-Fi SDIO + BT UART
  signaling banks), `sdmmc1`'s `vqmmc`, and BT `vddio` — Wi-Fi/BT wake
  dead, SDIO re-init on resume.
- `vdda_0v9_pmu` (LDO_REG3) has **zero DT consumers** because it feeds
  the SoC's own PMU-domain analog supply — invisible to DT and *not*
  safe to infer killable.

The RK3566 hardware-design guide's standby section says PMUIO0/1/2 IO
is what *remains valid* in standby — i.e. standard designs keep exactly
the rail hrdl turns off. Either his device genuinely wakes through some
path that survives (PMIC-internal PWRON?), or bl31 retains something DT
doesn't show, or his ~11 mW config simply cannot wake on the sources we
need. **This is now the gating question for the rail payload**, it is
supervised-UART territory, and until it is answered the modeled
firmware handshake (below) and the rail policy are decoupled: we can
tell firmware "ultra" without adopting any rail kill.

### Model status (2026-08-01): the firmware handshake is modeled, pinned, and hard-off

The free donor-diff check is **done**: hrdl's entire ultra kernel delta
is 8 lines in `rockchip_pm_config.c` (the SIP transport is
byte-identical across his branches), and our dormant model already
carried the load-bearing structural split — 0x09 emission decoupled from
regulator-list selection. `rockchip,suspend-state-override` is now
modeled in the bsp-sip-probe patch and host tools with a strict
contract: exactly one u32, value exactly 5 (0 is hrdl's in-band
no-override sentinel and is rejected — absence encodes no-override; 1–2
are not BSP states; 3 restates the default; 4 would tell firmware
mem-lite with no lite policy parseable). The override changes only the
firmware word; list selection stays derived from the real Linux state.
The production OF parser still refuses to bind any DT carrying the
property, that refusal is forbidden-token-pinned and mutation-tested,
and `suspend-check` names both the override and `cap-power-off-card` in
its spoof blacklist. Gates: `make rockchip-pm-check
activation-positive-check suspend-check`, all green. Whether the
deployed 2022-06-09 bl31 numerically honors `LINUX_PM_STATE=5` remains
unverified (string-level firmware inventory only) — supervised-UART
territory.

Blocker-list deltas from this pass: **SC7A20 accelerometer resume**
added (hrdl's own attempt is unfinished; our final4 state-replay
validation covered service disable/re-enable, not system suspend);
TPS65185 converted from "necessity unresolved" to "required, shape
known, REGCACHE-caveated, acceptance instrument proven"; **rail-kill
wake collision** added as the gating question for the ultra payload;
`sdmmc1 cap-power-off-card` recorded as implying full SDIO Wi-Fi
re-init on resume (blacklisted in the model, not modeled).

No hardware session is allocated or implied by any of this. The standing
rule holds: nothing suspends until the qualification ladder says so.

### Post-resume dead-write window (2026-08-01, offline source pass)

The rung-2 retry left one precisely localized residual: after resume,
every framebuffer write was accepted and produced no frame, while the
`GLOBAL_REFRESH` ioctl on the same state drove +47 frames. The driver,
the refresh thread, the ctx, the rails and the panel were all exonerated
on the device. This pass read the 7.0.11 submission path end to end and
found **four** gates that can produce that exact signature — accepted
write, `fsync` returning 0, no frame, and **nothing in dmesg, because
nothing failed**.

Submission order, from a userspace write to a queued EBC area:

| Gate | Site | Fires when | Readable as |
| --- | --- | --- | --- |
| G1 | `drm_fb_helper_damage_work()`, `drm_fb_helper.c:271` | `info->state != FBINFO_STATE_RUNNING`; returns before `drm_fb_helper_fb_dirty()`. Damage is not lost — the clip accumulates in `helper->damage_clip` and is never flushed. | `/sys/class/graphics/fb0/state` |
| G2 | `drm_atomic_helper_dirtyfb()`, `drm_damage_helper.c` | no plane has `plane->state->fb == fb`, so the loop matches nothing and `drm_atomic_commit()` commits an **empty** state — success, zero effect. | `dri/N/state`: primary plane `fb=0` |
| G3 | `drm_master_internal_acquire()`, `drm_auth.c` | any process holds DRM master, so `drm_client_modeset_commit()` / `_dpms()` return `-EBUSY` — and `drm_fb_helper_blank()` / `drm_fb_helper_set_par()` **discard that error and return 0**. | any opener of `/dev/dri/card*` |
| G4 | `fbcon_resumed()`, `fbcon.c:2653` | fbcon unbound, so `update_screen()` never runs and nothing regenerates damage after `fb_set_suspend(0)`. | `/sys/class/vtconsole/*/bind` |

Two consequences worth stating plainly.

**The probe ladder we ran could not have named the gate.** Each of the
four is silent and each returns success; a write probe can only ever
report "still no frames". `pinenote/tools/power/fb-damage-gates.sh` now
reads all four in one shot, and deliberately opens no DRM node — because
the first opener of `/dev/dri/card0` *becomes* master (`drm_master_open()`),
so a diagnostic that opens the card to issue an ioctl closes G3 on
itself and silently invalidates every unblank and `set_par` it then
attempts. Our own `probeC-setpar` result on 2026-08-01 is therefore not
conclusive evidence about G2, and is retired as such. **Standing rule:
check G3 before trusting any recovery attempt, and never hold the DRM
node open across an fbdev recovery probe.**

**G1 is unconditionally wrong and is now fixed in the driver.**
`drm_client_dev_resume()` → `drm_fbdev_client_resume()` →
`drm_fb_helper_set_suspend_unlocked(helper, false)` *defers* the
un-suspend to `helper->resume_work` whenever `console_trylock()` fails,
and nothing in the resume path ever waits for it. `rockchip_ebc_resume()`
now calls the same helper a second time after a successful
`drm_mode_config_helper_resume()`: that call opens with
`flush_work(&fb_helper->resume_work)`, which is precisely the missing
barrier — a deferred un-suspend is completed before resume returns, and
when the first call already took the console lock (the common case) the
second returns immediately and costs nothing. It is ordered *after*
`rockchip_ebc_wake_worker()` so that damage the un-suspend releases has a
live consumer.

**Correction from the os1 reading (2026-08-01, taken during the deploy).**
Running the probe on stock Debian showed that the sentence "fbcon-unbound
is why os1 never shows this" is **wrong**. os1 has fbcon *bound*
(`vtcon1 bind=1`) and still never exercises this path, because its plane
holds `fb=39` **allocated by gnome-shell** — the fbcon framebuffer is
`fb=37` and is not on the plane at all. `systemd-logind` holds DRM
master. So on os1 both G2 and G3 are permanently closed *for the fbdev
path*, and the panel works anyway because a KMS compositor owns the plane
and repaints through atomic commits. The real reason os1 is healthy is
that **os1 does not drive its display through fbdev at all.**

The consequence is a standing limit on the oracle: **os1 is not an oracle
for the fbdev damage path.** It answers hardware questions (does the
panel work, does a rail come back, does the waveform load); it cannot
answer "should this fbdev write have painted", because it never makes
one. The probe now correlates the plane's fb with its allocator so this
is visible in one line instead of inferred.

G2 and G4 are **not** fixed in the driver, deliberately.
`drm_atomic_helper_resume()` re-commits the state duplicated at suspend
time; if the panel was blanked before suspend then restoring "blanked"
is correct, and forcing a modeset on in resume would override the user.
The userspace unblank is the right actor — it was only ever suspected of
failing because G3 may have been closed under it. G4 is a design
property of the reader image (fbcon unbound), not a defect.

Next hardware session: run `fb-damage-gates.sh` once after resume,
before anything else touches the display. G1 should now read `0`. If a
dead-write window survives with G1 open and G3 open, G2 is the answer
and the fix is a userspace unblank, not a driver change.
