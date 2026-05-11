# PineNote Gate 6 Temporary Boot Prep

This document is the host-side preparation worksheet for Gate 6. It does not
authorize writing to `os2`, changing U-Boot environment variables, flashing,
repartitioning, or changing persistent boot selection.

## Status

Safe host-side preparation completed:

- Built the current slim PineNote Guix system.
- Built the current `raw-with-offset` image artifact.
- Extracted a direct ext4 root filesystem artifact from the single partition in
  that raw image.
- Staged a boot bundle under `/tmp/opencode`.
- Ran static boot-bundle inspection successfully.
- Ran static rootfs-image inspection successfully.
- Recorded artifact paths, target sizes, and checksums in a manifest under
  `/tmp/opencode`.
- Captured read-only U-Boot/device-tree model information in the 2026-05-10
  backup supplement.
- After explicit operator approval, wrote the validated slim `PNGuixRoot` rootfs
  to inactive `os2` (`/dev/mmcblk0p6`) and verified the written byte range.
- Stopped before reboot because the slim image has no confirmed USB-C console,
  Wi-Fi credentials, SSH path, or keyboard path.
- After separate explicit operator approval, replaced inactive `os2` with the
  validated `usb-console` `PNGuixRoot` rootfs and verified the written byte
  range plus embedded USB console service references.

No PineNote U-Boot environment, partition table, waveform, firmware path, `os1`,
or `data` partition was modified. `os2` currently contains the verified
`usb-console` `PNGuixRoot` rootfs. Reboot has not been attempted.

## Prepared host-side artifacts

Current artifact manifest:

```text
/tmp/opencode/pinenote-gate6-artifacts-20260510-113923-targets.txt
```

Current realized Guix system:

```text
/gnu/store/rv01lmlk6ksy2z3464xq3smg7dbghqiz-system
```

Initial staged boot bundle from `guix system build`:

```text
/tmp/opencode/pinenote-gate6-boot-bundle-slim-20260510-113844
```

Bundle contents resolve to:

| Artifact | Target | Size | SHA-256 |
| --- | --- | ---: | --- |
| `Image` | `/gnu/store/43g0m3k4gi9fcfnlbgi041z0fb3vic78-linux-pinenote-6.6.30-pinenote/Image` | 19,491,328 bytes | `6991061f6c5b387df6aa4ed9f46e3fc626e50b4b8cffb07784b21d24797e33ad` |
| `rk3566-pinenote-v1.2.dtb` | `/gnu/store/43g0m3k4gi9fcfnlbgi041z0fb3vic78-linux-pinenote-6.6.30-pinenote/lib/dtbs/rockchip/rk3566-pinenote-v1.2.dtb` | 61,094 bytes | `4f99379db3be1a4d6dc1b328bead01c1c5a0774d3625640f9260dd73df32d8c0` |
| `initrd.cpio.gz` | `/gnu/store/9ia1byzd0a93r42xm45ip5ccpbjhaj85-raw-initrd/initrd.cpio.gz` | 12,253,630 bytes | `e5069b0d374f556d8713ee639a84d3f0739a8f8c49a77fe43f680cef1b49d524` |
| `extlinux.conf` | staged file | 330 bytes | `f28255d7c65f194c92432b3398edb3d7ff6f8131ba4d8cc52450e6aa9ff1cb95` |

This initial bundle remains useful for static artifact inspection, but it is not
the preferred boot bundle for the extracted rootfs artifact because the extracted
rootfs comes from `guix system image` and has different `gnu.system` and initrd
store paths.

Current rootfs-matched boot bundle:

```text
/tmp/opencode/pinenote-gate6-rootfs-boot-bundle-slim-20260510
```

Rootfs-matched bundle contents:

| Artifact | Size | SHA-256 |
| --- | ---: | --- |
| `Image` | 19,491,328 bytes | `6991061f6c5b387df6aa4ed9f46e3fc626e50b4b8cffb07784b21d24797e33ad` |
| `rk3566-pinenote-v1.2.dtb` | 61,094 bytes | `4f99379db3be1a4d6dc1b328bead01c1c5a0774d3625640f9260dd73df32d8c0` |
| `initrd.cpio.gz` | 12,256,926 bytes | `2be3a56cc41456cdc87b0c8a46073119804fdbf96ca39392cf4f4b1d10c51d67` |
| `extlinux.conf` | 546 bytes | `bb53b497f405387b65f284e2df69dee7c7ae1e29e10ec069b133d1f8b90b22e4` |

The rootfs-matched `extlinux.conf` is for static inspection and temporary boot
planning only:

```text
# Generated from a validated PNGuixRoot rootfs image for static preflight only.
# Do not install automatically and do not persist U-Boot environment changes.
LABEL pinenote-guix-preflight
  MENU LABEL Guix PineNote slim preflight
  LINUX Image
  FDT rk3566-pinenote-v1.2.dtb
  INITRD initrd.cpio.gz
  APPEND root=LABEL=PNGuixRoot gnu.system=/gnu/store/vfpialj7b776qnfc401sqn5lb723f9pb-system gnu.load=/gnu/store/vfpialj7b776qnfc401sqn5lb723f9pb-system/boot ignore_loglevel rw rootwait earlycon console=tty0 console=ttyS2,1500000n8 fw_devlink=off
```

Current `raw-with-offset` image artifact:

```text
/gnu/store/2q99vvdyshpjs2qmw80jxlgjppda0fs3-disk-image
```

It is a 1,138,810,880-byte MBR disk image with one Linux partition starting at
sector 2048. Its SHA-256 is:

```text
91b7b6028b90b40a4b493f4b387c3fa1e7b16c7d6cabcb22b9d6a0c8de1d037e
```

Do not write this raw image to PineNote eMMC as a full-device image.

Current direct rootfs artifact extracted from that image:

```text
/tmp/opencode/pinenote-rootfs-artifacts/pinenote-slim-PNGuixRoot-20260510.ext4
```

It is a 1,137,762,304-byte ext4 filesystem image with no partition table,
filesystem label `PNGuixRoot`, and embedded `/boot/extlinux/extlinux.conf` using
`root=LABEL=PNGuixRoot`. Its SHA-256 is:

```text
26c1645ce3ccb3f87bc3a09db137c30217c026bbecf45bb70d874f6e4b6e11b1
```

The artifact was produced host-side with:

```sh
pinenote/scripts/preflight/extract-rootfs-from-raw.sh \
  /gnu/store/2q99vvdyshpjs2qmw80jxlgjppda0fs3-disk-image \
  /tmp/opencode/pinenote-rootfs-artifacts/pinenote-slim-PNGuixRoot-20260510.ext4
```

It was validated host-side with:

```sh
pinenote/scripts/preflight/inspect-rootfs-image.sh \
  /tmp/opencode/pinenote-rootfs-artifacts/pinenote-slim-PNGuixRoot-20260510.ext4
```

This slim artifact was written to `os2` after explicit approval, verified, then
replaced by the USB-console artifact below before any reboot attempt.

Current `os2` state after approved write:

| Check | Result |
| --- | --- |
| Target | `/dev/mmcblk0p6`, partition label `os2` |
| Written byte-range SHA-256 | `6164ed64e68f5ae1f979514de36f63cab451402405edf6e938e861e669e71f1f` |
| Filesystem | ext4, label `PNGuixRoot` |
| Embedded boot config | `/boot/extlinux/extlinux.conf` uses `root=LABEL=PNGuixRoot` |
| USB console services | `pinenote-usb-acm-gadget` and `term-ttyGS0` service files present |
| Passwordless sudo | `reader ALL=(ALL) NOPASSWD: ALL` present in sudoers |
| Rescue root | stock Debian `os1` remains mounted at `/` from `/dev/mmcblk0p5` |
| Reboot status | not attempted |

USB-C-accessible artifact previously installed on `os2`, then replaced before
reboot with the passwordless-sudo artifact below:

```text
/tmp/opencode/pinenote-rootfs-artifacts/pinenote-usb-console-PNGuixRoot-20260510.ext4
```

It is a 1,137,963,008-byte ext4 filesystem image with label `PNGuixRoot`, no
partition table, and embedded `root=LABEL=PNGuixRoot`. Its SHA-256 is:

```text
9b447db116771b703e999c2bd8f688b20a0e3a4380e5a8abb58ca0eac02fe84c
```

The `usb-console` flavor adds a temporary USB CDC-ACM gadget and an auto-login
`reader` getty on `ttyGS0`. It was later rebuilt with passwordless `sudo` for
`reader` so the USB-C console can perform rescue commands without a password.
If the kernel and Shepherd reach that service, the host should see a new
`/dev/ttyACM*` device over the existing USB-C cable.

Passwordless-sudo artifact now installed on `os2`:

```text
/tmp/opencode/pinenote-rootfs-artifacts/pinenote-usb-console-sudo-PNGuixRoot-20260510.ext4
```

It is a 1,137,963,008-byte ext4 filesystem image with label `PNGuixRoot`, no
partition table, embedded `root=LABEL=PNGuixRoot`, and sudoers content:

```text
reader ALL=(ALL) NOPASSWD: ALL
```

Its SHA-256 is:

```text
6164ed64e68f5ae1f979514de36f63cab451402405edf6e938e861e669e71f1f
```

This passwordless-sudo artifact was written to `os2` after separate explicit
approval and verified by reading back the written byte range. Rebooting into OS2
requires a separate explicit approval.

Current USB-C-only finding: the host-connected USB-C cable does not expose a
U-Boot console or CDC-ACM device. U-Boot has fastboot, rockusb, UMS, and USB boot
strings, but those are not a read-only console. Without UART, the first Guix
boot path used stock Debian as the control plane and wrote only inactive `os2`
after explicit approval.

## Current hardware facts relevant to Gate 6

Read-only inventory confirms:

- Model: `Pine64 PineNote v1.2`
- Compatible strings: `pine64,pinenote-v1.2 pine64,pinenote rockchip,rk3566`
- Stock Debian rescue path: `os1` on `/dev/mmcblk0p5`, reachable over SSH at
  `user@192.168.86.141`
- Candidate experimental slot: `os2` on `/dev/mmcblk0p6`, currently unmounted
- Current U-Boot environment printout via `fw_printenv` failed with
  `Cannot initialize environment`; raw `uboot_env_p3.img` is backed up, but the
  text environment is not currently decoded.

## Stop points before any hardware action

Stop before typing any U-Boot command or preparing `os2` unless all of these are
true:

- `doc/pinenote-gate6-runbook.md` backup checklist is still satisfied.
- The 2026-05-08 and 2026-05-10 local and NFS backup sets still verify.
- We have a confirmed way to reach U-Boot interactively and record output.
- We have a confirmed way to power-cycle back to stock Debian `os1`.
- We have chosen a boot source that does not require persistent U-Boot env
  changes.
- The operator explicitly approves any write to eMMC or `os2`.
- `doc/pinenote-gate6-serial-uboot.md` has been reviewed against the actual
  serial/U-Boot discovery output.

## Root filesystem source decision

The current safe prep now has boot artifacts and a direct ext4 root filesystem
artifact labelled `PNGuixRoot`.

The remaining open decision is placement and boot source, not rootfs artifact
format. Options to evaluate next:

1. Removable or network-accessible root filesystem, if U-Boot can load it
   without persistent environment changes.
2. Manual placement of the validated direct ext4 rootfs artifact into `os2`,
   after explicit write approval.

Until placement and temporary boot commands are approved, Gate 6 remains
prepared but not executable.

## Safe commands to refresh host-side artifacts

These commands run on the host and write only to the local Guix store and
`/tmp/opencode`; they do not write to the PineNote:

```sh
system=$(guix system build -L . --target=aarch64-linux-gnu \
  pinenote/systems/pinenote-slim.scm)

guix system image -t raw-with-offset -L . --target=aarch64-linux-gnu \
  pinenote/systems/pinenote-slim.scm

mkdir -p /tmp/opencode/pinenote-rootfs-artifacts
rootfs=/tmp/opencode/pinenote-rootfs-artifacts/pinenote-slim-PNGuixRoot-$(date +%Y%m%d).ext4
pinenote/scripts/preflight/extract-rootfs-from-raw.sh \
  /gnu/store/2q99vvdyshpjs2qmw80jxlgjppda0fs3-disk-image \
  "$rootfs"

pinenote/scripts/preflight/inspect-rootfs-image.sh "$rootfs"

rootfs_bundle=/tmp/opencode/pinenote-gate6-rootfs-boot-bundle-slim-$(date +%Y%m%d)
pinenote/scripts/preflight/stage-boot-bundle-from-rootfs.sh \
  "$rootfs" "$rootfs_bundle"
pinenote/scripts/preflight/inspect-boot-bundle.sh "$rootfs_bundle"

bundle=/tmp/opencode/pinenote-gate6-boot-bundle-slim.$$
pinenote/scripts/preflight/stage-boot-bundle.sh "$system" "$bundle"
pinenote/scripts/preflight/inspect-boot-bundle.sh "$bundle"
```

Do not add device-write commands to this document without a separate explicit
approval step.
