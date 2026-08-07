# Does bl31's ultra branch kill rails by itself? (2026-08-07, offline)

The gating question for ultra-suspend was *"we can tell firmware ultra
without adopting any rail kill"* — but that only holds if **bl31 does not
kill rails on its own**. Nobody had checked, and the reason it mattered
is sharp: `RKPM_SLP_PMIC_LP` is already set in the config word we send
today, and bl31's own banner prints `pmic: 0x14, 0x25`, so the firmware
demonstrably talks to the PMIC. "No rail change in DT" was not evidence
of "no rail change".

**Answer: the ultra path performs no PMIC access.** Static, offline, no
device time.

## Method

Source: `current-uboot.img`, sha256
`078f81dcab0a41cc…` — the exact FIT recorded in `doc/device-runbook.md`
as the deployed U-Boot. The 4 MiB image holds two mirrored copies; all
offsets below are from the first.

FIT parse (the header is an ordinary FDT, `totalsize=0x1d3000`):

| node | data-position | size | load |
|---|---|---|---|
| `uboot` | `0xe00` | `0x12a2e0` | `0xa00000` |
| `atf-1` | `0x12b200` | `0x27000` | `0x40000` |
| `atf-2` | `0x152200` | `0x4c6b` | `0x69000` |
| `atf-3` | `0x157000` | `0x2000` | `0xfdcd0000` (PMU SRAM) |

Disassembled with `aarch64-linux-gnu-objdump -D -b binary -m aarch64`
at the correct `--adjust-vma` per segment.

The banner format string is at file `0x15070c` → VA `0x6550c`:

    PM-STATE: %s (ultra: %lld, mem: %lld, cfg: 0x%x), pmic: 0x%02x, 0x%02x

**Two corrections to earlier readings of that line.** `%lld` twice
confirms `ultra:` and `mem:` are **cumulative counters**, not mode flags
— `ultra: 0` is a counter that has never incremented, not a bit waiting
to be set. And the printing function reads PMIC registers `0xb5`/`0xb6`
from device `0x20` (`bl 0x550bc` twice, at `0x5d340`-`0x5d360`) purely to
report them; that is where `pmic: 0x14, 0x25` comes from.

Also present, and the reason to keep going:

    0x15069e: (Feature: ultra suspend

**The deployed 2022-06-09 bl31 has ultra-suspend compiled in.** It is not
a question of whether the firmware knows the mode.

## The finding

The `(Feature: ultra suspend` string is referenced once, at `0x5d1e0`,
inside the function starting at **`0x5cf08`**. Three independent checks
on that function:

1. **Call-graph taint.** Seeding from the three PMIC-I2C helpers
   (`0x550bc` read, `0x55100` init, `0x55178` stop) and computing
   transitive callers gives 14 PMIC-touching functions. `0x5cf08` is not
   one of them, and none of its 11 direct callees (`0x55bbc`, `0x5d66c`,
   `0x60f54`, `0x5faac`, `0x5b7e4`, `0x61018`, `0x58ed0`, `0x55eb0`,
   `0x54cf0`, `0x59f48`) is tainted.
2. **No indirect calls.** The function's range `0x5cf08`–`0x5d304`
   contains no `blr`/`br`. Static tracing is therefore *complete* for it
   — nothing can hide behind a function pointer.
3. **No I2C MMIO.** Reconstructing every 64-bit immediate built by
   `mov`/`movk` in the range gives the MMIO bases it touches:
   `0xfdc20000` (PMUGRF), `0xfdd00000` (PMU), `0xfdd10000` (PMUCRU),
   `0xfdd90000` (GPIO0/PMU IO), `0xfdcc0000`, `0xfdcd0000`, `0xfead0000`,
   `0xfdc00000`. **`0xfdd40000` — I2C0, the RK817's bus — is absent.**

`atf-3`, the PMU-SRAM resident code that actually runs the power-down
stages, was checked the same way: its bases are `0xfdd90000` (x9),
`0xfdd20000`, `0xfe100000`, `0xfe200000`, `0xfe250000`, `0x01e00000`.
**No I2C0 either.**

`atf-2` does carry two literal `0xfdd40000` words — it holds the I2C bus
descriptor that `atf-1`'s helpers use (the PM-STATE function loads its
handle from `0x69010`). So bl31 *can* reach the PMIC, and does, to read
status for the banner. The precise claim is therefore **not** "bl31 never
touches the PMIC" but "**the ultra path does not**".

## What this does and does not license

**Does:** it retires the specific fear that telling firmware `ultra`
would, by itself, drop `vcc_3v3_pmu` and take the GPIO0 wake bank with
it. A firmware-word-only experiment — no DT rail payload — is not
silently a rail-kill experiment.

**Does not:** the ultra function writes GPIO0/PMU-IO space
(`0xfdd90000`, three sites) and the SRAM resident code writes it nine
times. That is wake/pad configuration, not a regulator kill, but it is
the same pad bank every armed wake source runs through, so "no rail
change" still does not mean "wake definitely survives". That question is
unchanged and remains supervised-UART territory.

**Also does not:** prove the firmware *honours* `LINUX_PM_STATE=5`. It
proves the branch exists and is PMIC-clean. Whether the SMC path reaches
it is still only answerable on hardware — but the banner prints *before*
the power-down stages, so a supervised capture answers it even if the
device never resumes.

## Reproducing

Everything here is offline and re-runnable from the backed-up FIT; the
scripts used (`findref.py`, `callgraph.py`, `taint.py`) are simple enough
to rewrite from this description, and the numbers above are the check
values — if a future firmware moves them, the analysis must be redone
rather than assumed.
