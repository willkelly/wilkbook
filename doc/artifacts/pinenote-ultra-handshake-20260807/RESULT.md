# Ultra firmware-handshake result — 2026-08-07

**The firmware honours `LINUX_PM_STATE=5`, and the device did not wake.**
Outcome 3 of the four the procedure anticipated. No rail payload was ever
adopted; the only change between the two runs is the single `0x09` word.

Device: wilkbook / wkelly's PineNote, os2 image
`7eaab3435f335323305976b3432a934b12c70f727b175c3a6cecc58d3748699e`
(the alpha ship candidate, secure build). Battery 85 %, discharging —
see "Deviations". UART proven both directions this session before the
run: `tx` 1701→1730 with a marker read on the host, `rx` 0→34.

## The two banners

Same boot, 65 seconds apart, one variable:

| | R9 control (`ultra_arm=0`) | R10 armed (`ultra_arm=5`) |
|---|---|---|
| banner | `PM-STATE: mem (ultra: 0, mem: 3, cfg: 0x5ec), pmic: 0x14, 0x25` | `PM-STATE: ultra (ultra: 1, mem: 3, cfg: 0x5ec), pmic: 0x14, 0x25` |
| stage trace | `abcdeghij701M` | `1234567abcdeghij789sram2wfi` |
| result | `rc=0 slept=60s`, clean resume | **no resume** |

What is certain from this:

1. **The state label changed `mem` → `ultra`.** bl31 read our word and
   took a different branch.
2. **`ultra:` incremented 0 → 1 — the first time it has ever moved** —
   while `mem:` stayed at 3. The counters are cumulative, so this is not
   a flag being misread.
3. **`cfg` is identical (`0x5ec`) and so are both pmic words (`0x14`,
   `0x25`).** This is the offline disassembly finding confirmed on
   hardware: the ultra branch performs no PMIC access, so the rails were
   configured identically in both runs. Whatever broke wake is in the
   SoC power-down sequence, not in a regulator we turned off.
4. **Ultra runs strictly more stages**, wrapping the common `abcdeghij`
   with a `1234567` prefix and a `789` suffix, and ends at `sram2wfi` —
   entering WFI from SRAM. The control never reaches that point.
5. **The RTC alarm at +60 s did not fire**, and the UART stayed silent
   for a further 110 s. SSH timed out.
6. **ICMP went dead too.** In ordinary deep suspend this device *answers*
   pings — brcmfmac offloads ARP/ICMP, which has misled this project
   before. Under ultra it does not, which is independent evidence that
   ultra powers down more than `mem` does.

## What this closes, and what it does not

**Closed:** the deployed bl31 *does* honour state 5. The question "is
ultra reachable at all without a firmware change?" is answered yes. That
was genuinely open — `ultra: 0` had never moved, and "firmware ignores
it" was the outcome we thought most likely.

**Closed:** ultra as-shipped, with the *proven `mem` rail configuration
and no DT changes at all*, breaks the RTC wake path. This is the
GPIO0 wake-collision question answered without adopting hrdl's rail
payload — the cheap half of the experiment paid for the expensive half.

**Closed, and this is the one that decides it: the power button does not
wake it either.** A short press was tried first, deliberately, before any
long-press — if it had woken the device, ultra would still have been a
usable reader state (RTC-less, but a reader wakes on a button). It did
nothing. Both wake sources are dead, so the only exit from ultra on this
firmware is a forced power-off, which loses the session.

**Therefore: ultra is not adoptable on this bl31, and the blocker is not
the rail payload.** We never touched a rail. A state that nothing can
wake is not a suspend, it is an off switch with extra steps — and the
proven `deep` path already gives ~20 mA. Ultra is closed for alpha.

**Open:** what ultra actually saves. Nothing here measured current. Do
not quote a number; the whole point of `doc/alpha-checklist.md` is that
alpha ships measured numbers or none.

**Not attempted, deliberately:** the rail payload. `suspend-check`
rejects it by design and it stays rejected.

## Deviations from PROCEDURE.md, stated

- **Battery was 85 %, not ~100 %.** The precondition exists so a long
  unattended window cannot die mid-test; this run was ~10 minutes with
  ~3392 mAh in hand (≈20 h awake). Judged not binding, and recorded here
  rather than quietly ignored.
- **`/tmp` evidence was skipped** — everything landed on p7
  (`/data/wilkbook/ultra-r*.log`), which is the copy that survives a
  no-resume, which is what we got.

## Two procedure bugs this run found

1. **The sysfs path in R10 was wrong.** `PROCEDURE.md` said
   `/sys/module/rockchip_suspend_activate/parameters/ultra_arm`; the
   module registers as `rockchip_suspend_mode_drv`. Following the
   procedure verbatim would have written to a nonexistent path, run a
   plain `mem` suspend, and produced `ultra:` not incrementing — which
   the outcome table reads as "firmware ignored state 5. Question closed
   cheaply. Nothing else to try." **The false negative was the
   most conclusive-sounding cell in the table.** Fixed.
2. **"Gadget quiesced" is load-bearing and was not spelled out.** The
   first control attempt aborted at 5 s with `dwc3 ... returns -11`
   (`-EAGAIN`) and `PM: Some devices failed to suspend` — bl31 was never
   asked anything. The ACM gadget stays bound to the UDC even in the
   secure build (the build flag gates the *shell* on it, not the gadget),
   so `/sys/kernel/config/usb_gadget/pinenote-acm/UDC` must be unbound
   first, exactly as `autosuspend.lua:578` does. `mem_sleep` must also be
   forced to `deep` and *verified*, or the run silently gets s2idle.
   Both are now in `ultra-run.sh`, committed beside this file.

## Recovery

Long-press forced a cold boot. The DDR init ran its resume path first
(`DDR Version V1.10 20200218_resume`, `suspend_info:0x8c, flag:0x20`)
before retraining 324→528→780→**1056 MHz (final freq)** — incidentally a
clean confirmation that the shipped `mode=off` leaves DDR at 1056.
U-Boot's autoboot took "Search for extlinux.conf on all partitions",
which finds p5 first, so the device came up on **os1** (Debian
6.12.11-pinenote) at a login prompt. The rescue path did its job; os2 was
untouched throughout.

## Files

- `r9-control.uart.log`, `r10-armed.uart.log` — raw UART, unedited
- `ultra-run.sh` — the runner, mirroring the proven `autosuspend.lua` path
- on-device: `/data/wilkbook/ultra-r9-control.log` (the R10 log will be
  truncated at entry, since the device never came back to write it)
