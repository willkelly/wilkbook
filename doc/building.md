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

## QEMU with the real PineNote artifacts

The PineNote kernels build with QEMU `virt` support (virtio disk/net and a
PL011 console are built in; see `%pinenote-qemu-virt-config-lines` in
`pinenote/packages/kernel.scm`), so the exact kernel, initrd, and rootfs
that would be written to the device can be booted off-device:

```sh
make qemu-virt ROOTFS=/tmp/opencode/pinenote-rootfs-artifacts/<artifact>.ext4 \
     [WAVEFORM=/path/to/local/waveform.bin]
```

This stages a boot bundle from the rootfs, builds a synthetic GPT disk that
mimics the PineNote layout (a 2 MiB partition GPT-named `waveform`, the
rootfs in a partition named `os2`), and boots QEMU with the bundle's exact
Guix boot arguments, only steering the console from `ttyS2` to `ttyAMA0`.

What it tests for real: the hardware kernel image boots with `PREEMPT_RT`,
the initrd finds the waveform partition by PARTNAME and installs `ebc.wbf`,
loads the EBC display modules, sees `PNGuixRoot` before the root switch,
root mounts by that label, and Shepherd brings up its base services. That
is the config/initrd/root-mount regression class — exactly how the
`VIRTIO_MENU` olddefconfig drop (which made virtio-blk vanish so root never
appeared) is caught.

What it does *not* reach: the virt boot deadlocks entering the `udev`
service — an idle-CPU hang confirmed 2026-07-04 (see `doc/status.md`) — so
the post-udev one-shot services (`pinenote-waveform`, the ACM gadget,
`pinenote-ebc-params`) never run here. The waveform/udev-ordering and
gadget-modprobe regressions therefore stay guarded by the host tools and
hardware until that hang is fixed. And nothing RK3566-specific — EBC
rendering, the dwc3 gadget, Wi-Fi/BT firmware — can be tested on virt at
all. `WAVEFORM` may point at a local waveform backup; it is never bundled
or committed.

`make qemu-virt-check` (offline ladder rung 4) wraps this boot into a
non-interactive gate. It captures the console, terminates QEMU once the log
goes quiescent (the udev deadlock, or a future healthy idle point), then
asserts the milestones above are present and a set of regression signatures
(waveform-not-found, PNGuixRoot-not-visible, kernel panic, RT
sleeping-in-atomic) are absent. It exits non-zero on any failed assertion
and finishes in well under a minute:

```sh
make qemu-virt-check ROOTFS=/tmp/opencode/pinenote-rootfs-artifacts/<artifact>.ext4 \
     [WAVEFORM=/path/to/local/waveform.bin]
```

Two software stand-ins are built into the image as modules for a future
rung that can exercise the gadget and render plumbing off-device:

```sh
modprobe dummy_hcd   # fake UDC: exercise the configfs/ACM gadget stack
modprobe vkms        # virtual DRM device: exercise render plumbing
```

`dummy_hcd` is a fake UDC for the configfs/ACM plumbing (libcomposite,
u_serial, usb_f_acm, ttyGS0); `vkms` gives DRM userspace a real connector.
Neither is reachable through a normal virt boot today: it has no interactive
console (the getty is on `ttyS2`, absent on virt; the reader shell is on the
`ttyGS0` gadget, also absent) and it deadlocks at udev before that point
anyway. So the note that the v3 gadget service "declines by design" on virt
is aspirational — that service lives past the udev hang and never runs here.
Neither module models EBC semantics; rendering policy (Y4 quantization,
waveform selection) lives in the host-side tools under `pinenote/tools/`,
and a QEMU device model for the EBC register block is a possible future rung
(see `ROADMAP.md`). (The dwc3 `ep0out` regression itself was never
reproducible here — dummy_hcd bypasses dwc3 — and was fixed on hardware
2026-07-04 via `snps,dis_u3_susphy_quirk`.)

## Validation ladder

Run before any hardware deployment, stopping at the first failure. The
reasoning behind this ordering — and the host tools in rung 0 — is in
`doc/testing.md`.

0. Host tool suites (offline, no VM):
   `make wbf-check ebc-logic-check rastersim-check WBF=/path/to/ebc.wbf`.
   These compile the verbatim EBC driver/waveform sources and catch
   driver-logic and waveform regressions; run them whenever you touch the
   forward-port patch.
1. Static Guix build of the scaffold packages (commands above).
2. QEMU `virt` smoke run for generic ARM64 userspace; `make qemu-virt` for
   an interactive boot of the real kernel/initrd/rootfs on a synthetic disk;
   and `make qemu-virt-check` for the non-interactive assertion gate over
   the same boot (kernel+RT, initrd waveform install, EBC module load,
   PNGuixRoot pre-root visibility, root mount — through Shepherd start).
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
