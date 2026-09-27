# Data recovery and promotion health — 2026-09-26

Host-only QEMU test after PR #87. No PineNote command or deployment ran in
this follow-up. **54 update-flow assertions passed**, with
`VIRT_UPDATE_DATA_RECOVERY=1` enabling the additional recovery stage.

## Inputs

- Reader image system A: `/gnu/store/wkv21zrmb8xrf2ynaqx8bcsw74irybj2-system`.
- Image derivation: `/gnu/store/73f2d4p81a3q0pbxrj37zcfcccvi7sbp-disk-image.drv`.
- Image's system derivation: `/gnu/store/41ydzxmg17cy64356li2wdwkg12w6b7p-system.drv`.
- B: `/gnu/store/7w76mqxmzz4rya37a18amvihiz8b0b8r-system`, derivation
  `/gnu/store/dxwxrawnrrfdi7ck7f22bd86bn4vzfx8-system.drv`.
- Rootfs SHA-256:
  `64b0d96d6ba1f4a0baf8e4e7be7d368a3477820aa680f92ca4e12bd3c4d7e7d1`.
- `channels.scm`, `--target=aarch64-linux-gnu`, `--no-grafts`.
- Both systems' helper **and ledger/health predicate** matched the checkout.

## What passed

1. The kernel-GPT resolver selected `/dev/vda3`; Guix mounted it through
   `/run/wilkbook-data-device`.
2. The fixture wrote and synced a baseline and checksum, made an unsynced
   write, then the host killed **only its QEMU process** with SIGKILL, leaving
   root and data mounted read-write. The next boot used the same disk, with
   no os1 rescue boot in between.
3. The next boot logged **`data: recovering journal`**. Its synced baseline
   matched, the device resolver selected vda3 again, and production health
   accepted the whole ext4 GPT data partition read-write.
4. A real tmpfs overmount on `/data` made `health --expect` fail with
   `data_ready=false`. Unmounting the overlay restored passing health.
5. Missing-image refusal, real busy-data refusal/restoration, delta import,
   trial/health/promotion, rollback, pin/unpin and pruning all passed.

`result.log` is the final harness output. `journal-excerpt.log` retains the
data journal-recovery/mount/remount lines from the console. Full temporary
console: `/tmp/wilkbook/pinenote-virt-update-346454.log`; the pre-cut boot is
in its `.before-cut` sibling.

## Failed attempts and scope

- The first image build exposed a packaging error: Guix's
  `source-module-closure` selects Guix/GNU namespaces by default and omitted
  our `(pinenote lib data-device)`. Importing that module explicitly fixed
  service compilation; the complete image then built and passed extraction.
- `attempt-source-alias.log`: the first VM fixture compared findmnt's source
  text directly to `/dev/vda3`; findmnt correctly retained the new `/run`
  symlink. The assertion now resolves the alias before comparison.
- `attempt-label-diagnostic.log`: journal recovery succeeded, but the fixture
  looked for a device name in e2fsck's diagnostic. E2fsck used the ext4 label
  (`data: recovering journal`). The matcher now accepts that exact line too.
- After the successful run, cleanup registration was moved after the tmpfs
  mount succeeds, so a failed negative-control mount cannot unmount the real
  filesystem. This does not change the exercised successful mount path.

This validates recovery from one VM power cut and the service composition;
it does not prove the physical tablet's dirty-mount race eliminated, guarantee
unsynced writes, test an unrepairable filesystem, or make root-remount kexec
clean. The VM still reports the expected busy root. Short-hold shutdown UI,
reversible root-writer teardown, and RTC writer coordination remain work.

## Replay

```sh
make TIME_MACHINE=1 rootfs-reader \
  GUIX_FLAGS='-L . --target=aarch64-linux-gnu --no-grafts --no-substitutes' \
  ARTIFACTS=/tmp/wilkbook/pinenote-data-recovery-20260926

VIRT_UPDATE_DATA_RECOVERY=1 timeout 1800 make TIME_MACHINE=1 qemu-update-check \
  GUIX_FLAGS='-L . --target=aarch64-linux-gnu --no-grafts --no-substitutes' \
  ROOTFS=/tmp/wilkbook/pinenote-data-recovery-20260926/pinenote-reader-PNGuixRoot-20260926.ext4 \
  ARTIFACTS=/tmp/wilkbook/pinenote-data-recovery-20260926
```

The extraction target date-stamps the rootfs name; use the path it prints.
Host checks: update-path (267 teardown assertions, ledger/data-health cases,
six production-health entrypoint cases, eleven kernel-resolver cases),
`gexp-modules-check`, `library-check`. No per-device waveform is involved.
