# Ultra firmware-handshake test — supervised procedure

The experiment: tell bl31 `LINUX_PM_STATE=5` (ultra) instead of 3 (mem)
for **exactly one suspend**, change no rails, and see what the firmware
does. Everything else about the suspend is the proven `deep` path.

**No-resume is a live outcome, not an edge case.** Plan for it: the only
recovery is a physical power-button long-press, and with one USB-C port
the cable is either UART or charger, never both.

## What is already true (do not re-derive)

- bl31 **has** ultra compiled in — it announces `(Feature: ultra suspend`
  — and its ultra branch performs **no PMIC access**: not PMIC-tainted by
  call graph, no indirect calls so the trace is complete, no I2C0 MMIO,
  and the PMU-SRAM resident segment is clean too
  (`doc/artifacts/pinenote-bl31-ultra-disasm-20260807/`). So this arms a
  handshake, not a rail kill.
- `ultra:` and `mem:` in the banner are **cumulative counters**, not
  flags. `ultra: 0` has never incremented.
- The banner prints **before** bl31 runs its power-down stages, so a
  supervised capture answers "did firmware accept 5?" even if the device
  never comes back. **Read the banner first.**
- The arm changes only the `0x09` word. Regulator-list selection stays
  derived from the real Linux suspend state, and the DT parser still
  refuses `rockchip,suspend-state-override` with all forbid pins intact.

## Preconditions — all of them, no exceptions

1. **Battery ~100% BEFORE the UART cable goes on.** One port: the whole
   session runs on battery. A test that dies of flat battery mid-window
   tells you nothing and costs a power cycle.
2. **UART proven in BOTH directions, this session**, via the SoC's own
   counters — not "it worked yesterday", which was false on 2026-08-06
   and cost an entire evening:
   ```sh
   sudo cat /proc/tty/driver/serial | grep '^2:'   # tx must climb; rx must leave 0
   ```
   Send a marker from the device and read it on the host; type at the
   host and watch `rx` increment. Both, or stop.
3. **Both roots backed up and SHA-verified** (`doc/device-runbook.md`).
4. **os1 reachable** as the rescue slot, and its suspend NOT masked
   (unmasked 2026-08-07 — leave it that way; use `systemd-inhibit` for
   deploys instead).
5. **Operator present, finger on the power button**, for the whole run.
6. Auto-suspend **paused** on os2 (`enabled=0` in
   `/data/wilkbook/autosuspend.conf`, which survives reflashes) so
   nothing suspends except when we say.

## The run

### R9 — control, same boot

One ordinary deep with the arm **disarmed**. This is not ceremony: if
plain deep is not clean on today's image, ultra is not the experiment to
be running.

Expect: `mem` counter increments, `cfg: 0x5ec`, clean resume, VCOM `8f`
before and after, panel intact. Anything less — **abort**.

### R10 — the attempt

```sh
cat /sys/module/rockchip_suspend_mode_drv/parameters/ultra_arm   # 0
echo 5 > /sys/module/rockchip_suspend_mode_drv/parameters/ultra_arm
```

Then one suspend with a short RTC backstop (60 s), gadget quiesced,
`sync` first, evidence written to both `/tmp` (p6) and `/data` (p7).

`dmesg` should carry `ultra handshake armed: this suspend sends
LINUX_PM_STATE=5` before entry. **Watch the UART for the banner.**

### The four outcomes

| banner | meaning | next |
|---|---|---|
| `ultra:` does **not** increment | firmware ignored state 5 | Question closed cheaply. The deployed bl31 does not honour it; ultra is dead without a firmware change. Nothing else to try. |
| `ultra:` increments **and it resumes** | firmware honoured it and the wake path survived | The interesting case. Measure draw over a real window before believing any number, and confirm the arm self-cleared (`ultra_arm` reads 0). |
| `ultra:` increments, **no resume** | firmware honoured it and killed something the wake path needs | Long-press. This is a RESULT, not a failure: it answers the GPIO0 wake-collision question without ever adopting a rail payload. Record what the banner showed. |
| nothing prints | the SMC never reached firmware, or the UART died again | Do not guess which. Re-verify the UART by its counters before drawing any conclusion. |

## After, either way

- `ultra_arm` self-clears; confirm it reads 0.
- A reboot returns to proven `mem` regardless — the arm is not
  persistent, by design.
- Record the outcome in `doc/status.md` with the banner line verbatim.

## What this run does NOT license

The rail payload. The ultra path writes GPIO0/PMU-IO space, and that is
the pad bank every armed wake source runs through — so even a clean
result here says nothing about whether killing `vcc_3v3_pmu` is
survivable. `make suspend-check` now rejects a rail payload outright
(2026-08-07); leave it that way until there is separate evidence.
