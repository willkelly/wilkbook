# wilkbook — orientation for contributors and agents

A Guix channel that builds a reading-first OS for the Pine64 PineNote
e-ink tablet. If you're an AI agent picking this up, read this file, then
`ROADMAP.md` (direction), then `doc/status.md` (current hardware truth).
This file is the "how we work and why" that isn't obvious from the code.

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

- `pinenote/packages/kernel.scm` — two kernels: `linux-pinenote` (the
  vanilla-7.0.x + forward-port-patch **primary**) and
  `linux-pinenote-6.6.30` (m-weigand baseline, now **regression-isolation
  only** — 7.0 reached parity 2026-07-04).
- `pinenote/patches/linux-pinenote-7.0-forward-port.patch` — the EBC
  display driver, `drm_epd_helper`, WS8100 pen, PineNote DTS, and
  `pinenote_defconfig`. This single patch is the most rebase-fragile,
  highest-value artifact in the repo. Treat edits to it with care; it is
  also **treated as permanent** (mainline has no EPD infrastructure and
  won't for years — see `doc/eink-research.md`).
- `pinenote/services/`, `pinenote/images/`, `pinenote/systems/` — Guix
  system services, initrd, and flavor entrypoints.
- `pinenote/tools/{wbf,ebc-logic,rastersim}/` — host-side test tools (see
  `doc/testing.md`). These compile the *verbatim* driver source out of the
  patch and test it on your workstation.
- `pinenote/scripts/preflight/` — non-destructive inspection/extraction.
- `doc/` — see the doc map below.

## Doc map (what lives where)

- `README.md` — project overview and quick start.
- `ROADMAP.md` — direction, three tracks + the offline testing ladder.
  Not status.
- `doc/status.md` — **the single source of hardware truth.** Update it
  after every hardware session; it records what's actually been proven.
- `doc/testing.md` — the testing philosophy, host tools, validation ladder.
- `doc/worked-examples.md` — the philosophy applied: replayable case
  studies (cherry-pick evaluation, harness-first risk-taking, patch
  surgery). Read these before your first non-trivial change.
- `doc/kernel-forward-port.md` — how to refresh the patch for a new
  kernel; hard-won config lessons; the pinned driver quirks; the
  community cherry-pick record.
- `doc/building.md` — exact build/QEMU/extraction commands.
- `doc/hardware-deploy.md` + `doc/device-runbook.md` — the os2 write
  protocol and the device inventory/backup ledger.
- `doc/eink-research.md` — domain background (waveforms, commercial e-ink
  stacks, the PineNote community lineage). Read before display work.
- `doc/networking.md` — the Wi-Fi/networking design: what's proven
  (firmware loads), the supplicant/connection-manager options, the
  out-of-band credentials plan, and how it unblocks the optics recorder.
- `doc/refresh-policy.md` — the display-quality program: waveform decodes
  from the device's own .wbf, policy decisions (flash thresholds, GL16
  globals, input architecture), and the replay-workbench plan.
- `doc/driver-findings-report.md` — the community-facing writeup of driver
  bugs the host tools found.
- `doc/pinenote-flavors.md` — the system flavors.

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
(`make wbf-check ebc-logic-check rastersim-check WBF=…`) — they exist
precisely to catch what a rebase silently breaks. If a tool goes red,
that's the patch changing behavior; understand why before re-pinning.

**The os1 oracle.** Stock Debian on the device's os1 slot (6.12-pinenote,
everything working) is reachable read-only over SSH and is the cheapest
"is our build doing the right thing" check: live `/proc/device-tree`,
`/sys/bus/iio`, dmesg signatures, gadget bracketing. Use it before
theorizing. Details and the standing device-access conventions are in the
agent's memory and `doc/kernel-forward-port.md`.

## Safety model (do not violate)

- **Builds never touch the device.** Deployment is a separate, manual,
  os2-only step (`doc/hardware-deploy.md`). os1 is the untouched rescue
  path.
- **Never bundle the waveform.** It's per-device calibration data
  extracted from the device's own `waveform` partition at boot. The repo
  fails visibly if it's absent rather than shipping a generic one. The
  same goes for VCOM and other per-device values.
- **Destructive device ops** (dd to os2, reboots) are user-present steps.
  Writing os2 has standing permission with the full protocol (confirm os1
  is root, os2 unmounted, dd, readback-SHA verify); rebooting needs a
  human on the UART.
- **When you find a driver bug**, report it (a `quirk:` test + a note in
  `doc/kernel-forward-port.md` / `doc/driver-findings-report.md`) — don't
  quietly patch the driver. The upstream/community lineage
  (m-weigand → hrdl → ayakael) should own driver fixes.

## Committing

Single-user repo; commit and push to `main` freely in logical increments
with descriptive messages. Keep `doc/status.md` in sync with reality after
any hardware session. Don't commit the per-device waveform or anything
under a tool's gitignored `build/`.

## Where we are (2026-07-05)

7.0.x is the validated primary: e-ink display with temperature-compensated
waveforms, Wi-Fi/BT, USB gadget console, and PREEMPT_RT — all confirmed on
hardware. **Reader first light achieved**: KOReader runs natively on the
framebuffer (no compositor — the cage/SDL kiosk died on hardware evidence,
`doc/koreader-spike.md` §3) with pen- and finger-navigable UI (cyttsp5
touch hardware-validated; pinch-zoom confirmed on the A.2 boot). Offline
ladder rungs 1–4 (+4v visual loop) are built and green, and the
refresh-policy program has its offline workbench plus its first real
device trace (`ebc-replay`, rung 7a phase B — `doc/refresh-policy.md`).
The A.2 boot surfaced two bugs, both root-caused and fixed offline the
same night: the refresh_waveform config bug (cmdline module params are
inert; the params one-shot owns them now, and rung 4 asserts the live
value) and the TOC-tap bug (pen hover captured finger taps into the
pen slot — fixed by `mixedrouter.lua`, proven on the `koreader-input`
host harness). Staged for the next device session: the A.2.2 image
(all three fixes; os2 ledger in `doc/status.md`). Open next steps
(ROADMAP): the GL16 optics + tap-fix hardware verdicts, refresh-policy
tuning on the workbench, a Wi-Fi networking/credentials story. See
`ROADMAP.md` and
`doc/status.md` for specifics.
