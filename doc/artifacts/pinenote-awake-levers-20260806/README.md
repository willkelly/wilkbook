# Awake-power levers, AFK session (2026-08-06)

Unattended session: SSH only, no reboots possible, device on the charger
the whole time. Three subagents (probe module build, regulator research,
trims analysis) ran in parallel with on-device measurement. Headline:
**one register bit was costing ~18% of the awake static floor.**

## Method: differential ABBA while charging

The charger could not be removed (nobody present) and exposes no software
pause. But the gauge counts *battery* current, and with the charger input
saturated every mA of load comes 1:1 out of the battery-charge rate — so
*differential* A/B measurement stays valid, with ABBA/ABA ordering to
cancel charger taper drift.

The regime was **calibrated, not assumed** (`calib-regime.txt`): a 4-core
CPU burn moved the battery rate by ~750 mA (idle −788/−799, burn −43),
proving input saturation. Idle repeatability ±5 mA, drift ~10 mA/16 min →
honest resolution ~3 mA per lever with 900 s phases.

**Method limit, hit live:** the method died the moment the battery
reached full (see BT below). Valid only while charge rate is far from
the CV taper.

## Result 1: vdd_cpu forced-PWM costs ~30 mA at idle — FIXED in next boot

The TCS4525 CPU buck powers on with force-PWM set (COMMAND 0x14 bit 6)
and *nothing in the ecosystem ever clears it* — not the kernel (fan53555
has no of_map_mode, so the DT property is ignored), not mainline u-boot,
not Rockchip's downstream u-boot. Effectively the whole rk3566 fleet runs
its CPU rail in forced PWM. Meanwhile the same dtsi's RK817 bucks
(vdd_logic et al.) already request and get auto mode — vdd_cpu was left
behind purely because its driver couldn't parse the property.

Runtime ABA (`vdd-cpu-deadman.log` + `vdd-cpu-battery-samples.log`),
direct i2c poke, DVFS clamped to 408 MHz, dead-man auto-revert armed:

```
A  force-PWM : +803.3 mA charging
B  auto-PFM  : +823.3 mA charging      <- against the taper direction
A2 force-PWM : +779.9 mA charging
```

Drift-corrected saving **+31.7 mA**, quoted **~30 ± 8 mA** after bounding
taper-shape uncertainty. Rail stable through the full window; revert
verified byte-exact; cpuidle residency unchanged. Baked into
`pinenote/patches/linux-pinenote-7.0-vdd-cpu-auto-pfm.patch` — which
must also carry the `fan53555_set_mode` NORMAL-branch fix
(upstream-register item 10): without it, the DT route writes the ACTIVE
VOLTAGE SELECTOR and drops the rail 400 mV at boot.

**Boot acceptance PASSED 2026-08-06** (image `1a582179…`): `vdd_cpu`
opmode reads `normal` from DT with no poke, no boot warnings, opmode
survives a deep suspend/resume, cpuidle unaffected. Realized in normal
operation: settled reader idle **~174 → 156.9 mA (~17 mA, ≈10%)**;
reading runtime 22.9 → 25.5 h. The realized figure is below the clamped
A/B's ~30 ± 8 mA — the A/B measured the best case (408 MHz pinned, near
zero load, PFM's sweet spot) while normal idle spends time at higher
OPPs and under periodic load where auto mode is in PWM anyway. Both
numbers are real; quote 17 for daily use and 30 for the register bit's
cost at idle.

## Result 2: DRAM SIP is implemented — DDR DVFS is GO (see ddr-sip-probe)

`ddr-sip-probe-dmesg.txt`: `DRAM_GET_VERSION → a0=0 (SUCCESS), a1=0x101`,
above the BSP DMC driver's ≥0x100 floor. First confirmation on this
device; tool now in-tree at `pinenote/tools/ddr-sip-probe/`.

## Result 3: BT measurement invalid — the method limit, demonstrated

```
A1: -624.7 mA   B1: -67.3 mA   B2: +0.6 mA   A2: +6.2 mA
```

The battery reached full mid-run; the "delta" is pure taper. Recorded as
the reference example of the method's failure mode. What *is* established:
the BT serdev unbind/rebind works cleanly (hci_uart_bcm, chip is
dead-but-powered on this image) and cpuidle was unaffected. Expected
<1 mA from analysis; measure unplugged.

## Also confirmed this session

- **Press-to-suspend works on glass**: `power tap -- suspending on
  request` in the autosuspend log — the user's tap before going AFK.
- 5/5 unattended auto-suspend cycles on the cpuidle kernel (bonus soak).
- Wi-Fi power_save already on (that lever was already pulled).
- dwc3 runtime-PM trim disqualified *while charging through that port*
  (suspending the controller could renegotiate input current — measurement
  poison); untested candidate for an unplugged session.

## Next-boot candidates found by the trims analysis (not yet acted on)

Ranked, all DT/driver work: audio cluster pinning **CPLL at 1 GHz** with
zero consumers; **NPLL at 1.2 GHz** with no visible owner; VI (camera)
and VO domains powered on a camera-less reader. Each plausibly mA-class;
all unknown until tried.

## Safety notes that held

Rules for unattended hardware: never touch the Wi-Fi path or the rootfs
eMMC; read-only SMCs only; risky pokes last with an independent dead-man
reverter; auto-suspend paused with a timed self-restore so a lost link
cannot strand the device awake. All held; zero incidents.

## Addendum: DDR DVFS measured on glass (later the same day)

The supervised SET_RATE campaign ran (`pinenote/tools/ddr-dvfs-test/`,
user at the power button, EBC quiesced for every switch). Firmware table:
324/528/780/1056 MHz — the TPL trained all four. First switch in this
board's history: 324 MHz, MCU path, 106.8 ms, memory intact.

Battery-drain windows (absolute, unplugged, same boot, minutes apart):

```
quiesced @ 324 MHz :  174.4 mA
quiesced @ 1056 MHz:  199.2 mA     ->  DDR at 324 saves ~24.8 mA
```

The reader-up@324 window (164.4 mA) is NOT quotable against the earlier
reader-up@1056 (156.9 mA): the measurement script failed to pin the
frontlight, so the conditions differ. The quiesced pair is bracketed and
clean. Daily-use numbers come with the driver.

Session ledger against the 163 mA static floor: vdd_cpu auto-PFM
~17 realized + DDR@324 ~25 quiesced — the floor is structural no more.

## Addendum 2: the 20.6 mA suspend draw is the rail floor, not a leak

Null-hypothesis audit of deep-suspend draw, same boot, 900 s windows:

```
D1  normal suspend path:                 20.6 mA
D2  touch+pen+BT unbound, wlan0 down:    22.7 mA
```

Pre-killing the peripherals changes nothing (D2's +2.1 mA is itself a
finding: unbinding a driver SKIPS its suspend hook, and the orphaned
hardware can sit in a worse state than the suspend path would have left
it — the callbacks do real work). Honest scope note: `rmmod brcmfmac`
failed ("D2 less clean" per the script's own log), so wifi was tested
link-down-driver-present, not hardware-removed; touch/pen/BT were
genuinely unbound.

Conclusion: the suspended draw is PMIC quiescent + always-on rails +
DDR self-refresh + bl31 retention — the regulator-suspend-policy /
rail-kill territory already mapped as the ultra-suspend program (with
its GPIO0 wake-collision question). No peripheral reachable from Linux
is leaking.

Also established: suspend draw is identical at 324 MHz DDR, and **bl31
preserves a non-boot DDR rate across suspend/resume** (ddr_after=324
following both D1 and D2 resumes) — the future DMC driver needs no
resume re-assert.

Operational lesson: the audit's restore path brought the wifi DRIVER
back but not the ASSOCIATION (stale supplicant on a fresh ifindex);
recovery ran over the UART root shell, which this session first
verified is passwordless. `herd restart pinenote-wifi` after any driver
reload.

## Addendum 3: v2 boot, the GL16 cold-start ghosting gap, and the soak

The DMC v2 image (eviction fixes) is deployed and soaking: 324 MHz floor,
input boost live, suspend cycling on defaults. Eviction verified: bridge
respawn leaves both daemons at 0 jiffies/5 s (the v1 bug measured 494).

**New display finding, confirmed on glass:** after ANY other software
paints the panel (U-Boot splash, an os1 session), our first boot starts
from the zero-initialized flat cache believing the panel is white; GL16
(refresh_waveform=6) deliberately drives nothing for white->white, so
foreign residue survives EVERY normal wash -- "insane ghosting" that
menu washes and page turns cannot clear, while accumulating no NEW
ghosting (normal operation is healthy, DDR exonerated). One GC16 wash
(refresh_waveform=4 momentarily) cleared it completely. Proper fix, not
yet implemented: make the FIRST wash after boot GC16, then GL16
thereafter -- one flash at boot buys immunity to foreign panel state.

Operational note from the same evening: a run of "os2 pick lands in os1"
failures was misattributed to UART TX degradation; a leaked host-side
`cat /dev/ttyUSB0` reader (competing for bytes, torn captures) polluted
the diagnosis, and the user's manual menu pick booted v2 fine. Kill
leaked serial readers before concluding anything about the console.

## Addendum 4: boost/suspend collision found on glass; soak is static-324

**SUPERSEDED by Addendum 5 (same night).** The DDR switch was coincident,
not causal; the root cause is power-key double ownership. The soak-state
change (boost disabled, static 324) stands. Original text kept below.

The input-driven boost's core assumption -- "input arrives when the EBC
is idle" -- is FALSE at the suspend/wake boundaries, which is exactly
where buttons get pressed. Timeline from the logs, 2026-08-06 21:25:

    21:25:16  resumed after 600s (backstop; restore wash runs)
    21:25:23  input boost 324->1056  AND  power tap -> suspending
    21:25:27  resumed after 4s (second press)

The switch landed inside suspend-path EBC activity: transient screen
corruption and a not-visible reader, recovered by the next button press
(no refresh timeouts, no poison -- the EBC state machine survived).
Compounding legibility trap: a backstop wake repaints the book and the
device LOOKS asleep, so the user's "wake" press is actually
press-to-suspend on an awake device.

Fixes required before the boost re-enables (next session):
1. ddr-boost: suspend-aware grace -- watch suspend_stats/success and
   suppress min_freq writes for a few seconds around any change; ideally
   also an EBC-idle precheck before any write that will fire SET_RATE.
2. Consider the design doc's device-link/QoS serialization between the
   DMC and EBC drivers as the structural fix.
3. Auto-suspend legibility: after a BACKSTOP wake (no user input), the
   panel should make the awake state visible (or re-suspend much sooner
   than 300 s) so a wake press cannot be mistaken for needed.

Soak state changed accordingly: ddr-boost.conf enabled=0 -- static
324 MHz, zero switches (the collision class cannot occur), which also
tests whether all-324 rendering feels acceptable in daily reading.

## Addendum 5: corrected diagnosis -- power-key double ownership, not DDR

The operator challenged Addendum 4 ("why would a DDR switch corrupt the
screen? the sleep screen used to show the book plus a SUSPENDED banner
and this boot it didn't"), and the challenge was right. Re-examined
offline, entirely from source; no device access needed.

**Against the DDR theory (already in hand, underweighted):** a DRAM
stall during an active EBC scan must blow the 25 ms frame budget (the
MCU-path switch takes ~107 ms) and produce `EBC_FRAME_TIMEOUT` -- and
the harvested dmesg has zero timeouts and no poison. The mechanism
predicts evidence that is absent.

> **RETRACTED 2026-08-06 (night).** That paragraph is wrong, and it is
> the reason DDR got demoted too early. The 25 ms `EBC_FRAME_TIMEOUT` is
> armed ONLY in the partial path, once per frame; a global refresh is a
> single hardware transaction under ONE 3000 ms `EBC_REFRESH_TIMEOUT`
> covering ~600 ms of drive, so a 107 ms stall fits four times over and
> is invisible by construction. The controller has no underrun interrupt
> either (`INT_STATUS` carries only frame/display-end and line-flag
> bits), so a starved fetch drives wrong voltages and reports nothing.
> For the global path, "no timeouts in dmesg" is the PREDICTED signature
> of a disturbed refresh, not evidence against one. Source-verified and
> adversarially checked; now pinned by
> `pinenote/scripts/preflight/validate-ebc-timeout-asymmetry.sh`.
>
> This does not resurrect the boost/suspend collision as the cause of the
> TAP corruption -- the power-key double ownership below is independently
> established from source -- but it does mean the DDR mechanism was never
> ruled out, only unproven, and both fixes were correctly kept.

**The actual mechanism (source-proven chain):**

1. KOReader has opened the rk805 pwrkey node and mapped `116 -> "Power"`
   since the original port (`device.lua:379,396`, commit `02962dd`).
2. Upstream `UIManager:init()` registers a Power handler
   unconditionally, and `Device:onPowerEvent()` never checks
   `canSuspend` (which we hard-disable via `suspend_policy.lua`).
3. Our config leaves `screensaver_type = "disable"`, so
   `Screensaver:show()` paints nothing -- but still sets
   `Device.screen_saver_mode = true`. Then, both inherited as `yes`:
   `needsScreenRefreshAfterResume` fires `screen:refreshFull()` (a
   global refresh, 1-2 s of drive) plus `UIManager:forceRePaint()` on
   EVERY power tap while awake. (The Wi-Fi kill in the same branch
   resolves to an empty stub on our device -- a no-op.)
4. Press-to-suspend -- NEW on this image -- writes `mem` ~1.2 s after
   the same tap (banner draw + `sleep 1`). The suspend parks the EBC
   worker MID-GLOBAL-REFRESH.
5. A mid-drive park leaves the glass in an intermediate optical state
   that matches no gray4 buffer, so `suspend_prev/next` snapshot a
   desynced cache. GL16 restore washes are neutral where buffers agree,
   so the corruption persists across resume. The next awake tap runs
   KOReader's `refreshFull` (full drive) and cleans it -- exactly the
   observed recovery ("pressing the button triggered a redraw").

**Why v1 never showed this:** the same KOReader handler existed, but
nothing suspended on a tap, so its global refresh always completed
harmlessly. Idle-path suspends fire after 5 min of input silence -- EBC
quiet, banner painted cleanly -- which is why the sleep screen "used to
work". It still should: idle suspends involve no Power event.

**Predictions (all testable without a reboot):**

1. The 2026-08-06 night soak's idle-suspends should show a CLEAN sleep
screen (book +
   banner). Checkable by looking at the sleeping device.
2. With the boost disabled and DDR pinned at 324 (current soak state),
   an awake power tap should reproduce the corruption class with ZERO
   DDR switches -- which would exonerate DDR on glass.
3. The corruption should never follow an idle-path suspend.

**Revised fix list (supersedes Addendum 4's):**

1. Single ownership of the power key: stop opening the pwrkey node in
   the KOReader device profile. `canSuspend = no` already says KOReader
   does not own suspend; today it reacts anyway. This also removes the
   silent `screen_saver_mode` latch that toggles on every tap/wake.
2. autosuspend daemon: replace the blind `sleep 1` before `mem` with a
   bounded EBC-idle wait (the `pinenote-dmc` one-shot pattern) -- robust
   against ANY in-flight EBC work, not just KOReader's Power repaint.
3. Post-resume cleanup wash: force GC16 (the panel flashes on resume
   anyway; GC16 heals any glass/cache desync for free). Same class as
   the first-wash-GC16 boot fix.
4. ddr-boost suspend-aware grace: keep as defense-in-depth, demoted
   from root-cause fix. The boost stays disabled until 1-2 land.

The Addendum 4 legibility trap (backstop wake leaves an awake device
looking asleep) is real and stands.
