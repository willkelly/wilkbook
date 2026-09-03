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

**2026-08-27 amendment — the collision defect is now quantified and
attributed** (`pinenote/tools/wbf/wbf-clut-diff.c`, the decode-fidelity
differ: the verbatim `drm_epd_helper` 4BIT_PACKED view vs an
independent walk of the compiled CLUT, per bin/slot/from/to, on this
device's own waveform):

- **32–34 GL16/GC16 cells per temperature bin (~13 % of transitions),
  6 DU4, 2 DU play genuinely different pulse sequences** than the
  shipping hardware's even-even read — and every one attributes to an
  odd 5-bit row winning the four-way cell collision, overwhelmingly
  `from5 ∈ {3, 29}`, i.e. **4-bit gray levels 1 and 14 — the
  near-extreme levels antialiased text edges occupy**. The class that
  moves ink, sitting exactly where the direct driver's text residue
  lives (doc/status.md part 13's 2× same-session gap).
- A further pervasive class: **~75–82 % of GL16 transitions are
  delivered with their leading neutral phases stripped**
  (shift-equivalent: same pulses, front-loaded) — co-scheduled pixels
  de-synchronize vs the shipping stack's aligned timeline and
  transitions complete early. A candidate mechanism for the settling
  ("coming into focus") character. Whether this is a fourth defect or
  deliberate reference behavior is not yet established against
  `wbf_to_custom.py`.
- The trailing-suffix defect shows as the differ's length-only class
  (INIT: all 256 cells, drives identical).

These remain offline findings for the LINEAGE report, but the glass
context has changed: the identity CLUT has now driven this panel for
two days, and the measured 2× residue gap plus the settling character
are consistent with, though not yet causally pinned to, these classes.

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

## 16. Two module parameters in `rockchip_ebc` that do not mean what they say

**Where it would go:** hrdl (`~hrdl/linux`, `v6.19_ebc_custom`), with a
cosmetic sibling in the m-weigand lineage this descends from (and so in
our own forward-port patch).

**What:** two independent defects in the direct-mode driver's parameter
block, both of which mislead a distributor writing a `modprobe.d` file.

1. **`MODULE_PARM_DESC(split_area_limit, ...)` sits on top of
   `module_param(limit_fb_blits, ...)`** (`rockchip_ebc.c:266-268`) — a
   description left behind by a rename:

   ```c
   static int limit_fb_blits = -1;
   module_param(limit_fb_blits, int, S_IRUGO|S_IWUSR);
   MODULE_PARM_DESC(split_area_limit, "how many fb blits to allow. -1 does not limit");
   ```

   `MODULE_PARM_DESC` only emits a modinfo string; it registers nothing.
   So the built module advertises `parm: split_area_limit:...` while
   there is no `/sys/module/rockchip_ebc/parameters/split_area_limit`,
   and `limit_fb_blits` — the parameter that does exist — has no
   description at all. Two of our own passes over this driver counted
   `split_area_limit` as "shared with our driver" purely on the strength
   of that modinfo line; the source says otherwise, and **`dclk_select`
   is the only one of our nine shipped options that is real in his
   module.**

2. **`delay_a` is declared, registered and never read.** The comment
   above it points at `plane_atomic_update` "for specific usage"; there
   is no use of the identifier anywhere else in the tree.

**How found:** twice, independently, on 2026-08-25 — once deriving the
real parameter set from `module_param*()` registrations for the
direct-mode modprobe options, once checking our nine shipped options
while wiring the `reader-direct` study flavor. Pinned as
`quirk:stale-parm-desc` in `make ebc-modprobe-options-check`, which
fails if a future extractor starts believing `modinfo -p`.

**Why it matters to him:** the kernel does **not** refuse an unknown
module parameter — `unknown_module_param_cb()` (`kernel/module/main.c`,
7.1.8 at `:3381`) `pr_warn`s "unknown parameter ignored" and returns 0 —
so a configuration written against the wrong name **loads successfully
with that intent silently dropped**. `modinfo` is the only parameter
inventory most integrators consult, which makes a wrong description a
defect whose whole cost lands on the user, quietly. That is worse than a
refusal, not better.

**The same typo is in our tree, harmlessly**, inherited verbatim through
m-weigand into `linux-pinenote-7.0-forward-port.patch`: we still declare
a real `split_area_limit`, so the stale desc merely duplicates a `parm:`
line and leaves `limit_fb_blits` undocumented. It becomes a real bug in
his tree only because the variable was deleted and the description was
not. Worth reporting to both, in opposite registers of severity.

**Status:** not sent, same reasoning as item 15 — worth more attached to
a concrete adoption than ahead of one. Both are one-line fixes.

## 17. Kernel NULL-deref panic: destroy a uinput device under a live evdev reader, then restart the reader

**Where it would go:** mainline `input`/`evdev` (likely — the faulting
frame is not conclusively attributed, see below), as observed on Linux
7.1.8 (`linux-pinenote-hrdl-direct-7.1.8`, the direct-mode study
kernel; nothing in our patch stack touches uinput or evdev, so the code
under suspicion is mainline's).

**What:** destroying a uinput-backed input device **while a consumer
still holds its evdev node open**, then restarting that consumer, panics
the kernel. Captured on the UART console during the 2026-08-25
direct-mode glass session (`uart-d5.log`; excerpt as recorded in
`doc/status.md`):

```
Unable to handle kernel NULL pointer dereference at virtual address 0000000000000008
Oops: 0000000096000044 [#1] SMP
Kernel panic - not syncing
```

**Reproduction pattern**, consistent across both occurrences that
session: (1) a uinput device exists (the orientation bridge's
`wilkbook-orientation` node, or a D5 gyro injector's); (2) KOReader has
the evdev node open; (3) the uinput device is destroyed out from under
it — the provider process killed, or `UI_DEV_DESTROY` on its fd; (4) the
reader is restarted; (5) NULL deref at offset 8, Oops
`0000000096000044` (a data-abort **write** through a near-NULL pointer),
panic. The controls both hold: reader restarts with **no** preceding
device destruction never crashed, and the **stop-consumer-first**
ordering — stop KOReader, then tear down the uinput device — survived
the same session where the other ordering died. That ordering is now the
standing session discipline, but it is a workaround: hot-unplugging an
input device under a reader is an ordinary event (any USB keyboard
yank), not an API misuse.

**How found:** D5 rotation debugging on the first direct-mode glass
session — injected uinput devices and repeated reader restarts made the
destroy-while-held ordering common enough to hit twice.

**Why it matters to mainline:** if this is what it looks like, any
userspace can panic the kernel with unprivileged-shaped operations on
`/dev/uinput` plus an open evdev client — a crash, possibly a
use-after-free-adjacent one, in core input hotplug. That is worth a
report even from a niche tree, *provided* it reproduces on a kernel
nobody can blame us for.

**What has to be true first:** (1) a minimal reproducer — create uinput
device, open its evdev node from a second process, destroy the device,
restart the second process — on a **vanilla** kernel; QEMU is enough,
no PineNote required, and it doubles as the trace decode the console
capture cannot give us (both on-glass traces are partially garbled by
console interleaving, which is why the faulting function is still
unattributed). (2) Check current mainline `drivers/input/` history for
an existing fix before reporting — 7.1.8 is not tip. (3) The standing
baseline gate does **not** apply if the vanilla reproducer works: a
panic reproducible on stock kernels stands on its own, with no
credibility dependence on our tree.

**Status:** not sent. Console evidence and reproduction pattern are
recorded; the offline reproducer is the next step and needs no
hardware.

## 18. dwc3: a bound, unattached gadget aborts system suspend (7.1.8)

**Status: needs a bisect-or-config check before any send.**

**What we saw (2026-08-26, on glass, `doc/status.md`):** with the ACM
gadget configured through configfs and bound to `fcc00000.usb` but **no
host cable attached**, every `echo mem > /sys/power/state` aborts:

    dwc3 fcc00000.usb: wait for SETUP phase timed out
    dwc3 fcc00000.usb: failed to set STALL on ep0out
    dwc3 fcc00000.usb: ep0 out: -110
    dwc3 fcc00000.usb: failed to enable ep0out
    dwc3 fcc00000.usb: PM: failed to suspend: error -11
    Some devices failed to suspend, or early wake event detected

The suspend unwinds before the rails ever drop. Unbinding the UDC
(`echo "" > .../UDC`) makes the identical suspend enter ultra cleanly
(rails off, DDR retrain on wake), and rebinding afterwards works.

**Why we believe it is a 7.1 change and not our configuration:** the
2026-08 unplugged soak ran **170 suspend cycles with zero failures** on
7.0.11 with the same gadget service, same configfs layout, same
unattached state (`doc/artifacts/pinenote-ultra-soak-20260815/`). Same
DT, same userspace; only the kernel series moved.

**Where it would go:** linux-usb / dwc3 maintainers, if it reproduces
outside our patch stack. None of our seven patches touches dwc3 or the
gadget core, but the BSP SIP suspend patch changes the suspend ordering
around it, so we cannot yet exclude an interaction.

**What has to be true first:** (1) reproduce on a clean 7.1.x defconfig
build (no SIP suspend patch) on the device — if it disappears, the bug
is ours to understand, not theirs; (2) check whether mainline dwc3
already grew a fix between 7.1 and HEAD (the ep0 SETUP-phase wait in
`dwc3_gadget_suspend` has history); (3) decide whether the reader's
suspend path should unbind the UDC as a matter of policy anyway — the
gadget draws ~2 mA awake and is a development affordance (the
power ledger already recommends gadget-off by default), which would
make this moot for the product while still worth reporting.

**Interim workaround, live tonight:** unbind before suspend, rebind
after. If auto-suspend ever runs on a 7.1 image before this is
resolved, its suspend hook must do the same or every idle suspend will
silently abort at ~full awake draw — the failure mode is a device that
never sleeps while looking asleep.

## 19. Direct-mode driver: redraw_delay > 0 parks damage indefinitely from idle

**Status: needs-verification against hrdl's intent before any send —
this may be working-as-designed for its actual use case.**

**What we saw (2026-08-26, on glass, `doc/status.md`):** with
`redraw_delay` set nonzero (tried 10000 and 1) and the panel idle,
every subsequent damage submission — page turns included — is parked
and never drives: zero EBC interrupts, framebuffer content visibly
stale. The waiting counter (`waiting_remaining = redraw_delay`,
`rockchip_ebc.c` work loop) decrements per *hardware frame*, and an
idle panel generates no frames, so the countdown never advances and
nothing ever schedules. A `GLOBAL_REFRESH` recovers (the wash bypasses
the waiting queue and its frames drain the counters).

**Why it is plausibly by design:** the knob pairs with the MODE ioctl's
`set_redraw_delay` and makes sense for FAST-mode handwriting, where
continuous strokes keep frames flowing and delayed redraws ride behind
the pen. Nothing in the driver documents the from-idle behaviour.

**Why it still deserves a report:** the failure is silent and total
from a reader's perspective — a sysfs write any experimenter would try
("defer the ghost-clean a little") freezes the screen with no error,
no log line, and no timeout. A one-line doc comment or an idle-kick
(schedule a frame when damage waits on a dead panel) would fix the
trap.

**What has to be true first:** read his dist's actual use of
set_redraw_delay to confirm the FAST-mode pairing; reproduce on his
unmodified branch (ours differs only by the DT hunk and build glue in
this area).

## 20. shepherd: the inetd ssh listener stays armed during halt and restarts stopped dependencies, wedging shutdown

**Where it would go:** bug-guix / the Shepherd's tracker
(shepherd is the supervisor; the service arrangement is Guix's
`openssh-service-type` in inetd style).

**Status: proven on device from the system's own log, one occurrence;
needs a minimal reproducer before sending.**

**What we saw (2026-08-26, `doc/artifacts/pinenote-shutdown-wedge-20260826/`):**
during `Stopping service root...` — four seconds into a clean, fast
teardown — shepherd killed the transient sshd serving the very session
that had issued `reboot`. The client reconnected (a tooling bug on our
side, since fixed), and shepherd **accepted** the new connection on the
still-armed inetd listener, spawned a transient service for it, and
**started the `networking` service the halt had stopped moments
earlier** to satisfy the transient's dependency. `Service networking
has been started.` is the last line the system ever logged: the halt
never completed, and the device sat indefinitely with the kernel alive
and userspace half-torn-down (ping answering through the restarted
dhcpcd, no ssh listener, no getty, no respawns) until a power-button
cycle.

**Why it deserves a report:** a headless machine that receives one ssh
connection in its ~seconds-wide halt window hangs forever instead of
rebooting — and monitoring systems, retrying deploy scripts, and
health-checkers all connect on exactly that schedule. The
half-alive state is also actively misleading (the box answers ping,
so remote hands conclude "it's up, ssh is just broken"). Plausible
fixes at either layer: shepherd could close inetd listeners at the
top of halt rather than in dependency order, refuse constructor
starts once halt has begun, or both.

**What has to be true first:** the baseline gate, plus a reproducer
outside our tree — a stock Guix system (or bare shepherd) with an
inetd-style service, `reboot` over ssh, and a scripted reconnect-on-
disconnect; confirm the same accept→dependency-restart→wedge sequence.
Also confirm against current shepherd (the device ran 1.0.x).

## 21. KOReader: `Input:resetState()` under live contacts creates ghost MT contacts; the gesture detector's safety nets then crash the next two-finger pan

**Where it would go:** koreader/koreader (frontend/device/input.lua,
frontend/device/gesturedetector.lua, frontend/apps/reader/modules/readerrolling.lua).

**Status: crashed on device (2026-09-02, PineNote, pinch-to-font-size),
root-caused offline, reproduced deterministically from the verbatim
upstream files, worked around in our device layer
(`device/pinenote/slotguard.lua`); the reproducer is
`pinenote/tools/koreader-input/test-slotguard.lua` and runs on any
x86 host against the stock bundle.**

**What we saw:** `gesturedetector.lua:325: attempt to perform
arithmetic on field 'x' (a nil value)` in `Contact:getPath`, called from
`handleTwoFingerPan` on a buddy contact, with `GestureDetector:newContact
recorded an initial_tev out of order for buddy slot 0` a few frames
earlier — and, over the preceding forty seconds, six more of those
warnings each landing at the exact second of a `Restoring user input
handling` line.

**Mechanism (all upstream code):** a pinch is emitted on the FIRST
finger's lift; ReaderFont changes the size and ReaderRolling re-renders
with `Input:inhibitInput(true)` (`readerrolling.lua:999`), which swaps
`handleTouchEv` for `voidEv` — the still-down finger's frames are
dropped — and `inhibitInput(false)` then calls `Input:resetState()`,
which replaces `ev_slots` with a single empty `{ slot = 0 }` and drops
every contact. The finger still on the glass keeps reporting per the
MT protocol-B contract: only what changed, so neither its tracking id
nor an unchanged axis is re-sent. Its next frame lands in the empty
table as a contact with no `id` and possibly no `x`. When the user's
next finger lands, `newContact` pairs it with that ghost as a buddy and
the "safety net for broken platforms" copies the positionless table
into `initial_tev`; `Contact:setState` has the same net. The next
`handleTwoFingerPan` builds `rstart_pos` from `buddy.initial_tev.x`
(nil, no throw) and calls `buddy:getPath()`, whose subtraction throws.
`ev_slots` being persistent is exactly why this needs the reset: on a
slot that has ever been used, x/y are otherwise always present.

**Why it deserves a report:** any reader that re-renders on a pinch and
inhibits input during it (that is the shipped ReaderRolling path) is
one delta-only frame away from this crash, on every MT panel. Three
plausible upstream fixes, any one sufficient: (1) `inhibitInput(false)`
re-reads slot state from the kernel (`EVIOCGMTSLOTS` for
`ABS_MT_TRACKING_ID`/`POSITION_X`/`POSITION_Y`) instead of forgetting
it; (2) the two safety nets refuse to record an `initial_tev` without
`x`/`y` (leave it nil and let `initialState` record the real one); (3)
`getPath`/`handleTwoFingerPan` guard a buddy without a position. Our
workaround does the frame-level equivalent of (2): a slot with no id,
or a live id and no position, is withheld from the detector until it
is complete.

**What has to be true first:** the baseline gate; reproduce on the
stock SDL build with the test's synthetic stream (it uses only
upstream files, so this is mechanical); confirm current master still
has `resetState()` in `inhibitInput(false)`.

**Our follow-up (independent of upstream):** the faithful fix on our
side is the `EVIOCGMTSLOTS` resync after every reset, so a finger that
survives a re-render stays a first-class contact instead of being
invisible until it is complete again — recorded here rather than done,
because the guard already makes the crash impossible and the resync
needs a real kernel to test against.

## 22. RK356x: a kexec'd kernel hangs in `rockchip_grf_init` because the previous kernel gated `pclk_pipe`

**What:** `drivers/soc/rockchip/grf.c` carries an rk3566 table that
writes three USB3-OTG bits into the PIPE GRF (`rockchip,rk3566-pipe-grf`,
`0xfdc50000`) from a `postcore_initcall`. That register block is on
`pclk_pipe`. Nothing in a board tree without PCIe/SATA/USB3 keeps that
clock, so the running kernel gates it as unused; U-Boot leaves it on,
which is why every cold boot is fine and every kexec'd boot stalls at
0.12 s with no message (an APB access into an unclocked block never
completes; the workqueue watchdog reports a lockup on whichever CPU ran
init). Found on the PineNote (RK3566, 7.1.8) 2026-09-02: three identical
hangs, then a full boot with `initcall_blacklist=rockchip_grf_init`,
`clk_summary` showing `pclk_pipe` at enable count 0 while the pipe power
domain was on.

**Fix candidates, either sufficient:** (1) `clocks = <&cru PCLK_PIPE>`
(and `clock-names`) on the `pipegrf` syscon node, so the syscon's
regmap-mmio enables the clock around each access — the mechanism
already used for other clocked syscons; (2) `CLK_IGNORE_UNUSED` on
`pclk_pipe` in `clk-rk3568.c`, as `clk_pcie*_pipe_dft` already are.
**Correction, the same night:** (1) was tried on glass (PR #46: the
built DTB carries the `clocks` reference, verified with fdtget) and a
kexec into that kernel with no skip *still* hung in `rockchip_grf_init`;
the PIPE power domain was measured on throughout. So the gated
`pclk_pipe` is a true observation but **not the mechanism**, and neither
is the domain. Established: the write into the pipe GRF from a kexec'd
kernel never completes, cold boots are fine, and skipping the initcall
on the kexec command line boots every time (the GRF retains the cold
boot's values). Next: a register diff (CRU, PMU, GRFs) between a cold
and a kexec'd boot, and a watchdog-armed userspace write into the block.
Until the mechanism is known, what goes upstream is the observation and
the workaround, not a fix.

**Related, same session (a known upstream limitation, not a bug
report):** the GICv3 LPI tables are reserved for the next kernel only
under EFI (`gic_reserve_range` is a no-op otherwise), so a U-Boot/DT
kexec prints "Booted with LPIs enabled, memory probably corrupted" and
this GIC cannot clear `EnableLPIs`. `irqchip.gicv3_nolpi=1` is the
documented answer where nothing uses LPIs; worth a line in the kexec
documentation for arm64 DT platforms.

**What has to be true first:** the baseline gate; reproduce on a clean
mainline tree with a plain rk3566 board (the PineNote DTS is not
upstream); confirm `clk_summary` after boot and the hang with
`initcall_debug`; test candidate (1) on glass.

## 23. hrdl direct-mode driver: probe returns bare after a failed `rockchip_ebc_drm_init`, leaking runtime PM and the refresh kthread

**What:** in hrdl's direct-mode rework of `rockchip_ebc_probe` the error
path after `rockchip_ebc_drm_init()` became `return ret;` — the
`err_stop_kthread` label (and its `kthread_stop`) was removed while
`err_disable_pm` survives, now unreachable from that path. A probe that
fails there returns with `pm_runtime_enable` still counted and the
parked refresh kthread alive. On wilkbook's direct image the first probe
fails there by construction (the CLUT is compiled on-device after the
module is loaded, then the driver is rebound), so every boot logs
`rockchip-ebc fdec0000.ebc: Unbalanced pm_runtime_enable!` at the
rebind. Benign in effect; still a leak on every failed probe.

**Fix:** restore `goto err_stop_kthread;` and the label
(`kthread_stop(ebc->refresh_thread);` falling into `err_disable_pm`).
Two lines.

**What has to be true first:** the baseline gate; confirm hrdl's current
tree still has the bare return (our patch is a snapshot); the pin
`make direct-probe-quirk-check` goes red when we port the fix or rebase
over theirs, by design.

## 25. RK3566 (PineNote): the watchdog resets the SoC at runtime; a kexec into a kernel that hangs before its drivers probe defeats it — mechanism unknown

**What:** `rockchip,rk3568-wdt` / `snps,dw-wdt` at `0xfe600000` **does
reset the chip as configured**, confirmed 2026-09-03 16:30 UTC
(10:30 MDT) on the running generation-4 kernel with no kexec involved
at all: armed via `echo 1 > /dev/watchdog0` (closed without the magic
character — see the driver quirk below), `WDT_CCVR` counted down at
24 MHz from `0x3ff41391` (≈44.7 s, matching the 44 s `timeout`), SSH
dropped ~45 s after arming, and the UART showed `DDR Version V1.10
20200218_resume`, U-Boot SPL, the boot menu (~58 s from arming by the
poller); the UART watcher picked os2 and generation 4 booted normally.
Registers immediately before arming: WDT_CR `0x8` (RMOD=0,
reset-on-first-timeout; RPL=2), WDT_TORR `0xe`, WDT_STAT `0`,
`CRU_GLB_RST_CON` (0xfdd200dc) `0x103`, `GLB_CNT_TH` (0xfdd200d0)
`0x00640064`.

Against that: two earlier tests of the **same** arm sequence — the
kexec-hardening helper's `wd:write("1"); wd:close()`, issued
immediately before `kexec -e` — through the update path's kexec
(2026-09-02 23:24 and 2026-09-03 01:34 local MDT) hung the next kernel
0.16 s in (the item-22 `rockchip_grf_init` stall) and produced **no
reset in four minutes, either time**; the UART sat silent (no repeated
`DDR Version`/BootROM output at all — not even a botched
reset-and-rehang loop), and the device needed the power button both
times. Same hardware, same arm sequence, same starting register state:
resets when nothing else happens, does not reset when a kexec
intervenes. Something about the kexec transition — not the watchdog's
own configuration — defeats it. The PX30-style route-bit theory (the
mainline U-Boot fix "make TSADC and WDT trigger a first global reset,"
`CRU_GLB_RST_CON` bits 0–1) is retested and still refuted: the register
already reads `0x103` on this board, was confirmed unchanged by
writing those bits again before the second armed-hang test, and the
hang still didn't reset (PR #54 closed).

**Driver quirk pinned along the way, not itself the cause:**
`dw_wdt_stop()` (`drivers/watchdog/dw_wdt.c`) is a hardware no-op on
this board: `if (!dw_wdt->rst) { set_bit(WDOG_HW_RUNNING, ...); return
0; }`. The `rockchip,rk3568-wdt` node (`rk356x-base.dtsi`, unmodified
by the forward-port patch) carries `clocks` but no `resets` property —
confirmed live on the device
(`/sys/firmware/devicetree/base/watchdog@fe600000/` has no
`resets`/`reset-names` file) — so `devm_reset_control_get_optional_shared()`
always returns NULL and every call to `stop()` reports success without
touching a single hardware register. This includes the SYS_RESTART
reboot notifier that `kernel_kexec()` **does** fire
(`kernel_restart_prepare()` → `blocking_notifier_call_chain(reboot_notifier_list,
SYS_RESTART, ...)`; `SYS_RESTART == SYS_DOWN`, so
`watchdog_reboot_notifier`'s check matches and it calls
`wdd->ops->stop()`). Relatedly, `dw_wdt_ident.options` carries
`WDIOF_MAGICCLOSE`, so closing `/dev/watchdog0` without writing `'V'`
never even reaches `stop()`: `watchdog_release()`'s guard evaluates
false, `err` stays at its initial `-EBUSY`, and the "watchdog did not
stop!" `pr_crit` fires and pings the watchdog again — a routine,
expected consequence of this policy on this driver, not a fault, and it
happens on every arm (the runtime test's included, since its arm used
the identical `echo 1 > /dev/watchdog0` idiom). Net effect: **the
software "stop" path is proven, from source, to be completely inert on
this board in either direction** — it cannot explain the
kexec-vs-no-kexec difference, since it behaves identically in both.

**Open, ranked most to least likely:**

1. **Leading candidate, mechanism not located.** The watchdog's
   counting reference clock (`tclk_wdt_ns`, CRU `CLKGATE_CON(26)` bit
   14, parented on `xin24m`) stops advancing somewhere between the old
   kernel's shutdown and the new kernel's earliest boot, freezing
   `WDT_CCVR` before it reaches zero. `clk_summary` on the
   currently-running (post-reset) kernel shows both `tclk_wdt_ns` and
   `pclk_wdt_ns` enabled (`enable_cnt` 1, held by the bound `dw_wdt`
   driver's `devm_clk_get_enabled()`), so — unlike item 22's
   `pclk_pipe`, which is simply never claimed and hence gated by the
   day's ordinary `clk_disable_unused()` — something would have to
   *actively* re-gate an in-use clock for this theory to hold, and no
   such write turned up in `clk-rk3568.c`'s `rk3568_clk_init()` or
   `drivers/clk/rockchip/clk.c`'s registration path
   (`clk_disable_unused()` itself runs at `late_initcall_sync`, long
   after the observed 0.16 s hang, so it cannot be the direct actor).
   The strongest evidence for this over "the reset fired but got
   absorbed" is the total UART silence: a genuine chip-level reset
   always restarts cleanly from the boot ROM regardless of what Linux
   left in the CRU — proven by the runtime test itself, which reset
   into a clean boot from the identical starting register state — so
   four minutes with no BootROM/U-Boot output at all argues the reset
   request never asserted, not that it fired into a wall.
2. **Reset-domain scoping too narrow — retested, inconclusive.** See
   the route-bit retest above: the obvious "wrong bits" theory is
   refuted, but a finer theory — that the "first global reset" *tier*
   structurally cannot recover a wedged AXI/APB transaction, and only a
   fuller reset can — remains open and unconfirmed; no RK3568 TRM or
   bit-level `cru_rk3568.h`/`rst-rk3568.c` turned up in the tree or in
   `/gnu/store` to check against (only `drivers/clk/rockchip/softrst.c`,
   generic, no RK3568 bit table; only `.drv` derivations for
   `u-boot-2026.01` exist in the store, no unpacked checkout).
   `CRU_GLB_RST_ST` (0xfdd200d4), read now on the post-reset
   generation-4 boot, is `0x00000000` — plain zero despite this exact
   boot having been caused by the watchdog — which is not informative
   on its own: either the register isn't sticky past the U-Boot
   handoff, or 0xd4 isn't the right offset/interpretation on this SoC
   revision.
3. **Firmware-level (ATF/BL31), unverifiable offline.**
   `machine_shutdown()` (`arch/arm64/kernel/process.c`) is a thin
   `smp_shutdown_nonboot_cpus()` wrapper — generic ARM64 hotplug code,
   nothing Rockchip-specific in the Linux tree. If BL31 (EL3 firmware;
   no source present anywhere in this checkout or the Guix store) does
   anything clock/bus-adjacent as a side effect of the PSCI CPU_OFF
   calls this issues, it is invisible to source review. Lowest
   confidence; flagged rather than argued.

**Safe next measurements:** done this session, read-only: confirmed no
`resets` property on the live devicetree; confirmed both wdt clocks
read enabled in the current `clk_summary`; confirmed `CRU_GLB_RST_CON`
unchanged at `0x103`; read `CRU_GLB_RST_ST` (inconclusive, above). For
a future session: (a) an operator-present but still non-destructive
test — arm with a much shorter timeout
(`echo 3 > /sys/class/watchdog/watchdog0/timeout` before arming) and
wait an order of magnitude longer than the timeout before reaching for
the power button; a reset that still never comes after ~10x the
timeout strengthens "frozen" over "very delayed," at no more risk than
what today's hang already recovers from (the power button); (b) if a
JTAG/SWD probe is ever available, read `WDT_CCVR` (0xfe600008) live
during a deliberately armed hang — the one test that would directly
settle "frozen vs. still counting" instead of inferring it from
silence; (c) locate the RK3568 TRM or `u-boot-2026.01`'s
`cru_rk3568.h` (a `guix build -S` of the u-boot package was not
attempted this session — slow, and not needed to reach the ranking
above) to interpret `CRU_GLB_RST_ST` properly.

**What has to be true first:** one of the safe next measurements above
narrows this to a single mechanism; then either a kernel-side fix (if
it is the WDT clock) or accepting the power button as the trial-recovery
path and saying so plainly in the update-path docs.

