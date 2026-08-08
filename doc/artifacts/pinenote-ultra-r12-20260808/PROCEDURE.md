# R12 — rails-off ultra, hrdl's configuration

**The question:** does the only community-working ultra configuration wake
on our bl31 + 7.0.11 stack? R11 established that with the rails ON,
firmware arms GPIO0 wake identically for `mem` (which wakes) and `ultra`
(which does not) — the failure is downstream of arming, and the rails are
the entire remaining difference from hrdl's working device.

**Image:** `pinenote-reader-ultra` — the reader plus
`linux-pinenote-7.0-ultra-rails.patch` (three `*_pmu` rails
off-in-suspend, `sdmmc1 cap-power-off-card`, the cyttsp5 resume
workaround), auto-suspend service **absent**, firmware diagnostics on
from the cmdline. Quarantined by `make ultra-quarantine-check`.

**Risk bound, accepted by the operator 2026-08-08:** worst case is a
ten-second power-button hold. The review verified the bound: no
persistent state sits under the three rails (the fuel gauge is on
vcc_bat inside the rk817; TPS65185 VCOM NVM is not written in this path;
eMMC is on vcc_3v3/DCDC4, not a payload rail), and the panel holds its
image unpowered. Two accepted uncertainties, on the record: rk817
register retention across a forced power-off, and vdda_0v9_pmu-off vs
the SoC's PMU-domain analog — both bounded only by hrdl's
board-identical device recovering routinely.

## Rules that differ from every previous session

1. **Every suspend is armed. There is no mem control on this image.**
   `regulator-state-mem` keys on the Linux suspend state, not the SIP
   word — so an unarmed `echo mem` here is rails-off + `LINUX_PM_STATE=3`,
   a combination neither we nor hrdl have ever run (their DT override
   makes it structurally unreachable on their device). Expect it not to
   resume; if it happens by accident, record it as non-evidence.
   R11 Phase 1 stands as the mem control; it ran on the same hardware.
2. **The health gate replaces R11's "abort if mem does not wake":**
   boot-clean + UART proven both directions + SSH up + the PMIC banner
   go/no-go below.
3. **Arm before every attempt, and re-arm after any failure.** The arm is
   one-shot and consumed even by an aborted entry. `ultra-run.sh <label>
   5 1` does the write and echoes the readback.

## The go/no-go banner (pre-registered before the session)

bl31's banner prints the rk817 `POWER_SLP_EN` registers. R11's rails-on
runs read `pmic: 0x14, 0x25` — word 1 bits 0/2/5 are LDO_REG1/3/6,
**exactly the three rails**. The payload clears those three bits and
touches nothing in word 0. Therefore, at the first suspend entry:

    expect:  pmic: 0x14, 0x00   -> the rails payload REACHED the PMIC; proceed
    if:      pmic: 0x14, 0x25   -> WRONG IMAGE or stale DTB; ABORT, press
                                   nothing, diagnose the deployment

This is the deployment check battery current cannot provide (rails-on
ultra already measured ~3 mA, indistinguishable from hrdl's figure).

## Reading the dead window

**UART silence is ambiguous by design here**: `vcc_3v3_pmu` powers the
UART2 console pads. A dark console during rails-off suspend is expected,
not evidence. Judge outcomes by whether the device *boots or resumes*,
never by console output during the window. Do capture the terminal stage
trace at entry and compare character-by-character with R11's
`…789sram2wfi` — a different terminal stage is localizing evidence.

**RTC-no-wake is NOT a failure result.** With the GPIO0 pad bank
unpowered, the rk817 INT line cannot deliver a wake through its normal
path *by construction*. Score stimuli independently; do not let a dead
RTC mask a live button.

## The session

0. Preconditions as R11 (battery ≥90% before UART, both-direction UART
   proof, backups, operator present). Deploy via
   `write-os2-verified.sh`, expected SHA from `SHA256SUMS`.
   Boot; confirm hostname `pinenote-reader-ultra`, confirm
   `sleep_debug_arm=1` already set (cmdline), confirm the autosuspend
   daemon is absent (`herd status` has no pinenote-autosuspend).
1. **A1 — armed ultra, RTC +90 s, hands off.** Read the banner
   (go/no-go), the firmware decode, the stage trace. Wait to +120 s.
2. **A2 — the button.** Short press; wait 15 s; second short; 1 s press;
   3 s press. The PWRON path is PMIC-internal on vcc_bat — this is the
   **primary expected wake** (hrdl's commit names no wake source; their
   device resumes, and this is the only path that survives rails-off).
3. **A3 — if nothing woke:** the ≥40-min gauge bracket (the only
   rails-off ultra current figure anyone will get), then the single
   budgeted long-press.
4. **Forensics, actually executed this time** (R11 planned, did not run):
   interrupt autoboot at the U-Boot prompt and read rk817 `INT_STS`
   0xf8/0xfa/0xfc — a pending RTC_ALARM bit is the one race-free probe
   proving the PMIC fired while the SoC ignored it. Then boot os1,
   harvest `/data/wilkbook/ultra-*.log`, capture the full cold-boot UART
   from the first byte (third data point on `suspend_info:0x8c`).

## Decision table (pre-committed)

| outcome | conclusion |
|---|---|
| banner ≠ `0x00` | deployment failure; nothing else in the session is evidence |
| button wakes (RTC does not) | **ultra solved for the user-facing case.** The RTC-backstop autosuspend model does NOT carry over — redesign the daemon's backstop before any adoption. |
| RTC also wakes | full backstop model survives; ultra is adoptable as-is pending soak |
| nothing wakes, banner `0x00`, trace captured | the rails hypothesis is dead on our bl31+7.0.11. Residual suspects (hrdl's 6.19 kernel-side suspend flow, the bl31 delta, non-rail DTS deltas) are all diffable offline. Ultra closes for alpha with the strongest record yet. |

## Do not

- Do not enable wowlan (keep-power is gone; the wowl branch would fail).
- Do not run an unarmed suspend, ever, on this image.
- Do not interpret console silence in the dead window.
- Do not spend more than the one budgeted long-press.
