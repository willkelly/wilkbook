# PineNote reader EBC barrier artifact — 2026-07-27

This manifest binds the current EBC generation-barrier and dormant coordinator
work to the exact `PNGuixRoot` artifact written to os2. The offline and guarded
write sections are not hardware evidence. The final section separately records
read-only first-boot compatibility, display-stack presence, and fail-closed
boundary evidence; it is not evidence for barrier execution, suspend, wake,
resume, firmware/PM behavior, display repair, or power savings.

## Source and build identities

- EBC forward-port patch SHA-256:
  `20a53fa3893b14d39a17f98bdfb4b5c9c942e4ebd002c5e74abd800ff63764b3`
- Dormant BSP PM patch SHA-256:
  `2ea3a96ceb07626499bb9bfa507c548011e1c4ff5c540a2349c8fc131c2c4b45`
- Dormant Lua capability/coordinator SHA-256:
  `e2f24522280fce8a941ad69bd726f554bf46e4a4d5b15daab20ea1c9f363650b` /
  `7af45927c7709b7d04e5b5293f62394a04f15f75e2648685c9d599f08b1bf4eb`
- Production `suspend_policy.lua` remains exactly disabled, SHA-256
  `25712167ce722b4ee26628e97f0cb8f344b8449288a27bf9a131a9f59f5183b7`.
- Production `device.lua` remains without the dormant PM imports, SHA-256
  `7f9f638e101a2cb32598d3b0f625f055048d62a1da390852d5dcc40ea59c35fb`.
- Kernel: `/gnu/store/9xw01l7vbjlzmjf7jqb5hq6w681dyv0m-linux-pinenote-7.0.11-pinenote`.
- Direct reader build: `/gnu/store/npbbqv9hjy71i032f6zbqysmpyxaqkxc-system`.
- System embedded in the image:
  `/gnu/store/27sd3c4537cqpfmqa2ik7gjghqqcp9n8-system`.

## Deployment artifact

- Rootfs:
  `/tmp/opencode/pinenote-rootfs-artifacts-ebc-barrier-20260727/pinenote-reader-PNGuixRoot-20260727.ext4`
- Bytes: 1,945,313,280
- Logical 512-byte sectors: 3,799,440
- SHA-256: `c15d023159e130633db87a0df742248ef5be2ac6e9aece9d4fc83f73c59cfd4d`
- Format: raw ext4, label `PNGuixRoot`, no partition table
- Matched bundle:
  `/tmp/opencode/pinenote-reader-boot-bundle-ebc-barrier-20260727`

| Bundle file | Bytes | SHA-256 |
| --- | ---: | --- |
| `extlinux/Image` | 20,406,784 | `1302cd62d0063c59d5914f21e9a8881eafe836c20d1eaa5c105ace38d2f611f3` |
| `extlinux/rk3566-pinenote-v1.2.dtb` | 62,107 | `9d981579a2bafd56b2c56c215c88b01a6ec2670dafc5d97a7dd949b66e229bf2` |
| `extlinux/initrd.cpio.gz` | 12,845,291 | `94f12a873fada28844e6b4af50a42a5b1567826f681938a6a3a18173b75a49a3` |
| `extlinux/extlinux.conf` | 574 | `8a6189d3daec3c26e3c9547ee326dadb7caf98efe0f39911d868629d08930206` |

Rootfs and bundle inspectors passed. The bundle uses `root=PNGuixRoot`, explicit
Image/DTB/initrd paths, and no raw root-device path.

## Validation

- The host suites passed for WBF, EBC logic (primary and debug ASan),
  rastersim, power coordinator, Rockchip PM, and synthetic positive activation
  with the production hard-off gate rerun.
- Primary/debug kernels and the reader system built successfully after the
  worker lost-wakeup remediation.
- Exact-artifact QEMU rung 4 passed every kernel/initrd/root/service sentinel
  and powered off cleanly:
  `/tmp/opencode/pinenote-virt-assert-3220998.log`.
- Exact-artifact visual rung 4v bound virtio-gpu, painted a non-uniform
  1872x1404 KOReader frame, and changed it after a scripted tap:
  `/tmp/opencode/pinenote-virt-visual-3222051`.
- Goal, QA, quality, security, and context/documentation reviews passed.

## Guarded os2 write

All four backup manifests (2026-05-08 and 2026-05-10, local and NFS copies)
were rerun and passed. Stock Debian os1 was reached at its new DHCP address
`192.168.86.145`; its archived `.141` SSH host identity was used for host-key
validation. The running root was `/dev/mmcblk0p5`, p6 was unmounted, and p6
capacity was 15,728,640,000 bytes.

The staged file
`/home/user/pinenote-reader-PNGuixRoot-20260727-ebc-barrier.ext4` matched the
host size and SHA-256. Exactly 3,799,440 sectors were written to
`/dev/mmcblk0p6` with `bs=512 count=3799440 iflag=fullblock conv=fsync`.
SHA-256 of an exact `bs=512 count=3799440 iflag=fullblock` p6 readback matched
`c15d023159e130633db87a0df742248ef5be2ac6e9aece9d4fc83f73c59cfd4d`.

The device remained on os1. No reboot, os2 boot, suspend request, persistent
boot-selection change, firmware/SMC/PSCI/regulator/CPU/MMIO action, or write to
any partition other than os2 occurred during the write sequence.

## First boot acceptance

The user then manually selected os2 with UART present. Read-only SSH acceptance
confirmed:

- root `/dev/mmcblk0p6`, embedded system
  `/gnu/store/27sd3c4537cqpfmqa2ik7gjghqqcp9n8-system`, Linux 7.0.11
  PREEMPT_RT, and taint zero;
- live Image, DTB, and initrd hashes equal the matched bundle values above;
- regenerated ED25519 host-key fingerprint
  `SHA256:vOfxe+6eauQjlK6gRjCj9zusG0R2rhkfVmCC5xqcPY0`;
- waveform version `0x19`, EBC fb0 at 1872x1404, connected DPI, and no EBC
  timeout, poison, or uncertain-ownership log signature;
- running KOReader and orientation bridge; finger, pen, and orientation input
  devices; Wi-Fi/DHCP at `192.168.86.145`; and key-only root SSH;
- a policy-free live `/rockchip-suspend` node containing only `compatible`,
  synthesized `name`, and `status`, bound with `DORMANT policy core bound;
  activation compiled out`;
- live packaged `suspend_policy.lua` and `device.lua` hashes matching the hard-off
  values above, with no dormant capability/coordinator import; and
- no fatal kernel or reader signature and no EBC timeout/poison signature.

This is boot compatibility and fail-closed boundary evidence. It does not
exercise the generation barrier because production has no UAPI caller, and it
does not prove suspend, wake, resume, firmware compatibility, regulator/CPU
behavior, sleep-frame painting, EBC repair, or suspend energy. No suspend or PM
backend action was requested.
