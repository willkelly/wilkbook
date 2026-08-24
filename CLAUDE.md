# wilkbook — orientation for contributors and agents

A Guix channel that builds a reading-first OS for the Pine64 PineNote
e-ink tablet. If you're an AI agent picking this up, read this file, then
`ROADMAP.md` (direction), then `doc/status.md` (current hardware truth —
start with its current-state header). This file is the "how we work and
why" that isn't obvious from the code.

## The one thing to internalize

**Hardware sessions are the scarce resource.** The physical PineNote needs
a charged battery, a debug cable, and a human watching a UART console.
Everything about how this project is structured — the offline test ladder,
the host tools, the read-only os1 oracle — exists to answer questions
*without* a device, and to make each real session validate a maximal,
pre-verified stack. Before you propose "let's boot it and see," ask what
you could prove offline first. The 2026-07-03 fix stack root-caused three
device failures entirely from logs, the os1 SSH oracle, chroot tests, and
code review — before a single reboot. That's the standard.

## Repo shape

- `pinenote/packages/kernel.scm` — three kernels: `linux-pinenote` (the
  vanilla-7.0.x + forward-port-patch **primary**), `linux-pinenote-debug`
  (primary + diagnostics/`EXTRACT_FBS`), and `linux-pinenote-6.6.30`
  (m-weigand baseline, **regression-isolation only** — 7.0 reached parity
  2026-07-04).
- `pinenote/patches/linux-pinenote-7.0-forward-port.patch` — the EBC
  display driver, `drm_epd_helper`, WS8100 pen, PineNote DTS, and
  `pinenote_defconfig`. This single patch is the most rebase-fragile,
  highest-value artifact in the repo. Treat edits to it with care; it is
  also **treated as permanent** (mainline has no EPD infrastructure and
  won't for years — see `doc/eink-research.md`). Six smaller patches ride
  alongside it (BSP SIP suspend, cpuidle, vdd_cpu PFM, DDR DVFS, st_accel
  PM, ultra rails-off suspend) — the inventory lives in `doc/kernel-forward-port.md`.
- `pinenote/services/`, `pinenote/images/`, `pinenote/systems/` — Guix
  system services, initrd, and flavor entrypoints.
- `pinenote/tools/` — twelve host-side test and diagnostic tools; the
  table in `doc/testing.md` says what each covers. The core display trio
  (`wbf`, `ebc-logic`, `rastersim`) compiles the *verbatim* driver source
  out of the patch and tests it on your workstation.
- `pinenote/scripts/preflight/` — non-destructive inspection/extraction.
- `doc/` — see the doc map below.

## Doc map (what lives where)

- `README.md` — project overview, quick start, human reading order.
- `CHANGELOG.md` — what changed for someone holding the device, newest
  first. Update it as work lands; entries are written for testers.
- `ROADMAP.md` — direction, three tracks + the offline testing ladder.
  Not status.
- `doc/status.md` — **the single source of hardware truth.** Update it
  after every hardware session; it records what's actually been proven.
  Newest entries at the top.
- `doc/testing.md` — the testing philosophy, host tools, validation ladder.
- `doc/alpha-checklist.md` + `doc/alpha-signoff.md` — what alpha is and
  what blocks it; and the human QC cycle that actually cuts it.
- `doc/alpha-expectations.md` — the tester-facing brief: what the reader
  should feel like, what is known-broken, how to report.
- `doc/worked-examples.md` — the philosophy applied: replayable case
  studies. Read these before your first non-trivial change.
- `doc/building.md` — host prerequisites and exact build/QEMU/extraction
  commands.
- `doc/hardware-deploy.md` + `doc/device-runbook.md` — the os2 write
  protocol, and the per-device inventory/backup ledger (including the
  provision-your-own-device path).
- `doc/install.md` — what has to be true *before* the write protocol
  applies, for an operator installing on their own device: cable,
  backups, waveform/VCOM, data-partition staging, root posture, and the
  open questions about a first boot. Unverified by construction — no
  second person has done it.
- `doc/device-access.md` — how to reach and safely use the device: os1
  oracle, ACM console, UART, SSH, post-mortem harvest, and their traps.
- `doc/kernel-forward-port.md` — how to refresh the patches for a new
  kernel; the patch inventory; hard-won config lessons; pinned driver
  quirks; the community cherry-pick record.
- `doc/power-management.md` — the power program: measurements, suspend
  qualification, auto-suspend, and the awake-power levers.
- `doc/networking.md` — the Wi-Fi/networking design: what's proven, the
  out-of-band credentials plan, what remains open.
- `doc/refresh-policy.md` — the display-quality program: waveform decodes,
  policy decisions, publish-on-call, the replay workbench.
- `doc/pageturn-program.md` — the page-turn latency/refresh campaign
  record (the double-refresh fix landed via `refresh-policy.md`).
- `doc/eink-research.md` — curated domain background (waveforms,
  commercial e-ink stacks, community lineage). Read before display work.
- `doc/eink-sota.md` — companion deep review: the adversarially-verified
  state-of-the-art survey, ranked steal list, and corrections register.
- `doc/optics-dataset-2026-07.md` — the committed camera-capture dataset
  and how to audit findings against it (data in `doc/datasets/`).
- `doc/hrdl-evaluation.md` — the standing evaluation of hrdl's tree:
  cherry-pick decisions and the corruption-hunt strategy.
- `doc/direct-mode-adoption.md` — the staged plan for adopting hrdl's
  direct-mode driver, its blockers, and its bail-out criteria. Written
  because handwriting needs latency the LUT path cannot reach.
- `doc/driver-findings-report.md` — the community-facing writeup of driver
  bugs the host tools found.
- `doc/upstream-register.md` — the standing list of what we owe the
  community, where it would go, and what has to be true first. Add rows as
  you find things; don't send.
- `doc/reference-register.md` — the inbound counterpart: external trees
  worth *watching* (hrdl's kernel + pinenote-dist, m-weigand, PNDeb,
  rkbin, the schematic), what each is authoritative for, and the access
  traps. Look here before theorising about a hard PineNote problem.
- `doc/pinenote-flavors.md` — the system flavors.
- `doc/koreader-spike.md` + `doc/ebc-harness-spike.md` — completed
  spike/decision records (kept for their still-cited evidence).
- `doc/archive/` — historical documents (indexed by its README).
  `doc/artifacts/` — committed hardware-session evidence.
  `doc/datasets/` — committed derived optics dataset.
  `doc/reviews/` — repo-wide review records.

Vocabulary used throughout: **os1/os2** — the two OS partition slots
(p5 = stock Debian rescue, p6 = ours); **wash** — a full-screen refresh
that clears ghosting; **rung** — a step on the offline-validation ladder
(`doc/testing.md`); **ABBA** — an A/B measurement repeated in reverse
order to cancel drift; **final4** — the 2026-07-19 reader image that
hardware-validated autorotation and touch normalization; **oracle** — a
known-good reference you can query (usually os1); **quirk:** — a pinned
host-tool test documenting an inherited driver bug.

## How to develop here

**Gate cheaply before building expensively.** `make kernel-drv` computes
the kernel derivation (seconds) before `make kernel` (a real cross-build).
Cross-builds target `aarch64-linux-gnu`; everything writes only to the
Guix store and `$(ARTIFACTS)`.

**Prove it offline, in ladder order** (`doc/testing.md`): host tool suites
→ static Guix builds → source inspection → QEMU virt → mock helpers →
hardware. Stop at the first failure. A change that only touches host tools
or docs never needs the device.

**When you touch the forward-port patch**, run the host tools
(`make wbf-check ebc-logic-check rastersim-check WBF=…` plus
`make suspend-check`, whose structural gates cover patch hunks that sit
behind config guards the other suites don't compile) — they exist
precisely to catch what a rebase silently breaks. If a tool goes red,
that's the patch changing behavior; understand why before re-pinning.

**The os1 oracle.** Stock Debian on the device's os1 slot (6.12-pinenote,
everything working) is reachable read-only over SSH and is the cheapest
"is our build doing the right thing" check: live `/proc/device-tree`,
`/sys/bus/iio`, dmesg signatures, gadget bracketing. Use it before
theorizing. The standing device-access conventions — slot disambiguation,
console discipline, UART settings, post-mortem harvest — are in
`doc/device-access.md`.

## Safety model (do not violate)

- **Builds never touch the device.** Deployment is a separate, manual,
  os2-only step (`doc/hardware-deploy.md`). os1 is the untouched rescue
  path.
- **Never bundle the waveform.** It's per-device calibration data
  extracted from the device's own `waveform` partition at boot. The repo
  fails visibly if it's absent rather than shipping a generic one. The
  same goes for VCOM and other per-device values.
- **Destructive device ops** (dd to os2, reboots) are user-present steps.
  Standing permissions for them are **per-operator grants, not repo
  facts**: each operator may grant their own agent the os2 write protocol
  (confirm os1 is root, os2 unmounted, dd, readback-SHA verify) after
  their own ledger's backups exist. Rebooting always needs a human on the
  UART.
- **When you find a driver bug**, report it (a `quirk:` test + a note in
  `doc/kernel-forward-port.md` / `doc/driver-findings-report.md`) — don't
  quietly patch the driver. The upstream/community lineage
  (m-weigand → hrdl → ayakael) should own driver fixes.

## Committing

Two-person repo (as of 2026-08). **Two remotes, two different rules
(2026-08-15):**

- **`github` is upstream and is PR-only.** Never push to
  `github main`. Everything reaches it through a pull request, whatever
  it touches — docs and host tools included.
- **`origin` (Forgejo) is the working remote.** Merge and push to its
  `main` freely.

So the normal flow is: commit → push `origin main` → open a PR against
`github` from a branch at the same commit. The forward-port stack, the
other kernel patches, the safety model, and another operator's workflow
additionally want a review before merge; everything else is a PR for the
record, not for permission.

**Never `git add -A` or `git add .` while an agent may be writing to the
tree.** Stage explicit paths. On 2026-08-15 an `add -A` swept 1,390
lines of a subagent's in-progress test harness into a commit whose
message described a memory measurement; it was already pushed by the
time anyone noticed, so the history stands uncorrected.

Keep commits in logical increments with descriptive messages. `doc/status.md` entries are labeled
by device/operator and updated after every hardware session — hardware
truth is per-device, so never overwrite another operator's entries; add
your own. Don't commit the per-device waveform, anything under a tool's
gitignored `build/`, or the reader's static address.

## Where we are (2026-08-24)

- **Product**: the reader image on os2 — KOReader natively on fbdev with
  pen/finger input, four orientations, publish-on-call single-pass page
  turns (8/8 on glass, 2026-08-01), the GL16 partial policy + idle washer,
  Wi-Fi with out-of-band credentials, key-only SSH, ACM gadget (console
  shell opt-in via `WILKBOOK_VERY_INSECURE_FOR_CONVENIENCE`).
  `v0.1.0-prealpha` is tagged and the repo is public
  (github.com/willkelly/wilkbook); the alpha sign-off has NOT happened
  (`doc/alpha-signoff.md`, `doc/alpha-checklist.md`).
- **Kernel — read this carefully, the tree and the device differ.**
  `%linux-pinenote-base` is `nongnu:linux-7.1` and `make kernel`
  cross-builds **7.1.8** clean (both DTBs, both modules linked). But
  **nothing on 7.1 has run on glass.** The hardware-proven kernel is
  still **7.0.11** (display, PREEMPT_RT, Wi-Fi/BT, gadget — 2026-07-04),
  and 7.0.11 is what the deployed os2 image runs today (`uname -a`,
  2026-08-24). So: 7.1 is what the repo *builds*, 7.0.11 is what is
  *proven*. Never state one as the other. `channels.scm` still pins
  nonguix at 7.0.11 and has no 7.1, so a reproducible `TIME_MACHINE=1`
  build of the current tree is **not yet possible** — that pin bump is
  its own change. 6.6.30 remains regression-isolation only. Seven
  patches; the 7.1 move *deleted* two hunks mainline absorbed. Inventory
  in `doc/kernel-forward-port.md`.
- **Suspend**: **ultra suspend is the shipping suspend** (2026-08-08,
  R12): hrdl's configuration adopted whole — standing
  `rockchip,suspend-state-override = <5>` + three `*_pmu` rails
  off-in-suspend + `sdmmc1 cap-power-off-card` + the cyttsp5 resume
  workaround — a MATCHED PAIR pinned by `make ultra-coupling-check`;
  either half alone is proven broken. Three consecutive rails-off
  resumes on glass (RTC backstop + power button); **4.64 mA measured**
  vs deep's ~20 mA (`doc/artifacts/pinenote-ultra-r12-20260808/`).
  Promoted image `9a08803e…` is on os2 and the unplugged soak
  **CONCLUDED 2026-08-15**, meeting every `doc/alpha-checklist.md` §3c
  exit criterion: 6.17 days unplugged, **170 suspend cycles / 0
  failures**, and standby measured at last — **5.47 mA idle** and
  **10.07 mA as actually read**, projecting to **~30.5 and ~16.6 days**
  from 4000 mAh (`doc/artifacts/pinenote-ultra-soak-20260815/`). Quote
  **both** numbers: ">30 days" describes a device nobody is reading. The
  old "~36 days pure / ~28 effective" arithmetic off R12's single
  bracket is retired — it was pessimistic on standby (the hourly RTC
  backstop costs ~0.83 mA, not ~1.3) and silent on the reading term.
  Documented tradeoff: GPIO0 is unpowered in suspend, so the pen cannot
  wake it. Wake sources are the RTC, power button, charger — **and the
  cover, confirmed 2026-08-09**. The rails half of that puzzle is
  SOLVED (2026-08-24, #8): the hall sensor sits on `vcc_hall_3v3` →
  `vcc_sys` → `vcc_bat`, i.e. powered off the **battery** through two
  always-on fixed regulators, with no PMIC involvement. `vcc_3v3_pmu`
  really is off-in-suspend; it simply never had any bearing on this
  sensor. The old contradiction came from conflating the GPIO pad's
  supply with the supply of the thing driving it. Still open, and now
  the only surviving candidate: whether the PMU can latch the edge with
  `pmuio1`/`pmuio2` down (alive-domain detection).
  `doc/artifacts/pinenote-input-clocks-20260824/`. Auto-suspend (5 min idle) is live, so **SSH to the
  reader is intermittent** — write `enabled=0` to
  **`/data/wilkbook/autosuspend.conf`** before working on it
  (`doc/device-access.md`). That path was recorded here as
  `/var/lib/pinenote/autosuspend.conf` until 2026-08-24; that file does
  not exist on the device. Still unexplained: the TPS `ENABLE` 2f→20
  delta after suspend, and one 13.09 mA idle segment in the soak.
- **Power**: awake reader idle ~157 mA after the vdd_cpu auto-PFM fix
  (was ~174); suspend 4.64 mA ultra in a quiet bracket, **5.47 mA as
  idle standby** once the hourly backstop is included (deep's ~20 mA is
  superseded as the shipping figure). **DDR DVFS is built but SHIPS
  DISABLED**: 324 MHz starves the EBC's phase-data fetch and corrupts
  the display silently (no underrun interrupt), proven by one-variable A/B 2026-08-07, so
  `wilkbook_dmc` defaults to `mode=off` and the boost is off too.
  End-to-end standby is **measured, not arithmetic** (2026-08-15):
  5.47 mA idle and 10.07 mA as actually read, from the daemon's own
  `charge_now` series over 6.17 unplugged days. The ~30.5/~16.6-day
  figures are projections from that measured draw, not an observed run
  to empty. Ledger and next levers:
  `doc/power-management.md`.
- **Display**: the portrait double-refresh is fixed on glass
  (publish-on-call + `defio_delay_ms=250`); the generation barrier is
  hardware-proven; the blank-panel and missing-border anomalies are
  closed (`doc/refresh-policy.md`). **79.68 Hz is one module parameter
  away** (2026-08-24, #23): `cpll_333m` already runs at 250 MHz, not
  333, so `rockchip_ebc.dclk_select=1` moves `dclk_ebc` onto it and
  gives a flat 1.25× — measured on glass, both directions. The DT and
  driver work #23 scoped is unnecessary. NOT cleared to ship: the
  failure mode is silent corruption and only a webcam-grade check has
  been done (`doc/artifacts/pinenote-dclk-reclock-20260824/`).

## Standing lessons (instrument corrections that cost real sessions)

- **A zero IRQ delta means nothing on its own** — writing content that
  already matches the region is a genuine no-op the driver correctly
  drops; `mmap-band-probe.lua` reports `fb-rows-changed` and flags no-ops.
- **A global refresh costs 1 IRQ; a partial costs 1 per frame** — never
  compare the two units (`doc/testing.md`).
- **The UART works** at 1500000 — the old "receives nothing from ttyS2"
  claim was a test artifact (device-side 9600 termios default + passive
  listens; `doc/device-access.md`).
- **os1 is not an oracle for the fbdev damage path** — it drives its
  display through KMS and never makes an fbdev write.
- **The ebc-logic harness compiles the `#else` stub of every `#ifdef` its
  shim does not define** — a green host suite proves nothing about code
  inside a config guard, **except `CONFIG_DRM_FBDEV_EMULATION`, which
  `ebc-fbdev-order-test` defines and executes** (deferred-io drain, resume
  barrier, `defio_delay_ms`, fbdev probe wrapper).
- **A single-stack harness cannot test an ordering that depends on
  preemption** — a deterministic baton models ordering, not the absence
  of a race.
- **Sustained damage starves the global-refresh path** (the 2026-07-29
  lesson): fbcon's blinking cursor was the producer; the deployed cmdline
  carries `vt.global_cursor_default=0` and campaign procedures unbind
  fbcon and require EBC-idle before supervised runs. **Structurally fixed
  in the driver 2026-08-24** (issue #22, hrdl's work-item drain gate) —
  the loop now drains within one area lifetime whenever a global refresh
  or a park is pending, so those procedures stop being load-bearing. That
  fix is harness-proven only; **no panel has run it.** Until a hardware
  session says otherwise, keep the procedures.
