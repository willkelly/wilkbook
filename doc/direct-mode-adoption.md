# Adopting direct mode: the plan

**Status: plan, not a decision record.** Written 2026-08-24, after the
operator named handwriting as a product direction that the current display
path cannot support. **The only thing built so far is P1's CLUT compiler**
(2026-08-25) — a host/device tool with no service, image or kernel change
behind it. Everything from P2 on is still a plan, and the bail-out
criteria at the bottom still apply.

Read `doc/hrdl-evaluation.md` first — this document assumes it.

## Why now

`doc/hrdl-evaluation.md` rejected the driver swap with an explicitly
conditional verdict:

> **Verdict: not now.** … Re-evaluate when the corruption hunt closes,
> when pen latency becomes the active track …, or when a community
> rebase forces a structural decision anyway.

**Both of the first two have fired.** The corruption hunt closed; pen
latency is now the active track, because handwriting — note-taking,
drawn UIs in books, handwritten code that executes — is a stated product
direction rather than a nice-to-have. Handwriting also adds *recognition*
latency on top of ink latency, so the panel budget matters more, not
less.

**The current path cannot get there.** Ink latency floor today:

| | |
|---|---|
| software path, damage → publish | 132–140 ms (measured) |
| A2, the fastest LUT-mode waveform | 10 phases = 157 ms |
| **floor** | **~290 ms** |

For scale, reMarkable claims ~21 ms. At 290 ms the ink trails a third of
a second behind the nib. #23's reclock takes A2 to 126 ms — real, and
nowhere near enough. `DRIVER_MODE_FAST` reaches **~11.7 ms to first
motion**, and it is structurally unavailable in 3WIN/LUT mode: it needs
the driver to own per-frame phase bytes.

## What the swap buys, beyond FAST mode

| | |
|---|---|
| `DRIVER_MODE_FAST` | ~11.7 ms to first motion (1-bit, visible smear) |
| **85 Hz** | needs `SDCLK_DIV=0`, direct-mode-only — **100 %** of the waveform's authored rate |
| phase buffer 2 bits/px | **~6× less DDR** (56 vs 335 MB/s) — cheaper on our one confirmed failure mode |
| per-pixel state | no areas, no queue, no `split_area_limit` — **area-collision bugs cease to exist as a class** |

That last one deletes the bug class issue #22 lives in. **The drain gate
we landed on 2026-08-24 is a fix for the driver we would be leaving.** It
stays correct and stays owed to the m-weigand lineage; it simply does not
port, because there is no queue to drain.

## What today's probe changed

The evaluation's strongest ground for rejecting was that the offline
harness dies:

> **Host tools — the big one.** … the entire offline refresh-machine
> harness and the replay workbench stop compiling on the workstation.
> Recovery options, none cheap …

Measured 2026-08-24 (`907efce`): the harness cross-compiles to aarch64
and runs under `qemu-aarch64` with **identical results** — drain-gate
31 PASS/0 FAIL, refresh-test **with ASan** 148 PASS/0 FAIL, ~3× wall
time. Cost: **one typedef**. Residual: LeakSanitizer does not work under
qemu-user, and qemu *emulates* NEON.

So the objection that killed the swap is now priced, and it is cheap.

## The blockers, and the decision each needs

### D1. `custom_wf.bin` has no producer we can run — **the hard one**

hrdl's driver `request_firmware`s `rockchip/custom_wf.bin` and **probe
fails `-EINVAL` if it is absent**. It is compiled from the device's own
`ebc.wbf` by `wbf_to_custom.py`; ayakael's first-boot recipe runs that
**on the device**.

**We cannot.** The reader image has no Python, no Perl, no standalone
Lua — verified 2026-08-24; KOReader's bundled `luajit` is the only
interpreter (`doc/artifacts/pinenote-input-clocks-20260824/`).

Three options:

1. **Reimplement the CLUT compiler in C, ship it as an on-device binary.**
   *Recommended — and **done** as of 2026-08-25 (see P1); the "ship it"
   half is not.* There is already exactly this precedent:
   `pinenote-install-waveform` is a compiled binary run by a one-shot
   shepherd service before the EBC module loads
   (`pinenote/services/ebc.scm`), and `pinenote-ebc-dump` in
   `pinenote/packages/firmware.scm` is an on-device C tool we already
   cross-build. Adding a sibling is the smallest change to a shape we
   already have. It keeps Python off the device, preserves never-bundle
   (compile from the device's own waveform at boot), and — crucially —
   **a C implementation differential-tested against `wbf_to_custom.py`
   is the "CLUT-compiler differential" §4.2 names as the natural first
   joint artifact with hrdl.** The work pays twice.
2. **Compile on the host at install time, stage to p7.** Simpler to
   build, but moves a mandatory boot artifact into a manual step, and a
   skipped step is a `-EINVAL` probe failure — i.e. no display at all.
   Viable as a *bridge* while (1) is written; poor as the end state.
3. **Put Python in the reader image.** Rejected: a large closure on a
   device whose whole design is minimal, to run one compile once.

### D2. A2 disappears from the vocabulary

hrdl's CLUT compiles six sequences — DU, DU4, GL16, GC16, INIT, WAITING.
**A2 is dropped**, folded into DU plus early cancellation. Bit depth *is*
the waveform choice: Y1→DU, Y2→DU4, Y4→GL16, set per-rect by hints.

`doc/refresh-policy.md` and KOReader's `device.lua` intent mapping are
written in A2/DU/GL16/GC16 terms. Both need rewriting against hints. This
is not hard, but it is not mechanical either — the policy decisions
encoded there were bought with hardware sessions and must be re-derived,
not transliterated.

### D3. Rotation via fbdev is untested upstream

> Nobody rotates via fbdev on his stack (sway does transforms).

Four orientations with autorotation is a **shipped, hardware-validated**
feature of ours (`final4`, 2026-07-19). His stack has never exercised
that path. This is the single most likely place for a nasty surprise,
and it must be an explicit bring-up gate rather than an assumption.

### D4. `-EINVAL` on missing firmware is a worse first-boot failure

Today a missing waveform fails visibly but the system boots. Under
direct mode the EBC probe fails outright: no display. For an operator
installing on their own device (`doc/install.md`) that is
indistinguishable from a brick. Needs either a fallback path, or a
loud pre-flight check, or both — decide deliberately.

### D5. Kernel base — **SIZED 2026-08-25, and it is small**

His tree is `v6.19_ebc_custom`; ours builds 7.1.8. **Port his driver onto
our kernel — do not adopt his kernel.** Our seven-patch stack, ultra
suspend matched pair, and the whole gate apparatus are built around our
base.

The plan called this "the larger of the two rebase surfaces and should be
sized before committing." Sized, from a `--depth 300 --single-branch`
clone at `~/src/reference/hrdl-linux` (2.3 GB; HEAD `819ba1724a6`, which
`git describe` puts at **`v6.19-182-g819ba1724a6`**):

| | |
|---|---|
| commits above `v6.19` | **182** |
| files touched | 12 — **7 of them new** |
| files *modified* | **5**: `drm/Kconfig` (+6), `drm/Makefile` (+8/−2), `rockchip/Kconfig` (+22), `rockchip/Makefile` (+8/−2), `panel-simple.c` (+251, a mode table) |
| total insertions | 5377 |
| his `rockchip_ebc.c` | 2527 (ours is 3481 — his is *smaller*, the pixel work having moved out) |
| new alongside it | `rockchip_ebc_blit_neon.c` 1253, `rockchip_ebc.h` 252, `..._neon.h` 62 |

**Four of the five modified files are build glue.** The textual rebase
surface is therefore close to nothing; the real surface is ~4000 lines of
*new* code compiling against 7.1's DRM.

**Two measurements say that surface is clean.**

1. **`drm_epd_helper.c`: our 7.1-forward-ported copy and his 6.19 copy
   differ by ONE change** — he makes `pvi_wbf_get_mode_index` non-static
   and adds `EXPORT_SYMBOL` so the separate blit module can call it. That
   file needed *zero* API adaptation across 6.19 → 7.1, and our
   forward-port work on it transfers wholesale.
2. **Nine kernel APIs appear in his driver and not in ours** — and ours is
   *proven* to compile on 7.1, so those nine are the entire risk set:
   `drm_client_setup_with_fourcc`, `drm_rect_height`, `drm_rect_width`,
   `drmm_kmalloc`, `drmm_kzalloc`, `kmalloc_array`, `ktime_us_delta`,
   `msleep_interruptible`, `pm_runtime_resume_and_get`.
   **All nine exist in 7.1.8**, checked against the extracted source.
   `drm_client_setup_with_fourcc` — the one that looked risky, being
   recent fbdev-client API — is at `include/drm/clients/drm_client_setup.h`
   in *both* 6.19 and 7.1.8, and he already includes it from that path.
   His tip commit switches to **`scoped_ksimd()`**, which sounds new and
   is: it is in 7.1.8's `arch/arm64/include/asm/simd.h`. He is tracking
   *toward* what 7.1 has.

**What this does NOT establish.** It is a static name-existence check, not
a compile. A name can survive while its signature, its struct layout or
its semantics change, and none of that is covered — nor are macros. The
honest reading is that **no obvious blocker exists**, which is a much
weaker claim than "it will build". The real test is P2, and it is cheap:
graft his files into our 7.1 tree and run `make kernel`.

### D6. Keep 3WIN as a bail-out?

3WIN survives upstream behind `CONFIG_DRM_ROCKCHIP_EBC_3WIN_MODE`.
Keeping it buildable costs little and preserves a retreat if direct mode
disappoints on glass. Recommended, at least through P3.

## The plan

Cheapest decisive things first, in the ladder's order. **Each phase has a
gate; a red gate stops the phase rather than deferring the problem.**

### P0 — offline de-risking, no kernel code *(mostly done, all rung 1)*

- ✅ **Harness goes aarch64.** Done 2026-08-24, `907efce`.
- ✅ **hrdl's tree is reachable and has not moved.** `v6.19_ebc_custom` tip
  is `819ba1724a6f` — byte-identical to the pin in
  `doc/hrdl-evaluation.md`, so that evaluation is current, not stale.
  `pinenote-dist` cloned to `~/src/reference/` (984 KiB; the register's
  `--depth --single-branch` rule matters — sr.ht silently ignores
  `--filter=blob:none`).
- ✅ **THEIR COMPILER RUNS ON OUR WAVEFORM.** This was the input-format
  risk and it is retired: `wbf_to_custom.py` against this device's own
  2 MiB `ebc.wbf` produces a valid **229,584-byte** `custom_wf.bin`,
  magic `CLUT0002`, **14 temperature bins**, first bin 0–3 °C. We now
  have a reference artifact to differential against.
- **Split cross and native build trees.** Still to do. They share
  `build/` today, and a stale aarch64 `.o` breaks the native link with a
  confusing "file in wrong format" — this bit during the 2026-08-24 probe.
- **Port hrdl's `Sim`** into the harness as a reference model. It is a
  dataclass at `wbf_to_custom.py:29` (`outer`, `inner`, `i`, `phases`,
  `history`) — small.
- ✅ **The CLUT differential is built.** `make clut-check` (2026-08-25):
  byte-identical to `wbf_to_custom.py`, with three mutation controls that
  must differ so identity cannot be accidental. See P1.

**D1 is much cheaper than §D1 estimated.** The compiler is **271 lines**
plus a 334-line `read_file.py` WBF parser — and *we already have the
parser*, in C, tested: `wbf-info --dump-lut` decodes a (waveform,
temperature) LUT to `codes[num_phases][from][to]` and cross-checks itself.
So the C reimplementation is run-length encoding per (from,to) pair plus
`CLUT0002` serialisation **on top of a decoder we already trust**, not
605 lines from scratch. Their Python needs numpy and pandas; ours needs
neither.

**Two things the systemd unit told us that the plan had wrong.**
`pinenote-hrdl-convert-waveform.service` runs the compile, then `mv`, then
**`mkinitcpio -P`**, then `modprobe -r rockchip_ebc; modprobe
rockchip_ebc`.

1. The `mkinitcpio` step is because *their* driver needs the firmware in
   the initramfs. **Ours may not**: `pinenote-ebc-modprobe-service-type`
   loads the module from a shepherd one-shot ordered after
   `pinenote-waveform`, so the firmware path is already populated before
   modprobe. Our existing ordering probably accommodates the CLUT compile
   with no initrd work — worth confirming, but it makes D1 smaller again.
2. Their `ExecCondition` is *compile-once-if-absent*, the same shape as
   our waveform installer's "destination exists → exit 0" — which
   `doc/configuration.md`'s neighbour issue #12 §7 already flags as a
   hazard, because a stale artifact then wins forever with no checksum.
   Adding a second derived artifact under the same pattern **compounds an
   existing bug**. Whatever we build should checksum.

**A safety gap was closed before it could bite** (2026-08-25). The CI
gate grepped `\.wbf$|vcom` and **could not see `custom_wf.bin`** — which
is the same calibration data in another encoding, and falls under the
same never-bundle rule. Extended to match `custom_wf` and to reject any
tracked file carrying the `CLUT0002` magic. Done now, while the count of
such files in existence is still zero.

### P1 — the CLUT compiler (D1) — ✅ **compiler done, gate met** (2026-08-25)

Write it in C, cross-built like `pinenote-ebc-dump`, run by a one-shot
before the EBC module loads. Differential-test against `wbf_to_custom.py`
on the host at rung 1.

**Gate:** byte-identical `custom_wf.bin` from the C compiler and the
Python one, on a real `ebc.wbf`. Not "equivalent" — identical.

**Met.** `pinenote/tools/wbf/wbf-clut.c` produces a 229,584-byte
`CLUT0002` file byte-identical to `wbf_to_custom.py`'s on this device's
own waveform, on x86-64 and — cross-built as `pinenote-wbf-clut` and run
under `qemu-aarch64` — on aarch64 as well. `make clut-check` is in
`CHECK_HOST_TARGETS`. No Python, no numpy, no pandas: the decode half is
the lineage's own verbatim `drm_epd_helper.c`, exactly as the plan
predicted, and only the run-length + serialisation halves are new.

**The two quirks the plan did not know about.** Byte-identity was not a
formality. `wbf_to_custom.py`'s "remove suffix" step drops the last run
*unconditionally* (an `enumerate`-index/tuple mix-up), and its 32→16 cell
downsample is four-way lossy, order-dependent, and never clears the cell
before writing. Both are reproduced deliberately, both are written up in
`doc/driver-findings-report.md`, and a third finding fell out alongside
them: `drm_epd_helper.c` never applies the `+ 1` to `temp_range_count`,
so the driver cannot select the file's top temperature range. A
clean-room compiler written to what the reference *means* is wrong here,
which is why the gate had to be identity rather than equivalence.

**What P1 did NOT do.** No service, no image, no initrd work — that is
the next step, and D4 (what a missing or stale `custom_wf.bin` should do
at first boot) has to be decided before it, along with the checksum the
`ExecCondition` note above demands. **And nothing has driven a panel:**
the compiler is proven against the Python and against nothing else.

### P2 — port the driver onto 7.1.8, behind a flavor

Direct mode only. New flavor (`reader-direct`) alongside the shipping
reader, exactly as `reader-debug` exists today, so the production image
is never the experiment. 3WIN kept buildable (D6).

**Gate:** `make kernel` clean; `make check-host` green with the harness
running aarch64-under-qemu; the drain-gate and ordering negative controls
replaced by whatever the new architecture's equivalents are — **a suite
that goes green because its subject vanished is worse than no suite.**

### P3 — bring-up on glass, one variable at a time

Order matters; each step is a separate session with the 2026-08-07
one-variable protocol:

1. Does it probe and display at all (D4's failure mode is here).
2. Static rendering quality vs the LUT path — optics rig, not a webcam.
3. **Rotation, all four orientations** (D3) — the highest-risk item.
4. Suspend/resume with the ultra matched pair intact.
5. Page-turn latency and quality against today's numbers.

**Gate:** parity with the shipping reader on 1–5 before any ink work.
Ink is the *reason*, but a reader that regresses reading to gain writing
is not a trade this project should make.

### P4 — policy rewrite (D2)

Re-derive `doc/refresh-policy.md`'s decisions against hints. Rewrite
`device.lua`'s intent mapping. Re-establish the idle washer and
publish-on-call equivalents.

### P5 — FAST mode and ink

Only now does the thing we came for get built: `DRIVER_MODE_FAST` for
pen-down rendering, stroke capture on top of it. #20's capture, storage
and vectorization work is **independent of all of the above** and can
proceed in parallel from day one — it needs no panel.

## What only hardware can answer

Everything in P3, plus: whether FAST mode's 1-bit output and visible
smear are acceptable for ink in practice; whether 85 Hz is stable on this
panel; and whether the 6×-lower DDR fetch actually removes the starvation
margin or merely moves it.

## Bail-out criteria

State these now, while nobody is invested:

- P0's differential does not converge → we do not understand the
  waveform format well enough. Stop.
- P3 step 3 (rotation) cannot be made to work → the shipped
  four-orientation feature regresses. Stop, or descope orientations
  deliberately.
- P3 step 5 shows page-turn quality worse than today with no path back →
  stop; reading is the product.

Direct mode is a means to handwriting, not an end. If it costs the
reader, it is the wrong trade and the plan should die here rather than
be defended.
