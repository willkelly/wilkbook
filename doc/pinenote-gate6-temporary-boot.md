# PineNote Gate 6 Temporary Boot Prep

This document is the host-side preparation worksheet for Gate 6. It does not
authorize writing to `os2`, changing U-Boot environment variables, flashing,
repartitioning, or changing persistent boot selection.

## Status

Safe host-side preparation completed:

- Built the current slim PineNote Guix system.
- Built the current `raw-with-offset` image artifact.
- Staged a boot bundle under `/tmp/opencode`.
- Ran static boot-bundle inspection successfully.
- Recorded artifact paths, target sizes, and checksums in a manifest under
  `/tmp/opencode`.
- Captured read-only U-Boot/device-tree model information in the 2026-05-10
  backup supplement.

No PineNote storage, U-Boot environment, partition table, firmware path, or OS
slot was modified.

## Prepared host-side artifacts

Current artifact manifest:

```text
/tmp/opencode/pinenote-gate6-artifacts-20260510-113923-targets.txt
```

Current realized Guix system:

```text
/gnu/store/rv01lmlk6ksy2z3464xq3smg7dbghqiz-system
```

Current staged boot bundle:

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

The generated `extlinux.conf` is for static inspection only:

```text
# Generated for static preflight only; do not install automatically.
LABEL pinenote-guix-preflight
  MENU LABEL Guix PineNote slim preflight
  LINUX Image
  FDT rk3566-pinenote-v1.2.dtb
  INITRD initrd.cpio.gz
  APPEND ignore_loglevel rw rootwait earlycon console=tty0 console=ttyS2,1500000n8 fw_devlink=off root=LABEL=PNGuixRoot
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

## Open decision: root filesystem source

The current safe prep has boot artifacts, but not an approved root filesystem
placement method.

Options to evaluate next:

1. Removable or network-accessible root filesystem, if U-Boot can load it
   without persistent environment changes.
2. A purpose-built partition image for `os2`, after explicit write approval.
3. A different Guix image type that produces a direct ext4 root filesystem
   artifact rather than an MBR disk image.

Until this decision is made, Gate 6 remains prepared but not executable.

## Safe commands to refresh host-side artifacts

These commands run on the host and write only to the local Guix store and
`/tmp/opencode`; they do not write to the PineNote:

```sh
system=$(guix system build -L . --target=aarch64-linux-gnu \
  pinenote/systems/pinenote-slim.scm)

guix system image -t raw-with-offset -L . --target=aarch64-linux-gnu \
  pinenote/systems/pinenote-slim.scm

bundle=/tmp/opencode/pinenote-gate6-boot-bundle-slim.$$
pinenote/scripts/preflight/stage-boot-bundle.sh "$system" "$bundle"
pinenote/scripts/preflight/inspect-boot-bundle.sh "$bundle"
```

Do not add device-write commands to this document without a separate explicit
approval step.
