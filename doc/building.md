# Building PineNote images

All commands run from the repository root on the x86_64 build host. Everything
here writes only to the Guix store and `/tmp/opencode`; deploying artifacts to
the device is covered separately in `doc/hardware-deploy.md`.

The `Makefile` wraps the common invocations; the raw commands are recorded
below for when a wrapper is not enough.

## System flavors

See `doc/pinenote-flavors.md` for the flavor matrix. Build a system closure:

```sh
guix system build -L . --target=aarch64-linux-gnu \
  pinenote/systems/pinenote-usb-console-linux-6-6.scm
```

Build the deployable disk image (an MBR image with a single ext4 partition;
the rootfs gets extracted from it before deployment, see below):

```sh
guix system image -t raw-with-offset -L . --target=aarch64-linux-gnu \
  pinenote/systems/pinenote-usb-console-linux-6-6.scm
```

Substitute any other flavor entrypoint from `pinenote/systems/`. The
`usb-console-linux-6-6` flavor is the hardware-validated baseline; the
`usb-console` flavor carries the current forward-ported kernel
(see `doc/status.md` for what works on each).

## Packages

```sh
guix build -L . pinenote-ebc-test --target=aarch64-linux-gnu
guix build -L . pinenote-diagnostics --target=aarch64-linux-gnu
guix build -L . pinenote-firmware-support --target=aarch64-linux-gnu
guix build -L . pinenote-broadcom-wifi-firmware --target=aarch64-linux-gnu
guix build -L . pinenote-broadcom-bt-firmware --target=aarch64-linux-gnu
```

Compute the kernel derivation before committing to a full kernel build:

```sh
guix build -d -L . -e '(@ (pinenote packages kernel) linux-pinenote)' \
  --target=aarch64-linux-gnu
```

Kernel packaging and the forward-port workflow are described in
`doc/kernel-forward-port.md`.

## Rootfs extraction and boot bundles

The raw image is a build intermediate, never written to the device whole.
Extract the single ext4 partition into a direct rootfs artifact labelled
`PNGuixRoot`, validate it, and stage a matched boot bundle from it:

```sh
mkdir -p /tmp/opencode/pinenote-rootfs-artifacts
rootfs=/tmp/opencode/pinenote-rootfs-artifacts/pinenote-$(date +%Y%m%d).ext4

pinenote/scripts/preflight/extract-rootfs-from-raw.sh \
  /gnu/store/...-disk-image "$rootfs"
pinenote/scripts/preflight/inspect-rootfs-image.sh "$rootfs"

bundle=/tmp/opencode/pinenote-boot-bundle-$(date +%Y%m%d)
pinenote/scripts/preflight/stage-boot-bundle-from-rootfs.sh "$rootfs" "$bundle"
pinenote/scripts/preflight/inspect-boot-bundle.sh "$bundle"
```

The extraction helper normalizes the embedded `/boot/extlinux/extlinux.conf`
to `root=PNGuixRoot` (Guix initrd label shorthand, not the Linux `LABEL=`
form). The validated rootfs must have no partition table and the `PNGuixRoot`
label. The boot-bundle inspector checks for an uncompressed `Image` (older
PineNote U-Boot may not load `Image.gz`), `rk3566-pinenote-v1.2.dtb`, the
initrd, and a label-based root argument.

## QEMU smoke test

A generic ARM64 QEMU `virt` check that avoids all PineNote kernel, DTB,
waveform, and EBC assumptions. It proves Guix userspace construction only,
not PineNote hardware behavior:

```sh
guix system vm -L . --target=aarch64-linux-gnu \
  pinenote/systems/qemu-aarch64-smoke.scm
guix shell qemu -- /gnu/store/...-run-vm.sh -M virt -cpu max -nographic -no-reboot
```

The VM launcher has reached the `pinenote-qemu-smoke login:` prompt; treat
that as the validated QEMU gate. The `qcow2-gpt` image path fails while
copying Syslinux `.c32` modules and is not used.

## Validation ladder

Run before any hardware deployment, stopping at the first failure:

1. Static Guix build of the scaffold packages (commands above).
2. QEMU `virt` smoke run for generic ARM64 userspace.
3. Kernel source inspection:
   `pinenote/scripts/preflight/inspect-kernel-source.sh /path/to/linux`
   (read-only; checks `pinenote_defconfig`, PineNote DTS/DTSI, `rockchip_ebc`,
   and the EBC/PMIC/Wi-Fi/pen defconfig markers).
4. Boot-bundle inspection (commands above).
5. Mock helper tests: `pinenote/scripts/preflight/mock-pinenote-services.sh`
   (inspects hardware-targeted helpers without executing them; fixtures live
   only under `/tmp/opencode`).
6. Hardware deployment per `doc/hardware-deploy.md`, with the backup
   checklist in `doc/device-runbook.md` satisfied first.

## First-boot service logic

The Shepherd services in the bring-up flavors are one-shot hooks:

- `pinenote-waveform` copies a waveform from
  `/dev/disk/by-partlabel/waveform` or `/state/firmware/ebc.wbf` to
  `/lib/firmware/rockchip/ebc.wbf`, failing visibly if neither exists. The
  initrd performs the same extraction pre-root so `rockchip_ebc` can bind
  early. The waveform is never bundled in this repository: it is per-device
  calibration data.
- `pinenote-ebc-modprobe` installs `/etc/modprobe.d/rockchip_ebc.conf` with
  the PNDeb-derived module options.
- `pinenote-ebc-params` applies the `rockchip_ebc` parameter values once
  sysfs exposes them, failing if the parameter directory is absent.
- `pinenote-diagnostics` records read-only boot diagnostics.
- `pinenote-ebc-test` runs a read-only EBC report; its explicit
  `--draw-smoke` mode performs a reversible framebuffer smoke test manually.
- The usb-console flavors additionally start a CDC-ACM gadget (gated on the
  USB role switch) with an auto-login `reader` shell on `ttyGS0`, plus an
  auto-login getty on UART `ttyS2` at 1500000 baud.
