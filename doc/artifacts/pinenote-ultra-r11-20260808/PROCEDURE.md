# R11 — the instrumented ultra session

**What is different from R10, in one line:** last time we asked firmware to
do something and had no way to see what it did. This time the firmware
narrates.

R10 (2026-08-07) proved bl31 honours `LINUX_PM_STATE=5` — `ultra:` went
0→1 — and then the device never woke, from anything. The record is
`../pinenote-ultra-handshake-20260807/RESULT.md`. What that session could
not say is *why*, because every diagnostic bl31 has was switched off.

## What this session is NOT

**No rail payload.** hrdl's working ultra couples state 5 with three
`*_pmu` rails off-in-suspend and `sdmmc1 cap-power-off-card`
(`doc/reference-register.md`), and adopting it is a real candidate — but
it is a DT/safety-model change that our gates reject by design and that
wants the other operator's eyes. It is deliberately **not** in this
session. R11 is the cheap, safe, information-dense half that must come
first: with the firmware talking, we may learn enough to know whether the
rails are even the right next move.

## The two new instruments

1. **`sleep_debug_arm`** — a module parameter that turns on bl31's own
   suspend diagnostics. With it set, firmware prints its decode of the
   sleep-mode and wakeup words *and*
   `WAKEUP: PMU_WAKEUP_INT_CON:0x%x, reg: 0x%x` — a hardware **readback**
   of the armed wake register. This is the only on-device observability of
   the wake word that exists. Diagnostic only: it changes what firmware
   prints, never what it does.
2. **The cover switch.** Our own suspend gate declares exactly two armed
   DT wake paths — `/gpio-keys/switch-cover` and the PMIC. **Every test
   this project has ever run used the PMIC leg**: the RTC alarm and the
   power button are both rk817-internal and arrive over the same
   PMIC-INT → GPIO0 line. The cover sits on its own GPIO0 pin. It has
   never been tried as a wake source, and it is free.

## The artifact

Built and gated 2026-08-08, ready to write:

    /tmp/opencode/r11/pinenote-reader-PNGuixRoot-20260808.ext4
    sha256 387d20c1c207281e8d96585b509f261339c9a8b67d21e2a64d96a1afc728c229

Verified *in the built kernel*, not assumed: `strings` on the shipped
`Image` carries `rockchip_suspend_mode_drv.sleep_debug_arm`. The parameter
is **built in, not a module** (`CONFIG_ROCKCHIP_SUSPEND_MODE=y`), which
has a useful consequence — it can also be set on the kernel command line:

    rockchip_suspend_mode_drv.sleep_debug_arm=1

so firmware diagnostics can be live from the very first suspend of a boot,
before any shell exists. Use that if a suspend ever happens too early to
instrument by hand.

Offline ladder, all green on this exact artifact: `make check-host`,
`qemu-virt-check`, and `qemu-data-check` on all three fixtures
(`os1-used`, `with-library`, `empty`).

This image also carries the 2026-08-08 reader fixes — cover-close now
suspends instead of delaying suspend, and the frontlight is saved/zeroed/
restored across suspend. **Neither has been seen on glass**, so watch for
them: the light should go out with the device and come back after resume,
and closing the cover should put it to sleep promptly.

## Preconditions — all of them

1. Battery ≥ 90 % **before** the UART cable goes on (one port: the session
   runs on battery). R10 ran at 85 % without trouble for ~10 minutes.
2. **UART proven in BOTH directions this session** via the SoC counters —
   `grep '^2:' /proc/tty/driver/serial`, `tx` must climb and `rx` must
   leave 0. It was false once and cost an evening.
3. Auto-suspend paused: `enabled=0` in `/data/wilkbook/autosuspend.conf`.
4. os1 reachable as the rescue slot.
5. Operator present, finger on the power button, for the whole run.
6. Both roots backed up and SHA-verified (`doc/device-runbook.md`).

**Correct sysfs paths** (R10's procedure named a module that does not
exist, which would have produced a silent false negative):

```sh
/sys/module/rockchip_suspend_mode_drv/parameters/ultra_arm         # 0 | 5
/sys/module/rockchip_suspend_mode_drv/parameters/sleep_debug_arm   # -1 | 0 | 1
```

Every suspend must also quiesce the USB gadget and force `deep`, or it
never reaches firmware — R10's first control died at 5 s on
`dwc3 … returns -11`. `pinenote/tools/power/ultra-run.sh` (committed
beside the 2026-08-07 artifact) does both; reuse it.

## Phase 1 — mem with the firmware talking (zero new risk)

The proven `deep` path, unchanged, with `sleep_debug_arm=1`. Recoverable
by construction: this is the suspend the device does every five idle
minutes.

```sh
echo 1 > /sys/module/rockchip_suspend_mode_drv/parameters/sleep_debug_arm
# ultra_arm stays 0
```
Then one suspend with an RTC backstop at +60 s, UART capturing.

**This is the highest-value step in the session.** Read from the banner
and the debug lines:

- What wakeup word does firmware say it received? (we send `0x10`)
- What does `PMU_WAKEUP_INT_CON` **read back as**? If the readback is not
  `0x10`, our word is not reaching the register and every hypothesis
  about ultra's teardown is premature.
- Does the per-bit decode name a timeout wake source?

Then, still under mem, **exercise the cover**: suspend again and wake it by
opening the cover. If cover-wake works under mem, it is a real wake leg
and worth trying under ultra. If it does not work under *mem*, it never
had a chance under ultra, and that is worth knowing before we spend the
armed attempt on it.

ABORT if plain mem does not wake: the device is not in the known-good
state and nothing after this is interpretable.

## Phase 2 — ultra, instrumented

```sh
echo 1 > .../sleep_debug_arm
echo 5 > .../ultra_arm          # one-shot, self-clearing
```
One suspend, RTC backstop +60 s.

**Read the banner and debug output first** — bl31 prints before it powers
down, so this is evidence even if the device never returns.

Then the stimulus ladder, each step timestamped against the UART log.
R10 tried only the RTC and one short press, so most of this is new:

| # | stimulus | wait |
|---|---|---|
| a | RTC alarm | to +90 s |
| b | **open the cover** | 15 s |
| c | close then open the cover | 15 s |
| d | short power press | 15 s |
| e | second short press | 15 s |
| f | ~1 s press | 15 s |
| g | ~3 s press (below the ~10 s forced-off threshold) | 30 s |
| h | plug USB-C (VBUS/charger event) | 30 s |
| i | **the dead window is free** — leave it 30–60 min unplugged and bracket `charge_now` before entry and after recovery. This is the only ultra current figure anyone will ever get from this configuration, and it decides whether reopening is ever worth it. | — |
| j | ~10 s long-press: forced power-off | — |

**Budget: one forced power-off for the whole session.**

## Phase 3 — forensics, at the U-Boot prompt

Do this **before** any kernel touches the PMIC. The rk817's `INT_STS`
registers are write-1-to-clear and both U-Boot and os1's driver service
the PMIC before a shell exists — reading them from os1 loses the race.
The U-Boot menu is interactable on the device, so interrupt autoboot and
read from there:

- `INT_STS` `0xf8` / `0xfa` / `0xfc` — an RTC_ALARM pending bit proves the
  PMIC fired and the SoC ignored it.
- `ON/OFF_SOURCE` `0xf5` / `0xf6` — **note the limit honestly**: the
  long-press is itself a PWRON event and the power-on is the operator's
  own press, so after a forced recovery these record *the recovery*. They
  only carry information if the device came back some other way.

Also capture the full cold-boot UART from the first byte: the
`suspend_info:0x8c, flag:0x20` line from the DDR blob has been seen
exactly once, and a second data point says whether it is sticky state or
ordinary.

## What each outcome kills

| observation | conclusion |
|---|---|
| Phase 1 readback ≠ `0x10` | our wake word never reaches the register. Everything about ultra's teardown is premature; fix this first. |
| Phase 1 readback = `0x10`, mem wakes, cover wakes under mem | the wake plumbing is healthy and the cover is a real leg. Phase 2's cover rung becomes the most informative step. |
| Cover does **not** wake under mem | the cover is not a usable leg on this build; stop attributing hope to it. |
| Phase 2: firmware debug shows a *different* wakeup word or register value under ultra | ultra's teardown is clobbering the wake arming — a named, localised cause at last. |
| Phase 2: identical word and readback, still nothing wakes | the arming survives and the wake path is dead downstream. That is the strongest case yet that no interrupt-class wake exists in this mode with the PMU rails up, and it makes hrdl's rails-off configuration the only remaining candidate. |
| Anything wakes | record what, and stop. That is the result. |

## Close-out

New `RESULT.md` beside this file with the raw UART **including the
recovery boot** (R10's was not committed), a `doc/status.md` entry the
same day, and either the closure record or the narrow continuation.
