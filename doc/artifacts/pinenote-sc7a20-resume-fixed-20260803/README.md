# SC7A20 accelerometer survives deep suspend — FIXED (2026-08-03)

**Status: hardware-proven, 6/6 deep cycles.** The last open blocker from
the 2026-08-02 deep-suspend program is closed. Autorotation now survives
platform `deep`; before this the sensor was dead until reboot.

Image `a3ea6a2d…` (kernel `vhb7v5fr…`, system `cqvbxca4…`) on os2.

## Result

```
cycle |  pre/s | post/s | 0x25 | 0x27 | storm | ddepth | result
------+--------+--------+------+------+-------+--------+-------
    1 |     10 |     10 |  0x2 |  0x0 |    no |      0 | PASS
    2 |     10 |     10 |  0x2 |  0x0 |    no |      0 | PASS
    3 |     10 |     10 |  0x2 |  0x0 |    no |      0 | PASS
    4 |     10 |     10 |  0x2 |  0x0 |    no |      0 | PASS
    5 |     10 |     10 |  0x2 |  0x0 |    no |      0 | PASS
    6 |     10 |     10 |  0x2 |  0x0 |    no |      0 | PASS
```

10 interrupts per 10 s window on both sides of every cycle, matching the
configured 1 Hz ODR exactly. `success=7 fail=0` for the session.

## Two bugs, and why the first one hid the second

Both were in *our* PM patch, not in the kernel.

### (1) read-after-clobber — the storm

`st_sensors_resume()` called `st_sensors_reinit_hw()` and only then tested
`->hw_irq_trigger` to decide whether to re-arm DRDY. `reinit_hw()`
inherits `init_sensor()`'s *"disable DRDY, this might still be enabled
after reboot"* step, and `st_sensors_set_dataready_irq()` assigns
`->hw_irq_trigger` as a side effect — so the test always read false. The
re-arm never ran, and `enable_irq()` then unmasked a line whose handler
had to take `st_sensors_irq_thread()`'s "spurious IRQ" → `IRQ_NONE` branch
every time.

Measured: `irq 73: nobody cared`, count **116 → 100,117** in the second
after resume, then `Disabling IRQ #73`.

Fix: latch the flag *before* `reinit_hw()`.

### (2) interrupt polarity not restored — the silent failure

Fixing (1) removed the storm and produced something worse-looking-fine:
no error in dmesg, `ddepth=0`, every control register reading back
correctly, raw channels readable — and **0 interrupts**. The sensor was
sampling into an overrun the whole time.

`st_sensors_allocate_trigger()` is the only place the active-low polarity
bit is ever written, and it runs once at probe. After a suspend that
removes power the chip is back at its **active-high** reset default while
the GPIO is still `IRQ_TYPE_LEVEL_LOW`. The line reads permanently
de-asserted.

Proven on the device *before* writing any code:

| `0x25` (addr_ihl, mask 0x02) | IRQ rate |
|---|---|
| `0x00` (active high — post-resume state) | **0 / 5 s** |
| `0x02` (active low — written by hand) | **10 / 10 s = 1 Hz** |

This also explains the burst-then-silence in the (1)-only run: the count
jumped **65 → 7488** across the cycle and then flatlined. At reset the
chip idles the line low (active-high, no data yet), which a `LEVEL_LOW`
GPIO reads as *asserted* — the burst; once data arrives it drives the line
high, read as *de-asserted* — the silence. One inverted bit, both symptoms.

Fix: latch the polarity in `->int_active_low` where it is programmed and
re-apply it from `st_sensors_reinit_hw()`.

## Instrument notes (the reusable part)

- **`0x27` (STATUS_REG) is the tell for the silent mode.** `0xff` means
  data-ready **plus overrun on all three axes** — the chip is sampling and
  nobody is reading. `0x00` means it is being consumed. A healthy-looking
  register dump plus `0xff` here is a dead interrupt path, not a dead chip.
- **An absent error line is not a passing test.** Criteria A (no storm)
  and B (`ddepth=0`) both passed while autorotation was completely dead.
  Only criterion C — comparing the interrupt *rate* across the suspend
  against a same-length pre-suspend baseline — caught it.
- **A zero baseline invalidates the comparison.** The first valid run had
  `pre=0` because an earlier *failed* suspend had already broken DRDY via
  the same bug. The harness now reports `INVALID` rather than scoring it.
- **The USB gadget must be unbound before `echo mem`**, or dwc3 returns
  `-EAGAIN` (`last_failed_dev=fcc00000.usb`) and the device never
  suspends. A test that skips this measures nothing — the first run here
  "passed" criterion A purely because there had been no resume.
- **`readelf`/`nm`/`objdump`/`strings` do not exist on the device image.**
  A verification script that shells out to them reports "absent" when it
  means "could not test". Use `grep -a` on the module, or check from the
  host with the cross binutils in the store.

## Rotation on glass — CONFIRMED

Will rotated the device after a deep cycle on 2026-08-03 and the screen
followed. This was the one thing the harness could not establish: every
measurement above proves the data-ready interrupt is *delivered* at the
configured rate, not that the orientation bridge consumes it and the
reader reorients. It does.

That closes the loop end to end: chip → DRDY line → GPIO → threaded
handler → iio buffer → orientation bridge → uinput → KOReader.

## Reproduce

`sc7a20-accept2.sh` — one cycle, three criteria, refuses to score a run
that did not actually suspend.
`sc7a20-soak.sh` — `N=6` repeats with per-cycle register readback.
