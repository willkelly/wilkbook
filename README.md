# wilkbook

A Guix channel that builds a reading-first operating system for the
Pine64 PineNote e-ink tablet. The goals, in order — all three now have
hardware-proven substance behind them:

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

Before your first build, read the **host prerequisites** in
`doc/building.md` (Guix + nonguix channel setup, substitutes, and honest
build-time expectations — a cold cross-build of the kernel is hours, not
minutes). Note for collaborators: the validated images bundle
personally-licensed fonts staged from a gitignored directory
(`pinenote/fonts/README.md`); a fresh clone builds with fallback fonts.

Deployment to the device is deliberately manual: the extracted `PNGuixRoot`
rootfs is written to the inactive `os2` partition only, observed over UART,
with stock Debian on `os1` as the rescue path. See `doc/hardware-deploy.md`,
and `doc/device-runbook.md` for provisioning a device of your own.

## Reading order (humans)

1. This file, then `doc/status.md` (current-state header) — where we are.
2. `doc/building.md` — host setup and your first build.
3. `doc/hardware-deploy.md` + `doc/device-runbook.md` — getting it onto a
   device, including one that isn't the author's.
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
- `pinenote/tools/` — host-side test and diagnostic tools: `wbf`,
  `ebc-logic`, `rastersim`, `orientation`, `koreader-input`, `optics`,
  `power`, `rockchip-pm`, `ebc-barrier`, `ebc-damage-probe`,
  `ddr-dvfs-test`, `ddr-sip-probe`. The table in `doc/testing.md` says
  what each covers.
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

## Hosting

The canonical remote is a private Forgejo instance on the author's network;
collaborator access is provisioned per person (ask Will). Until then, work
from a shared clone/bundle and send changes as patches or bundles.
