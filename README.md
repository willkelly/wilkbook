# wilkbook

Guix channel-style scaffold for first, non-destructive PineNote bring-up system
flavors. The current focus is build reproducibility, size tracking, first-boot
waveform handling, Shepherd service wiring, read-only EBC diagnostics, and an
initial no-credentials, service-level D-Bus-free networking baseline.

## What Is Here

- `channels.scm` and `.guix-channel` for channel-style development.
- `pinenote/packages/` with scaffold packages for the PineNote kernel,
  firmware support, boot reference docs, diagnostics, and EBC test placeholder.
- `pinenote/services/` with Shepherd service definitions for waveform install,
  EBC parameter application, diagnostics, state metadata, and one-shot EBC test.
- `pinenote/images/` with conservative partition/image notes and shared labels.
- `pinenote/systems/` with slim, networked, minimal, dev, and generic QEMU
  smoke operating-system entrypoints.
- `pinenote/systems/qemu-aarch64-smoke.scm` as a generic ARM64 QEMU smoke
  entrypoint that does not emulate PineNote hardware.
- `pinenote/scripts/preflight/` with non-destructive kernel-source,
  boot-bundle, and helper inspection scripts.
- `doc/build-only-workflow.md` with the build-only workflow and safety notes.
- `doc/pinenote-preflight.md` with the validation ladder and pass/fail gates.
- `doc/pinenote-gate6-runbook.md` with the backup and rescue checklist before
  any hardware-adjacent preflight.
- `doc/pinenote-gate6-temporary-boot.md` with the prepared host-side Gate 6
  artifacts and stop points before hardware execution.
- `doc/pinenote-flavors.md` with flavor definitions and current size
  measurements.

## Build Commands

From this repository:

```sh
guix build -L . pinenote-ebc-test --target=aarch64-linux-gnu
guix build -L . pinenote-diagnostics --target=aarch64-linux-gnu
guix build -L . pinenote-firmware-support --target=aarch64-linux-gnu
```

Build and run the generic ARM64 QEMU smoke VM when you want a preflight check
that does not depend on PineNote kernel, DTB, waveform, or EBC services:

```sh
guix system vm -L . --target=aarch64-linux-gnu \
  pinenote/systems/qemu-aarch64-smoke.scm
/gnu/store/...-run-vm.sh -M virt -cpu max -nographic -no-reboot
```

The generic QEMU smoke VM has reached the `pinenote-qemu-smoke login:` prompt;
use the VM launcher path as the validated QEMU gate.

The `linux-pinenote` package is pinned and configured to use the in-tree
`pinenote_defconfig`. Start with derivation computation before full realization;
see `doc/pinenote-flavors.md` for the flavor matrix and current sizes:

```sh
guix build -d -L . linux-pinenote --target=aarch64-linux-gnu
guix system build -d -L . --target=aarch64-linux-gnu \
  pinenote/systems/pinenote-slim.scm
```

Before any kernel build or boot-bundle work, inspect the selected PineNote
kernel source checkout. This does not build the kernel or prove hardware boot:

```sh
pinenote/scripts/preflight/inspect-kernel-source.sh /path/to/linux
```

The eventual first image target should be a label-based ext4 root filesystem
with root label `PNGuixRoot`, intended for a manually selected experimental OS
slot after the exact device edition and partition labels are confirmed.

For the full non-destructive validation ladder, including boot-bundle inspection
and mock helper checks, see `doc/pinenote-preflight.md`.

## Safety Notes

This repository intentionally contains no hardware deployment automation. It
does not create whole-device images, modify partition layouts, alter persistent
boot selection, or bundle private waveform or firmware blobs.

The waveform support follows the PNDeb behavior conceptually: first boot reads
from `/dev/disk/by-partlabel/waveform` and installs the data at
`/lib/firmware/rockchip/ebc.wbf` for `rockchip_ebc`. If that source is absent,
the helper may use `/state/firmware/ebc.wbf`. The destination is fixed and not
caller-overridable. If neither source exists, it fails visibly and does not try
to drive the panel.

The `rockchip_ebc` modprobe options are installed into the operating system by
`pinenote-ebc-modprobe-service-type`, which populates
`/etc/modprobe.d/rockchip_ebc.conf`. The copy in `pinenote-firmware-support` is
kept as package documentation; package inclusion alone is not treated as `/etc`
configuration. The parameter application service also fails visibly if the
kernel has not exposed `/sys/module/rockchip_ebc/parameters`.

## Confirmed References

- PNDeb `pinenote-debian-image` uses a debos pipeline and extracts waveform
  data from `/dev/disk/by-partlabel/waveform` into the firmware path used by
  `rockchip_ebc`.
- PNDeb `rockchip_ebc` options used here are `direct_mode=0`,
  `auto_refresh=1`, `refresh_threshold=60`, `split_area_limit=0`,
  `panel_reflection=1`, `prepare_prev_before_a2=0`, and `dclk_select=0`.
- PNDeb extlinux references `/extlinux/Image`,
  `/extlinux/rk3566-pinenote-v1.2.dtb`, `/extlinux/uInitrd.img`, and kernel
  arguments `ignore_loglevel rw rootwait earlycon console=tty0
  console=ttyS2,1500000n8 fw_devlink=off`.
- Pine64 documentation identifies `https://github.com/m-weigand/linux` branch
  `branch_pinenote_6-6-30`, `pinenote_defconfig`, uncompressed
  `arch/arm64/boot/Image`, and `rk3566-pinenote-v1.2.dtb` as the stable kernel
  reference shape.

## Non-Goals

- No Wayland, wlroots, browser, MuPDF, Waydroid, or full reader shell yet.
- No system D-Bus requirement in slim or networked bring-up flavors; add it
  later only for concrete desktop, mobile, or PineNote control services.
- No on-device package management in release-slot flavors.
- No private waveform blobs or redistributed firmware dumps.
- No full-device image or persistent boot-selection workflow until hardware
  edition, partition labels, rescue path, and target slot are confirmed.
