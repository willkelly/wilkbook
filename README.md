# wilkbook

A Guix channel that builds a small operating system for the Pine64 PineNote
e-ink tablet. The goals, in order:

1. **Kernel currency** — track recent kernels by carrying the downstream
   PineNote display/pen stack as explicit patches, with working (non-free)
   firmware.
2. **Easy image building** — one command from checkout to a deployable
   rootfs artifact.
3. **E-ink userland** — eventually a reading-first device: an EBC-aware
   render harness, then a KOReader spin or a MuPDF-based renderer.

See `ROADMAP.md` for direction and `doc/status.md` for what is currently
proven on hardware.

## Status (2026-07)

- The **forward-ported 7.0 kernel is the validated primary** (2026-07-04
  hardware session): e-ink display output with temperature-compensated
  waveform selection, Wi-Fi/Bluetooth firmware, USB ACM gadget console,
  and full `PREEMPT_RT` — on an untainted vanilla-source kernel. Build it
  with `make rootfs-usb-console`. Details in `doc/status.md` and
  `doc/kernel-forward-port.md`.
- The **6.6.30 m-weigand flavor** is kept as a regression-isolation tool
  only (`make rootfs-usb-console-linux-6-6`); it no longer leads
  anything.

## Quick start

```sh
make help                              # list targets
make rootfs-usb-console               # validated primary (7.0 + PREEMPT_RT)
make rootfs-usb-console-linux-6-6     # 6.6 regression-isolation baseline
make kernel-drv                       # cheap gate: compute kernel derivation
make qemu-smoke                       # generic ARM64 userspace check
```

Deployment to the device is deliberately manual: the extracted `PNGuixRoot`
rootfs is written to the inactive `os2` partition only, observed over UART,
with stock Debian on `os1` as the rescue path. See `doc/hardware-deploy.md`.

## Layout

- `pinenote/packages/` — the two kernel packages (`linux-pinenote` forward
  port, `linux-pinenote-6.6.30` regression baseline), Broadcom Wi-Fi/BT
  firmware packages, firmware helper scripts, EBC test and diagnostics
  tools.
- `pinenote/patches/` — the kernel forward-port patch (EBC driver, WS8100
  pen, PineNote DTS, `pinenote_defconfig`).
- `pinenote/services/` — Shepherd services: waveform install, EBC modprobe
  options and parameters, diagnostics, USB CDC-ACM gadget console.
- `pinenote/images/` — initrd wrappers (pre-root waveform extraction and
  display module loading), extlinux bootloader config, kernel arguments,
  partition labels.
- `pinenote/systems/` — flavor entrypoints (see `doc/pinenote-flavors.md`).
- `pinenote/scripts/preflight/` — non-destructive inspection and extraction
  helpers.
- `pinenote/tools/` — host-side test tools that compile the verbatim EBC
  driver/waveform sources and test them off-device (`wbf`, `ebc-logic`,
  `rastersim`; see `doc/testing.md`).
- `doc/` — start with `testing.md` and `kernel-forward-port.md`; also
  `building.md`, `hardware-deploy.md`, `status.md`, `device-runbook.md`
  (device inventory and backup ledger), `eink-research.md` (domain
  background), `driver-findings-report.md`, `pinenote-flavors.md`, and
  `archive/` for historical documents. Contributors and agents should read
  `CLAUDE.md` first.

## Firmware and waveform policy

- The per-device EBC **waveform is never bundled**. The initrd and a
  first-boot service extract it from the device's own `waveform` partition
  (fallback: `/state/firmware/ebc.wbf`) into
  `/lib/firmware/rockchip/ebc.wbf`, failing visibly if absent.
- Broadcom Wi-Fi/BT firmware is packaged from public sources
  (linux-firmware, RPi-Distro bluez-firmware) under the names brcmfmac and
  the BT driver request on the PineNote. The kernel builds from vanilla
  sources via nonguix because linux-libre refuses to load these blobs (see
  `doc/kernel-forward-port.md`).
- VCOM calibration, waveform, U-Boot, and partition-table backups are
  recorded in `doc/device-runbook.md` before any hardware work.

## Safety model

Builds never touch the device. Deployment writes only the `os2` slot after
the backup checklist passes, never the bootloader, partition table,
`waveform`, or `os1` rescue system, and never persists U-Boot environment or
boot-order changes.
