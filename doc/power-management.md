# PineNote power management: evidence first

**Current state (2026-08-08).** What is hardware-proven, in one place:

- **Ultra suspend is in production** (2026-08-08, R12): hrdl's rails-off
  configuration adopted whole on the primary kernel
  (`linux-pinenote-7.0-ultra-rails.patch`, matched pair enforced by
  `make ultra-coupling-check`); three consecutive rails-off resumes
  (RTC + power button); **4.64 mA measured** over a 40-min gauge bracket
  vs deep's ~20 mA — ~36 days of pure suspend on paper. Wake sources
  reduce to rk817-internal (RTC, power button, charger). The ≥3-day soak
  is running. `doc/artifacts/pinenote-ultra-r12-20260808/`.

- **Deep suspend works** (2026-08-02): BSP SIP activation is live and
  bound (`cfg: 0x5ec`, wakeup-config `0x10`); the device enters `deep`,
  wakes on the RTC alarm and the power button, and resumes with a
  working display at both CRTC states. Suspend-ladder rungs 1–3 all
  PASS (`doc/status.md`).
- **Auto-suspend is live on os2** (2026-08-03): the standalone
  `pinenote-autosuspend` daemon sleeps the device after 5 minutes
  without input (RTC backstop every cycle, sleep banner, charging
  inhibit, short-press-to-suspend). Consequence: **ssh is
  intermittent** — see `doc/device-access.md` for the runtime
  `enabled=0` pause before working on the device.
- **Standby has never been measured, and what shipped was not the deep
  floor** (2026-08-07, offline): every deployed daemon re-armed a full
  idle period after an RTC-backstop wake, so an idle device ran ~25 %
  awake — 54.7 mA, flat in ~3 days, not the ~8 the floor implies. Fixed
  in tree (`626cb02`), default backstop 900 s → 1 h; **not deployed, and
  every post-fix figure is arithmetic.** Numbers and acceptance: "The
  idle duty cycle" below.
- **The awake floor fell twice on 2026-08-06**: vdd_cpu auto-PFM is
  accepted on hardware (settled reader idle 174 → **156.9 mA**,
  ~25.5 h), and DDR DVFS landed (`wilkbook_dmc` + input-driven boost;
  DDR at 324 MHz saves ~24.8 mA, quiesced measurement).
- **Deep draw is 20.6 mA and it is the rail floor** (2026-08-06 audit,
  peripherals exonerated). The 2026-08-02 gauge A/B read 19.3 mA — see
  the reconciliation note under the targets table.
- **Not yet proven**: the unplugged multi-day soak; any wake source
  beyond RTC + power button (cover wake in particular); the TPS
  `ENABLE` 2f → 20 drift across deep is unexplained; ultra-suspend
  remains unadopted (rail-kill wake collision unresolved).
  [Superseded 2026-08-08: ADOPTED — rails-off ultra resumes on both wake
  legs and ships on the primary kernel; the running multi-day soak is the
  outstanding suspend proof. See the lead bullet above.]

The rest of this document accumulated with the program. Dated sections
are session records and stand as written at their dates; where later
work superseded one, a dated note says so in place. The document began
as the first, **read-only** power-management slice — instrumentation
discovery, not policy — and the companion `pinenote/tools/power` Guile
snapshot tool from that slice is still the measurement instrument: it
emits versioned S-expressions on stdout, accepts a fake root for
offline tests, and only reads an explicit allowlist.  It never reads
waveform or VCOM calibration data and never writes sysfs, procfs,
debugfs, or tracefs.

## Open question: the cover wakes it, and it should not (2026-08-09)

**Observation, on glass:** opening the cover wakes the device from ultra
suspend. Confirmed by the operator; cover-close-to-suspend is confirmed
on two devices the same day.

**Why that is a problem for our model.** The cover switch is
`gpio0 RK_PC7` (`rk3566-pinenote.dtsi`, `switch-cover`). GPIO0's pad
supply comes from `pmuio1`/`pmuio2`, and this board wires **both to
`vcc_3v3_pmu`** (`&pmu_io_domains`). The production configuration marks
`vcc_3v3_pmu` `regulator-off-in-suspend`, and bl31's banner confirms the
rails reach the PMIC (`pmic: 0x14, 0x00`). So the pad should be
unpowered during suspend and a transition on it undetectable — the exact
reasoning this repo used to explain R10/R11, and to tell testers the
cover could not wake the device. That explanation is now incomplete at
best.

**Candidate explanations, none verified:**

1. **The rail does not actually drop.** The DT says off-in-suspend; the
   rk817 may decline for a rail with other constraints, or bl31's
   `PMIC_LP` handling may override the regulator framework's intent. If
   so, our 4.64 mA is achieved by something other than we think — and
   the number stands regardless, since it was measured, not derived.
2. **The PMU wake detector is not on the pad supply.** GPIO0 is the PMU
   bank; `RKPM_SLP_PMUALIVE_32K` is set in `cfg 0x5ec`, so the PMU alive
   domain is running. A hall switch that shorts the line to ground may
   present a detectable level to alive-domain logic without the IO
   supply being up.
3. **Something else in hrdl's configuration keeps this path alive** that
   we adopted without isolating.

**Why it matters even though the news is good.** A third wake source is
a product win. But the same reasoning that said "cover cannot wake"
also underwrites "the pen cannot wake" and parts of how R10/R11 were
interpreted — if the premise is wrong, those conclusions deserve
re-examination rather than inheritance.

**A discriminator that was proposed and is VOID (2026-08-09).** "Does
the pen wake it?" was offered here as the cheap test — same pad supply,
different pin, so pen-wakes would mean the rail is up. It was run: the
pen does not wake it. **That result carries no information**, because
the pen is not an armed wake source in the first place: only two nodes
in `rk3566-pinenote.dtsi` carry `wakeup-source` — the cover switch and
the rk817 PMIC — and this repo's own suspend gate pins exactly that
(`expected_wake_paths`). The pen could never have woken the device
regardless of any rail. The premise was not checked before the test was
proposed.

**Current is not a discriminator either.** R11's rails-ON ultra
estimated ~3 mA (wide error bars, boot cost subtracted) and R12's
rails-OFF ultra measured 4.64 mA. Those overlap, and the rails-off
figure is nominally the *higher* of the two, so suspend draw cannot
separate "rail dropped" from "rail stayed up".

**What would actually discriminate** (all need a test image, hence
issue #8):

- Add `wakeup-source` to the pen node in a bench image. If the pen then
  wakes the device from ultra, `vcc_3v3_pmu` is up and explanation 1 is
  confirmed; if it still does not while the cover does, explanation 2
  (alive-domain level detection specific to the hall switch) survives.
- Instrument bl31's own PMIC readback further: the banner reports
  `POWER_SLP_EN` (intent). What is missing is the rail's *actual* state
  during suspend, which nothing in the current stack reports.
- A hardware measurement across `vcc_3v3_pmu` during suspend would
  settle it outright, and needs no software at all — just probe access.

## Hibernation (suspend-to-disk) — scoped 2026-08-07, not built

(2026-08-08: ultra landed at 4.64 mA, clearing the 18-day target on paper
with ~2× slack — hibernation is re-priced from "the only step change" to
a pre-1.0 option, still gated on the os2-default-boot question.)

Raised as an interim step the same night the ultra handshake came back
unwakeable. It deserves the serious treatment because it is the only
remaining lever that is a **step change** rather than a few mA.

### Why it is attractive

`deep` costs ~20 mA. On the measured 3392 mAh in this device's gauge that
is ~7 days of pure standby, and the shipped duty cycle makes it less.
Hibernation powers the SoC off outright: standby draw becomes PMIC/RTC
leakage, which is a different order of magnitude. The 18-day target stops
being a stretch and becomes slack.

It is also the only lever that gets *better* the longer the device sits,
which is exactly the failure case we care about — a reader that went into
a bag on Friday and is expected to work on Monday.

### What is already in our favour

**The drivers have the hooks.** `SET_SYSTEM_SLEEP_PM_OPS(rockchip_ebc_suspend,
rockchip_ebc_resume)` (forward-port patch, ~line 6010) points
`.freeze`, `.thaw`, `.poweroff` and `.restore` at the same callbacks the
proven `deep` path already uses; the TPS65185 and the WS8100 pen use the
simple-PM macros, which do the same. So the hibernation phases would at
least be *called* on every device we care about.

Note the size of that claim: having a hook is not the same as surviving a
real image restore, where the kernel that reads the image is a different
boot of the same kernel and every device has been through a full power
cycle. Unproven, and not cheaply provable offline.

### What is missing, in increasing order of difficulty

**1. `CONFIG_HIBERNATION`.** Appears nowhere in `pinenote_defconfig` or
`kernel.scm`. A kernel rebuild, and a `make kernel-drv` gate first.

**2. Swap, ~4 GB for 4 GB of RAM.** There is no swap in any system
definition. Placement is a genuine decision, not a detail:

- *A swapfile on p7.* Easiest, and it needs `resume=` plus
  `resume_offset=`, which is per-device state the image cannot carry —
  the same class of problem as the waveform. Worse, p7 is os1's `/home`:
  a 4 GB file appears in the Debian user's home, where they can move or
  delete it, and a hibernation image referenced by a stale offset is a
  corrupt restore rather than a clean failure.
- *A new partition.* Clean addressing by partlabel, no offset, but it
  means repartitioning a device whose partition table is currently
  treated as untouchable, and there is no free space without shrinking
  p7.
- *Shrink os2 and swap inside it.* Self-contained and reflashable, but
  our image is written as a whole-partition `dd`, so swap would be
  re-created on every deploy — acceptable, since a hibernation image
  never needs to survive a reflash.

The third is the only one that does not put per-device state or a
deletable 4 GB file into os1's home, and it is probably the answer.

**3. The blocker: resume must land on os2 by itself.** Resume from
hibernation is a cold boot that must reach the os2 kernel, which then
finds the image and restores it. As of 2026-08-07 the boot behaviour is
settled and it is exactly wrong for this:

- The U-Boot menu **is** interactable on the device — a human can always
  pick "Boot OS2 (part 6)" without a serial console.
- But the **default** entry searches all partitions and finds p5 first,
  because os1 carries `/boot/extlinux/extlinux.conf`. With nobody
  touching the device the countdown elapses to os1 — captured on UART
  during the ultra recovery boot, 15→0 with no keypress.

**A hibernate wake is unattended by definition.** The user presses power
expecting their page back; they get os1's Debian login, and the
hibernation image is never read. Making os2 the default means changing
persistent boot state (U-Boot env, or p1), which `doc/hardware-deploy.md`
deliberately never touches. That is a safety-model decision for the
operators, not an implementation detail — and it is the first thing to
settle, because everything else is wasted work without it.

There is a second-order hazard in the same area: if os1 ever boots while
a hibernation image is live and touches the swap, the image is stale and
restoring it later corrupts the running system. Any design must make the
image self-invalidating across an os1 boot.

### The shape worth building, if it is built

Not "hibernate instead of deep" — **suspend-then-hibernate**. Deep is
instant to wake and costs ~20 mA; hibernation is near-free to hold and
expensive to leave. So:

    idle -> deep (instant wake, the normal case)
      -> after N hours still idle, wake on the RTC backstop and hibernate

That keeps the reader's felt behaviour identical for every ordinary
use — pick it up within a few hours and it resumes instantly — and only
pays the slow wake in the case where the device was genuinely abandoned,
which is the case where the user is not waiting anyway.

`autosuspend.lua` already has the machinery: it wakes on an RTC backstop,
it knows how long it slept, and it already fails closed. The escalation
is a new branch at the top of the backstop wake, not a new daemon.

### What the user would actually see

This has to be designed, not discovered on glass. A restore reads ~1-2 GB
off eMMC; call it 10-30 s, against `deep`'s effectively-instant resume.
On e-ink, that window is not blank — it is whatever the panel last held,
because the display holds its image with no power. So the device would
show the user's page, frozen and unresponsive, for up to half a minute.
That is a worse experience than a blank screen with a progress
indicator, and it is precisely the kind of thing the frozen-page
ambiguity would get reported as "it hung".

Mitigation is cheap and must be in scope from the start: paint a
"resuming" banner before entering hibernation — the same
`draw_banner` path the suspend banner already uses, with the geometry fix
from 2026-08-07 — so the frozen image is one that explains itself.

### What to prove offline, in ladder order, before any hardware

1. `CONFIG_HIBERNATION` builds and the kernel derivation computes
   (`make kernel-drv`).
2. The image boots in QEMU virt with swap and completes a
   hibernate/restore cycle there. This is the rung that would catch a
   driver whose `.restore` is wrong, without a device.
3. Structural gates: swap present, `resume=` on the cmdline, the
   escalation logic in `autosuspend.lua` under `luac -p` plus the
   existing suspend gates.
4. Only then, one supervised hardware session with the UART capturing the
   restore — with the boot-default question **already resolved**, because
   a hardware session that resumes into os1 proves nothing.

### Sequencing

**Do not build this before the one end-to-end standby measurement**
(`doc/alpha-checklist.md`). Hibernate's entire value is the delta against
real deep standby, and no standby figure in this repo has ever been
measured end to end. The precedent is exact and expensive: the
2026-08-03 soak measured the duty-cycle bug, was written up as an
argument for the setting that made it worse, and the model said 8.6 days
while reality was 3.0 — wrong by 2.4x, in the direction that flatters.

If real standby comes back near the arithmetic, hibernation is a large
lift for a target already close. If it comes back at 2x the model, it is
the whole ballgame. One night decides which.

## Power program: targets, measured gaps, and ordering (2026-08-02, figures refreshed 2026-08-06)

Will's targets, and where we actually stand. All from a 4000 mAh charge
(`charge_full`), against measurements in
`doc/artifacts/pinenote-battery-ab-20260802/`,
`.../pinenote-awake-idle-profile-20260802/`, and
`.../pinenote-awake-levers-20260806/`.

| target | needs | measured | verdict |
| --- | --- | --- | --- |
| **>= 25 h active reading** | <= 160 mA | awake floor **156.9 mA** (25.5 h) since the vdd_cpu fix | **met on the floor, thinly** — and the floor was measured at frontlight ZERO, so this is "25.5 h in daylight". Two switchable domains take it to 144.6 mA / **27.7 h** (below), leaving **15.4 mA of budget for the frontlight** before 25 h is at risk. The frontlight's cost is unmeasured — that is the open term. |
| **>= 18 days suspend** (accepted) | <= 9.2 mA idle average | delivered standby **~22.6 mA** (~7.4 d) after the 2026-08-07 duty-cycle fix — arithmetic, never measured | **~2.5x short.** No awake-side lever touches it. Only ultra-suspend can close it, and its own pessimistic end (9 mA) lands *exactly* here: 17.0 d at a 1 h backstop, **18.1 d at 4 h**. |
| **> 30 days suspend** (desired) | <= 5.56 mA idle average | as above | needs ultra at **<= 4.71 mA** (1 h backstop) or **<= 5.35 mA** (4 h) — the optimistic half of hrdl's unreplicated bracket. Wanted, not counted on. |

Targets revised 2026-08-07 to Kindle-class: >= 25 h reading, >= 18 days
standby accepted with > 30 desired. They supersede the older "~40 h
active / a week idle" pair, which priced the program against a standby
figure the duty-cycle bug made fictional.

**Why 18 days changes the ultra question.** It turns "does ultra hit its
best case?" into "does ultra work at all?" — worth knowing, because even
the pessimistic 9 mA end clears it. It also makes the backstop length
load-bearing for the first time: at 9 mA, 1 h gives 17.0 d (miss) and 4 h
gives 18.1 d (meet). That is a runtime knob, not a rebuild.

**The awake path to comfortable margin**, from the 2026-08-06 domain
teardown — only 14 mA of the awake draw is switchable at all, and two of
the three are things a reader has no business running by default:

| lever | measured | running total | hours |
| --- | --- | --- | --- |
| today | — | 156.9 mA | 25.5 |
| Wi-Fi off | 10.3 mA | 146.6 mA | 27.3 |
| USB gadget off | 2.0 mA | 144.6 mA | 27.7 |
| KOReader idle work | 4.1 mA | 140.5 mA | 28.5 |

Wi-Fi is needed to fetch books, not to read them; the gadget console is a
development affordance. Neither should be on by default in the reader
flavor. The panel itself measured **0.0 mA** — on e-ink a static page is
genuinely free, which is why the frontlight is the only awake term left
worth measuring.

**Which suspend-draw number to quote (19.3 vs 20.6 mA):** both are
real measurements of the same deep draw at different dates and
durations. **19.3 mA** is the 2026-08-02 battery A/B
(`doc/artifacts/pinenote-battery-ab-20260802/`); **20.6 mA** is the
2026-08-06 rail-floor audit (900 s windows, same boot,
`doc/artifacts/pinenote-awake-levers-20260806/` Addendum 2). Quote
**20.6** going forward: it is the newer, longer measurement, and the
audit established it as the rail floor — PMIC quiescent + always-on
rails + DDR self-refresh + bl31 retention, with every Linux-reachable
peripheral exonerated. Older text below says 19.3; read it as the same
floor measured earlier.

**2026-08-06: the switch-things-off half of the awake row is closed —
and the "irreducible" floor fell the same day.** A domain teardown
attributes only 14 mA of a 177.5 mA awake draw to anything we can
switch off — Wi-Fi 10.3, KOReader 4.1, USB gadget 2.0, panel **0.0** —
leaving **163.1 mA (91.9%) as a static floor**, and CPU idle states,
the last plausible *scheduling* lever, moved it by only **2.1 mA** (see
"Both halves resolved" below and
`doc/artifacts/pinenote-cpuidle-psci-20260806/`). But that floor turned
out to be configuration, not structure: the same day's lever hunt
measured **~30 mA** in the vdd_cpu forced-PWM bit (~17 mA realized at
settled reader idle, 174 → 156.9) and **~24.8 mA** in DDR pinned at
1056 MHz (driver landed as `wilkbook_dmc`; quiesced measurement). The
honest ledger: 163 mA measured floor − ~17 mA realized vdd_cpu −
~25 mA available DDR ≈ **~120 mA still unattributed**. The row's
verdict stands — no awake floor reaches a 100 mA average — but
"irreducible" was falsified within hours of being measured
(`doc/artifacts/pinenote-awake-levers-20260806/`: "the floor is
structural no more").

### The idle duty cycle: standby was never the deep floor (2026-08-07)

**The week-idle row used to read "deep 20.6 mA (leaves ~13%)", which
assumes an idle device sits at the deep floor. It did not.** From the
2026-08-03 deployment to 2026-08-07 the auto-suspend daemon stamped
`last_activity = os.time()` after *every* resume, with no branch
separating an RTC-backstop wake (nobody present) from a button wake
(somebody present). A device alone in a bag therefore ran a loop: 900 s
asleep at 20.6 mA, then a **fresh 300 s idle period awake at 156.9 mA**,
repeat.

| daemon | awake duty | average | 4000 mAh lasts |
| --- | --- | --- | --- |
| as shipped, `idle=300 backstop=900` | 25 % | 54.7 mA | 3.0 days |
| fixed, 900 s backstop | 2.2 % | 23.6 mA | 7.1 days |
| fixed, 3600 s backstop (the new default) | 0.6 % | 21.4 mA | 7.8 days |

**Every figure in that table is arithmetic on measured inputs (156.9 mA
awake, 20.6 mA deep, 4000 mAh), not a measurement.** It is also
optimistic, because it charges the awake window at settled idle draw: the
2026-08-03 soak measured **64.4 mA where the same component model
predicted 49.8**, and that 14.6 mA over a ~300 s cycle is **~1.2 mAh of
per-cycle resume work** — Wi-Fi re-association, banner restore, the GC16
wash. Carrying that constant across gives **~28.3 mA / ~5.9 days** at a
900 s backstop and **~22.6 mA / ~7.4 days** at 3600 s. That is why the
default backstop moved to 1 h in the same change: post-fix, a backstop
wake buys nothing by construction, so its only remaining term is how
often it happens. What the longer period costs is the worst-case wait for
a device whose button wake has regressed (15 min → 1 h); bounded
self-recovery survives that, and `backstop=` remains a runtime knob for
anyone who wants denser cycles. **No measured standby number exists yet
— the multi-day unplugged soak still has not been run.**

**The durable lesson: the measurement was already in the record, and had
been read.** The 2026-08-03 unplugged soak
(`doc/artifacts/pinenote-autosuspend-soak-unplugged-20260803/`) recorded a
64.4 mA average at "~20 % awake duty cycle" with awake windows of ~60 s
at `idle=60 backstop=240` — this bug, measured, on the day the daemon was
declared working. It was written up as an argument *for* the long 300 s
idle default ("the gap is the argument for a long idle timeout"), which
is the exact opposite of the conclusion: a longer idle default made every
unattended wake more expensive, not less. **A soak that reports a duty
cycle is reporting a policy result.** Read the awake windows against what
*should* have been awake — here, nothing at all, because nobody was
present for any of those wakes.

Fix in `626cb02`: `suspend_once()` returns the sleep duration, and a sleep
within 5 s of the backstop re-suspends after a 20 s settle while a button
wake still gets the whole idle period. Pinned offline by
`pinenote/tools/power/test-autosuspend-policy.lua` (`make power-check`),
which executes the daemon's own extracted `suspend_once()` and post-wake
branch against a virtual clock and reproduces the 25 % / 54.7 mA numbers
from the un-fixed source.

**Still on the table**: an unobserved wake also pays for the banner
restore and a full-panel GC16 wash, because `cleanup_wash()` runs
unconditionally — a device in a bag washes its glass once per backstop
cycle for nobody, and that is most of the ~1.2 mAh. Skipping display
recovery when the wake was the alarm was not taken here: a wash deferred
once has to still be correct after the *next* resume, and GC16 on every
resume is what heals a mid-refresh suspend desync today (Addendum 5,
2026-08-06).

#### Acceptance on the next session (log read, no supervision needed)

The daemon logs one timestamped line per resume and nothing at suspend
time, so the quantity in dispute — the awake window — is the gap between
consecutive resumes minus the sleep the second one reports:

```sh
awk '/resumed after/ {
       split($2, c, ":"); t = c[1]*3600 + c[2]*60 + c[3];
       n = $0; sub(/.*resumed after /, "", n); sub(/s.*/, "", n);
       if (prev != "") printf "%s  awake %ds, then slept %ds\n", $2, t - prev - n, n;
       prev = t }' /var/log/pinenote-autosuspend.log
```

1. **Quick confirmation first** (~15 min): write `backstop=240` to
   `/var/lib/pinenote/autosuspend.conf`, leave the device alone unplugged,
   and read three cycles. **PASS: `awake 20s` (±3), so `resumed after
   240s` lines ~260 s apart.** `awake 300s` / ~540 s apart means the fix
   is not in the running image. Remove the override afterwards.
2. **Then the default period, which has never been tested**: the 1 h
   backstop is 1.5x the longest dwell this device has ever slept
   (2400 s, R12 2026-08-08; this line previously said 4x against the
   retired 900 s default). Expect
   `resumed after 3600s` (±3) roughly hourly, each followed by `awake
   20s`. **If the resume lines stop, the alarm is not re-arming** — that
   is a fail, and the device is then relying on button wake alone.
3. **A button wake must still get the full idle period**: press power,
   touch nothing, and confirm that cycle reports **`awake 300s`**, not
   `awake 20s`. A regression here sleeps the device under a reader's
   hands.
4. `/sys/power/suspend_stats/{success,fail}`: `success` should equal the
   count of `resumed after` lines. Any `fail` growth is the EBC-busy or
   gadget-veto abort path (30 s retry), not this change.
5. **The first measured standby number this program has ever had**:
   `charge_now` before and after ≥ 6 h unplugged and untouched. The model
   says ~22.6 mA. A materially higher reading means per-cycle resume cost
   is bigger than the 2026-08-03 extrapolation, and the backstop should go
   longer still.

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

[Answered 2026-08-08: the payload is adopted and measures 4.64 mA — R12.]
No amount of scheduling fixes 20.6 mA → 6 mA. That is the **ultra-suspend
/ rail-kill** payload we deliberately left unadopted (`ultra: 0` in every
bl31 `PM-STATE` line so far), and it is gated on the rail-kill wake
collision: `vcc_3v3_pmu` feeds `pmuio1/2`, the GPIO0 bank carrying every
external wake source. Turning those rails off is exactly what saves the
power *and* what could make the device unwakeable.

The 2026-08-06 deep audit sharpened this: pre-killing touch, pen, and
BT and downing wlan0 before suspend does not lower the draw at all (the
stripped run D2 read 22.7 mA against the normal path's 20.6) —
**no peripheral reachable from Linux is leaking**, so the whole
20.6 → 6 gap lives in the PMIC-quiescent/always-on-rail territory only
ultra-suspend touches. D2's excess is itself a finding worth keeping:
**unbinding a driver skips its suspend hook**, and the orphaned
hardware can sit in a worse state than the suspend path would have
left it — the callbacks do real work. The same audit also proved twice
that bl31 preserves a non-boot DDR rate across suspend/resume.
(`doc/artifacts/pinenote-awake-levers-20260806/`, Addendum 2.)

### Ordering

1. **Auto-suspend scheduling — SHIPPED 2026-08-03.** The
   `pinenote-autosuspend` daemon is live on os2: inactivity detection
   over every input device, power-button wake (hardware-proven
   2026-08-02) with an RTC backstop armed every cycle, sleep banner,
   charging inhibit, and short-press-to-suspend (2026-08-04). Cover
   wake remains unproven. The unplugged multi-day soak that would
   validate standby end to end has **not** been run.
2. **Measure one wake+render+refresh cycle.** It sets whether
   suspend-between-page-turns is viable and what resume latency budget we
   have.
3. **Resume latency** — UX first, power second.
4. **Suspend draw 20.6 → <10 mA** — DONE 2026-08-08 at 4.64 mA (R12);
   originally gated on the rail-kill
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

### Deferred: awake-idle floor research (resolved 2026-08-06, below)

Written when this was explicitly parked; both halves were then resolved
on 2026-08-06 — see "Both halves resolved" and the vdd_cpu/DDR results
that follow it. The 171.6 mA awake floor has two known
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

### Both halves resolved, 2026-08-06

**CPU idle states: done, and they are not the answer.** We wrote the DT
node and it works — `psci_idle` registers, `cpu-sleep` is entered
constantly, cores idle 31–72% of wall time, no core ever failed to wake.
Same boot, same book, toggling only `state1/disable`: **172.7 mA enabled
vs 174.8 mA disabled — 2.1 mA, ~1.2%, noise.** The risk asymmetry feared
above did not materialise; the payoff did not either. Full detail and the
patch in `doc/artifacts/pinenote-cpuidle-psci-20260806/`.

**The reason is now measured: 91.9% of the awake draw is a static floor.**
Cumulative teardown, 300 s per stage: Wi-Fi 10.3 mA, KOReader 4.1 mA, USB
gadget 2.0 mA, panel/fbcon **0.0 mA** — and **163.1 mA left when all of it
is gone**. There is essentially nothing to break down. CPU core power is
not where this board's awake power goes, and neither is the display.

**os1 does NOT run DDR DVFS either** (checked 2026-08-06): its only
devfreq device is `fde60000.gpu`, there is no DMC device and no
`dmc`/`memory-controller` node in its DT. The BSP *has* the driver
(`drivers/devfreq/rockchip_dmc.c`) — it is simply not wired up for the
PineNote. So DDR has been pinned at 1056 MHz on every kernel this device
has ever run, including Rockchip's own. The cheap comparison suggested
above cannot size the prize, because there is no DVFS on either side.

### DDR rate: 324 MHz corrupts the display — OFF by default, and the open path (2026-08-07)

**The finding.** Static 324 MHz starves the EBC's real-time phase-data
fetch. The panel comes up striped with a dark vertical band, every boot.
The controller has **no underrun interrupt** — `EBC_INT_STATUS` carries
only frame/display-end and line-flag bits — so it fails *silently*: clean
dmesg, clean checkpoint table, wrecked glass. That silence is why this
cost two days.

**The A/B that settled it**, one variable, one image, one boot path:

| selector | DDR | panel |
|---|---|---|
| `mode=normal` | 324 MHz | striped + dark band, reproducible |
| `mode=noswitch` | 1056 MHz (module never loaded) | clean |

**The switch EVENT is innocent** and should not be blamed again: the
instrumented boot shows it landing with the refresh kthread `thr=P`
(*parked*, not merely idle) and the EBC interrupt count frozen across the
whole window. It is the RATE, not the transition.

**Console traffic is innocent too.** Dropping `console=tty0` cut boot EBC
interrupts from ~580 to **79** and changed nothing on the glass. (Kept
anyway — it is a 7x reduction in panel work and gives a free U-Boot-logo
splash.)

**What it was worth**, so the trade is on the record: ~24.8 mA measured
**quiesced**, never confirmed with the reader running. At realistic
reading hours that is 4-10% of runtime, and **nothing** in deep suspend:

| reading h/day | days @1056 | days @324 | gain | suspend share of budget |
|---|---|---|---|---|
| 1 | 6.34 | 6.60 | 4.1% | 75% |
| 2 | 5.22 | 5.58 | 6.9% | 59% |
| 4 | 3.85 | 4.25 | 10.5% | 40% |

A corrupted display is not a good trade for that, which is why
`pinenote/services/dmc.scm` now defaults to `mode=off`. The capability
survives: `mode=normal` in `/data/wilkbook/dmc.conf` opts back in per
boot.

#### The path to pursue

1. **Try 528 and 780 MHz** — the two untested middle entries of the
   firmware table (324/528/780/1056). If either drives the panel cleanly
   it recovers part of the saving at zero display cost, and it is the
   cheapest open lever we have. Two boots: write `mode=normal` with
   `%dmc-target-rate` rebuilt at the candidate rate, boot, and judge with
   `pinenote/tools/optics/belief-vs-glass.sh` rather than by eye. Bisect:
   780 first, since it is likeliest to pass and bounds the answer.
2. **Find the actual threshold, not just a safe rung.** If 528 passes and
   324 fails, the interesting number is where the EBC's fetch budget runs
   out — that is a bandwidth/latency figure worth knowing before anyone
   tries DVFS again on this SoC.
3. **Do NOT pursue dropping the rate for suspend only.** Measured: the
   rail-floor audit's 900 s window at 324 read 20.6 mA against 19.3 mA at
   1056 in the earlier session — same band, 324 if anything marginally
   worse. Physically expected: in deep suspend the DRAM is in self-refresh
   with the PHY down, so the interface clock has no meaning. Not worth two
   windows.
4. **A per-refresh boost is not viable.** A switch is ~107 ms wall; a page
   turn is ~600 ms of drive. There is no room to raise the rate around
   individual refreshes.

The honest summary for anyone reconsidering this: the DDR lever is worth
single-digit percent of runtime, the display is the product, and the
failure mode is invisible to every log the system produces. Gate any
future attempt on `belief-vs-glass.sh`, not on a clean dmesg.

### Probe the DRAM SIP before porting anything (answered 2026-08-06: GO, and landed)

DDR DVFS on rk356x lives **entirely in bl31**, behind
`ROCKCHIP_SIP_DRAM_FREQ`. Linux only requests; firmware does the work.
We already have that machinery — the BSP-SIP suspend patch calls
`arm_smccc_smc(ROCKCHIP_LEGACY_SIP_SUSPEND_MODE, …)` through the same
conduit, different function ID.

**ANSWERED 2026-08-06 — GO.** The read-only probe was built
(`pinenote/tools/ddr-sip-probe/`, cross-built with matching vermagic and
MODVERSIONS CRCs, insmodded on the running system) and the firmware
replied:

    DRAM_GET_VERSION fid=0x82000008 -> a0=0x0 (SUCCESS), a1=0x101

The bl31 implements the DRAM SIP, version 0x101, and the full campaign
ran the same day: `pinenote/tools/ddr-dvfs-test/` performed this board's
first-ever DDR rate change (324 MHz, MCU path, 106.8 ms, memory intact,
EBC quiesced for every switch) and the measurement is in: **DDR at
324 MHz saves ~24.8 mA over 1056** (quiesced battery-drain windows, same
boot, minutes apart).  Firmware table: 324/528/780/1056.  The Linux-side
integration **landed the same day** (commit `7b0251b`): `wilkbook_dmc`,
a minimal devfreq driver over the same SIP
(`pinenote/patches/linux-pinenote-7.0-dmc-static-low.patch`), floored
at 324 by the `powersave` governor, plus an input-driven boost daemon
that raises `min_freq` to the firmware's top rate on any input event
and drops back to the floor after 10 s quiet
(`pinenote/tools/power/ddr-boost.lua`; services `pinenote-dmc` and
`pinenote-ddr-boost` in `pinenote/services/{dmc,ddr-boost}.scm`).
**The boost ships disabled** (2026-08-06): without `enabled=1` in
`/var/lib/pinenote/ddr-boost.conf` the daemon never raises — the
no-conf state after a reflash must be the validated static-324 floor
until the boost's wake-boundary behavior is proven on glass.  The
SMC sequences and their BSP citations are documented in
`pinenote/tools/ddr-dvfs-test/{procedure,protocol}.md`.  One earlier
design choice is explicitly **overridden** by newer evidence: the
driver carries no suspend hooks and no `opp-suspend`, because the deep
audit proved twice that bl31 preserves a non-boot DDR rate across
suspend/resume (awake-levers artifact, Addendum 2) — suspend hooks
would only add switches, and EBC exposure, for nothing.  Rules that
held and must keep holding: never switch with the EBC active (a
retraining stall inside a frame can trip the terminal-poison timeout),
never target above the boot rate (no OPP voltage scaling).

**Expect a modest result, and size it before investing.** Deep suspend is
20.6 mA *with DRAM in self-refresh*, so retention is cheap — but that
bounds DDR **retention**, not DDR **active**, which additionally runs the
controller, PHY and I/O at 1056 MHz. What the 20.6 mA does bound is the
destination: nothing awake can go below ~20 mA, so the 163 mA floor holds
at most ~142 mA of reachable content, shared between DDR-active, the CPU
rails and the domains suspend switches off. DVFS lowers the DDR clock
rather than turning DDR off, so it can only claim a fraction of DDR's
share of that. **Tens of mA at best.** Worth having; not a step change,
and not a reason to delay the suspend-scheduling work that is worth 8x.

**vdd_cpu forced PWM: MEASURED AND FIXED 2026-08-06 — ~30 ± 8 mA, the
largest single awake win of the program.** The TCS4525 CPU buck (not the
RK817; the rail has its own chip at i2c0/0x1c) powers on with force-PWM
set and nothing in the ecosystem ever clears it. A runtime i2c ABA with a
dead-man revert (DVFS clamped to 408 MHz, differential coulomb method
while charging, input saturation calibrated) measured the chip's
automatic PFM/PWM mode saving ~30 mA — ~18% of the 163 mA static floor.
Baked into `linux-pinenote-7.0-vdd-cpu-auto-pfm.patch` together with the
`fan53555_set_mode` NORMAL-branch fix it requires (upstream-register item
10). ACCEPTED on boot 2026-08-06: opmode "normal" straight from DT, survives
deep suspend/resume; settled reader idle realized 174 → 156.9 mA
(~17 mA in daily use; the clamped-idle cost of the bit remains ~30). Full data:
`doc/artifacts/pinenote-awake-levers-20260806/`.

## Safe measurement boundary

The five evidence domains stay separate:

1. **Awake idle:** snapshot after a stable, specified workload; compare CPU,
   IRQ, runtime-PM, wake-source, and gauge counters.
2. **Reader/display activity:** bracket known page turns or refresh intervals;
   do not infer panel energy from counters alone.
3. **Suspend/resume:** capture before/after evidence and console signatures.
   (The first actual suspends have since run and passed — 2026-08-02 —
   but the bracketing discipline stands for every new experiment.)
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
measured `deep` result can support a multi-day battery target.

**Verdict updated 2026-08-03: suspend is SUPPORTED and scheduled.**
`deep` is hardware-proven (2026-08-02) and the standalone
`pinenote-autosuspend` daemon now writes `/sys/power/state` on its own:
idle-triggered `deep` with an RTC backstop, power-button wake, a sleep
banner with band save/restore, charging inhibit, and
short-press-to-suspend. The ownership split is deliberate: the
*daemon*, not KOReader, owns suspend — `suspend_policy.lua` still
returns `false`, so `device.lua`'s sole `canSuspend` field stays off
and KOReader's own suspend transaction remains unwired. Cover-triggered
suspend is still blocked (cover wake unproven). Operational
consequence: **ssh is intermittent on the deployed image**; see
`doc/device-access.md` for the runtime `enabled=0` pause before any
session. (The pre-2026-08-03 verdict here read "unsupported: … no
unsupervised code may write `/sys/power/state`" — retired.)

The eventual full KOReader-integrated suspend operation needs one
serialized transaction; the live daemon implements a minimal version
of it (gadget quiesce, banner save/restore, post-resume refresh), and
the numbered phases below remain the specification for the full
orchestration, which is future work:

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

**Superseded in part, 2026-08-03:** qualification is complete for
`deep` with RTC and power-button wake (both hardware-proven
2026-08-02), and automatic idle suspend is live (`pinenote-autosuspend`,
5-minute default, runtime-tunable). What stands: cover, touch/pen, MMC,
USB, and network wake remain unproven and out of scope, and cover-close
suspend stays blocked until cover wake is attributed. The original
qualification rule follows as written at the time.

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

**The gate flipped polarity on 2026-08-02, with activation.** It now
*requires* `CONFIG_ROCKCHIP_SUSPEND_MODE_ACTIVATE=y` (`deep` cannot
wake without the SIP configuration activation sends — the cfg `0x0`
hang proved it) and exactly the reviewed ACTIVE policy node:
`rockchip,sleep-mode-config = 0x5ec`, `rockchip,wakeup-config = 0x10`,
`rockchip,sleep-debug-en = 0`, and nothing else — where it previously
required activation unset and a policy-free node. It still requires
exact suspend/freezer/debug config, exactly the approved two
effectively enabled DT wake declarations with their verified
identities, and the exact disabled policy module (`suspend_policy.lua`
returns `false`: the autosuspend daemon owns suspend, KOReader does
not). A restricted LuaJIT harness evaluates `device.lua` with injected
false and true policy values and requires its returned class to follow
both.

**Known gate/kernel contradiction (noted 2026-08-06, follow-up
tracked):** the gate still rejects CPU idle-state nodes and references
— a rule from before `linux-pinenote-7.0-cpuidle-psci.patch` added the
reviewed `CPU_SLEEP` state to the PineNote DTS (2026-08-05,
deep-proven 4/4 cycles). Until `inspect-pinenote-suspend-gates.sh` is
reconciled to accept that node, the against-a-built-image invocation
above is **expected to fail on idle-states** for any current build;
that failure is the stale gate, not a kernel regression. Do not "fix"
it by removing the idle-states — they are hardware-proven.

Passing proves none of TF-A/U-Boot, DDR retention, runtime wake policy,
physical wake routing, RK817/TPS65185 behavior, EBC rail state, resume,
or current draw — those were proven on hardware separately (2026-08-02
and after; `doc/status.md`). The 2026-07-20 built 7.0.11 kernel and
generated DTB passed the then-current, pre-activation gate.

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

**2026-08-03 update: these are no longer suspend blockers** — deep is
proven and scheduled. The list is preserved with per-item status
because several items still gate the *full* KOReader-integrated
transaction and the ultra-suspend program:

- no production provider or userspace coordinator yet performs the host-proven
  transaction; a dormant LuaJIT barrier adapter and injected sleep-frame
  provider are host-proven and packaged with the recursively grafted PineNote
  device sources, but remain intentionally unimported by `device.lua`.
  *Still true 2026-08-06: the live autosuspend daemon performs a
  minimal transaction outside the coordinator model*;
- the deployed stable BSP-ATF/DDR/U-Boot contract is identified, and its
  execution-capable Linux parser/model/executor/backend stack is now
  production-linked and offline-qualified. **Resolved 2026-08-02:**
  activation and the reviewed active DT policy are live (`0x5ec`/`0x10`),
  the driver binds on the activation path, and the supervised
  qualification ladder ran and passed through `deep`;
- the EBC driver has system/runtime PM callbacks, special post-suspend refresh
  bookkeeping, and a host-proven refresh-completion barrier. The separately
  invoked C diagnostic can now paint, wait, and restore under supervision, and
  the daemon's banner save/restore is proven on glass (2026-08-03), but
  production sleep-frame painting through the coordinator remains absent;
- the known-working downstream stack also carries TPS65185 standby/resume
  register restoration — **resolved 2026-08-01: required before `deep`,
  and now WRITTEN: the forward-port patch carries a snapshot/restore
  suspend-resume pair (dormant until the ladder reaches `deep`; VCOM
  never written; cache-through restore; structurally gated in
  `make suspend-check`, negative-tested; see
  `doc/kernel-forward-port.md`)** — and explicit
  RK817 regulator suspend states, whose adoption is now gated on the
  rail-kill wake-collision question (see the evidence pass below);
- **SC7A20 accelerometer resume — FIXED AND HARDWARE-PROVEN 2026-08-03**
  (6/6 deep cycles; `doc/artifacts/pinenote-sc7a20-resume-fixed-20260803/`).
  `pinenote/patches/linux-pinenote-7.0-st-accel-pm.patch` adds the missing
  `.pm` in four parts. Two of them were defects in our own first attempt
  and are worth remembering, because the first hid the second:
  *(a)* `st_sensors_resume()` tested `->hw_irq_trigger` **after**
  `st_sensors_reinit_hw()`, which clears it as a side effect of its
  inherited "disable DRDY" step — so the re-arm never ran and the storm
  happened anyway (116 → 100,117 interrupts); *(b)* with that fixed the
  storm vanished and the interrupt went **silent** instead, because the
  active-low polarity bit is written only at probe and the chip returns
  active-high while the GPIO stays `LEVEL_LOW`. `reinit_hw()` now restores
  it. Diagnostic worth keeping: `STATUS_REG` (0x27) reading `0xff` means
  data-ready **plus overrun** — the chip is sampling and nothing is
  reading it, i.e. a dead interrupt path behind a healthy-looking register
  dump. The historical description follows.

  After the first real `deep` cycle (pre-fix):
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
- cover and RK817 wake properties are compiled in. **Partially proven
  2026-08-02:** power-button and RTC wake work through the RK817 path
  on real deep cycles; cover wake and finer PMIC child-event
  attribution remain unproven. Also open from that session: TPS
  `ENABLE` moved `2f → 20` across deep and was not restored by our PM
  pair — the display works via runtime PM, but understand the drift
  before long dwells.

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

**2026-08-02: the ladder completed — rungs 1–3 all PASS.** The retry
ran with the worker-bracket fix in place. Rung 2 passed both
discriminator cases: post-resume damage paints a full 46-frame pass at
blanked *and* unblanked CRTC states, no regulator or TPS drift, VCOM
intact (`doc/artifacts/pinenote-suspend-ladder-20260802-discriminator/`).
Rung 3 (`deep`) first hung inside bl31 with `PM-STATE: … cfg: 0x0` —
firmware-level proof that dormant activation sends no suspend
configuration or wake-source arming
(`doc/artifacts/pinenote-deep-suspend-hang-20260802/`). Enabling
activation the same day (`cfg: 0x5ec`, wakeup-config `0x10`) turned
that hang into a clean 60 s deep cycle: RTC wake on schedule, the
monotonic clock frozen (1.08 s kernel across 60 s wall — the signature
of a real power-down), OP-TEE re-initialising secondary CPUs on
resume, VCOM surviving at `8f`, and a fully working display at both
CRTC states (`doc/artifacts/pinenote-deep-suspend-WORKS-20260802/`).
Full session record: `doc/status.md`. Open residue: TPS `ENABLE`
`2f → 20` across deep, unrestored by our PM pair and unexplained.

Amendments from the 2026-08-01/02 sessions, now standing procedure:
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
(Since done: `linux-pinenote-7.0-cpuidle-psci.patch`, 2026-08-05,
deep-proven 4/4 cycles — see "Both halves resolved" above.)

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

**Superseded 2026-08-02 — activation is now ON.** This section records
the activation-hard-off milestone as built (2026-07-26) and is kept as
the design record of the fail-closed core; read its present tense as of
that date. Since 2026-08-02 the PineNote defconfig sets
`ROCKCHIP_SUSPEND_MODE_ACTIVATE=y`, the DT carries the reviewed ACTIVE
policy (`sleep-mode-config 0x5ec`, `wakeup-config 0x10`,
`sleep-debug-en 0` — values measured from os1's booted DTB, not
tuned), the driver binds on the activation path (`BSP suspend policy
activated`, four probe-time SIP calls emitted), and deep suspend is
hardware-proven through it (`doc/status.md`, 2026-08-02 entries; SIP
evidence in `doc/artifacts/pinenote-sip-sequence-differential-20260802.md`).

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
(2026-08-02: production now binds the reviewed activated policy node
described in the supersession note above; this donor model still backs
the host harness.)

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
values, permanent poison, and zero-action retry. The same composite command then reruns the
production suspend preflight, which since 2026-08-02 requires
activation *set* and exactly the reviewed active policy node, with
`suspend_policy.lua` exactly false. Passing is fake-only implementation
evidence for the coordinator model; activation and suspend are
governed by the hardware evidence recorded above, not by this gate.

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
evidence. (**Done 2026-08-02**: the BSP driver/DT policy path was
supplied, offline-proven, and the supervised attempt succeeded — see
the qualification ladder above.)

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
  the resume dependencies all still stand. *(2026-08-02: activation and
  the reviewed MEM policy have since landed and `deep` is proven; the
  coordinator and sleep-frame items still stand, and the ultra rail
  payload remains unadopted.)*
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

No hardware session is allocated or implied by any of this. The
standing rule as written then — nothing suspends until the
qualification ladder says so — was satisfied on 2026-08-02: the ladder
ran, `deep` passed, and scheduled suspend is now live. The rule's
successor applies to the *ultra* payload: no rail-kill suspend until
its GPIO0 wake-collision question is answered under supervised UART.

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
