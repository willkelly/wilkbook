# Adopting direct mode: the plan

**Status: plan, not a decision record.** Written 2026-08-24, after the
operator named handwriting as a product direction that the current display
path cannot support. Built so far (all 2026-08-25): P1's CLUT compiler,
P2's `linux-pinenote-hrdl-direct` kernel package, and P2a's modprobe
options. **Nothing has ever run** — not loaded, not probed, not bound, no
frame on any panel — and P3 onwards is still a plan. The bail-out
criteria at the bottom still apply.

Read `doc/hrdl-evaluation.md` first — this document assumes it.

**Decision (operator, 2026-08-25): we ship ONE image.** The
`reader-direct` flavor is **scaffolding for the experiment, not a product
line**. The gate is embrace-or-reject, decided on glass: *embrace* means
the `reader` flavor itself moves to the direct-mode kernel and the
scaffolding is deleted; *reject* means the same deletion with the
shipping driver unchanged. Either way, the next prealpha tag ships
`reader`, singular — never a direct/non-direct pair. Nothing
direct-mode-related may therefore grow roots the deletion would tear:
no doc may tell a user to choose between flavors, and no service may
exist only in the direct flavor without a note that it dies or graduates
with the decision.

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

### D6. Keep 3WIN as a bail-out? — **the premise was wrong**

3WIN survives upstream behind `CONFIG_DRM_ROCKCHIP_EBC_3WIN_MODE`, and
this plan said "keeping it buildable costs little."

**It is not buildable.** Compiling his tree against 7.1.8 with
`CONFIG_DRM_ROCKCHIP_EBC_3WIN_MODE=y` fails in
`rockchip_ebc_blit_neon.c`, and not on anything to do with 7.1:

```c
#ifdef CONFIG_DRM_ROCKCHIP_EBC_3WIN_MODE
        if (!direct_mode) {
            vst1q_u8(phases_line, vshrq_n_u8(q8_inner_new, 6);   /* 2 opens, 1 close */
        } else
#endif
```

An unbalanced paren, plus `direct_mode` undeclared in that translation
unit — both wholly inside the `#ifdef`. A missing parenthesis cannot ever
have compiled, so **that configuration has never been built**, which fits
a tree whose default is direct mode.

So the retreat 3WIN was supposed to provide costs a repair, not nothing.
**The real bail-out is our own driver**, which we keep and which is the
shipping one — a strictly better retreat than a config of his we would
have to fix first. Reported upstream rather than patched.

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

**Compile gate MET, 2026-08-25.** Grafted his 12 files into a clean
7.1.8 tree and cross-compiled with `aarch64-linux-gnu-`:

- the 366-line patch for the **5 modified files applies clean** — no
  conflicts at all, confirming D5's "the textual surface is nothing";
- **all three objects build in the direct-mode configuration**:
  `drm_epd_helper.o` (25,792 B), `rockchip_ebc.o` (173,296 B),
  `rockchip_ebc_blit_neon.o` (75,528 B, `ELF aarch64 relocatable`), with
  **one** warning (`unused variable 'frame_counter'`).

**What that does and does not prove.** It proves ~4000 lines of his new
code compile against 7.1.8's headers — which is exactly what D5's static
name check could not, since a name can survive while its signature or a
struct layout changes. It does **not** prove the module links, probes,
binds, or works, and the build used arm64 `defconfig` plus minimal
enables rather than our `pinenote_defconfig` alongside our other six
patches. Those are the next steps, not this one.

**Built in OUR kernel package, 2026-08-25.** The compile above used
arm64 `defconfig`; this is the real thing — `pinenote_defconfig`, our
seven patches, his driver, as `linux-pinenote-hrdl-direct` in
`pinenote/packages/kernel.scm` (the `linux-pinenote-debug` shape: inherit,
append one patch).

```
Image                       20,195,840 B
drm_epd_helper.ko               40,368 B
rockchip_ebc.ko                217,152 B
rockchip_ebc_blit_neon.ko       88,184 B
rk3566-pinenote-v1.{1,2}.dtb    63,713 B each
EXIT=0, zero errors, one unused-variable warning
```

**The modules LINK, and modpost resolves the cross-module symbols** —
`rockchip_ebc.ko` imports `rockchip_ebc_schedule_advance_neon` and
`drmm_epd_lut_*` from the other two. That is what an object-only build
cannot show, and it is why his `EXPORT_SYMBOL(pvi_wbf_get_mode_index)`
exists. `CONFIG_DRM_ROCKCHIP_EBC_3WIN_MODE` lands **off** under
`olddefconfig`, which is necessary given D6.

The swap is `pinenote/patches/linux-pinenote-7.1-hrdl-direct-mode.patch`:
**6194 lines, 11 files**, applying after our seven. One hunk is
hand-merged — his `rockchip/Makefile` context did not match because our
forward-port already adds `rockchip_ebc.o` there. The merge keeps our line
and adds his NEON object with its flags: the blitter needs
`-mgeneral-regs-only` **removed** and `CC_FLAGS_FPU` added, since kernel
code is otherwise built with no FP registers.

**The shipping kernel's derivation is unchanged** — nothing here reaches
an image, and no flavor references the variant.

**One gap found while doing it:** his `v6.19_ebc_custom` branch contains
**no EBC device-tree node** and touches no DTS at all, so it cannot bind
on its own — he must compose branches. It means the third clock the
evaluation cites (`cpll_333m` for direct mode, DTS commit `9444147d35a2`)
is on a branch we have not identified yet.

**That gap is not harmless, corrected 2026-08-25.** The note above said
"for us that is harmless (we have the node)". We have *a* node, and it is
the wrong one: our forward-port's `ebc@fdec0000` declares
`clock-names = "hclk", "dclk"` and nothing else, while his probe does a
hard `devm_clk_get(dev, "cpll_333m")` and `dev_err_probe`s on failure
(`rockchip_ebc.c:2391`). **The module cannot probe on our device tree.**
It is a small DT change, but it is a blocker that has to be named before
P3 step 1, and it is a second reason — alongside `custom_wf.bin` — that
nothing here has been near a panel.

### P2a — module parameters (blocker 1) — **decided 2026-08-25**

A kernel that builds still needs to be *told* something, and our nine
shipped `rockchip_ebc` parameters are aimed at a different driver.

**First, a correction to the premise.** The working assumption was that
our options "would fail the module load". They would not.
`unknown_module_param_cb()` (7.1.8, `kernel/module/main.c:3366`)
`pr_warn`s `unknown parameter '%s' ignored` and **returns 0**. So the
module would load *successfully* with eight of nine intents discarded and
the ninth accepted into dead code. That is strictly worse than a refusal,
and it is the reason this needed a gate rather than a comment.

**The real parameter sets**, derived from `module_param*()` registrations
rather than `modinfo -p` (see below for why that distinction matters):
ours registers **26**, his registers **16** in the configuration we
build. Seven names appear in both (`bw_threshold`, `dclk_select`,
`delay_a`, `hskew_override`, `limit_fb_blits`, `no_off_screen`,
`temp_override`) — but of the **nine we actually ship**, exactly one is
in his set, and it is dead code there.

| our option | fate under his driver |
|---|---|
| `direct_mode=0` | registered only under `CONFIG_DRM_ROCKCHIP_EBC_3WIN_MODE`, which does not compile (D6) — and inverted in meaning |
| `auto_refresh=0`, `refresh_threshold=60` | gone; he has no threshold-fired auto-global at all |
| `panel_reflection=1` | gone |
| `prepare_prev_before_a2=0` | gone with A2 (D2) |
| `refresh_waveform=6` | gone — his `GLOBAL_REFRESH` is **hard-coded GC16** |
| `defio_delay_ms=250` | gone — no knob; `drm_fbdev_shmem`'s `HZ/20` stands |
| `split_area_limit=0` | **a mirage** — see below |
| `dclk_select=0` | accepted, and never read in direct mode |

**`split_area_limit` is not shared, it only looks it.** `modinfo -p`
prints `parm` modinfo tags, which come from `MODULE_PARM_DESC` — and his
driver carries `MODULE_PARM_DESC(split_area_limit, ...)` on top of
`module_param(limit_fb_blits, ...)`, a description left behind by a
rename. So `modinfo -p` advertises a parameter the module will not accept
and hides the one it will. Transliterating our value into the "renamed"
parameter would be worse than dropping it: `limit_fb_blits=0` means
*allow zero framebuffer blits*, i.e. a panel nothing ever reaches
(`rockchip_ebc.c:1846`). Logged as `doc/upstream-register.md` item 16 and
pinned as `quirk:stale-parm-desc`.

**`dclk_select` is the trap worth reading twice.** It is a real parameter
of his driver, it accepts our value, it appears in sysfs — and
`rockchip_ebc_set_dclk()` returns **before** the `switch (dclk_select)`
whenever `direct_mode` is true, which for us is always. #23's glass
measurement (`dclk_select=1` → `cpll_333m` at 250 MHz → 79.68 Hz) does
not carry over, and the reason is structural rather than a matter of
degree:

| | 3WIN / LUT mode | direct mode |
|---|---|---|
| `SDCLK_DIV` | `pixels_per_sdck - 1` = 7 | **0** |
| `dclk` | 200 MHz (or 250 at `dclk_select=1`) | **34 MHz**, hard-coded |
| panel SDCK | dclk ÷ 8 = 25 MHz (31.25 at 250) | = dclk = **34 MHz** |
| frame rate | 63.7 Hz (79.68 at 250) | **~85 Hz** |

The 33.33 MHz `cpll_333m` in his DTS is not a mistake by a factor of
eight; it is the parent rate for a dclk that has become the source-driver
clock itself. The ~85 Hz the whole swap is for arrives from that line of
`rockchip_ebc_set_dclk()`, with no module parameter involved.

**The decision: the direct-mode options set no parameters at all.** They
carry the `softdep panfrost pre: rockchip_ebc` guard and nothing else.
Every one of his sixteen keeps its driver default, each for a stated
reason recorded in `pinenote/services/ebc-direct.scm`. The two that took
actual argument:

- **`redraw_delay`** — ayakael's `pinenote-dist` ships `redraw_delay=200`
  against a driver default of 0, and that is the *only* one of his four
  shipped options that changes anything (the other three are the
  defaults written out). It schedules a periodic top-up drive of every
  `REDRAW`-hinted pixel, ~2.35 s apart at 85 Hz. We keep 0, because our
  display policy is that **userspace owns every drive** — the same
  2026-07-12 optics finding 10 that makes us ship `auto_refresh=0` —
  and because its power and DDR-fetch cost is unmeasured on the one axis
  with a known silent failure mode.
- **`shrink_virtual_window`** — off, as hrdl ships it. Recorded as the
  *first* thing to try if direct mode shows corruption, since it cuts
  DDR fetch with damage area, but a bring-up default is not where an
  experiment belongs.

**Where it lives, and why not next to the shipping options.** The
service type `pinenote-ebc-modprobe-service-type` gained a real
configuration record with an `options` field, defaulting to the shipping
text — so `base.scm` is unchanged and the reader system derivation is
byte-identical (verified: `f849a8rc…-system.drv` before and after). The
direct-mode value lives in a new `(pinenote services ebc-direct)`, not in
`ebc.scm`, because `make settings-check` requires **exactly one**
`options rockchip_ebc` line in `ebc.scm` — that string has three
build-time copies it holds in agreement, and a second unrelated string
there would break a gate that is right to be strict. Two *service types*
were rejected outright: both would extend `etc-service-type` with the
same `modprobe.d/rockchip_ebc.conf`, so instantiating both collides by
construction. **This is not issue #12 step 3** — no schema, no
validation, no p7 override; it is a Guix-level field where there was a
constructor that ignored its argument.

**Gate:** `make ebc-modprobe-options-check` (in `CHECK_HOST_TARGETS`).
It reconstructs each driver's `rockchip_ebc.c` from its own patch —
verified byte-identical to hrdl's real file, 87,016 bytes — reads the
`module_param*()` registrations with `#ifdef` resolution that **refuses**
rather than guesses at an unknown guard, and checks each options string
against the driver it is for. Since the direct set is deliberately
empty, the load-bearing assertion is the **positive control**: the
*shipping* string, checked against his driver, must be rejected, and it
is — 8 of 9 names unknown. Plus the `quirk:stale-parm-desc` membership
pin, a 3WIN-forced-on control proving the `#ifdef` logic is real, a
sha256 tripwire on the shipping text, and a `guix repl` step that
actually loads the new module (nothing else imports it, so no build
would).

**What this does NOT solve.** Three things, all found while doing it:

1. **On our boot path `/etc/modprobe.d` is nearly inert.** The initrd
   raw-loads `rockchip_ebc`, so parameters land through
   `pinenote-apply-ebc-params` writing sysfs. That one-shot hard-codes
   our nine names and **silently skips** a name whose sysfs file is
   absent, then exits 0. Against his driver it would apply nothing and
   report success. A direct-mode flavor needs its own params one-shot, or
   none — it must not inherit that one unexamined.
2. **`refresh_waveform=6` has no successor.** Global refresh is
   hard-coded `GC16` in his loop. The GL16 wash — no white flash, bought
   with hardware sessions — is a driver change or a CLUT change under
   direct mode, not a parameter. This is D2 becoming concrete.
3. **His fbdev client is forced to `RGB565`.** He calls
   `drm_client_setup_with_fourcc(drm, DRM_FORMAT_RGB565)`; we call
   `drm_client_setup(drm, NULL)`, which takes the plane's preferred
   format — `DRM_FORMAT_XRGB8888`, and KOReader runs
   `framebuffer_linux` on a **32bpp XR24** `/dev/fb0`
   (`doc/koreader-spike.md`). A 16bpp `/dev/fb0` is a different
   framebuffer for every consumer we have. Alongside it, his off-screen
   firmware is `rockchip_ebc_default_screen_x4y4.bin` at one byte per
   pixel where we install a 4bpp `rockchip_ebc_default_screen.bin`, so
   his request misses and he memsets white. Neither is fatal, and
   neither is a parameter.

Nothing here has loaded, probed or bound. It is a configuration derived
from source, gated offline.

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
