# R11 result — 2026-08-08

**The arming is identical. The wake is not.** With bl31's own diagnostics
switched on for the first time, a working `mem` suspend and a
non-returning `ultra` suspend were shown to receive **bit-for-bit the same
configuration**, with firmware stating in both cases that it enabled GPIO0
as a wake source. The difference is entirely downstream of arming.

Device: wilkbook / wkelly's PineNote. os2 image
`387d20c1c207281e8d96585b509f261339c9a8b67d21e2a64d96a1afc728c229`,
written and readback-verified (475153 blocks of 4096, every number derived
by `write-os2-verified.sh` rather than typed). Battery 96 % at start, on
battery throughout (the UART occupies the only port). UART proven both
directions before the run.

## The contrast

Same boot, ~11 minutes apart, one variable:

| | Phase 1 — `mem` | Phase 2 — `ultra` |
|---|---|---|
| banner | `PM-STATE: mem (ultra: 0, mem: 1, cfg: 0x5ec), pmic: 0x14, 0x25` | `PM-STATE: ultra (ultra: 1, mem: 1, cfg: 0x5ec), pmic: 0x14, 0x25` |
| `sleep mode config` | `0x5ec` → CENTER_PD, ARMOFF_LOGOFF, PMIC_LP, HW_PLLS_PD, PMUALIVE_32K, OSC_DIS, 32K_PVTM | **identical, all seven** |
| `wakeup source config` | `0x10` → *"Enable GPIO0 interrupt as wakeup source"* | **identical, same line** |
| stage trace | `abcdegh…ij701M` | `1234567abcdegh…ij789sram2wfi` |
| outcome | woke at the +60 s RTC, `rc=0` | never returned |

## What this establishes

1. **Our words reach firmware intact, under both states.** bl31 echoes
   `cfg 0x5ec` and `wakeup 0x10` and decodes each bit. The hypothesis that
   the wake word never arrives, or arrives altered under ultra, is dead —
   by firmware's own account rather than by inference.
2. **Firmware believes it armed GPIO0 wake in the ultra case too.** The
   line *"Enable GPIO0 interrupt as wakeup source"* is printed on the run
   that never woke. So ultra is not silently selecting a different wake
   policy.
3. **Therefore the failure is downstream of arming**, in what ultra's
   extra teardown does after the shared path completes — the stages
   bracketing the common `abcdeghij` as `1234567…789` and ending at
   `sram2wfi`.
4. **`mem` and `ultra` are separated by exactly one thing we control**:
   the `0x09` word. Everything else observable is identical, including
   both PMIC report words (`0x14`, `0x25`).

## Stimuli tried, and their outcomes

| stimulus | result |
|---|---|
| RTC alarm at +60 s | no wake |
| short power press | no wake |
| ~1 s press | no wake |
| ~3 s press | no wake |
| **cover switch** | **could not be tested — see below** |
| USB-C VBUS | pending |
| ~10 s long-press | recovery, pending |

Liveness was checked three ways after entry and after the presses: SSH
(`No route to host`), ICMP (100 % loss — note it *answers* under ordinary
deep via brcmfmac offload), and UART (zero bytes).

## The cover switch: wired, armed, and unactuatable on this device

This was R11's second new instrument and it produced a clean negative.

The DT node is real and correctly configured — `gpio-23` on gpio0,
`ACTIVE LOW`, IRQ present, `linux,code = 0` (SW_LID), `linux,input-type =
5` (EV_SW), `wakeup-event-action = 2` (wake on cover *open*), identical to
hrdl's node. `/sys/bus/platform/devices/gpio-keys` is wakeup-enabled.

But with the operator's cover physically shut, `gpio-23` still reads `hi`
(unasserted) and `wakeup_sources` shows `gpio-keys event_count = 0`. No
state change was ever observed. **The cover on this device does not
actuate the sensor** — no magnet, or misaligned. It is not a broken wake
path; it is an unreachable one.

Consequences worth stating plainly:

- The cover rung was removed from the Phase 2 ladder. Every stimulus we
  *could* apply reaches the SoC through the single rk817 PMIC-INT → GPIO0
  line, which is exactly the line R10 already showed dead. **The one
  physically independent wake leg remains untested, for want of a magnet.**
- The 2026-08-08 auto-suspend change that makes cover-close a suspend
  request can never fire on this device. The code is still correct, and
  correct for anyone with a magnetic cover, but it is **unexercisable
  here** and must not be recorded as validated on glass.

## Incidental results

- **Persistent SSH host keys survived a reflash** — first proof. os2 was
  fully overwritten and SSH reconnected with no host-key change, i.e.
  `ssh-keys.scm`'s `/data/ssh/host/` sync worked. It had been
  "hardware-unproven until the next deployed image" since 2026-08-06.
- **The library one-shot behaved correctly on real hardware.** p7 carried
  an existing `/data/books` with the operator's books; the service left it
  strictly alone and added no pointer — the `with-library` fixture
  behaviour, now confirmed on glass rather than only in QEMU.
- **The `PMU_WAKEUP_INT_CON` register readback did not print.** Prior
  offline analysis predicted `WAKEUP: PMU_WAKEUP_INT_CON:0x%x, reg: 0x%x`
  would appear with debug on. It does not at this verbosity. We therefore
  have firmware's *intent* confirmed, not the register contents — a
  distinction worth keeping, since "firmware says it armed GPIO0" and "the
  register holds 0x10" are different claims.

## Where this leaves ultra

The remaining candidate is the one the community actually runs: hrdl's
configuration couples state 5 with three `*_pmu` rails off-in-suspend and
`sdmmc1 cap-power-off-card`, and their commit states the mode-5 override
"is needed for the system to resume". Our policy words are already
identical to theirs; the rails are the entire difference. R11 has now
shown that with the rails **up**, arming succeeds and wake still dies —
which is precisely what a rails-on ultra would look like if the supported
configuration is rails-off.

That change is a DT/safety-model item and is not in this session.
