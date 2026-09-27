# Batch update-path QEMU acceptance — 2026-09-26

Source: `0690838` on `batch/integration`, including `main` at `6e8a19a`.
Host-only QEMU virt run; no PineNote command authenticated during this work.
The device SSH connection reached public-key acceptance but host-agent signing
timed out, independently reproduced with `ssh-add -T`. No device setting was
changed and no device generation was registered or trialled.

## Inputs

- Pinned channels: repository `channels.scm`.
- Image derivation: `/gnu/store/8gznkhrz66yl149jlnagm0vgxwip8mzn-disk-image.drv`.
- Built image: `/gnu/store/m7xaabdsmr86yrjq37xc1rd1147hlsh1-disk-image`.
- Guest A: `/gnu/store/x955n2ki52n2v5hgs0cq96md0lrd7ilv-system`.
- Guest B derivation: `/gnu/store/113kg2mj7zhjgrrs3w80isv906sb0p8j-system.drv`.
- Guest B: `/gnu/store/dws3s89r8qp2959a7mrk8ljg8zq9gkgw-system`.
- Helper SHA-256: `1fc24b36f9fb250dc0e833e34be4c77fa5f7499dc3e55de9bcbb42c85449b534`.
- Extracted/normalized rootfs SHA-256:
  `d0b4f624807d77b5bedd8d86f778a3faf02ea9287cedc70a7ed21c71ec6d150e`.

The image and B were derived through `guix time-machine -C channels.scm --`,
with `--no-grafts` and target `aarch64-linux-gnu`, then realized without
substitutes. The existing extraction/inspection helpers prepared the rootfs.
Both guest systems passed the harness's exact-current-helper comparison.

```sh
timeout 1200 make TIME_MACHINE=1 qemu-update-check \
  ROOTFS=/tmp/wilkbook/pinenote-batch-20260926/reader-PNGuixRoot.ext4 \
  SYSTEM_B=/gnu/store/dws3s89r8qp2959a7mrk8ljg8zq9gkgw-system \
  ARTIFACTS=/tmp/wilkbook/pinenote-batch-20260926
```

## Result

**Exit 0; 40 PASS checks; `qemu update flow: OK`.**

- A booted; root grew from the 2,684,211,200-byte image to 4,683,517,952 bytes.
- Importer and signing-key ACL worked; only 13 of B's 439 closure paths needed
  transfer. Registration staged both payloads while leaving DEFAULT at A.
- The deliberately missing B kernel made `kexec -l` refuse. The helper's
  refusal reached the caller, the same guest boot remained reachable, reader
  health recovered, the refusal record belonged to that boot, and DEFAULT
  remained A.
- A → B trial changed system, hostname and boot ID. Health passed while
  DEFAULT was still A; promotion then selected B and its Guix profile.
- Pinning A protected it from `prune --keep 1`; unpinning removed that marker.
- B → A rollback changed boot ID again, passed health, and promoted A.
- `prune --keep 0` removed B's payload/profile and retained A and DEFAULT.

Both successful trials logged the actual root-remount refusal:

```text
root remains read-write: legacy best-effort root remount (exit 32): mount: /: mount point is busy.
```

Thus the root-writer concern found by source review is reproduced in the
realized QEMU service composition. The helper proceeded only after its strict
mounted-data check. This does not establish root crash consistency.

Boot IDs: `f549aca2-d608-43a5-8509-551d773d8ff1` →
`715c5d66-b272-4292-9ebd-4847490f1e5e` →
`5c9c0ded-dc09-411c-95cf-3d39ec8caf3f`.

## Evidence and limits

**Final merge qualification:** `busy-data-result.log` records the extended
suite against the same A/B inputs: **48 checks passed**. An unrelated guest
process held `/data/update-busy.txt` open writable while the production helper
attempted a trial. Linux returned EBUSY; the helper refused, unloaded the
candidate, retained original mount IDs/modes and the writer/data hash, restored
reader health and kept extlinux DEFAULT at A. After releasing the holder, the
normal trial/promotion/rollback/prune sequence passed. The fixture checks the
actual extlinux default because A has no `/boot/gen-default` until its first
explicit promotion (the first version of the added assertion incorrectly
required that optional ledger file and stopped before the good trial).

`result.log` preserves the harness output from its boot announcement through
its final verdict, with CRLF line endings normalized; host package-download
and disk-preparation output is omitted.

Local full harness output: `/tmp/opencode/wilkbook-batch-qemu-update.log`.
Console plus per-trial logs: `/tmp/wilkbook/pinenote-virt-update-197727.log*`.
Console SHA-256: `5ad3bf5b2ee2f9c7b50b4e5e7002a18464110a9326b4256dfb433e63ed47a583`.
These temporary paths are replay/debug aids, not committed evidence files.

The guest is the plain reader composition, not the experimental note-authority
composition. Actual note-authority shutdown (subsequently exercised by the
23→24 device trial), mount-replacement refusal, EBC quiescence, Wi-Fi teardown and RK3566 watchdog
recovery are not proven by this run. Failure-path host tests cover modeled
authority/mount cases separately. The waveform partition was zero-filled;
this is update-mechanism acceptance, not display or calibration acceptance.
