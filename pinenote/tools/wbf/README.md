# wbf — host-side PVI waveform parser tests (offline ladder, rung 1)

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
- 13 temperature bins (0…≥38 °C, 3 °C steps). GC16 needs **131 phases at
  0 °C vs 38 at ≥24 °C** — cold panels take ~3.4× longer per refresh,
  which is why the EBC driver re-reads the TPS65185 temperature on every
  refresh.
- Phase counts at 28 °C: A2=10 (~118 ms), DU=19, DU4=24, GC16/GL16=38
  (~450 ms) — matching E Ink's published mode timings.
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
