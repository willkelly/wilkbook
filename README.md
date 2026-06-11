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

## Status (2026-06)

- The **6.6.30 m-weigand kernel flavor works entirely** on the device:
  display, Wi-Fi, Bluetooth, USB console. Build it with
  `make rootfs-usb-console-linux-6-6`.
- The **forward-ported 7.0 kernel** boots to Guix userspace on the
  experimental `os2` slot. It now builds from vanilla kernel.org sources
  (via the nonguix channel) so non-free firmware can load — the earlier
  linux-libre base gated firmware loading entirely. Open issues: Wi-Fi
  firmware on the vanilla base awaits hardware confirmation, the USB gadget
  fails at `ep0out` (UART console works), and nothing has been drawn on the
  panel yet. Details in `doc/status.md` and `doc/kernel-forward-port.md`.

## Quick start

```sh
make help                              # list targets
make rootfs-usb-console-linux-6-6     # known-good baseline image -> rootfs
make rootfs-usb-console               # kernel-currency track
make kernel-drv                       # cheap gate: compute kernel derivation
make qemu-smoke                       # generic ARM64 userspace check
```

Deployment to the device is deliberately manual: the extracted `PNGuixRoot`
rootfs is written to the inactive `os2` partition only, observed over UART,
with stock Debian on `os1` as the rescue path. See `doc/hardware-deploy.md`.

## Layout

- `pinenote/packages/` — the two kernel packages (`linux-pinenote` forward
  port, `linux-pinenote-6.6.30` baseline), Broadcom Wi-Fi/BT firmware
  packages, firmware helper scripts, EBC test and diagnostics tools.
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
- `doc/` — `building.md`, `hardware-deploy.md`, `status.md`,
  `kernel-forward-port.md`, `device-runbook.md` (device inventory and
  backup ledger), `pinenote-flavors.md`, and `archive/` for historical
  documents.

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
