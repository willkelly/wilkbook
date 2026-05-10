# PineNote Preflight Validation

This repository only supports non-destructive preflight checks before any real
PineNote experiment. The checks below increase confidence in Guix evaluation,
generic ARM64 bootability, kernel source selection, boot-bundle shape, and
helper behavior, but they do not prove PineNote hardware correctness.

## What Preflight Can Prove

- Guix modules evaluate and package derivations can be built for AArch64.
- A generic ARM64 Guix operating-system can be constructed for QEMU `virt`.
- The selected PineNote kernel source checkout contains the expected config,
  DT, EBC, PMIC, Wi-Fi, touch, pen, and storage support markers.
- A PineNote boot bundle has the expected static file and kernel argument shape.
- Read-only helper commands can run on a host, and hardware-targeted helpers can
  be inspected without executing writes to real paths.

## What Preflight Cannot Prove

- QEMU `virt` is not a PineNote, RK3566, U-Boot SPL, eMMC layout, EBC,
  waveform, or panel renderer emulator.
- Passing QEMU does not prove that PineNote display, bootloader, storage slot,
  waveform, or `rockchip_ebc` behavior is correct.
- Static bundle inspection does not prove that firmware paths, DTB compatibility,
  or the device boot order are correct on hardware.
- Kernel source inspection does not build the kernel, compute the Guix source
  hash, prove that a DTB was produced, or prove that EBC works on hardware.

## Validation Ladder

1. Static Guix build and module evaluation.
2. QEMU `-M virt` smoke build for generic ARM64 Guix userspace.
3. Kernel source inspection with `inspect-kernel-source.sh`.
4. Boot-bundle inspection with `inspect-boot-bundle.sh`.
5. Mock helper tests with `mock-pinenote-services.sh`.
6. Temporary manual U-Boot hardware boot that changes only the current session.
7. Experimental slot boot only after the earlier gates pass and the rescue path
   has been confirmed.

Stop at the first failure. Do not continue to a later rung to compensate for a
failed earlier gate.

## Gate 1: Static Guix Build

From the repository root, build the current user-space scaffold packages:

```sh
guix build -L . pinenote-ebc-test --target=aarch64-linux-gnu
guix build -L . pinenote-diagnostics --target=aarch64-linux-gnu
guix build -L . pinenote-firmware-support --target=aarch64-linux-gnu
guix build -L . pinenote-extlinux-reference --target=aarch64-linux-gnu
```

Pass gate:

- All commands complete successfully.
- No private waveform or firmware blob is required.

Fail gate:

- Any package fails to evaluate or build.
- The build requires a private local blob.

## Gate 2: QEMU ARM64 Smoke Derivations

Compute the QEMU-friendly VM script derivation:

```sh
guix system vm -d -L . --target=aarch64-linux-gnu \
  pinenote/systems/qemu-aarch64-smoke.scm
```

Compute a QEMU-friendly qcow2 image derivation:

```sh
guix system image -d -t qcow2-gpt -L . --target=aarch64-linux-gnu \
  pinenote/systems/qemu-aarch64-smoke.scm
```

The smoke system uses Guix's generic operating-system defaults rather than the
PineNote kernel, DTB, initrd modules, or EBC services. It includes the PineNote
user-space scaffold packages where they are safe to build, but it does not enable
services that require real waveform storage or EBC sysfs state.

The smoke system uses `extlinux-bootloader` and a single label-based root file
system for Guix VM/image derivation generation. It intentionally avoids a fixed
`/boot/efi` filesystem because that conflicts with VM derivation generation on
this Guix revision.

QEMU itself is available through an ephemeral Guix shell:

```sh
guix shell qemu -- qemu-system-aarch64 --version
```

Validation returned `QEMU emulator version 10.2.1`. The
`qemu-system-aarch64` binary is not on the plain host `PATH` outside that shell,
so run QEMU commands with `guix shell qemu -- ...`.

The validated QEMU gate is the VM launcher path. Build the launcher, then run it
headless on QEMU `virt`, for example:

```sh
guix system vm -L . --target=aarch64-linux-gnu \
  pinenote/systems/qemu-aarch64-smoke.scm
/gnu/store/...-run-vm.sh -M virt -cpu max -nographic -no-reboot
```

The VM launcher has reached the `pinenote-qemu-smoke login:` prompt. Treat that
as evidence that generic ARM64 userspace can start, not as evidence of PineNote
hardware readiness. The optional `qcow2-gpt` image path currently fails while
copying `boot/extlinux/libgpl.c32`; it is not the validated QEMU gate.

Pass gate:

- The VM launcher builds.
- The QEMU `virt` run reaches userspace or an expected login prompt.

Fail gate:

- The VM launcher fails to build.
- The generic ARM64 smoke run fails before userspace for reasons not explained by
  the local QEMU setup.

## Gate 3: Kernel Source Inspection

The `linux-pinenote` package pins the intended source identity to commit
`6bf9085fb0a7c44ca7e6b92eeedfef817bd7d931` from
`https://github.com/m-weigand/linux`, with Guix `base32` hash
`0n1drcm98ljif528sfx9jxyvmc80zg28s47x91pn6dns4d7xlvjd`. It inherits Guix's
Linux package and runs the source tree's `pinenote_defconfig` directly, while
keeping the standard Guix kernel build and install phases.

Prepare a disposable source checkout outside the repository, then inspect it
without building the kernel:

```sh
git clone https://github.com/m-weigand/linux /tmp/opencode/mw-linux
git -C /tmp/opencode/mw-linux fetch origin \
  6bf9085fb0a7c44ca7e6b92eeedfef817bd7d931
git -C /tmp/opencode/mw-linux switch --detach \
  6bf9085fb0a7c44ca7e6b92eeedfef817bd7d931
pinenote/scripts/preflight/inspect-kernel-source.sh /tmp/opencode/mw-linux
```

If a local checkout already exists, first confirm that it is not being used for
unrelated work, then run only the inspector against that path. The inspector is
read-only: it does not run `make`, build a kernel, fetch, checkout, or write to
the source tree.

The inspector checks for:

- `arch/arm64/configs/pinenote_defconfig`.
- `arch/arm64/boot/dts/rockchip/rk3566-pinenote-v1.2.dts`.
- `arch/arm64/boot/dts/rockchip/rk3566-pinenote.dtsi`.
- `drivers/gpu/drm/rockchip/rockchip_ebc.c`.
- PineNote defconfig symbols for EBC, TPS65185, CYTTSP5, BRCMFMAC,
  I2C HID, and Rockchip DesignWare MMC.
- DTS/DTSI markers for PineNote compatibility, the EBC node, TPS65185 PMIC,
  and Wacom HID-over-I2C pen support.
- Git commit identity when the path is a git checkout.

By default, a git checkout fails this gate if `HEAD` is not
`6bf9085fb0a7c44ca7e6b92eeedfef817bd7d931`. For exploratory inspection of a
different commit, make the exception explicit:

```sh
PINENOTE_KERNEL_ALLOW_DIFFERENT_COMMIT=1 \
  pinenote/scripts/preflight/inspect-kernel-source.sh /path/to/linux
```

Pass gate:

- The script exits with status 0.
- The printed commit is the pinned PineNote reference, or a different commit was
  intentionally allowed and documented.

Fail gate:

- Any required source artifact, defconfig symbol, or DTS/DTSI marker is missing.
- A git checkout is at a different commit without the explicit override.

## Gate 4: Boot-Bundle Inspection

Build the slim system, stage a boot-bundle fixture under `/tmp/opencode`, then
inspect that prepared directory without modifying it:

```sh
system=$(guix system build -L . --target=aarch64-linux-gnu \
  pinenote/systems/pinenote-slim.scm)
bundle=/tmp/opencode/pinenote-boot-bundle-slim.$$
pinenote/scripts/preflight/stage-boot-bundle.sh "$system" "$bundle"
pinenote/scripts/preflight/inspect-boot-bundle.sh "$bundle"
```

The staging helper refuses output directories outside `/tmp/opencode`, creates
only a local fixture, and generates an `extlinux.conf` from the Guix system boot
parameters plus `root=LABEL=PNGuixRoot`. The staged directory is for static
inspection; it is not a deployment artifact.

The inspector checks for:

- `Image`, with `Image.gz` alone treated as a failure.
- `rk3566-pinenote*.dtb`.
- `uInitrd.img` or a documented initrd filename.
- `extlinux.conf`.
- `root=LABEL=PNGuixRoot`.
- Absence of a raw eMMC root path in `extlinux.conf`.
- Absence of forbidden deployment-oriented strings in the bundle.

Pass gate:

- The script exits with status 0.
- Warnings are understood and documented before hardware use.

Fail gate:

- Any required file or label-based root argument is missing.
- Any forbidden deployment-oriented string is found.

## Gate 5: Mock Helper Tests

Run the host-level mock checker:

```sh
pinenote/scripts/preflight/mock-pinenote-services.sh
```

Without store paths, the script prints the Guix build commands needed for a full
helper check and exits clearly. After building the packages, pass the store paths
with environment variables:

```sh
PINENOTE_FIRMWARE_SUPPORT=/gnu/store/...-pinenote-firmware-support-0.1.0 \
PINENOTE_DIAGNOSTICS=/gnu/store/...-pinenote-diagnostics-0.1.0 \
PINENOTE_EBC_TEST=/gnu/store/...-pinenote-ebc-test-0.1.0 \
pinenote/scripts/preflight/mock-pinenote-services.sh
```

The mock checker creates fixtures only under `/tmp/opencode` unless another
`/tmp/opencode` subdirectory is supplied. It does not execute helpers that target
real `/lib` or `/sys` paths. It only inspects those helpers and runs read-only
diagnostic helpers on the host.

Pass gate:

- The script exits with status 0.
- Hardware-targeted helpers are inspected but not executed.
- Read-only helpers run and report non-destructive behavior.

Fail gate:

- Required helper paths are missing or not executable.
- A read-only helper fails on the host.
- The EBC test helper no longer reports that it avoids framebuffer, EBC,
  partition, and bootloader writes.

## Gate 6: Temporary Manual U-Boot Hardware Preflight

Only after the earlier gates pass, a hardware preflight may use temporary U-Boot
commands entered interactively for the current boot session. The intent is to
load a kernel, DTB, initrd, and label-based root argument from a removable or
already prepared experimental location, then boot once without changing the
persistent environment.

Safe manual principles:

- Confirm the device edition, serial console, power recovery, and known-good
  rescue path before testing.
- Use label-based root selection: `root=LABEL=PNGuixRoot`.
- Keep all environment edits in RAM for the current session only.
- Do not alter persistent boot selection, partition layout, bootloader storage,
  or device contents during preflight.
- Record exactly what was typed and what the console reported.

Pass gate:

- The temporary boot reaches the expected Guix userspace or fails in a way that
  is clearly unrelated to persistent storage changes.
- The original boot path remains available after a power cycle.

Fail gate:

- The temporary boot requires persistent environment or storage changes.
- The console output suggests an unknown partition layout, missing rescue path,
  or unclear device edition.

## Gate 7: Experimental Slot Only

Use an experimental OS slot only after all previous gates pass. Keep the root
filesystem label as `PNGuixRoot`, keep private blobs out of the repository, and
preserve the known-good rescue path. This repository intentionally does not
provide full-device image generation or persistent deployment automation.
