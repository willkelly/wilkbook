# rastersim — Gray8→Y4 raster library + waveform simulator (offline ladder, rung 3)

Host-first seed of the reader render pipeline (roadmap track 4): a plain-C,
dependency-free library (`rastersim.[ch]`) plus golden tests. It mirrors the
`rockchip_ebc` driver's **bookkeeping** — Y4 buffer layout, the driver's
quantization modes, prev/next damage semantics, and the decoded waveform
LUT's drive sequences — so pipeline logic can be proven red/green on the
host and the library can later move on-device unchanged.

```sh
# from the repo root:
make rastersim-check [WBF=/path/to/ebc.wbf]
# or here:
guix shell gcc-toolchain python -- make check [WBF=/path/to/ebc.wbf]
```

Without `WBF=` the waveform-dependent tests are skipped with a message (the
waveform is per-device and never committed; see `doc/device-runbook.md`).
With it, the rung-1 tool (`../wbf`, which compiles the kernel's own
`drm_epd_helper.c` out of the forward-port patch — that is why `python` is
in the shell) dumps the GC16/GL16/A2/DU LUTs at 25 °C and `sim-wbf-test`
runs against them.

## What is validated, what is not

Validated (host, deterministic):

- packed Y4 buffer ops: pack/unpack roundtrips, nibble order, rect blits
  with stride and odd-x edge preservation (exhaustive over small rects);
- Gray8→Y4 quantization goldens over a committed 64×64 gradient+checker
  image for all five modes, with driver-exact threshold semantics pinned at
  the boundaries;
- damage model: seeded random sequences of overlapping partial updates
  (batched in flight, completed in shuffled order) compose to exactly the
  same `prev` contents as a per-pixel reference redraw;
- waveform application (with `WBF=`): for the GC16 LUT at 25 °C every
  (from, to) ∈ 0..15² update converges — the state model lands on `to` and
  every emitted per-pixel drive code equals the decoded LUT row, including
  the driver's neutral 0xff tail substitution;
- pinned properties of the PineNote's real waveform (see below).

**Not validated — hardware-only list:** electrophoretic optics. The
simulator applies LUT drive codes to driver bookkeeping; it does not model
ink particle dynamics, so ghosting, temperature drift, DC balance and
actual reflectance stay on the hardware validation list. Also out of scope
here: the EBC hardware's timing/register behavior, and the driver's area
scheduling/splitting logic (that is ladder rung 2).

## RSL1 LUT dump format

Produced by `../wbf/build/wbf-info --dump-lut WAVEFORM_NAME TEMP_C OUTFILE
FILE.wbf`, all fields little-endian:

| offset | size | value |
|-------:|-----:|-------|
| 0 | 4 | magic `"RSL1"` (u32 0x314C5352) |
| 4 | 4 | `num_phases` |
| 8 | 4 | `from_levels` = 32 |
| 12 | 4 | `to_levels` = 32 |
| 16 | `num_phases`·32·32 | `codes[phase][from][to]`, u8 ∈ 0..3 |

Drive codes as pinned from the PineNote file: 0 = neutral, 1 = darken,
2 = lighten; 3 never appears. `from`/`to` are 5-bit waveform states; the
driver's Y4 gray `g` maps to state `2*g` (`drm_epd_lut_convert` keeps only
the even rows/columns when packing the 16×16 LUT the hardware consumes),
which `rs_wf_code_y4()` mirrors.

### How the (from, to) axis order was derived

Getting this transposed poisons everything downstream, so it is pinned
three independent ways:

1. **Code path.** `pvi_wbf_decode_lut` fills the `DRM_EPD_LUT_5BIT` buffer
   as `buf[phase*0x400 + x*0x20 + y]` (x = the raw stream's fast axis,
   transposed to stride 0x20 on decode). `drm_epd_lut_convert` packs the
   even (x, y) entries into the `4BIT_PACKED` buffer the EBC hardware
   consumes as u32 `word[phase*16 + x/2]`, bit `2*(y/2)`. In hardware LUT
   mode (`direct_mode=0`, what `pinenote/services/ebc.scm` ships) the
   driver hands `prev` to `EBC_WIN_MST0` and `next` to `EBC_WIN_MST1` and
   the silicon does the indexing, so software cannot name the axes from
   this alone — but the byte-level relation between the two buffers is
   verified at every dump (`crosscheck-4bit-packed`).
2. **Waveform content.** The file itself names the axes: the final
   non-neutral drive of a sequence physically sets the target state, and
   over every mode it is a function of y alone (ends darken for y=0, ends
   lighten for y=31); DU drives only pairs with y ∈ {0, 31} (E Ink's DU:
   any gray → black/white); A2's two driven pairs come out 1=darken /
   2=lighten, the standard PVI polarity. Hence **x = from (prev), y = to
   (next)**: the decoded 5BIT buffer is `buf[phase*0x400 + from*0x20 +
   to]`, and the packed LUT is `word[phase*16 + prev4]` bit `2*next4`.
3. **Regression tests.** `sim-wbf-test` pins the DU driven-pair shape and
   the end-drive polarity; a transposed dump fails both immediately.

**Driver quirk found while deriving this:** `rockchip_ebc_blit_direct`
(the software-LUT `direct_mode=1` path, unused on the PineNote) reads the
packed LUT as `word[next] >> (2*prev)` — the transpose of the file
semantics above. If direct mode is ever enabled it would apply reversed
transitions; worth a look upstream but harmless in our configuration.
A second quirk: `rockchip_ebc_blit_pixels` gets *neither* edge right —
at an odd `x1` edge it restores the *source's* low nibble (a no-op after
the memcpy, leaking one out-of-clip column of `final` into `next`), and
its odd-`x2` "preserve" targets byte `pitch-1` instead of the clip edge,
which is a no-op for partial-width clips and a 1-byte heap overrun when
the clip touches the last row with `x1 >= 2` (see
`pinenote/tools/ebc-logic/README.md` Findings (c)/(d) for the full
analysis with patch line numbers). `rs_y4_blit` implements correct edge
preservation on both edges (the damage-composition test depends on it),
so the library intentionally diverges from the driver there — note for
the future `EXTRACT_FBS` hardware oracle: odd-edge clips will show
systematic one-column differences against the device unless the quirk is
emulated for comparison runs.

## Library overview (`rastersim.h`)

- **Y4 buffers** — packed 2 px/byte, low nibble = even x (the driver's
  prev/next layout), 0 = black … 15 = white. `rs_y4_pack/unpack/get/set/
  to_gray8`, `rs_y4_blit` (same-coordinate rect copy, driver's blit_pixels
  model).
- **Quantization** (`rs_gray8_to_y4`) — all applied to `g >> 4` with the
  driver's exact comparisons and defaults (`rs_quant_params`):
  - `RS_QUANT_SHIFT`: plain `g >> 4`;
  - `RS_QUANT_BW`: driver `bw_mode=2`, `v4 >= bw_threshold(7)`;
  - `RS_QUANT_ORDERED_BW`: driver `bw_mode=1`, the driver's 4×4 pattern
    indexed `pattern[x&3][y&3]`, `>=` semantics;
  - `RS_QUANT_FOURTONE`: driver `bw_mode=3`/DU4 prep, strict `<`
    thresholds (4/7/12) onto 0/5/10/15;
  - `RS_QUANT_FS`: Floyd–Steinberg error diffusion to 16 levels. Chosen
    because it is the standard error-diffusion for e-ink text/image
    rendering (no fixed-pattern texture like the ordered dither) and is
    exactly reproducible: integer arithmetic, plain raster order, error
    split 7/16, 3/16, 5/16 + remainder so the diffused error sums exactly.
    Levels are `q = round(v*15/255)`, reconstruction `q*17`, so multiples
    of 17 quantize losslessly.
- **Screen state** (`rs_screen`) — the driver's ctx model: `submit` =
  `next[clip] ← final[clip]` (partial_refresh frame 0), `complete` =
  `prev[clip] ← next[clip]` (after the last phase).
- **Update stepping** (`rs_update`) — mirrors the partial_refresh frame
  loop for one area: real LUT phases `0..N-2`, then the 0xff neutral
  substitution for the last two frames (sound because the last decoded
  phase is all-neutral in the real file — asserted), then completion;
  `num_phases + 1` frames total, per-pixel codes from
  `lut[phase][2*prev][2*next]`.

## Golden files and regeneration

`testdata/gradient-checker.pgm` is generated by `gen-testimage.c` (rows
0–31 horizontal gradient, 32–47 8×8 B/W checker, 48–63 4×4 checker of
64/192 to exercise the thresholds away from the extremes). The committed
goldens are `testdata/quant-goldens.sha256` (all five modes) and
`testdata/quant-shift.hex` (full od dump of the shift mode, so a failure
shows *where* it diverged). `run-tests.sh` regenerates the image and all
five outputs on every run and compares.

To regenerate after an intentional change to the image or a quantization
mode:

```sh
guix shell gcc-toolchain -- make regen-goldens
```

and commit the `testdata/` changes with a note on why the goldens moved.

## What the PineNote's waveform actually does (25 °C, SHA `ba3d4883…`)

Pinned by `sim-wbf-test` (INFO lines first, assertions second — measured
from the file, not folklore):

| mode | phases | driven Y4 pairs | from==to driven | last phase neutral |
|------|-------:|----------------:|----------------:|:------------------:|
| GC16 | 38 | 256/256 | 16/16 | yes |
| GL16 | 38 | 255/256 | 15/16 | yes |
| A2 | 10 | 2/256 | 0/16 | yes |
| DU | 22 | 30/256 | 0/16 | yes |

Notable, versus common folklore:

- **GC16 drives every pair, including from==to.** Unchanged pixels are NOT
  neutral at the LUT level; skipping them is the driver's `diff_mode`
  masking, not the waveform.
- **GL16 drives from==to for every gray except white→white** — exactly one
  neutral pair, (15, 15). "GL leaves unchanged pixels alone" is only true
  for the white background.
- **A2 is stricter than "B/W transitions": only 0→15 and 15→0 are driven.**
  Even 0→0/15→15 are neutral, and every pair involving an intermediate
  gray is neutral — which is why the driver's A2 path binarizes buffers
  first (`prepare_prev_before_a2`, ordered dither).
- DU is textbook: any gray → {black, white}, diagonal neutral.
- Code 3 never appears; the last decoded phase of every mode is
  all-neutral, which is what makes the driver's phase-0xff tail
  substitution sound.

These are properties of this waveform family (and the assertions guard
our decode chain against axis transposition); a different panel's file may
legitimately differ — the INFO lines print whatever the loaded file does.

## Later pairing

The `EXTRACT_FBS` ioctl on the device exposes the driver's live
prev/next/final buffers; the state model here is designed to diff against
those as a hardware-differential oracle (see ladder rung 3's follow-up in
ROADMAP.md section 3 and track 4).
