# PineNote reader BSP PM OF-name fix artifact — 2026-07-26

This manifest binds the offline validation inputs and results to the exact
`PNGuixRoot` artifact that fixes the live Linux OF `name` metadata rejection.
The offline sections are not hardware-binding, firmware-compatibility, suspend,
wake, resume, optics, or power evidence. No device access, os2 write, reboot,
suspend request, or real firmware/SMC/PSCI/regulator/CPU/MMIO action occurred
during those gates. The later deployment and metadata-only dormant-bind evidence
is recorded separately at the end of this manifest.

## Source and inputs

- Kernel source worktree base: `5e2c0c5659cc3909cd7d99b5fb1dab60e0ae6bb2`
- Canonical PM patch:
  `pinenote/patches/linux-pinenote-7.0-bsp-sip-probe.patch`
  - bytes: 53,650
  - SHA-256: `2ea3a96ceb07626499bb9bfa507c548011e1c4ff5c540a2349c8fc131c2c4b45`
- Validation-source-set digest:
  `b45a2869388ce447e1cb207f4fd9686e52a7d5c9e599dc113453d84c45314827`
  - algorithm: SHA-256 over 19 sorted relative paths and bytes; each record is
    `u32be(path length) || path || u64be(content length) || content`
  - set: `Makefile`, `pinenote/packages/kernel.scm`, the canonical PM patch,
    non-build files under `pinenote/tools/rockchip-pm/`, and the five PM/source
    suspend preflight scripts
- Device waveform input (never bundled):
  `/home/wkelly/pinenote-backup/2026-07-04-wbf-pull/ebc.wbf`
  - bytes: 2,097,152
  - SHA-256: `ba3d48837efc60353973f867ab15b4fa7dfbec755f6105c6d3e7e8b649c08f3b`

The kernel parser now uses one predicate for standard OF metadata and accepts
exactly `compatible`, `name`, and `status`. Dormant mode still rejects every
policy property and child before model construction. Positive compiled-DTB
coverage accepts both explicit `name = "rockchip-suspend"` and source that omits
`name` before the adapter synthesizes it; adversarial coverage rejects the
lookalike `names` and all policy/unknown properties.

## Guix identities

- Derivation:
  `/gnu/store/bd193vwdddlcr14nw1297b6yhcybjmf6-linux-pinenote-7.0.11-pinenote.drv`
- Kernel:
  `/gnu/store/pk42mcgg1cvxnmjpa028n6x6ddniz1ba-linux-pinenote-7.0.11-pinenote`
- Direct reader build:
  `/gnu/store/p95nmngvvbi5m77p99h0caivnfbbd4yf-system`
- System embedded in the extracted image:
  `/gnu/store/arh9k85n6h7i8mr2w1f29s5v8pz6qpzv-system`
- Packaged KOReader:
  `/gnu/store/4vfdfwz3jjbvw7f6y0kn2kqizni4j5zn-koreader-bin-2026.03`

## Deployment artifact

- Rootfs:
  `/tmp/opencode/pinenote-rootfs-artifacts-bsp-pm-namefix-20260726/pinenote-reader-PNGuixRoot-20260726.ext4`
  - bytes: 1,945,280,512
  - logical 512-byte sectors: 3,799,376
  - SHA-256: `0c67785ff434bac66e3652e940c1d088e2c242cf6dfd132fc66fd8e2b8f97f4f`
  - format: raw ext4, label `PNGuixRoot`, no partition table
- Rootfs-matched bundle:
  `/tmp/opencode/pinenote-reader-boot-bundle-bsp-pm-namefix-20260726`

| Bundle file | Bytes | SHA-256 |
| --- | ---: | --- |
| `extlinux/Image` | 20,406,784 | `7fcb4c88238c0009d5ae6e5e934b6f6182c2b24835aff4b9434fcafd46c5c828` |
| `extlinux/rk3566-pinenote-v1.2.dtb` | 62,107 | `9d981579a2bafd56b2c56c215c88b01a6ec2670dafc5d97a7dd949b66e229bf2` |
| `extlinux/initrd.cpio.gz` | 12,840,522 | `ffa080110c373b16c8f176746f13c25b9572455d2129ee1535f7b03949b31d07` |
| `extlinux/extlinux.conf` | 574 | `5d5a118e6c4efa07fd065dc46aff58b240b14c3333981775995dc6f4dc7b2f56` |

The bundle `Image` and DTB byte-match the named kernel output. The generated
extlinux configuration selects the embedded system above and
`root=PNGuixRoot`.

## Packaged hard-off evidence

| File | SHA-256 |
| --- | --- |
| kernel `.config` | `310958576631a4e0add34afcf931ecfceee1fe43ef7309385448e9409d8d609c` |
| `System.map` | `46b64622ca94071420dcd793c06b454e4c0bdad7b68bbaeeab822635ddde925d` |
| `suspend_policy.lua` | `25712167ce722b4ee26628e97f0cb8f344b8449288a27bf9a131a9f59f5183b7` |
| `device.lua` | `7f9f638e101a2cb32598d3b0f625f055048d62a1da390852d5dcc40ea59c35fb` |

The resolved config enables the production-linked core and omits hidden
activation. `System.map` contains the dormant probe, parser, model, executor,
and backend, with no activation prepare/complete edge. The Lua policy remains
exactly `return false\n`. The compiled DT has one enabled policy-free
`/rockchip-suspend` node, exactly the approved cover/RK817 wake sources, and no
CPU idle-state nodes or references.

## Commands and results

All aggregate commands below exited zero. Negative-fixture `FAIL:` lines from
mutation suites are expected rejection evidence.

1. Complete host rung:
   `make wbf-check ebc-logic-check rastersim-check koreader-input-check orientation-check optics-check power-check rockchip-pm-check suspend-check WBF=/home/wkelly/pinenote-backup/2026-07-04-wbf-pull/ebc.wbf`
2. Canonical patch checks: the full-index patch byte-matched the exact 19-path
   source diff from the pinned base; changed-path inventory and `diff --check`
   passed.
3. Source/config inspection:
   `inspect-kernel-source.sh /tmp/opencode/linux-7.0.11-executor-work /gnu/store/pk42mcgg1cvxnmjpa028n6x6ddniz1ba-linux-pinenote-7.0.11-pinenote/.config`
4. Guix ladder: `make kernel-drv`, `make kernel`, `make packages`, `make reader`,
   and `make rootfs-reader ARTIFACTS=/tmp/opencode/pinenote-rootfs-artifacts-bsp-pm-namefix-20260726`.
5. Rootfs/bundle, packaged battery-DTB, suspend config/DT/Lua, and complete
   mock-helper gates passed. The rootfs bundle Image and DTB byte-match the
   fresh kernel output.
6. QEMU rung 4 passed every required boot/service sentinel and powered off
   cleanly: `/tmp/opencode/pinenote-virt-assert-990116.log`.
7. QEMU rung 4v reached login, bound virtio-gpu, painted a non-uniform
   1872x1404 KOReader frame, and changed it after a scripted tap:
   `/tmp/opencode/pinenote-virt-visual-990174`.

## Deployment, first boot, and remaining boundary

This corrected image was staged on stock os1 at
`/home/user/pinenote-reader-PNGuixRoot-20260726-bsp-pm-namefix.ext4`. With p5
confirmed as the running root, p6 unmounted, and p6 capacity measured as
15,728,640,000 bytes, exactly 3,799,376 sectors were written with
`bs=512 count=3799376 iflag=fullblock conv=fsync`; SHA-256 of the
`bs=512 count=3799376 iflag=fullblock` p6 readback matched
`0c67785ff434bac66e3652e940c1d088e2c242cf6dfd132fc66fd8e2b8f97f4f`.
The two backup-root checksum verifications were not rerun in this deployment
session, so this records the guarded write and exact-range readback sequence and
does not claim that every `doc/hardware-deploy.md` precondition was repeated.

The exact image then booted from os2 with root `/dev/mmcblk0p6`, system
`/gnu/store/arh9k85n6h7i8mr2w1f29s5v8pz6qpzv-system`, Linux 7.0.11 PREEMPT_RT,
and taint zero. The live node contained only `compatible`, synthesized `name`,
and `status`; the sysfs driver link was present and dmesg reported `DORMANT
policy core bound; activation compiled out`. Activation symbols remained absent
and the Lua policy remained `return false`. EBC waveform `0x19`, fb0, KOReader,
orientation, inputs, Wi-Fi, and SSH were healthy. No suspend was attempted.

This proves only a metadata-only activation-hard-off bind and healthy reader
boot. Activation, active DT policy, firmware compatibility, PineNote
suspend-state/resume dependencies, DDR retention, physical wake, regulator
behavior on hardware, EBC repair, and suspend energy remain unproven. Suspend
stays disabled.
