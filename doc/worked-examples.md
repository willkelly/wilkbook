# Worked examples — how changes get proven here

`doc/testing.md` states the philosophy (hardware sessions are scarce;
prove everything offline, in ladder order). This file shows the
philosophy *applied*, as concrete case studies a future contributor or
agent can replay on a new problem. Each one really happened; the commits
and docs it produced are cited so you can read the full diffs.

## Case study 1: evaluating community cherry-picks (2026-07-04)

**Problem.** The ROADMAP listed four cherry-pick candidates from hrdl's
v6.19 tree, known only by commit title: a temperature clamp,
pixels-to-IDLE on waveform change, `fsleep`, and `dma_sync` size fixes.

**Approach — read the diffs before believing the titles.**

1. Find the upstream tree and enumerate branches without cloning a
   kernel:

   ```sh
   git ls-remote https://git.sr.ht/~hrdl/linux
   ```

2. Fetch just the topic branch, shallow, into a scratch repo (the
   sourcehut server ignores blob filters, but a `--depth` fetch of a
   topic branch is only tens of MB):

   ```sh
   git init scratch && cd scratch
   git remote add origin https://git.sr.ht/~hrdl/linux
   git fetch --depth=300 origin v6.19_ebc_custom
   git log --oneline FETCH_HEAD | grep -in "temp\|idle\|fsleep\|dma"
   git show <sha>          # the actual diff, not the title
   ```

3. Map each diff onto **our** driver copy — grep the verbatim extraction
   (`pinenote/tools/wbf/extract-from-patch.py`) for the constructs the
   diff touches. This is where the story changed: all four commits sit
   on hrdl's 60–85 Hz driver *rework* (per-pixel scheduler state, NEON,
   early cancellation). Two of the "fixes" turned out to be workarounds
   for rework-only features our m-weigand-lineage copy doesn't have.

**Outcome.** Two ported (as *translations*, since nothing applied
cleanly), two rejected — each rejection recorded with its evidence in
`doc/kernel-forward-port.md` ("Cherry-picks from the community
lineage"). The commit titles alone would have argued for porting all
four; the temperature clamp in particular would have silently discarded
the waveform's cold-temperature bins.

**Lessons to reuse.**

- A commit title is a claim; the diff plus its commit message body is
  the evidence. hrdl's clamp commit *says* it works around their early
  cancellation — one grep (`grep -i cancel rockchip_ebc.c`) settled
  that it can't apply to us.
- A rejection deserves a pinned test too, not just a doc note: the
  `wbf cold:` harness test (131-phase GC16 @ 0 °C orchestrates cleanly)
  is what makes "we don't need the clamp" a fact rather than an
  opinion.
- When the upstream base has diverged structurally, "cherry-pick"
  really means "translate", and a translation needs an offline gate
  built *first* — see case study 2.

## Case study 2: make the risk testable before taking the risk

**Problem.** The `dma_sync` shrink changes per-frame full-buffer cache
cleans into row-span syncs. Its failure mode — a blitted row the device
reads *stale* — is invisible on a cache-coherent host: the old harness
resolved DMA handles straight to the CPU buffers, so even a driver that
never called `dma_sync` at all would have passed every pixel assertion.

**Approach — teach the harness to see the failure class, prove it green
on the unchanged code, only then change the code.**

1. Model the hardware property that makes the bug possible. The shim's
   DMA registry grew a *shadow copy* per mapping: only `dma_map_single`
   (whole buffer — matching the arch's map-time cache clean) and
   `dma_sync_single_for_device` (the synced range only) update it, and
   the fake EBC reads exclusively from shadows
   (`pinenote/tools/ebc-logic/shim/kernel-shim.h`, "non-coherent
   model").
2. Pin the model's own contract with a self-test (`dma shadow:` in
   `ebc-refresh-test.c`): unsynced CPU writes must be invisible,
   a partial sync must publish exactly its range, an out-of-bounds sync
   must count as a violation. A harness feature nobody has watched fail
   is itself untested code.
3. Run the whole suite against the **unmodified** driver. Green here
   proves two things at once: the model is faithful enough not to
   false-positive, and the current driver's sync discipline is real.
   (One subtlety surfaced immediately: `global_refresh` writes `prev`
   *after* its refresh with no trailing sync — masked on hardware
   because the driver re-maps per refresh and mapping cleans the cache.
   The shadow model reproduces exactly that masking, because the copy
   happens at map time. Model the mechanism, not your guess about it.)
4. Now apply the risky change and re-run. The 256-transition waveform
   differential and the PGM goldens become, retroactively, a sync-
   coverage checker: one missed row and they go red.

**Lessons to reuse.**

- Before a change whose failure mode the current tests cannot express,
  extend the harness until they can — then the change's PR carries its
  own proof.
- Self-test the harness extension; assert its counters/violations stay
  zero in every driver test (`harness_clean()`), so the model polices
  the driver *and* the driver exercises the model.
- "Green before, green after" is only meaningful if step "before" was
  actually run. Do not skip it to save one suite run.

## Case study 3: editing the forward-port patch without a refresh

**Problem.** The patch is the most rebase-fragile artifact in the repo,
and most of it is *new-file* diffs (the whole EBC driver as one `+`
block). Editing driver code "inside a patch" by hand invites malformed
hunks.

**Approach — extract, edit, splice, round-trip, ladder.**

```sh
# 1. extract the verbatim file
python3 pinenote/tools/wbf/extract-from-patch.py \
    pinenote/patches/linux-pinenote-7.0-forward-port.patch \
    /tmp/port-src drivers/gpu/drm/rockchip/rockchip_ebc.c

# 2. edit /tmp/port-src/... normally

# 3. regenerate that file's new-file section in place
python3 pinenote/scripts/update-patch-file.py \
    pinenote/patches/linux-pinenote-7.0-forward-port.patch \
    /tmp/port-src/drivers/gpu/drm/rockchip/rockchip_ebc.c \
    drivers/gpu/drm/rockchip/rockchip_ebc.c

# 4. round-trip: re-extract and diff against your edited copy
#    (must be identical)

# 5. gate in ladder order
make wbf-check ebc-logic-check rastersim-check WBF=...   # minutes
make suspend-check   # structural gates over patch hunks (see caveat)
make kernel-drv                                          # seconds
make kernel                                              # the real build
```

The host tools compile the *patch's* driver, so step 5 exercises your
edit within minutes — that is the entire reason the verbatim-extraction
rule exists. The cross-build then proves the regenerated hunk applies
and compiles for the real target (check for `Image`, the PineNote DTBs,
and `rockchip_ebc.ko` in the store output).

One caveat (`doc/testing.md`, 2026-08-01): the host tools compile the
driver under the shim's config, so code behind an `#ifdef` the shim
does not define is **invisible** to them — the suite can go green with
such a branch deleted outright. `CONFIG_DRM_FBDEV_EMULATION` is the
lone exception since 2026-08-04 (`ebc-fbdev-order-test` defines and
executes it). For hunks the host tools cannot see — the TPS65185 PM
section and the fbdev/resume hunks that `make suspend-check`'s
validators cover — the structural gate is the behavioral check and the
cross-build is the only compile gate. Before trusting a green suite,
confirm the harness actually compiles the lines you changed.

**Lessons to reuse.**

- Never hand-edit hunk bodies; regenerate the whole file section.
- The round-trip check (step 4) is cheap and has caught real
  whitespace/trailing-newline mistakes; make it a habit, and run the
  long build in the background while you write docs.
- Remember the shim: if the driver gains a new kernel API call, the
  host tools fail to compile until `shim/kernel-shim.h` stubs it
  (`fsleep` needed exactly that).

## Where the other examples live

- The **2026-07-03 fix stack** (three device failures root-caused from
  logs, the os1 SSH oracle, chroot tests, and review — zero reboots):
  `doc/status.md`; the device-access conventions it leaned on are
  `doc/device-access.md`, and the kernel-side lessons are in
  `doc/kernel-forward-port.md`.
- Building the **refresh harness itself** (rung 7a) from a scoping
  spike, including the effort pricing that made option (a) obviously
  right: `doc/ebc-harness-spike.md` and the ebc-logic README.
- The **qemu-virt rung 4** build, including honestly recording what the
  rung appeared unable to reach (the "udev deadlock" finding) — and then
  the 2026-07-05 retraction of that finding as a console-logging
  artifact, a case study in chasing a wrong-but-precise theory to the
  evidence that kills it: `ROADMAP.md` §3 and `doc/status.md`.
