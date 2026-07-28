# PineNote reader signal-safe dormant EBC adapter artifact — 2026-07-27

This manifest binds the dormant LuaJIT barrier/sleep-frame adapter, supervised
C paint/barrier/restore diagnostic, and atomic signal-wait fix to an exact offline
reader artifact. The offline identities below are distinct from the deployment
record at the end: the image was written to os2 with exact-range verification on
2026-07-28 but has not booted. No suspend, firmware, regulator, CPU, or
power-state action was requested.

## Source and build identities

- `ebc_barrier.lua` SHA-256:
  `653304f7bbcf6c0299833c86f8c5a117b75086b186fe21cbcf0e17582e4237b4`
- `ebc_sleep_frame.lua` SHA-256:
  `49b3215938d0ae551b0317a2bc22b81f71d4e1308e6d73a2a81e3da82d33f9be`
- `power_capabilities.lua` / `power_coordinator.lua` SHA-256:
  `e2f24522280fce8a941ad69bd726f554bf46e4a4d5b15daab20ea1c9f363650b` /
  `f7eab4423ebd6a85749b5de1156ff6c29ba92d5bf4b80f0d353eee000bac1463`
- Atomic acknowledgement source/header/test SHA-256:
  `e7e976e7880e04b393f42c57fefbf931de95ffc91c45d8c45bf5c1103b43efe5` /
  `e603458673a5b076fc83734ce988a992763386c9e0a57f9569963365037dc10d` /
  `889b2fedff14c27da34752eb07d55869dad6cb24271f6c4305a915bcff4ac867`.
- Startup signal-guard source/header/test SHA-256:
  `568905a059ab076a22dfe4e2e690de797a7aab2b54423ac0286cdcbbdb0ebb30` /
  `3a95a4c64762d3e09c4980d6233410d96e6edf1195348debbaaa704bb879f2f9` /
  `27abc111f42e0ddea8688b2f94d38c6fc83a3a066a94a6294df1e9f071d4235e`.
- Supervised C command source SHA-256:
  `804fd6bc3b221d49503287e22339abb1a432ea856577b00162986ef8222fb74f`
- Barrier core/header/test SHA-256:
  `2f5fa53d4ea90cd037f087f4492a2922b38f1dc3780aa23bfd7cab20d082210c` /
  `915015a38ed0ea623343637f75779b74ac06a0bcc36e477331a5952914779fb9` /
  `31e911d0a948b05b4b8e8c0736865aaf2709444f3d4f70a1949bde167e2333f5`.
- Reader-enumeration source/header/test SHA-256:
  `d09a13400534b3550e9ee09231f99aeaf72ca9ba2c27bae27c31ac165295a751` /
  `708e96f18dac66a051be8144dc9512894eb17d57bef878687ebe0b8699db4a46` /
  `1ff1c1f789ec69a86d735a4b1a28d441377729328c462ad9c3f0f93b878833e9`.
- Production `suspend_policy.lua` remains exactly disabled, SHA-256
  `25712167ce722b4ee26628e97f0cb8f344b8449288a27bf9a131a9f59f5183b7`.
- Production `device.lua` remains without dormant power imports, SHA-256
  `7f9f638e101a2cb32598d3b0f625f055048d62a1da390852d5dcc40ea59c35fb`.
- Diagnostic package:
  `/gnu/store/iacbgbk8dl5gj4dl0cwmcqwawbx2f4i3-pinenote-ebc-barrier-test-0.1.0`.
- KOReader package:
  `/gnu/store/p3x3wfkl6pd82i1cn6szhkzrab2y6w3z-koreader-bin-2026.03`.
- Direct reader build: `/gnu/store/fcqy7h44bm0af414i6vy6nl3ibnals1d-system`.
- System embedded in the image:
  `/gnu/store/jswc6b1vhx07z7c7llgrns86wnqkkdgb-system`.

## Offline artifact

- Rootfs:
  `/tmp/opencode/pinenote-rootfs-artifacts-ebc-adapter-release-reviewed-20260727/pinenote-reader-PNGuixRoot-20260727.ext4`
- Bytes: 1,945,583,616
- Logical 512-byte sectors: 3,799,968
- SHA-256: `1777dde4c5febd7eaaf9d763b422b48ab7d24ca5c75a615bc966406cf973ae64`
- Format: raw ext4, label `PNGuixRoot`, no partition table
- Matched bundle:
  `/tmp/opencode/pinenote-reader-boot-bundle-ebc-adapter-release-reviewed-20260727`

| Bundle file | SHA-256 |
| --- | --- |
| `extlinux/config` | `310958576631a4e0add34afcf931ecfceee1fe43ef7309385448e9409d8d609c` |
| `extlinux/Image` | `1302cd62d0063c59d5914f21e9a8881eafe836c20d1eaa5c105ace38d2f611f3` |
| `extlinux/rk3566-pinenote-v1.2.dtb` | `9d981579a2bafd56b2c56c215c88b01a6ec2670dafc5d97a7dd949b66e229bf2` |
| `extlinux/initrd.cpio.gz` | `94f12a873fada28844e6b4af50a42a5b1567826f681938a6a3a18173b75a49a3` |
| `extlinux/extlinux.conf` | `9eb513b3c8ffe7240b46db86a67b89e07286c0cc95f0c66201cd9401b9399fba` |

## Validation

- `make ebc-barrier-check`, its ASan/UBSan variant, the AArch64 diagnostic
  package build, `make activation-positive-check`, and `make suspend-check`
  passed.  The latter two rerun the production activation/suspend hard-off
  boundary and adversarial fixtures.
- Goal review found that a flag check followed by `read()` left a signal race.
  The command now blocks INT/TERM/HUP during setup and restoration and uses
  `pselect` to atomically unmask them only for acknowledgement. A five-second
  host regression proves both a signal pending before the wait and one delivered
  while blocked; reader-running and tty-refusal paths are now explicitly tested.
- Final code review then found a startup interval before signal blocking and
  cross-layer loss of valid negative kernel barrier results. The shared signal
  guard now blocks before installing handlers, detects a pending guarded signal
  immediately before snapshot, and has a real raised-SIGTERM regression proving
  zero mutation. C and Lua clients preserve valid SUBMIT/WAIT rejection codes;
  tests pin `-ENODEV`, poison-style WAIT errors, and malformed positive results.
- A second code review found cancellation could arrive during the read-only
  snapshot copy and that teardown unblocked before restoring original signal
  dispositions. The core now checks pending cancellation again after snapshot
  and directly before paint; an injected-during-copy regression proves the
  framebuffer stays byte-identical with zero paint/fsync/barrier calls. Teardown
  drains already-pending campaign signals while blocked, restores original
  dispositions, then restores the original mask; the shared test proves a
  subsequent SIGTERM reaches the original handler.
- Final review also caught fail-open `readdir()` error handling and a mismatch
  between the two-generation acceptance contract and one-generation output.
  The shared enumeration helper resets/checks `errno` and its injected test
  distinguishes entry, EOF, and `-EIO`; the core's first/second reader-error
  cases prove zero mutation. Successful restore now prints its nonzero
  generation, and the happy-path test requires both messages.
- Security follow-up made process inspection fail closed on unreadable or
  truncated cmdlines, opens DRM before mutation, and checks reader ownership
  both before setup and immediately before the framebuffer snapshot. The second
  gate's reader-present and inspection-error tests prove zero framebuffer copy,
  fsync, or barrier call. EUID root is an operational gate rather than an
  authorization boundary under the image's existing maintenance sudo policy.
- The framebuffer gate rejects non-32-bit-aligned strides, and the AArch64
  build compile-time-pins barrier version/op constants to the extracted UAPI.
  Dormant sleep-frame/coordinator objects snapshot validated dependencies so
  later caller-table mutation cannot change their authority.
- The reader closure and rootfs built successfully. Direct ext4 inspection
  resolved the embedded KOReader profile target and found all four dormant Lua
  module inodes; dumped policy/device hashes match the exact hard-off sources.
- The corrected rootfs inspector resolved the persistent system generation and
  found the diagnostic in its profile. It also requires `/boot/config` copied
  from the same kernel profile as `/boot/Image`, rejects enabled Rockchip
  activation, and repeats that check in the matched bundle. An adversarial image copy with
  `/boot/Image` removed was rejected, closing `debugfs`'s misleading zero-exit
  behavior for missing paths.
- Exact-artifact QEMU rung 4 passed every required kernel, initrd, service, and
  inert-command sentinel and powered off cleanly:
  `/tmp/opencode/pinenote-virt-assert-3703052.log`.
- Exact-artifact visual rung 4v bound virtio-gpu, painted a non-uniform
  1872x1404 KOReader frame, and changed it after scripted input:
  `/tmp/opencode/pinenote-virt-visual-3703054`.
- The rootfs-matched bundle inspector passed with `root=PNGuixRoot`, short boot
  paths, and no forbidden raw root-device path.

## Hardware boundary

On 2026-07-28 all four local/NFS backup manifests passed. The archived stock-os1
ED25519 fingerprint
`SHA256:vT0BeMam25qi9bWdKQEFPUR/xEoEeAHCiSM6vMfxRtY` matched at
`192.168.86.145`; Debian 6.12 was confirmed on `/dev/mmcblk0p5`, p6 was
unmounted, and its capacity was 15,728,640,000 bytes. The staged file matched
the host at 1,945,583,616 bytes and the SHA-256 below. `dd` wrote exactly
3,799,968 records to `/dev/mmcblk0p6` with
`bs=512 count=3799968 iflag=fullblock conv=fsync`; `blockdev --flushbufs` then
flushed p6. A `bs=512 count=3799968 iflag=fullblock` readback over the exact
written range produced matching SHA-256
`1777dde4c5febd7eaaf9d763b422b48ab7d24ca5c75a615bc966406cf973ae64`.
The final read-only check found root still on p5, p6 unmounted, and p6 labeled
`PNGuixRoot` with ext4 UUID `70c4c247-0bbd-3a2e-f332-95ba70c4c247`. os2 has
not been booted and the diagnostic has not run. No boot-selection or other
partition write occurred. The next action is the separate UART-supervised boot
and single test under the authoritative **EBC barrier campaign (one supervised
run)** section in `doc/hardware-deploy.md`. This is not suspend permission.
