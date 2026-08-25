# Upstream register — what we owe the community, and when to send it

A standing list of things this project has built or found that would be
useful to someone else, together with **where** they'd go and **what has
to be true before we send them**. It is a tracker, not a plan: nothing
here is scheduled work.

Companion to `doc/driver-findings-report.md` (the written-up findings) and
`doc/hrdl-evaluation.md` (the community-diff evaluation whose §3.3 already
recommends "land the findings report upstream"). This file is the register
that gates that, and everything like it.

## The gate

**Nothing goes out until the baseline is done and the finding is proven in
a system that actually works.**

"Baseline done" means: a minimal PineNote distro that works *very well* as
an ereader and a note-taking device. Not feature-complete — good at those
two things, on hardware, in daily use.

The reason is credibility, and it's specific to our position. We are the
only public 7.0.x PineNote tree (verified 2026-07-31: hrdl tops out at
v6.19 with no 7.0 branch; postmarketOS ships 6.19.3). Everything we report
therefore arrives from a tree nobody else runs. A finding from a working
daily-driver reader is a contribution; the same finding from a tree that
has never been lived on is a code review from a stranger. We only get to
make the first impression once.

Secondary reason: several items below are still moving. A report we have
to retract costs more than one we send late.

## How to use this

When you find something worth giving back, add a row. Don't send it.
When the gate opens, work the list in value order.

Each entry records: what it is, where it lives in our tree, who it's for,
how it would be sent, what has to be true first, and its current status.

Status vocabulary: **ready** (written, verified, gated only on the
baseline) · **needs-verification** (real, but a claim in it is unconfirmed)
· **needs-work** (would have to be written or generalized) · **parked**
(low value, recorded so we stop re-deciding).

---

## Register

### 1. `rockchip_ebc` findings report — **ready**

The full findings report: the seven original host-suite findings, four
defects in the `v6.19_ebc` EXTRACT_FBS reference implementation, and
dated hardware-session and code-read findings through 2026-08-02 (the
silent global-refresh starvation, the suspend-ctx use-after-free, and
the resume damage-baseline defect). Written up in
`doc/driver-findings-report.md` (living draft, last updated 2026-08-06,
already addressed to the community).

**For:** hrdl (`git.sr.ht/~hrdl/linux`) primarily, and ayakael as the
postmarketOS kernel maintainer — the defect ships to users through
pmaports `device/community`, so the report has a real audience downstream
as well as upstream.
**Why it's the top item:** it's already written, it's machine-verified
against driver source rather than read, and it applies to code hrdl ships
*today* — not just to our fork.

**Applicability confirmed 2026-07-31** for the flagship finding (a
sustained damage source starves the global-refresh path indefinitely and
silently). Fetched `v6.19_ebc` and found the exact structure present:
`do_one_full_refresh` declared at `:180`, read at the top of the refresh
thread at `:1545`; `rockchip_ebc_partial_refresh` at `:1082`;
`list_splice_tail_init` re-splicing the queue inside the frame loop at
`:1128` and `:1257`; the drained-list exit at `:1231`. The report's own
caveat — "equivalent code exists in the hrdl/ayakael 6.19 lineage;
re-check before applying" — is discharged for this finding.

**Newest entry (2026-08-02): the resume damage-baseline defect.** The
`suspend_was_requested` re-init branch never seeds the `kmalloc`'d
`final_atomic_update` diff baseline, so post-resume damage is diffed
against uninitialised memory and silently dropped by drop-on-match.
Inherited lineage code (verified present in our original import); fixed
in our tree behind a mutation-tested structural gate
(`validate-ebc-resume-baseline-hunk.sh`). The report carries the honesty
caveat that it is not proven to be the whole dead-write explanation —
the probes' own black-on-black no-op writes were a major confound.

**Not yet re-checked** against `v6.19_ebc` for findings 2–7 or the
resume-baseline finding. Do that before sending; the same fetch method
works.

**Update (2026-08-24, issue #22): the starvation finding now ships with a
fix, and the shape of the report changes.** We adopted hrdl's own drain
gate (`v6.19_ebc_custom` @ `819ba1724a6f`), adapted to this driver's area
list — see the update block in `doc/driver-findings-report.md`. Two things
follow for whoever sends this:

- **It is no longer "here is a bug"; it is "here is a bug, here is your
  own fix applied to the older branch, and here is an offline
  reproduction".** That is a stronger send, and it is aimed at a
  *different* audience than before: hrdl has already fixed it on
  `v6.19_ebc_custom`, so the people who still need it are the branches
  that have not taken that work — `v6.19_ebc`, m-weigand, and ayakael's
  pmaports `linux-pine64-pinenote` (which ships to postmarketOS users).
  Frame it as a backport request, not a discovery.
- **The blast radius is larger than the report currently says.** The same
  loop stalls `kthread_park()`, so it stalls a **system suspend** under
  sustained damage, not just a global refresh. That is worth leading with
  for a battery-powered device.

**Also new and sendable with it:** the offline reproduction itself
(`ebc-refresh-starvation-test` + `ebc-drain-gate-test` +
`mutate-drain-gate.py`) — a desk-runnable proof that the boundary is the
waveform's phase count rather than any timeout. Nobody in the lineage has
an executable model of the refresh machine; that may be worth more to them
than the patch.

**Gate:** baseline done. Also re-confirm findings 2–7 and the
resume-baseline finding still apply, and re-check *which* branches still
carry the ungated splice before framing the starvation item.

### 2. `DRM_IOCTL_ROCKCHIP_EBC_REFRESH_BARRIER` — **needs-verification**

A generation-addressed refresh barrier (SUBMIT/WAIT, poison-on-failure)
authored here and hardware-proven 2026-07-30.

**For:** hrdl, as an offer rather than a patch.
**Blocker:** we have no production caller. The barrier is proven by a
separately-invoked root-only diagnostic, not by the reader. Offering UAPI
we don't ourselves depend on is weak. `doc/hrdl-evaluation.md` §3.3 also
notes `v6.19_ebc_custom` is where the community UAPI is actually heading —
check whether that branch has already grown something equivalent before
proposing ours.

**Gate:** a production caller exists, *and* `v6.19_ebc_custom` doesn't
already solve it.

### 3. Deferred-io flush period is tunable — **ready** (as a footnote to item 1: in-tree implementation, measured win)

`fbdefio.delay` is a plain writable per-helper field
(`drm_fbdev_shmem.c:184`, `HZ/20`), `drm_fbdev_shmem_driver_fbdev_probe()`
is `EXPORT_SYMBOL`'d (`:203`), and `fb_defio.c:297` re-reads the delay on
every fault. So **any** driver can set its own value in a `.fbdev_probe`
wrapper with no upstream change at all.

**There is nothing to upstream to mainline.** Recorded here because it's
worth *telling* hrdl: his driver carries 25 `module_param`s and **zero**
references to `defio`/`fbdefio` (verified 2026-07-31 against
`v6.19_ebc`) — the knob is simply unnoticed, and it is directly relevant
to anyone driving this panel through deferred-io.

**Since 2026-08-01 the offer includes an implementation and measured
results, not just the technique.** Our forward-port carries the knob as
the `defio_delay_ms` module parameter (a `.fbdev_probe` wrapper; the
default 50 preserves vanilla behavior), and the publish-on-call program
proved its value on glass: with the window at the chosen 250 and
KOReader fsync-publishing at every refresh intent, eight of eight uinput
portrait page turns cost exactly one pass (23/23 turns cost two before
the fix), and publish latency is timer-independent at 133–140 ms from
EBC-idle to first IRQ. Details in `doc/refresh-policy.md`
("publish-on-call").

Do **not** pitch it to mainline as a user-tunable module parameter. The
DRM maintainers' documented position on e-paper driver knobs is hostile to
that framing. (That position was reported to us as a specific 2026-05-05
review quote which we could **not** verify — lore.kernel.org is behind an
anti-bot wall. Treat the specific quote as unconfirmed; the general
principle is well enough established to act on regardless.)

**Gate:** send with item 1 as a footnote. No separate effort.

### 4. Host-harness testing discipline — **needs-work**

The verbatim-source host tools (`pinenote/tools/{wbf,ebc-logic,rastersim}/`)
compile the driver's own source on a workstation and differential-test it.
`doc/hrdl-evaluation.md` §4 argues this is the deeper offer: hrdl's rework
shipped ~130 KB of scheduler with zero regression tests, and a
CLUT-compiler differential (`wbf-info --dump-lut` vs his
`wbf_to_custom.py`) is the natural first joint artifact.

**Gate:** baseline done. Generalizing the harness beyond our tree is real
work — offer the idea first, build only if there's interest.

### 5. Waveform-decode and optics measurement methodology — **needs-work**

`doc/refresh-policy.md` plus `pinenote/tools/optics/`. Per the 2026-07-11
sweep, quantitative display-quality measurement is novel community-wide —
dithering quality, `redraw_delay`'s felt effect, DU-vs-A2 equivalence are
all assertions in the community and numbers here.

**Gate:** the optics program produces results we actually trust and use.

### 6. The 7.0.x forward-port itself — **parked**

Genuinely scarce (we're the only public 7.0.x) but there is **no
consumer**: hrdl hasn't branched past v6.19, postmarketOS ships 6.19.3.
The EBC driver delta from `v6.19_ebc` to ours is only ~231 diff lines, so
the porting value isn't in the driver anyway — it's in DTS, defconfig,
tps65185 and PREEMPT_RT integration.

**Unpark trigger:** someone in the lineage starts a 7.x branch.

### 7. fbdev-emulation resume is silent when it fails — **needs-verification**

Two core-DRM findings from the 2026-08-01 offline pass, both about the
same thing: the fbdev-emulation path **reports success while doing
nothing**, so a driver whose display is dead after resume gets no signal
at all. Full analysis in `doc/power-management.md` ("Post-resume
dead-write window").

1. **The deferred un-suspend is never awaited.**
   `drm_fb_helper_set_suspend_unlocked(helper, false)` punts to
   `helper->resume_work` whenever `console_trylock()` fails, and nothing
   on the resume path waits for it. Until it lands, `info->state` is
   still `FBINFO_STATE_SUSPENDED` and `drm_fb_helper_damage_work()`
   returns before `drm_fb_helper_fb_dirty()` — every damage submission
   is dropped, the clip silently accumulating in `helper->damage_clip`.
   Drivers that repaint from userspace writes (no fbcon to trigger
   `update_screen()`) resume into a dead display. Our fix is a
   second call to the same helper from the driver's resume, using its
   own opening `flush_work()` as the barrier — which suggests the real
   upstream shape is for `drm_fbdev_client_resume()` to do that itself.

2. **`drm_fb_helper_blank()` and `drm_fb_helper_set_par()` discard
   `-EBUSY`.** Both call into `drm_client_modeset_*`, which return
   `-EBUSY` from `drm_master_internal_acquire()` whenever any process
   holds DRM master; both then return 0. So `FBIOBLANK` and
   `FBIOPUT_VSCREENINFO` report success for a modeset that was refused.
   This is what makes G3 above so treacherous to diagnose — including
   for our own tooling, which took master merely by opening the card.

**For:** dri-devel — unlike everything else in this register these are
mainline core-DRM, not `rockchip_ebc`, so the lineage is not the right
audience. Small and self-contained.

**Verification state (updated 2026-08-06):** the old condition (1) —
hardware confirmation of finding 1 — is discharged, with a nuance. The
fix for finding 1 (a second `set_suspend_unlocked` call from the
driver's resume, barriered by its own `flush_work`) is **hardware-proven
2026-08-02**: `fb0.state=0` after resume, the deferred un-suspend
completes, and suspend-ladder rungs 1–2 pass on s2idle. But the same
sessions showed finding 1 was **not** what our device's dead-write
window actually was: with the fix in and every gate reading open, damage
still painted zero frames, and the window was reattributed to our own
probes' black-on-black no-op writes plus the inherited resume
damage-baseline defect (item 1; `doc/driver-findings-report.md`,
2026-08-02 finding). G1 was real and is fixed; it was not the cause.
Both core-DRM observations (the unawaited `resume_work`, the discarded
`-EBUSY`) stand as source-verified mainline behavior — but the local war
story motivating them is weaker than this row originally implied, and
any report should say so rather than lean on our symptom.

**What has to be true first:** (1) check current `drm-misc-next`, not
7.0.11 — this is live code and may already have moved; (2) the standing
baseline gate.

**Status:** needs-verification (the `drm-misc-next` re-check is the
outstanding item). Do not send on 7.0.11 source reading alone.

### 8. `st_accel` has no power management — **needs-work** (real patch, real audience)

`struct i2c_driver st_accel_driver` has no `.pm`, and there are **zero**
occurrences of `pm_ops`/`suspend`/`resume` across
`drivers/iio/common/st_sensors/`, `drivers/iio/accel/st_accel*`, and
`include/linux/iio/common/st_sensors.h` (7.0.11). Across a suspend that
actually removes power, the sensor loses its configuration, nothing
re-initialises it, its INT line stays asserted, and the level-triggered
IRQ storms until the kernel's spurious protection disables it —
permanently, until reboot.

Observed on PineNote 2026-08-02 as `irq 71: nobody cared`,
`Comm: irq/71-sc7a20-t`, after the first real `deep` cycle. **Confirmed by
Will to reproduce on stock Debian/6.12 as well**, so it is inherent to the
driver rather than to any one image — every PineNote Linux distro that
suspends loses autorotation after the first sleep.

**For:** linux-iio (`Denis Ciocca` is the listed author; the ST sensors
maintainers) — this is mainline, *not* the EBC lineage, so unlike every
other item here it is ours to fix rather than to report to m-weigand/hrdl.
Worth telling hrdl regardless, since `v6.19_iio_accel` is an unfinished
attempt at the same problem.

**Shape:** add `.pm` to the i2c (and spi) driver — suspend disables the
sensor, resume re-runs the probe-time `st_sensors_init_sensor()`, which
restores ODR, enable state, and the DRDY/interrupt configuration.

**Written and hardware-proven 2026-08-03** (6/6 deep cycles;
`pinenote/patches/linux-pinenote-7.0-st-accel-pm.patch`,
`doc/artifacts/pinenote-sc7a20-resume-fixed-20260803/`). Two findings that
belong in the submission, because a reviewer will hit both:

1. **Re-running the init path is not sufficient by itself.** The split-out
   `st_sensors_reinit_hw()` inherits `init_sensor()`'s "disable DRDY, this
   might still be enabled after reboot" step, and
   `st_sensors_set_dataready_irq()` assigns `->hw_irq_trigger` as a side
   effect — so any `if (sdata->hw_irq_trigger)` **after** that call reads
   false and the re-arm is silently skipped. Latch it first.
2. **`st_sensors_init_sensor()` does not restore the interrupt polarity.**
   The active-low bit (`drdy_irq.addr_ihl`) is written only in
   `st_sensors_allocate_trigger()`, which runs once at probe. A chip that
   lost power returns active-high against an `IRQ_TYPE_LEVEL_LOW` GPIO and
   delivers nothing at all — a *silent* death, distinct from the storm,
   and one that survives fixing the storm. This is the part any
   "just call init_sensor() on resume" patch (including hrdl's unfinished
   `v6.19_iio_accel`) will miss.

Still not sent — per this register's standing rule, nothing ships until
the baseline reader image is done. The patch also carries a
`disable_irq()`/`enable_irq()` bracket whose noirq-ordering justification
is **unproven**; that should be split out or dropped before submission
rather than defended with a story we did not measure.

**What has to be true first:** written and working on our hardware across
repeated deep cycles, plus the standing baseline gate. Unlike the EBC
findings this one has a straightforward upstream home and a reproducer on
two independent kernels, which makes it the strongest candidate in this
register once it exists.

---

## Destinations

| who | what they own | channel | verified? |
|---|---|---|---|
| hrdl | `git.sr.ht/~hrdl/linux` — the live upstream, 69 heads, tops at v6.19 | sourcehut; likely `git send-email` to a list | **address not confirmed — look up before sending** |
| m-weigand | `github.com/m-weigand/linux` — the root we forked | GitHub issues/PRs | dormant since ~Feb 2025 |
| postmarketOS | pmaports `device/community/{device,linux}-pine64-pinenote` | GitLab MR on **`gitlab.postmarketos.org`** | **live** — kernel 6.19.3, device pkgver 11, maintainer Antoine Martin (ayakael) `<dev@ayakael.net>`. Builds vanilla kernel.org tarball + one big patch, same shape as us. Device package sources hrdl's `pinenote-dist` @ `28d2c05` |
| ayakael | the Forgejo fork pmOS's kernel patch is generated from | via the pmOS maintainer address above | host `ayakael.net` is up (200) but `/forge/linux-pinenote` **404s**, including the exact `…/compare/526524233b…..v6.19.patch` URL pmaports fetches. Verified 2026-07-31. May be transient or a move — re-probe before relying on it |
| dri-devel | mainline DRM | `git send-email` | only relevant if the driver is ever resubmitted; no EPD infrastructure in mainline and none pending |
| KOReader | `github.com/koreader/koreader` — the reader we ship | GitHub issue, then PR | **not probed** — confirm the issue template and where input-stack changes are reviewed before opening item 11 |

### 9. rk356x has no CPU `idle-states` — **needs-work** (works; does NOT do what you would expect)

Neither mainline nor Rockchip's BSP defines `idle-states` for
rk3566/rk3568. Rockchip ships them for **rk3308, rk3328, rk1808, rk3528,
rk3562, rk3576 and rk3588** — both older and newer parts — and skips
rk356x. So Linux registers **no cpuidle driver at all**
(`current_driver` reads `none`) and the cores never leave WFI. Confirmed
absent on both our 7.0.11 tree *and* os1's 6.12 BSP kernel running
Rockchip's own DTB and ATF.

**We added it and it works** (2026-08-06,
`pinenote/patches/linux-pinenote-7.0-cpuidle-psci.patch`,
`doc/artifacts/pinenote-cpuidle-psci-20260806/`). `psci_idle` registers,
`cpu-sleep` is entered constantly, cores idle 31–72% of wall time, and no
core ever failed to wake:

    current_driver: psci_idle
    state1: cpu-sleep  latency=220us  residency=1000us
    cpu0 72.06% / cpu1 70.10% / cpu2 55.98% / cpu3 31.19% of wall

**And it saves 2.1 mA.** Same boot, same book, same 900 s window, toggling
only `state1/disable`: 172.7 mA enabled vs 174.8 mA disabled — ~1.2%,
which is noise. A cumulative teardown the same day showed why: **91.9% of
the awake draw is an irreducible static floor** (163.1 mA of 177.5).
CPU core power simply is not where this board's awake power goes.

**This changes what there is to send.** The original framing here was
"cpuidle is missing and that is why awake idle is 206 mA" — that framing
is dead. What remains is still worth contributing, but honestly:

- rk356x *should* have `idle-states`; it is a real gap in the DT and the
  hardware and firmware support it (PSCI debugfs reports CPU_SUSPEND
  implemented, non-OSI, Original StateID format).
- The patch is small, safe in our testing, and completes the SoC's
  description.
- **But anyone adopting it for power reasons will be disappointed**, and
  the submission should say so with the numbers, rather than let a
  reviewer assume a win. A DT node that is correct-but-inert is a weaker
  sell than one that saves power, and pretending otherwise would be the
  wrong first impression.

**For:** linux-rockchip / devicetree, `rk356x-base.dtsi`. Still the one
item here that is not PineNote-specific — Quartz64, SOQuartz, PineTab2,
Odroid-M1, Radxa E25 all inherit from that file.

**What has to be true first:**

1. Residency/latency figures must be **ours**. The current values are
   copied from rk3588 (same A55 core, different SoC) and Linux sums them
   into `latency=220us`. Fine for an experiment, not for a submission.
2. Tried on a **second rk356x board** before claiming the SoC rather than
   the board. We have one device; this is a shared dtsi.
3. The power result stated plainly, so nobody adopts it expecting a win
   we did not get.
4. Ideally paired with an explanation of *where* the power does go — see
   the teardown — which is the more useful contribution to that audience.

### 10. `fan53555_set_mode` writes the wrong register on TCS4525 — **needs-verification** (found by source read; NEVER test it live)

Found 2026-08-06 while engineering a runtime regulator-mode A/B on the
PineNote's `vdd_cpu` (TCS4525, `drivers/regulator/fan53555.c`).

On the FAN53555 proper, the force-PWM mode bit lives inside the active
VSEL register, so `fan53555_set_mode()` writing `di->vol_reg` for both the
FAST and NORMAL branches is correct.  On the **TCS4525** the mode bit
moved to the COMMAND register (0x14 bit 6), and the driver's probe sets
`mode_reg = COMMAND` accordingly — but the NORMAL branch of `set_mode`
still writes **`di->vol_reg`** (fan53555.c ~:200, present in 7.0.11, the
Rockchip BSP, and current mainline).  On a TCS4525 that clears bit 6 of
the *active voltage selector*, i.e. subtracts 64 × 6.25 mV = **-400 mV
from the CPU rail in one write**.  Any kernel path that ever requests
REGULATOR_MODE_NORMAL on this chip hard-hangs the board.

Nobody hits it today only because nothing in-tree calls
`regulator_set_mode()` on this rail and `regulator-initial-mode` is
ignored without an `of_map_mode` (which fan53555 lacks).  It is a
landmine, not an active bug — which is exactly the kind of thing worth
fixing before someone wires up mode control.

A second, softer observation for the same audience: the TCS4525 powers on
with force-PWM set and no software in the ecosystem (kernel, u-boot
mainline or Rockchip downstream) ever clears it, so effectively the whole
rk3566 fleet runs its CPU rail in forced PWM.  Whether auto-PFM is worth
anything is being measured on our hardware now; the measured number
should accompany any submission.

**For:** linux-regulator (fan53555.c maintainers).
**Shape:** two-line fix (NORMAL branch → `di->mode_reg`/`mode_mask`) plus
optionally `of_map_mode` support; a full-reasoning draft existed only in an uncommitted working
scratchpad; reconstruct it from this section plus
`pinenote/patches/`-adjacent material at send time.
**What has to be true first:** the register-level claim re-verified
against the then-current mainline at send time; the fix itself must NOT
be "tested" by invoking the broken path on hardware (it provably drops
the CPU rail 400 mV) — correctness is by inspection plus, if wanted, a
regmap-level unit test.

### 11. KOReader's slot numbers are treated as identities — **ready** (reproduced offline, two pinned tests)

Two defects in KOReader's `frontend/device/input.lua` +
`gesturedetector.lua`, both from the same assumption: that a kernel MT
**slot number** identifies *which* thing is touching, rather than being
an opaque index the controller chooses.

**11a. `pen_slot = main_finger_slot + 4` collides with a real panel
slot.** `Input` keeps one `ev_slots` table for every input device, so a
touchscreen contact assigned kernel slot 4 and the pen are the same
entry. The finger's `ABS_MT_TRACKING_ID`/`ABS_MT_POSITION_*` land on a
slot still marked `tool = TOOL_TYPE_PEN`, which makes
`handleMixedTouchEv` honor the pen's next hover `ABS_X`/`ABS_Y` and
rewrite the live contact to the pen's position. The tap crosses
`PAN_THRESHOLD` along the finger→pen bearing and leaves as a swipe.
`BTN_TOUCH` from the pen is worse: it writes the pen's contact state onto
the finger's tracking id and *neither* survives, so an ink stroke leaves
as a page-turn swipe.

**11b. Two-finger gestures only work in slots 0 and 1.**
`GestureDetector:newContact` computes a buddy only for
`main_finger_slot` and `main_finger_slot + 1`; contacts in any other slot
have no buddy and are classified independently. The same two fingers in
slots `{0,2}` produce two swipes instead of a spread — two page turns
instead of a font-size change.

**Not a five-finger hypothetical.** `mixedrouter.lua` carried that
framing until 2026-08-24, when a live capture disproved it: cyttsp5
advertises 32 MT slots (`ABS_MT_SLOT` max = 31) and does **not** allocate
them densely — a 120 s session peaking at *three* simultaneous contacts
used slots `{0, 1, 2, 5}`
(`doc/artifacts/pinenote-input-clocks-20260824/`). A lone finger can be
handed slot 4.

**Where it lives in our tree:** four pinned scenarios in
`pinenote/tools/koreader-input/test-mixedrouter.lua`
(`quirk:pen-slot-collision`, `quirk:pen-slot-collision-tip`,
`quirk:buddy-slots-0-1-only`, plus the `pen-hover-finger-slot3` control),
run by `make koreader-input-check` against the bundle's **verbatim**
`input.lua`/`gesturedetector.lua`. The collision scenario reproduces a
gesture stream byte-identical to the 2026-07-05 hardware bug
`mixedrouter.lua` was written to fix — same mechanism, different route
in.

**Deliberately not fixed locally, and the reason is the module's remit.**
`mixedrouter.lua` disambiguates by event **source**; when the pen and a
finger agree on the slot *number* there is nothing left for it to
disambiguate. A fix has to change the slot *space* — move the pen above
the panel's advertised `ABS_MT_SLOT` max — which is a different job from
"restore the routing upstream already assumes", and it would put a
per-controller hardware constant inside a KOReader module. Upstream can
do it properly and once, for every `wacom_protocol` device
(reMarkable, Elipsa, Sage), by querying the panel's slot range instead of
hard-coding `+ 4`. Same for 11b: generalizing buddy detection beyond a
hard-coded pair is upstream's call, not a local override that our next
KOReader bump has to re-litigate.

**For:** KOReader upstream (`github.com/koreader/koreader`), not the
kernel lineage — this is application code, and `cyttsp5` is behaving
correctly.
**Shape:** an issue with the two reproducers, since the fix is a design
choice (query the panel's range vs. reserve a high constant) rather than
an obvious patch. Our test file is directly quotable: it runs their own
source.
**What has to be true first:** the standing baseline gate. Also worth
saying plainly in the report that we have **not** measured how often the
controller hands out a colliding or non-adjacent slot — one capture says
"not never", which is not a rate. Reporting a frequency we did not
measure is exactly the credibility cost this register exists to avoid.

### 12. A pinch slower than 900 ms silently does nothing — **ready** (reproduced offline, one pinned test)

`Contact:panState` only builds `pinch`/`spread` (and `two_finger_swipe`,
and `rotate`) on the contact-lift branch, and gates that whole branch on
`Contact:isSwipe()` — which requires the interaction to finish within
`ges_swipe_interval`, default `SWIPE_INTERVAL_MS = 900`. Past that the
lift emits `two_finger_pan_release` instead, and **nothing in KOReader
consumes `two_finger_pan_release`** (nor `inward_pan`, `outward_pan`,
`two_finger_pan` or `two_finger_hold_pan` — a scan of the bundle's
`frontend/` + `plugins/` finds no subscriber outside the detector that
emits them). So the user gets no font-size change, no page turn, and no
feedback of any kind.

The failure is *inverted from the user's mental model*: the more slowly
and deliberately you pinch, the more likely it is to do nothing. That is
a poor fit for any device, and a specifically bad one for e-ink, where a
~600 ms panel update trains the reader to move slowly.

**Why this is a design question and not a one-line bump.** Reusing the
*swipe* interval for pinch/spread conflates two different intents: a
swipe is a flick and genuinely should be time-bounded, while a pinch is a
positioning gesture with no reason to be. Candidate shapes: a separate
interval for the span-changing gestures; classifying on span change
rather than elapsed time; or emitting the terminal gesture on lift
regardless of duration when both contacts crossed `PAN_THRESHOLD` in
opposite directions. Upstream should pick.

**Where it lives in our tree:**
`quirk:slow-pinch-is-a-silent-no-op` in
`pinenote/tools/koreader-input/test-continuous-gesture-cost.lua`, run by
`make koreader-input-check` against the bundle's **verbatim**
`input.lua`/`gesturedetector.lua`. It is a one-variable A/B: the same
pinch geometry, the same frames, only the inter-frame gap differs — 20 ms
(260 ms end to end) gives one `pinch`, 80 ms (1040 ms) gives none. The
same file's whole-tree scan is the evidence for the "no consumer" half,
and goes red if upstream ever adds one.

**Deliberately not worked around locally.** `ges_swipe_interval_ms` is
already a `G_reader_settings` key, so raising it is a settings change
rather than a patch — but it would raise it for *swipes* too, which is
the wrong trade, and it would hide the defect from the very users best
placed to report it. The measurement that found this is in
`doc/refresh-policy.md` ("Continuous gestures already defer").

**For:** KOReader upstream (`github.com/koreader/koreader`) — application
code, same destination as item 11, and worth sending in the same issue or
an adjacent one since both are `gesturedetector.lua`.
**Shape:** an issue with the A/B reproducer, since the fix is a design
choice.
**What has to be true first:** the standing baseline gate. Say plainly
that this is reproduced **offline only** — no PineNote panel has been
used to confirm how often a real user's pinch exceeds 900 ms, and we
should not imply a rate we did not measure.
**Status:** ready.

### 13. A C CLUT compiler, and the joint differential it makes possible — **needs-work** (the artifact exists; the offer does not)

`pinenote/tools/wbf/wbf-clut.c` compiles a PVI `.wbf` into hrdl's
`CLUT0002` `custom_wf.bin` **byte-identically** to `wbf_to_custom.py`, in
C, with no Python/numpy/pandas, reusing the lineage's own verbatim
`drm_epd_helper.c` to decode the waveform. Cross-built for aarch64 as
`pinenote-wbf-clut` and confirmed byte-identical there too (under
`qemu-aarch64`), so it runs on the device that needs it.

**Why it matters to them, not just to us.** `doc/hrdl-evaluation.md` §4.2
already names a "CLUT-compiler differential" as the natural first joint
artifact with hrdl, and this is it: two independent implementations of the
same format, gated against each other on a real waveform. It also removes
the Python dependency from the direct-mode first-boot recipe, which is a
real cost for anyone packaging a minimal image — ayakael's recipe pulls
numpy and pandas onto the device to run one compile once.

**For:** hrdl (`git.sr.ht/~hrdl/pinenote-dist`) primarily; ayakael as the
packager who would benefit most.
**Shape:** the tool plus its differential harness, offered as a companion
to `wbf_to_custom.py` rather than a replacement — the Python is the
reference and should stay the reference.
**What has to be true first:** the standing baseline gate, **and** we have
to have actually booted direct mode. Today this compiler is proven only
against the Python; **no panel has ever been driven from its output**
(`doc/direct-mode-adoption.md` P3). Offering a waveform compiler we have
never watched drive a display would be exactly the "code review from a
stranger" failure the gate exists to prevent.
**Status:** needs-work — gated on P3, not on writing.

### 14. Three defects in the direct-mode CLUT compiler — **ready** (as a section of item 1)

Written up in `doc/driver-findings-report.md` (2026-08-25): the
unconditional `summary[:-1]` in `table_summarise`'s "remove suffix" step
(an `enumerate`-index/tuple-element mix-up, which also `IndexError`s on a
single-run summary); the 32→16 downsample's undetected four-way cell
collision, whose winner depends on loop order and which never clears the
cell, so a short sequence can leave a previous row's `0x20` end marker
behind; and `drm_epd_helper.c` not applying the `+ 1` to
`temp_range_count`, so the driver can never select the file's top
temperature range (43–48 °C on the PineNote's waveform).

**For:** hrdl for the first two (`pinenote-dist`), the m-weigand/hrdl
lineage for the third (`drm_epd_helper.c`).
**Shape:** part of the item-1 report, or its own message if that report is
sent trimmed — the first two are only interesting to someone running
direct mode.
**What has to be true first:** the standing baseline gate. Say plainly
that all three are **offline** findings from a differential and a file
read: we have driven no panel with any CLUT, so we cannot say what the
corrected tables look like on glass, and finding 1's fix is precisely the
kind of change that needs a display in front of it.
**Status:** ready.

## Standing caveats

- **We are ahead of, not aligned with, the lineage.** Line numbers and
  structure in our reports are ours. Always re-fetch the target branch and
  re-verify before sending — the method that worked on 2026-07-31 is
  `https://git.sr.ht/~hrdl/linux/blob/<branch>/<path>`, which returns the
  raw file, plus `git ls-remote --heads` for tips.
- **pmaports has a stale mirror on `gitlab.com` — do not read it.** It
  still shows the PineNote kernel at 6.3.10 in `device/testing`, pinned to
  a 2023-era m-weigand commit, APKBUILD last touched 2024-07-30. The
  canonical instance is **`gitlab.postmarketos.org`**, where the same
  package is 6.19.3 in `device/community` and actively maintained. This
  cost an incorrect "postmarketOS is dead" conclusion on 2026-07-31;
  don't repeat it.
- **`doc/hrdl-evaluation.md` §3.3 is the standing strategy**: stay on the
  m-weigand lineage at 7.0.x, track `v6.19_ebc` as our rebase reference
  and `v6.19_ebc_custom` as the UAPI-direction reference.
- **Report, don't patch** (`CLAUDE.md`): driver fixes belong to the
  lineage. This register is how we honor that without dropping findings on
  the floor.

## 15. `rockchip_ebc_blit_neon.c` does not compile with `CONFIG_DRM_ROCKCHIP_EBC_3WIN_MODE=y`

**Where it would go:** hrdl (`~hrdl/linux`, `v6.19_ebc_custom`).

**What:** the 3WIN-mode branch of `rockchip_ebc_schedule_advance_fast_neon`
has an unbalanced parenthesis and references an identifier that is not
declared in that translation unit. Both are wholly inside the `#ifdef`:

```c
#ifdef CONFIG_DRM_ROCKCHIP_EBC_3WIN_MODE
        if (!direct_mode) {
            vst1q_u8(phases_line, vshrq_n_u8(q8_inner_new, 6);   /* 2 opens, 1 close */
        } else
#endif
```

`gcc` reports `error: 'direct_mode' undeclared` and
`error: expected ')' before ';' token` at `:177` and `:178`.

**How found:** cross-compiling his tree against Linux 7.1.8 for arm64
while sizing a possible adoption (2026-08-25). The direct-mode
configuration — his default — builds clean; only `3WIN_MODE=y` fails.

**Why it matters to him:** a missing parenthesis cannot ever have
compiled, so that Kconfig option has never been buildable. Anyone
selecting it, or any distributor offering it, gets a build failure with
no hint that the option is unmaintained. Either fix it or drop the
option.

**Status:** not sent. We are not shipping his driver yet, and sending a
build-break report is more useful attached to a concrete adoption than
ahead of one.
