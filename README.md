# wilkbook

A Guix channel that builds a reading-first operating system for the
Pine64 PineNote e-ink tablet.

> ## THIS IS AI SLOP HARDLY TESTED NONSENSE. ONLY RUN THIS IF YOU ARE INSANE OR HATE YOUR PINE NOTE.

That is the short version and it is not a joke. Specifically, so you can
judge for yourself:

- **It writes to a partition on a device most people cannot easily
  re-flash.** Deployment `dd`s a rootfs onto the `os2` slot. Stock Debian
  on `os1` is deliberately never touched and every procedure here is
  built around keeping that rescue path intact — but you are still
  running `dd` against your eMMC on a tablet that is awkward to recover.
- **It is largely AI-written.** Most of the code and nearly all of the
  prose was produced by AI agents working under the rules in `CLAUDE.md`,
  with a human reviewing and running the hardware sessions.
- **Hardware validation is one device and one operator.** Every number
  and every "proven on glass" claim in `doc/status.md` came off a single
  PineNote v1.2. Nothing here has been reproduced on a second device, and
  **no second person has ever installed it** — `doc/install.md` is
  derived from this repo's own procedures, not from a successful replay.
- **There is no update path and no support.** A new build is the whole
  manual write protocol again. There is no package management on the
  device, no migration, no issue triage promise, and no warranty of any
  kind (`LICENSE`).
- **You need a UART.** The U-Boot menu is serial-only, so booting `os2`
  at all requires an SBU debug cable. Without one you cannot select the
  slot and cannot recover from a bad boot.

The genuinely valuable part of this repo, for anyone who is not the
author, is below: the host tools and the findings. Those you can read,
run, and lift **without touching your device at all**.

## Reproducing a build

We publish no binaries. `channels.scm` pins Guix and every extra channel
by commit, so a tagged tree rebuilds byte-identically anywhere:

```sh
guix time-machine -C channels.scm -- \
  system image -t raw-with-offset -L . --target=aarch64-linux-gnu \
  pinenote/systems/pinenote-reader.scm
```

`doc/release.md` has the full procedure. This is a claim about
*reproducibility*, not about quality — see the banner above.

## What to steal

Written for other PineNote people. Nothing in this section requires
Guix, a deployment, or this repo's packaging unless it says so; the real
coupling is to the kernel patch and to the driver source, both of which
you probably already carry.

**Test the display driver on your workstation.** These compile the
*verbatim* `rockchip_ebc` / `drm_epd_helper` source straight out of
`pinenote/patches/linux-pinenote-7.0-forward-port.patch` — extracted at
build time, never hand-copied — so they cannot drift from the driver.
`gcc` + `python3`; no device.

- `pinenote/tools/wbf` — decodes your panel's own PVI `.wbf` exactly as
  the driver loads it (modes, temperature bins, LUTs), and dumps LUTs for
  the simulator. The cheapest way to find out what your waveform file
  actually contains.
- `pinenote/tools/ebc-logic` — the driver's pure logic (XRGB8888/R4→Y4
  blitters, damage split/collision scheduling) against independent
  references, plus a behavioral device model that *executes* the refresh
  state machine (probe, LUT upload, DMA windowing, IRQ/completion) under
  ASan, plus `ebc-replay`, which replays KOReader refresh traces through
  it under candidate policies.
- `pinenote/tools/rastersim` — a dependency-free C Gray8→Y4 raster
  library and waveform simulator; the independent reference that pinned
  the LUT `(from, to)` axis order three separate ways.
- `pinenote/scripts/preflight/validate-*-hunk.sh` — POSIX-shell
  structural gates over the patch itself, with mutation tests. They exist
  because a host harness compiles the `#else` stub of any `#ifdef` it
  does not define, so a green suite can prove nothing about code inside a
  config guard. If you carry the same patch, these port unchanged.

**Measure what the panel actually does.**

- `pinenote/tools/optics` — a camera-in-a-box optical-defect instrument:
  a self-calibrating EPUB test card, video ingest, and deterministic
  black-flash / ghosting / slow-settle / double-flash classifiers.
  Explicitly designed to be portable to other people's PineNotes — a
  phone camera and a dark box are enough to produce a comparable dataset.
  Analysis is pure Python and needs no device.
  `pinenote/tools/optics/belief-vs-glass.sh` is the cheap version of the
  same idea: put `/dev/fb0` (what the driver believes it painted) next to
  the photo (what the glass shows), so "looks bad" becomes a measurement.
  (Edit the host/known-hosts at the top; it is written for the author's
  device.)
- `pinenote/tools/ebc-damage-probe` — device-side LuaJIT probes that
  write chosen patterns into the mmapped framebuffer and count EBC
  interrupts, isolating deferred-io and damage scheduling from KOReader
  entirely. This is the instrument that found fbcon starvation and drove
  the `defio_delay_ms` choice. Needs `/dev/fb0`, `/proc/interrupts` and
  LuaJIT; its build snippets hardcode Guix store paths you would replace.
- `pinenote/tools/power/fb-damage-gates.sh` — a read-only dump of the
  four silent gates between a userspace framebuffer write and an EBC
  frame. It deliberately opens no device node (the first opener of
  `/dev/dri/card0` becomes DRM master).

**Kernel work.**

- `pinenote/patches/linux-pinenote-7.0-forward-port.patch` — the EBC
  display stack, `drm_epd_helper`, WS8100 pen, PineNote DTS and
  `pinenote_defconfig`, forward-ported onto vanilla 7.0.x and
  hardware-validated. Five smaller patches ride alongside it (BSP SIP
  suspend, cpuidle, vdd_cpu PFM, DDR static-low, st_accel PM).
  `doc/kernel-forward-port.md` carries the inventory, the refresh
  procedure, the config lessons, and the community cherry-pick record.
- `pinenote/tools/ddr-sip-probe/src` — a ~zero-risk out-of-tree module
  that asks whether your bl31 implements the Rockchip DRAM-frequency SIP
  and then returns `-ENODEV` so it can never stay loaded. Plain Kbuild;
  only its `guix.scm` is Guix-specific. (Its sibling `ddr-dvfs-test`
  *changes* the DDR rate and is the highest-risk artifact in the repo —
  read its `protocol.md` before you consider it.)
- `pinenote/tools/orientation/orientation-bridge.lua` — SC7A20
  accelerometer → uinput orientation bridge in plain LuaJIT, independent
  of the display driver; you would swap the Shepherd handshake for your
  own supervisor.
- `pinenote/tools/koreader-input` — runs KOReader's *own*
  `input.lua`/`gesturedetector.lua` against synthetic evdev streams;
  reproduces the pen-hover tap-capture bug (finger tap read as a swipe)
  and pins cyttsp5 touch-axis normalization to measured targets.

**Findings and method.**

- `doc/driver-findings-report.md` — a community-facing writeup of
  `rockchip_ebc` defects found from the desk (heap overrun on odd clips,
  a scheduler hole, teardown UAF, …), each with a deterministic
  reproducer and its fix status. Written to be posted upstream.
- `doc/refresh-policy.md` + `doc/pageturn-program.md` — waveform decodes,
  the publish-on-call fix for the portrait double refresh, the GL16
  partial policy and idle washer, and the replay workbench behind them.
- `doc/eink-research.md` + `doc/eink-sota.md` — curated e-ink domain
  background, and an adversarially-verified state-of-the-art survey with
  a ranked steal list and a corrections register.
- `doc/device-access.md` — the UART/SSH/console conventions that cost
  sessions to learn: 1500000 baud, the device-side 9600 termios trap, a
  flipped USB-C plug swapping SBU1/SBU2, proving the link with the SoC's
  own `tx`/`rx` counters, and post-mortem log harvest from the other slot.
- `doc/power-management.md` and `doc/artifacts/` — the measured power
  ledger and the raw session evidence (scripts included) behind it,
  including the ABBA measurement discipline used to cancel drift.
- `doc/testing.md` — the method itself, which is the most portable thing
  here: verbatim source extraction, independent references rather than
  re-pasted code, "absence of an error is not a passing test", and why a
  single-stack harness models ordering but not races.

## What this is

The goals, in order — all three now have hardware-proven substance behind
them:

1. **Kernel currency** — track recent kernels by carrying the downstream
   PineNote display/pen stack as explicit patches, with working (non-free)
   firmware. The forward-ported 7.0.x kernel is the validated primary.
2. **Easy image building** — one command from checkout to a deployable
   rootfs artifact.
3. **E-ink userland** — a reading-first device. KOReader runs natively on
   the framebuffer with pen and finger input; this is the deployed product.

See `doc/status.md` for what is currently proven on hardware (start with
its current-state header), `ROADMAP.md` for direction, and the reading
order below for onboarding.

## Status (2026-08-06)

- **The reader image is the product.** KOReader runs directly on fbdev
  with pen + finger input, four orientations, and single-pass
  publish-on-call page turns (fixed on glass 2026-08-01). Wi-Fi with
  out-of-band credentials, key-only SSH, and the USB ACM gadget console
  are hardware-proven.
- **Deep suspend works** (2026-08-02) and **auto-suspend is live**: the
  device sleeps to `deep` after 5 minutes idle and wakes on the power
  button (~157 mA awake reader idle vs ~20 mA suspended). A multi-day
  unplugged soak is still outstanding. Practical consequence: SSH to a
  deployed reader is intermittent while auto-suspend is enabled — see
  `doc/device-access.md`.
- **Kernel**: the forward-ported vanilla-7.0.x kernel with `PREEMPT_RT`,
  temperature-compensated e-ink waveforms, Wi-Fi/BT firmware, and the
  power-management patch set is the validated primary. The 6.6.30
  m-weigand flavor is kept for regression isolation only.
- Details, exact image hashes, and every session record: `doc/status.md`.

## Quick start

```sh
make help                              # list targets
make rootfs-reader                     # the product: KOReader reader image
make rootfs-reader-debug               # reader + diagnostics/EXTRACT_FBS kernel
make rootfs-usb-console               # headless debug image (ACM console)
make kernel-drv                       # cheap gate: compute kernel derivation
make qemu-smoke                       # generic ARM64 userspace check
```

Never used Guix? `doc/building.md` opens with a **from-zero** section —
install Guix, `guix pull -C channels.scm` (nonguix is required and the
file carries its channel introduction), authorize substitutes, build.
Guix is the only host dependency; it brings its own toolchain.

Before your first build, read the **host prerequisites** in
`doc/building.md` (Guix + nonguix channel setup, substitutes, and honest
build-time expectations — a cold cross-build of the kernel is hours, not
minutes). Note for collaborators: the validated images bundle
personally-licensed fonts staged from a gitignored directory
(`pinenote/fonts/README.md`); a fresh clone builds with fallback fonts.

Deployment to the device is deliberately manual: the extracted `PNGuixRoot`
rootfs is written to the inactive `os2` partition only, observed over UART,
with stock Debian on `os1` as the rescue path. See `doc/hardware-deploy.md`
for the write protocol and `doc/device-runbook.md` for the backup ledger.

**Installing on a PineNote that isn't the author's** — the cable you
need, the backups to take first, the per-device waveform and VCOM, what
to stage on the data partition, and what the repo does *not* know about
a first boot: `doc/install.md`. Nobody has done it yet; that page says
so throughout.

## Alpha

Scope, blockers and what is explicitly deferred: `doc/alpha-checklist.md`.
Alpha is the reader flavor for two people who can build from source and
drive a UART. The repo is public so other PineNote people can read the
findings and take what is useful (see "What to steal" above), not because
this is installable by anyone else. If you are the second person,
`doc/install.md` is your starting page.

## Reading order (humans)

1. This file, then `doc/status.md` (current-state header) — where we are.
2. `doc/building.md` — host setup and your first build.
3. `doc/install.md` — the path from a stock PineNote to a booting os2, if
   the device is yours rather than the author's. Then
   `doc/hardware-deploy.md` (the write protocol) + `doc/device-runbook.md`
   (the backup ledger).
4. `doc/testing.md` — the offline validation ladder; read before changing
   code. `doc/worked-examples.md` shows the philosophy applied.
5. `ROADMAP.md` — direction. `CLAUDE.md` — required reading for AI agents,
   useful for humans too (safety model, conventions).

## Layout

- `pinenote/packages/` — three kernel packages (`linux-pinenote` forward
  port, `linux-pinenote-debug` with diagnostics + `EXTRACT_FBS`,
  `linux-pinenote-6.6.30` regression baseline), Broadcom Wi-Fi/BT
  firmware packages, firmware helper scripts, the KOReader device target.
- `pinenote/patches/` — the kernel forward-port patch (EBC driver, WS8100
  pen, PineNote DTS, `pinenote_defconfig`) plus the smaller
  power-management patches (BSP SIP suspend, cpuidle, vdd_cpu PFM, DDR
  DVFS, st_accel PM). `doc/kernel-forward-port.md` has the inventory.
- `pinenote/services/` — Shepherd services: waveform install, EBC
  parameters, reader session, orientation bridge, auto-suspend, DDR
  DVFS (dmc + input-driven boost), networking, USB CDC-ACM gadget
  console, diagnostics.
- `pinenote/images/` — initrd wrappers, extlinux bootloader config, kernel
  arguments, partition labels.
- `pinenote/systems/` — flavor entrypoints (see `doc/pinenote-flavors.md`).
- `pinenote/scripts/preflight/` — non-destructive inspection and extraction
  helpers.
- `pinenote/tools/` — test and diagnostic tools. Host-side (no device):
  `wbf`, `ebc-logic`, `rastersim`, `orientation`, `koreader-input`,
  `optics`, `power`, `rockchip-pm`, `ebc-barrier`. Device-side and
  supervised: `ebc-damage-probe`, `ddr-sip-probe`, `ddr-dvfs-test`. The
  table in `doc/testing.md` gives each one's rung and coverage.
- `pinenote/fonts/` — optional, gitignored personally-licensed fonts
  (`pinenote/fonts/README.md`).
- `doc/` — the doc map in `CLAUDE.md` describes every document. Highlights:
  `status.md` (hardware truth), `testing.md`, `building.md`,
  `hardware-deploy.md`, `device-runbook.md`, `device-access.md`,
  `networking.md`, `refresh-policy.md`, `power-management.md`,
  `kernel-forward-port.md`, `eink-research.md` + `eink-sota.md` (domain
  background), `driver-findings-report.md` + `upstream-register.md`
  (community-facing), `pinenote-flavors.md`. `doc/archive/` holds
  historical documents, `doc/artifacts/` committed hardware-session
  evidence, `doc/datasets/` the committed optics dataset.

## Firmware and waveform policy

- The per-device EBC **waveform is never bundled**. The initrd and a
  first-boot service extract it from the device's own `waveform` partition
  (fallback: `/state/firmware/ebc.wbf`) into
  `/lib/firmware/rockchip/ebc.wbf`, failing visibly if absent.
- Broadcom Wi-Fi/BT firmware is packaged from public sources
  (linux-firmware, RPi-Distro bluez-firmware). The kernel builds from
  vanilla sources via nonguix because linux-libre refuses to load these
  blobs (see `doc/kernel-forward-port.md`).
- VCOM calibration, waveform, U-Boot, and partition-table backups are
  recorded per-device in `doc/device-runbook.md` before any hardware work.

## Licensing

The channel's own code (Scheme, tools, docs) is AGPL-3.0 (`LICENSE`).
Kernel patches carry the kernel's licenses (GPL-2.0, per the SPDX headers
inside the patch files) — a patch to GPL-2.0 code is GPL-2.0. The KOReader
device target follows upstream KOReader (AGPL-3.0). Nothing in this repo
relicenses upstream work.

## Safety model

Builds never touch the device. Deployment writes only the `os2` slot after
the backup checklist passes, never the bootloader, partition table,
`waveform`, or `os1` rescue system, and never persists U-Boot environment or
boot-order changes. Reboots and other destructive steps are user-present.

## Build flags

One knob, off by default: `WILKBOOK_VERY_INSECURE_FOR_CONVENIENCE`.

Bring-up on this device is awkward — one USB-C port, so the debug cable
and the charger are mutually exclusive, and serial is not an armed wake
source. An unauthenticated shell is genuinely the difference between a
five-minute fix and a teardown. That was never the problem. The problem
was that it shipped **unconditionally and invisibly**: no build said
whether it carried one, and nobody had to decide.

So it is opt-in:

```make
# local.mk at the repo root -- gitignored, per-checkout
export WILKBOOK_VERY_INSECURE_FOR_CONVENIENCE = 1
```

or `WILKBOOK_VERY_INSECURE_FOR_CONVENIENCE=1 make image-reader` for a
one-off. A plain clone cannot build the conveniences by accident.

What it gates, listed explicitly in `pinenote/insecure.scm` so that
adding to the list is a deliberate edit that shows up in review:

- the **USB ACM gadget console**, which execs a shell on `/dev/ttyGS0`
  with no login prompt at all;
- **passwordless sudo** for the `reader` account, which is what makes
  that shell root-equivalent.

The two move together on purpose: a build with the shell but no sudo is
just latent, and one with sudo but no shell is the worst of both.

**Every reader build says which one it is.** `/etc/wilkbook-build` is
present either way and names the build, so a mounted image or a running
system answers the question without inferring from behaviour:

```
WILKBOOK_BUILD=default                     # or: very-insecure-for-convenience
```

Verified by inspecting built systems, not by reading the code: the
secure closure contains zero `shepherd-pinenote-usb-acm-console` items
and no `NOPASSWD` line; the insecure one contains both.

**Scope: the flag and the marker are on the `reader` flavor.** The
bring-up flavors carry the conveniences unconditionally and write no
marker — `pinenote/systems/pinenote-usb-console.scm` ships the
unauthenticated ACM console, `reader ALL=(ALL) NOPASSWD: ALL`, and an
auto-login getty by definition. They are debug images.

Neither build sets an account password, and `%base-services` runs a getty
on the kernel console, so **the SBU debug cable is a passwordless root
shell on any build** while the device is awake (`doc/device-access.md`).
That is the recovery channel, deliberately. "Default" means not reachable
over a USB data cable, not locked down.

## Hosting

The canonical remote is currently a private Forgejo instance on the
author's network; the repo will move to GitHub for sharing. Until then,
work from a shared clone/bundle and send changes as patches or bundles.
