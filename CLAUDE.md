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
- `doc/upstream-register.md` — the standing list of what we owe the
  community, where it would go, and what has to be true first. Nothing
  ships upstream until the baseline reader/note-taking image is done and
  the finding is proven in a system that actually works. Add rows as you
  find things; don't send.
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

## Where we are (2026-07-30)

7.0.x is the validated primary: e-ink display with temperature-compensated
waveforms, Wi-Fi/BT, USB gadget console, and PREEMPT_RT are hardware-proven.
KOReader runs directly on fbdev with pen and finger input; final4 validated
all four orientations, state replay, contact deferral, and normalized cyttsp5
coordinates on glass. Wi-Fi association, DHCP, and key-only SSH are proven on
the reader image. The optics pipeline has real device datasets plus an offline
 round-trip harness, and the awake-power program selected `conservative` after
 static and exact-reader-workload ABBAs; the 2026-07-25 probe-only reader boot
 verified the boot-time governor readback. Suspend remains deliberately disabled.
 Firmware
inventory identified the downstream BSP-ATF contract. The probe-only first
compatibility slice booted on 2026-07-25, but its invalid private version-query
gate returned `-EOPNOTSUPP` and left the driver unbound. It is now fail-closed:
the first activation-hard-off image booted on 2026-07-26 but rejected Linux OF's
standard synthesized `name` metadata before binding. The corrected adapter
accepts only the metadata-only policy-free node and keeps firmware calls
disabled; the corrected kernel booted and bound on 2026-07-26 with activation
compiled out and no suspend attempt. The maximal offline dormant
Linux-side contract now has donor-faithful typed events, compiled-DTB fixtures,
and a production-linked, execution-capable MEM-policy stack behind an
activation-hard-off boundary. Failed prepares poison activation until reboot,
and regulator restoration is retryable. The EBC disable-tail caller/off-screen
snapshots and generation-addressed barrier now pin a first setup/hardware failure
as terminal poison for later starts. The exact image carrying that code booted
cleanly on 2026-07-27 with no timeout/poison signature, but production has no
barrier UAPI caller, so the barrier's hardware semantics remain unproven. A
separately invoked, root-only paint/barrier/restore diagnostic and dormant
LuaJIT adapter/provider were written to os2 with exact-range SHA verification
on 2026-07-28. **That image booted on 2026-07-29 and its one supervised run
failed with `-110`; the corrected run on 2026-07-30 PASSED all five acceptance
criteria and the generation barrier is now hardware-proven** (generations 1 and
2, exact restore, exit 0, clean reader repaint, four benign dmesg lines all
session). **The 2026-07-29 defect was never in the barrier**, and it was
root-caused the same session without a second boot.
`rockchip_ebc_partial_refresh` never returns while damage keeps arriving
(unbounded frame loop, exits only on a drained area list, re-splices the queue
every frame), so `rockchip_ebc_refresh_thread` never gets back to the top where
`do_one_full_refresh` is read. The barrier's SUBMIT allocated its generation
correctly; nothing was ever there to consume it. Every frame completed inside
the 25 ms `EBC_FRAME_TIMEOUT`, so nothing timed out and the kernel logged
**nothing** (the 3 s bound belongs only to the *global* path, which is how we
know the thread was never in one). The damage source is fbcon, which `herd stop
reader-session` — step 1 of the campaign — re-binds; stock os1 ships
`vt.global_cursor_default=0` and the reader image did not. That was **measured**
on 2026-07-30: `cursor_blink=1` and 63 Hz with fbcon bound, **exactly 0 Hz**
and the thread `D`→`I` with it unbound. `barrier_poison` was provably never
set, and the waveform hypothesis was measured out (GC16 and GL16 are both 46
phases at 23 °C). Mitigations are in: the cmdline argument for the next build,
and an explicit fbcon unbind plus an EBC-idle precondition in the campaign
procedure. Also closed: the blank-panel anomaly (fb0 matched the offline card
golden byte-for-byte, so the paint was always correct) and the missing 1-px
border (the bezel occludes the outermost 4–10 px, measured with a
concentric-ring probe — this is the reader UI's usable-area inset). The
diagnostic blocks
INT/TERM/HUP outside an atomic `pselect` acknowledgement wait, blocks before
installing handlers, refuses pending cancellation before framebuffer mutation,
and preserves kernel barrier rejection codes, with startup, pending, and
blocked-delivery host regressions; none is imported by
the reader. Process inspection fails closed and is repeated immediately before
framebuffer mutation; EUID root is only an operational gate under the image's
existing maintenance sudo policy. The tree also provides a closed provider boundary plus pure
injected-capability userspace coordinator model, and executes a separate
synthetic active DT policy through fake Rockchip operations. The composite gate
reruns production hard-off validation; none of this is production-wired or a
suspend permission. Do not allocate another boot merely to repeat zero-call
binding. Activation, an active reviewed DT policy, real coordinator providers
and production sleep-frame wiring, and the PineNote-specific resume/ultra-suspend
dependencies remain required before any suspend attempt—not a firmware reflash.
See `ROADMAP.md`, `doc/status.md`, and `doc/power-management.md` for specifics.
