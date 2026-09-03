# The embrace sweep: one reader, on the direct-mode driver

**Status: plan for review (Will, Ron), written 2026-09-02 from a full
inventory of the tree. Nothing here has been done.** The decision it
serves: direct mode is tentatively embraced by both operators
(`doc/direct-mode-adoption.md`, top). The 2026-08-25 rule stands — one
shipping image, `reader`, singular; the `reader-direct` scaffolding is
deleted, not renamed.

## What the tree looks like today

`pinenote-reader-direct.scm` is `pinenote-reader.scm` plus exactly ten
deltas (nothing removed):

| # | Field | `reader` | `reader-direct` |
|---|---|---|---|
| 1 | host-name | `pinenote-reader` | `pinenote-reader-direct` |
| 2 | kernel | `linux-pinenote` | `linux-pinenote-hrdl-direct` (same seven patches + hrdl's driver swap + our parallel-advance patch) |
| 3 | kernel-arguments | reader args | + `fbcon=map:1` |
| 4 | packages | reader set | + `pinenote-wbf-clut` |
| 5–7 | services added | — | `pinenote-ebc-clut` (CLUT from the device's own waveform, then rebind), `pinenote-ebc-direct-params` (`temp_override`, `default_hint`), `pinenote-ebc-splash` (white page after the rebind) |
| 8 | modprobe options | the shipping nine-parameter line | `softdep panfrost pre: rockchip_ebc` only |
| 9 | KOReader profile | `avoid_flashing_ui=false`, `pinenote_flash_area_fraction=0.6` | `true`, `0.98` |
| 10 | modules | — | `(pinenote services ebc-direct)`, `(pinenote packages firmware)` |

Everything the direct flavor *needs* to run is already a first-class
package or service; what dies is the second flavor, the shipping-driver
pieces the direct driver has no use for, and every gate and doc whose
job was to keep the two apart.

## Decisions the sweep needs (recommendation in bold)

1. **Which kernel is `linux-pinenote`?** **The direct one.** Append the
   two direct patches (`7.1-hrdl-direct-mode`, `7.1-ebc-parallel-advance`)
   to `%linux-pinenote-patches`; delete `linux-pinenote-hrdl-direct`.
   `make kernel`, `kernel-drv`, `kernel-version-check` and every flavor
   then mean the direct driver. The forward-port patch keeps carrying
   the old `rockchip_ebc.c` that the swap overwrites (that is how the
   tree builds today); trimming those hunks out of the forward-port
   patch is a *separate*, later change — it is the most rebase-fragile
   file in the repo and the sweep should not touch it.
2. **The debug kernel and `reader-debug`.** **Delete both**
   (`linux-pinenote-debug`, `linux-pinenote-debug-extract-fbs.patch`,
   `pinenote-reader-debug.scm`, `ebc-dump-grab`'s flavor). The direct
   driver already registers `EXTRACT_FBS`, and `belief-grab.lua` was
   revived on it 2026-08-27; keeping a debug flavor on the old driver is
   exactly the two-flavor shape the decision forbids.
3. **`linux-pinenote-6.6.30` / `usb-console-linux-6-6`.** **Untouched.**
   Regression isolation on a different lineage, not a reader flavor.
   Docs stop listing it beside `reader-debug`/`reader-direct`.
4. **Gates that compile or inspect the shipping driver** (`ebc-logic`,
   `rastersim`, `ebc-barrier-check`, the four EBC hunk gates in
   `suspend-check`, `validate-ebc-global-arm-order-hunk.sh`). **Barrier
   dies; the rest stay, relabelled "legacy: the retained forward-port
   driver source", until the harness is ported to the direct driver.**
   They keep proving the community record (`quirk:` pins, the
   `driver-findings-report`) and guarding the forward-port patch against
   rebases — they no longer prove the shipped image, and the docs must
   say so. Porting `ebc-logic`/`rastersim` to hrdl's driver is its own
   track (ROADMAP §3), not a sweep step.
5. **Deployer default.** `FLAVOR=reader`, landed in the same commit as
   the file deletion (the deployer fails hard on a missing flavor file).
6. **Hostname.** Stays `pinenote-reader`. Lineage is visible from
   `/run/current-system` and `wilkbook-generation list`; a marker in the
   login banner is a nicety, not a sweep item.
7. **KOReader profile defaults graduate** (`avoid-flashing-ui? #t`,
   `flash-area-fraction 0.98`) and the three pins move in the same
   commit: `test-koreader-profile-seed.scm`, `device.lua`'s fallback
   default, `check-settings.py` (+ its mutation controls). The record's
   comment ("the shipping flavor keeps 0.60 because ghosting is resolved
   only on direct") becomes the universal statement.
8. **`fbcon=map:1` + the splash graduate together.** The operator
   directive (2026-08-27: the panel never shows a tty) was about the
   reader, not the experiment. Bringup flavors keep `console=tty0` and
   no splash — the panel *is* their diagnostic channel.
9. **One addition, easy to miss:** `reader-session` gains
   `pinenote-ebc-clut` as a requirement. The direct flavor deliberately
   left that edge out because adding it would have moved the shipping
   reader's derivation; the embrace removes the constraint.
10. **`pinenote-ebc-params` (shipping sysfs one-shot) leaves
    `%pinenote-bringup-services`; `pinenote-ebc-direct-params` goes in
    the reader flavor only.** The old one succeeds vacuously on the
    direct driver; the new one fails loudly on a missing node, which is
    wrong for the 6.6.30 console flavor. Bringup flavors need no tuning.
11. **The two gates that lose their positive control**
    (`ebc-modprobe-options-check`: "the shipping string must be rejected
    against hrdl's driver"; `validate-ebc-ioctl-roster.py`: both
    rosters). **Rewrite each as a single-driver gate with a new positive
    control**: a deliberately wrong option / ioctl must be rejected
    against the direct driver's registered parameters and UAPI. A gate
    with no way to go red is not a gate (`doc/testing.md`).
12. **Workbench READMEs** (`tools/pen`, `tools/ebc-lab`, `tools/wbf`)
    stop describing their target as an experiment.

## The sweep, in order (each step builds and gates before the next)

Every step is a PR against `main`; the kernel step wants review.

**S1 — kernel identity.** `kernel.scm`: direct patches into the shipping
list; delete `-hrdl-direct` and `-debug` and the extract-fbs patch;
delete `pinenote-reader-debug.scm`; `Makefile` FLAVORS and help.
Proof: `make kernel-drv` (seconds), `make kernel` (minutes), the patch
inventory in `doc/kernel-forward-port.md` (now: seven + two, in order),
`validate-ultra-coupling.sh`, `direct-probe-quirk-check`,
`validate-ebc-ioctl-roster.py` rewritten to one roster (decision 11).

**S2 — the reader absorbs the deltas.** `pinenote-reader.scm` takes
deltas 3–9 and the requirement edge (decision 9); `base.scm` drops the
shipping params one-shot and the barrier test (decision 10);
`pinenote-reader-direct.scm` is deleted; `ebc-direct.scm` keeps its
service types but loses the "exactly one flavor" docstring and the
uncalled `pinenote-ebc-direct-modprobe-service`; `ebc.scm` loses the
nine-parameter options string; `firmware.scm` loses the second copy of
it and `pinenote-apply-ebc-params`; `ebc-test.scm` and the barrier tool
go. Gates that move in the same commit: `test-ebc-clut-install.py`'s
flavor pin (→ `pinenote-reader.scm`), `test-koreader-profile-seed.scm`
values, `check-settings.py`, `inspect-rootfs-image.sh` (no barrier
tool, no `ebc_barrier.lua`), `inspect-pinenote-suspend-gates.sh`'s
module roster, `run-virt-assertions.sh` (drop `VIRTCHK-WF-6` and
`VIRTCHK-BARRIER-yes`; add the direct fingerprints — `temp_override`
and `default_hint` present, `refresh_waveform` absent),
`update-flow-generation-b.scm` (inherits `reader`, hostname
`pinenote-reader-genb`) and `run-virt-update-flow.sh`'s hostname
assertion, `validate-ebc-modprobe-options.py`'s `gate_no_shipping_consumer`
(inverts: the reader *must* reference `ebc-direct`). Proof: `make
check-host`, `make qemu-virt-check` (the CLUT one-shot must be a clean
no-op with the rig's zero-filled waveform — `test-ebc-clut-install.py`
already exercises that branch), `make qemu-update-check`.

**S3 — one driver in the broker and KOReader.** `broker_quiesce.lua`
becomes IRQ-quiescence only; `driver_has_barrier` and the
`refresh_waveform` fingerprint leave the broker; `ebc_barrier.lua` is
deleted; `test-quiesce.lua` loses its barrier cases and keeps the
IRQ ones; `idlewasher` and `autosuspend.lua` keep their absent-node
fallback for now (their `refresh_waveform` wash is P4 work on the
direct vocabulary — carried, dated, not silently deleted). Proof:
`make platform-controls-check`, `koreader-input` suites,
`ebc-ioctl-roster-check`.

**S4 — tools and gates.** Decision 4's relabelling; `ebc-barrier-check`
deleted; `ebc-modprobe-options-check` rewritten (decision 11);
`ebc-card-resolution-check` reworded (now unconditional); the deployer
default. Proof: `make check-host` green with every positive control
still able to go red (`doc/testing.md`'s rule).

**S5 — docs.** `pinenote-flavors.md` (the table: `reader`, the bringup
flavors, `usb-console-linux-6-6`; no `reader-direct`, no
`reader-debug`), `building.md`, `hardware-deploy.md`, `testing.md`'s
gate rows, `ROADMAP.md` §4/§5, `CLAUDE.md` ("Where we are" and the doc
map), `CHANGELOG.md` (one entry for the person holding the device: the
reader is now the direct-mode reader; what they will notice — turns
settle flash-free, the transition ghost, `fbcon=map:1`'s white page;
what is gone — the barrier tool), `direct-mode-adoption.md`'s status
line ("embraced; the sweep landed on <date>"), `glass-plan-2026-08.md`,
the three workbench READMEs, `power-management.md:403`,
`upstream-register.md:728`. Historical `doc/status.md` entries and
artifact names stay as written.

**S6 — glass.** The merged `reader` reaches os2 as a generation through
the update path (`make deploy DEVICE=… FLAVOR=reader`), cold-booted
from the menu as well as kexec-trialled (it changes early boot: kernel
and command line). Then the shipping-reader validation list in
`doc/glass-plan-2026-08.md` on that image, suspend/resume, and a
`pinenote-flash-area` optics check against `doc/datasets/`. On a green
list, the next prealpha tag ships `reader`, singular
(`doc/alpha-checklist.md` gains the row).

## Bail-out

`doc/direct-mode-adoption.md`'s bail-out criteria stay live. Until S6
is green the old tree is one `git revert` of S1/S2 away, and the
generation ledger on the device keeps the last shipping-driver
generation bootable from the menu; prune it only after S6.
