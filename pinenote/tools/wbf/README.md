# wbf — PVI waveform parser tests and the CLUT compiler (offline ladder, rung 1)

Two programs share this directory because they share a decoder:
`wbf-info`, the host-side inspector/test harness, and **`wbf-clut`**, the
CLUT compiler that hrdl's direct-mode driver needs on the *device*
(see "CLUT compiler" below).

Compiles the **verbatim** `drm_epd_helper.[ch]` out of
`pinenote/patches/linux-pinenote-7.0-forward-port.patch` (extracted at
build time, so the tests always exercise exactly the code the kernel
ships) against a ~100-line kernel-API shim, and inspects a PVI `.wbf`
waveform file the way `rockchip_ebc` does on the device
(`DRM_EPD_LUT_4BIT_PACKED`, 256 max phases).
Extraction first validates every new-file hunk's advertised line count, so
the host rung fails if the kernel patch would truncate or overrun a source.

```sh
# from the repo root:
make wbf-check WBF=/path/to/ebc.wbf
# or here:
guix shell gcc-toolchain python -- make check WBF=/path/to/ebc.wbf
```

The waveform is per-device and never committed (repo policy); use the
backup ledger in `doc/device-runbook.md` or pull
`/lib/firmware/rockchip/ebc.wbf` from the running device.

## What the PineNote's waveform looks like (2026-07-04, SHA `ba3d4883…`)

- mode-version `0x19` (5-bit LUTs), AF waveform, 85 Hz, panel string
  `…R474_AF4831_ED103TC2C6_VB3300-KCD_TC…`.
- **14 temperature ranges** delimited by 15 temperatures
  (0, 3, …, 33, 38, 43, 48 °C), of which the driver can only ever select
  13. The header stores `temp_range_count` as count − 1, the same
  convention it uses for `mode_count` (raw 7, yet the driver itself reads
  DU4 from mode index 7); `drm_epd_helper.c` applies the `+ 1` to neither,
  so `pvi_wbf_get_temp_index` tops out at index 12 and the real 43–48 °C
  range is unreachable. This README said "13 temperature bins" until
  2026-08-25, when the CLUT differential surfaced it — the write-up is in
  `doc/driver-findings-report.md` and it is **not** patched here (report,
  don't patch). GC16 needs **131 phases at 0 °C vs 38 at ≥24 °C** — cold
  panels take ~3.4× longer per refresh, which is why the EBC driver
  re-reads the TPS65185 temperature on every refresh.
- Phase counts at 28 °C: A2=10, DU=19, DU4=24, GC16/GL16=38. Those match
  E Ink's published mode timings (~120 / ~260 / ~450 ms) **at the 85 Hz the
  waveform declares** — independent confirmation of its design point. But the
  driver never reads that field and clocks the panel at 63.744 Hz
  (`doc/refresh-policy.md`), so the delivered durations are 1.33× longer:
  A2 ~157 ms, DU ~298 ms, DU4 ~377 ms, GC16/GL16 ~596 ms.
- Temperatures below the first bin map to index −1 → the driver's
  `set_temperature` returns `-ENOENT` and keeps the previous LUT (the
  edge hrdl's tree clamps at ≥19 °C).

`wbf-info FILE.wbf [TEMP_C]` prints all of the above for any file;
`run-tests.sh` pins the PineNote-specific golden values plus generic
invariants (all 9 modes decode, A2 < GC16, all bins decode,
deterministic output).

## LUT export (`--dump-lut`)

`wbf-info --dump-lut WAVEFORM_NAME TEMP_C OUTFILE FILE.wbf` writes the
decoded LUT for one (mode, temperature) pair in the RSL1 format consumed
by `pinenote/tools/rastersim` (rung 3): a 16-byte little-endian header
{magic `"RSL1"`, num_phases, 32, 32} followed by u8 drive codes indexed
`[phase][from][to]` over the 5-bit waveform states (Y4 gray `g` = state
`2*g`). Before writing, the tool re-derives the driver's `4BIT_PACKED`
buffer and verifies the axis relation byte-for-byte
(`crosscheck-4bit-packed`), and checks the beyond-`num_phases` padding is
neutral (what the driver's phase-0xff tail substitution relies on). The
from/to axis derivation — including the `blit_direct` transpose quirk it
turned up — is documented in `pinenote/tools/rastersim/README.md`.

## CLUT compiler (`wbf-clut`)

```sh
make clut-check WBF=/path/to/ebc.wbf CLUT_REF=~/src/reference/pinenote-dist/bin
```

hrdl's direct-mode `rockchip_ebc` `request_firmware()`s
`rockchip/custom_wf.bin` and **fails probe with `-EINVAL` without it**
(`doc/direct-mode-adoption.md` D1/D4). Upstream compiles that file on the
device with `wbf_to_custom.py`, which needs Python + numpy + pandas; our
reader image has no interpreter at all beyond KOReader's bundled luajit,
so `wbf-clut` is the C replacement. It is cross-built for the device as
the `pinenote-wbf-clut` Guix package and, since 2026-08-25, is **wired
into exactly one flavor** — `pinenote-reader-direct`, both as the
compiler behind `pinenote-ebc-clut-service-type`'s boot one-shot and as
an on-device console fallback. No shipping flavor references it.

```
wbf-clut [-v] INPUT.wbf OUTPUT.bin
```

The decode half is not reimplemented: `wbf-clut.c` `#include`s the same
extracted `drm_epd_helper.c` `wbf-info` does and drives its
`drm_epd_lut_update()` directly, so only the run-length summarise and the
`CLUT0002` serialisation are new code. Output layout (all little-endian):
8-byte magic `CLUT0002`, `u32 n_luts`, then `n_luts` × 16398 bytes of
`{i32 temp_lower, i32 temp_upper, u8 offsets[6], u8 cells[16][16][64]}`.
On the PineNote that is 14 bins and **229,584 bytes**.

**The gate is byte-identical output, not equivalent output.**
`wbf_to_custom.py` carries two bugs (an unconditional drop of the last
run in `table_summarise`, and an order-dependent 32→16 cell collision
that never clears the cell) whose *behaviour* `wbf-clut` reproduces
deliberately — a compiler written to the reference's intent produces
different bytes and would silently change the shipped waveform. Both are
written up in `doc/driver-findings-report.md` and queued in
`doc/upstream-register.md`; **do not "fix" them here.**

`run-clut-tests.sh` brackets the differential so it cannot pass
vacuously. Without any reference it still rejects an empty or degenerate
CLUT (magic, exact size, LUT count vs the header, offsets ascending from
1 and staying inside the 64-cell axis, a phase-count cross-check against
`wbf-info`, determinism, and refusal of a truncated waveform). Then three
`--mutate=` variants — `drop-suffix-off`, `collision-first-wins`,
`axis-swap`, one per reproduced behaviour — must each **differ**; they
exist only in a `-DWBF_CLUT_MUTATIONS` self-test binary, and the suite
proves the shipping binary rejects the flags. The output is per-device
calibration data in another encoding: it is written to a temp dir, never
the repo, and CI rejects both the name and the `CLUT0002` magic.
