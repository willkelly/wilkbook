# PineNote Build-Only Workflow

This scaffold is for Guix evaluation and artifact construction only. It does
not provide hardware deployment automation, storage layout mutation, or
persistent boot selection changes.

## Commands

Evaluate the channel modules:

```sh
guix repl -L . -- /dev/stdin < /tmp/check-pinenote-modules.scm
```

Build the placeholder user-space packages for the PineNote target:

```sh
guix build -L . pinenote-ebc-test --target=aarch64-linux-gnu
guix build -L . pinenote-diagnostics --target=aarch64-linux-gnu
guix build -L . pinenote-firmware-support --target=aarch64-linux-gnu
```

Compute the generic ARM64 QEMU smoke VM and image derivations when you need a
preflight that avoids PineNote kernel, DTB, waveform, and EBC service
assumptions:

```sh
guix system vm -d -L . --target=aarch64-linux-gnu \
  pinenote/systems/qemu-aarch64-smoke.scm
guix system image -d -t qcow2-gpt -L . --target=aarch64-linux-gnu \
  pinenote/systems/qemu-aarch64-smoke.scm
```

The VM run itself is optional. `qemu-system-aarch64` is available through an
ephemeral Guix shell, not on the plain host `PATH`:

```sh
guix shell qemu -- qemu-system-aarch64 --version
```

Validation returned `QEMU emulator version 10.2.1` through that shell. The
generic ARM64 VM launcher has also reached the `pinenote-qemu-smoke login:`
prompt under QEMU `virt`. This proves only generic ARM64 userspace startup, not
PineNote hardware behavior. The optional `qcow2-gpt` image path currently fails
while copying `boot/extlinux/libgpl.c32`; use the VM launcher path as the
validated QEMU gate.

The `linux-pinenote` package is pinned and configured to use the in-tree
`pinenote_defconfig`. Start with derivation computation before full realization;
see `doc/pinenote-flavors.md` for the flavor matrix and current sizes:

```sh
guix build -d -L . linux-pinenote --target=aarch64-linux-gnu
guix system build -d -L . --target=aarch64-linux-gnu \
  pinenote/systems/pinenote-slim.scm
```

Before any kernel package build, inspect the selected PineNote kernel source
checkout. This only checks source identity and expected PineNote support markers;
it does not build the kernel or prove hardware boot:

```sh
pinenote/scripts/preflight/inspect-kernel-source.sh /path/to/linux
```

The image module currently aliases Guix's generic raw image type only as a
placeholder. PineNote systems use an Extlinux configuration generator with
bootloader installers disabled, so image construction can install
`/boot/extlinux/extlinux.conf` without copying Syslinux `.c32` modules or
writing an MBR into the rootfs artifact. Keep the first real artifact as a root
filesystem labelled `PNGuixRoot` for a manually selected experimental OS slot.
Do not turn this scaffold into a whole-device image until the exact PineNote
edition, partition labels, and rescue path have been confirmed on the target
device.

Validation has built the slim `raw-with-offset` artifact successfully. It is an
MBR disk image with one active Linux partition, not proof of PineNote hardware
boot and not a full-device image to write over eMMC.

## First-Boot Logic

The Shepherd services are one-shot bring-up hooks:

- `pinenote-waveform` copies a waveform from `/dev/disk/by-partlabel/waveform`
  or `/state/firmware/ebc.wbf` to the fixed destination
  `/lib/firmware/rockchip/ebc.wbf`, and fails if neither source exists.
- `pinenote-ebc-modprobe` installs `/etc/modprobe.d/rockchip_ebc.conf` with the
  PNDeb-derived module options.
- `pinenote-ebc-params` applies the PNDeb-derived `rockchip_ebc` parameter
  values when sysfs exposes those parameters, and fails if the parameter
  directory is absent.
- `pinenote-diagnostics` records read-only boot diagnostics.
- `pinenote-ebc-test` runs a read-only placeholder test once.

The waveform is never bundled in this repository.

## Preflight Checks

See `doc/pinenote-preflight.md` for the non-destructive validation ladder,
including these safe host-side helpers:

```sh
pinenote/scripts/preflight/inspect-kernel-source.sh /path/to/linux
system=$(guix system build -L . --target=aarch64-linux-gnu \
  pinenote/systems/pinenote-slim.scm)
bundle=/tmp/opencode/pinenote-boot-bundle-slim.$$
pinenote/scripts/preflight/stage-boot-bundle.sh "$system" "$bundle"
pinenote/scripts/preflight/inspect-boot-bundle.sh "$bundle"
pinenote/scripts/preflight/mock-pinenote-services.sh
```

The QEMU smoke path uses QEMU `virt` only as a generic ARM64 userspace check. It
does not emulate PineNote, RK3566, EBC, waveform hardware, U-Boot SPL, eMMC
layout, or panel rendering.
