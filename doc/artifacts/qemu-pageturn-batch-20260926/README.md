# Batch full-log page-turn campaign — 2026-09-26

Host-only QEMU virt qualification on `batch/integration` after `13f9563`, with
the harness corrections recorded below. No additional device access occurred.

## Inputs and reproduction

Same pinned image/rootfs as `../qemu-update-batch-20260926/`:

- System: `/gnu/store/x955n2ki52n2v5hgs0cq96md0lrd7ilv-system`.
- Image: `/gnu/store/m7xaabdsmr86yrjq37xc1rd1147hlsh1-disk-image`.
- Rootfs SHA-256:
  `d0b4f624807d77b5bedd8d86f778a3faf02ea9287cedc70a7ed21c71ec6d150e`.
- Zero-filled waveform fixture; no EBC or physical panel.
- Default plan: 160 turn taps plus 38 menu open/dismiss taps, with the normal
  3.5/1.6/0.9-second cadence settings and 80 ms contacts.

```sh
timeout 1500 make TIME_MACHINE=1 qemu-pageturn-campaign \
  ROOTFS=/tmp/wilkbook/pinenote-batch-20260926/reader-PNGuixRoot.ext4 \
  ARTIFACTS=/tmp/wilkbook/pinenote-batch-20260926
```

## Failed attempt and corrections

The first run stopped at its paint gate after 337 seconds. QMP repeatedly
returned 640x480; the recovered guest log showed KOReader had initialized and
requested a repaint at 1872x1404. The device's `fbcon=map:1` suppresses fbcon by
mapping it to absent fb1; under virtio-gpu it also left scanout inactive. The
visual harnesses now substitute `fbcon=map:0`, then let the ordinary reader
service unbind fbcon before launching KOReader.

That change produced a correctly sized UI, exposing a second stale assumption:
the current image starts in the file manager, not the old quickstart book.
The campaign now uses the guest console to stop the reader, save its settings,
select a generated 600-paragraph numbered text fixture, and restart the same
supervised service. A settings wrapper preserves the original table, changing
only `start_with` and `lastfile`. Setup waits for the fixture's `opening file`
entry; final acceptance also requires full-panel partial/partial requests.

The standalone visual smoke test's old `936,100` tap missed the menu; its tap
now uses the campaign's measured portrait-to-framebuffer coordinate `150,700`.
The final visual test passed all four assertions (login, DRM, paint, changed
screen). The initial paint failure and intermediate missed-tap failure are
retained in `first-attempt.log` and `visual-before-menu-fix.log`.

## Final campaign result

**Exit 0**, with seven campaign assertions and both analyzers successful.

- First paint at 37 s; the book baseline settled at 94 s.
- Input plan completed at 535 s: **198 taps issued**. This is a host command
  count, not a count of handled gestures or page turns.
- Complete reader snapshot: **57,045 bytes**, SHA-256
  `4e33edba1e4aa7ec5547cf5d494af31f85cd855e8ec2acdfbd59182ca6acd83c`.
- **158 traces**, none unparsed: 89 partial/partial, 66 ui/partial,
  3 full/global; 601 non-trace lines retained.
- All 89 partial/partial requests covered the full panel. Their 88 adjacent
  gaps had median 3.525 s and minimum 0.955 s. Three gaps were under one
  second; none under 0.7 s.
- Harvest guest-minus-host clock interval: `[+0.151191, +0.344387]` s.
- **Missing antecedent coverage:** no flash/global menu lookbacks. The
  conjunction used by the historical field analysis was unexercised.

This validates capture/analysis integration and actual book request activity.
It does not establish one refresh per issued tap, input delivery timing, panel
completion, visible quality, or non-reproduction of issue #14. Clock drift
during the campaign remains unmeasured. The notebook authority is absent from
this plain-reader composition.

## Evidence

`result.log` is the successful harness output; `reader-session.log` is the
validated full snapshot, with `action-ledger.txt`, `plan.txt` and `harvest.txt`
for replay. `visual-result.log` holds the final visual assertions.

Re-run capture validation and both analyses into a separate output directory:

```sh
mkdir -p /tmp/opencode/pageturn-batch-replay
guile --no-auto-compile -e main \
  -s pinenote/tools/refresh-episodes/campaign-report.scm \
  doc/artifacts/qemu-pageturn-batch-20260926/harvest.txt \
  /tmp/opencode/pageturn-batch-replay \
  doc/artifacts/qemu-pageturn-batch-20260926/action-ledger.txt
```

`make HOST_TOOLCHAIN=1 refresh-capture-check refresh-episodes-check
refresh-trigger-check` also passed after the harness correction.
Local full VM artifacts are at `/tmp/wilkbook/pinenote-virt-pageturn-228291/`;
the failed initial run is `/tmp/wilkbook/pinenote-virt-pageturn-218460/`.
