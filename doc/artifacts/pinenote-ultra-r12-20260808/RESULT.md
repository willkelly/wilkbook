# R12 result — 2026-08-08

**THE WAKE PROBLEM IS SOLVED.** hrdl's rails-off configuration resumes
from ultra suspend on our bl31 (v2.3-210-g4af361e4c) + 7.0.11 stack, on
**both** wake legs — the RTC alarm and the power button.

Image `e1374a79…` (pinenote-reader-ultra), deployed and readback-verified.
Battery 89% at session start (1% under the ≥90% precondition, recorded).
UART both-directions proof required a device-end USB-C flip first — the
documented SBU orientation trap, third session running that the proof
paid for itself.

## The two suspends that answered it

| | armed | banner | wake | result |
|---|---|---|---|---|
| A1 | ultra + debug | `PM-STATE: ultra (ultra: 1, mem: 0, cfg: 0x5ec), pmic: 0x14, 0x00` | RTC alarm +60 s | **RESUMED rc=0 slept=60s** |
| A2 | ultra + debug | `PM-STATE: ultra (ultra: 2, …), pmic: 0x14, 0x00` | power button ~28 s | **RESUMED rc=0 slept=28s** |

The pre-registered go/no-go held exactly: the second PMIC word read
**`0x00`** — the payload cleared precisely the three `POWER_SLP_EN` bits
(LDO_REG1/3/6) that R11's rails-on runs read as `0x25`. Proof from the
firmware itself that the rails configuration reached the PMIC.

`suspend_stats 2/0`. Kernel continuity across both resumes (`slept=`
measured by wall clock in the same process).

## What resumed, verified

- **Wi-Fi**: `wlan0 up` after `cap-power-off-card` powered the SDIO card
  off and mmc re-tuned from scratch — the SSH session used to read the
  result was itself the proof.
- **Touch**: `cyttsp5: HID power cmd execution timed out` once — exactly
  the cold-controller path hrdl's `[HACK]` covers — then the reset-and-
  continue recovery ran, and the operator confirmed **on glass**: panel
  clean, touch works, page turns fine.
- **Display**: `rockchip_ebc_resume` clean, no corruption.
- **Pen** present.

## What this settles

1. **Wake under rails-off ultra is PMIC-mediated and it is a genuine
   RESUME**, not a restart: with the GPIO0 pad bank unpowered, the rk817
   wakes on its internal alarm (or PWRON) and restores the rails; the
   kernel continues. R11's "RTC-no-wake is by construction" reasoning was
   correct for the SoC GPIO path and irrelevant to the PMIC path — which
   is the path that matters.
2. **R10's failure is now fully explained**: rails-on ultra is the one
   configuration with no wake path — the SoC-side arming is orphaned by
   ultra's teardown, and the PMIC-side wake handshake only engages when
   the rails are handed to it. hrdl's commit sentence ("needed for the
   system to resume") was the whole story.
3. **The RTC-backstop autosuspend model carries over unchanged** —
   decision-table outcome (b), the best case.

## A3 — the measured window

The cleanest suspend measurement in the project's history: both gauge
reads from the runner's own process, seconds either side of the sleep —
no boot confound, no attribution model.

    entry : 3,281,760 µAh   2026-08-08T21:32:27Z
    resume: 3,278,664 µAh   2026-08-08T22:12:30Z  (slept exactly 2400 s, rc=0)
    delta =     3,096 µAh over 40.0 min  ->  **4.64 mA**

Third consecutive successful rails-off wake; `suspend_stats 3/0`.

Context: deep (rails-on mem) measured ~20 mA; R11's rails-on ultra
estimate (~3 mA, wide error bars) is now calibrated — the ≤10.2 mA hard
bound held, the point estimate was optimistic; hrdl's ~11 mW ≈ 3.0 mA
claim is independently corroborated at the same order of magnitude on
our stack.

Standby arithmetic at 4.64 mA: 4000 mAh full charge → ~36 days of pure
suspend; with backstop-wake overhead, roughly ~28 effective. The 18-day
alpha target now carries ~2× slack, and the >30-day desired outcome is
in reach. (Arithmetic, labelled as such — the multi-day soak remains the
proof.)

## Deviations and notes

- Battery 89% start (procedure says ≥90) — R11 precedent, recorded.
- A1 used the runner's +60 s alarm rather than the procedure's +90 s.
- The runner gained a `BACKSTOP` 4th argument (on-device edit, mirrored
  to the repo copy) for the A3 window.
