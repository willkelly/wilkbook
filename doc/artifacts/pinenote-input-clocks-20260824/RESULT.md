# Input, clock and rail ground truth — 2026-08-24

Device: author's PineNote, os2 (`/dev/mmcblk0p6`), `pinenote-reader`, Linux
7.0.11 `PREEMPT_RT`, uptime 9.63 d, 229 suspend cycles / 0 failures.
Plugged in and awake. **Read-only**: two Lua probes and shell reads over
SSH. Nothing on the device was written, restarted or reconfigured.

Both probes are committed here (`absprobe.lua`, `evmon.lua`). They run on
KOReader's bundled `luajit` — the reader image has no other interpreter.

## Why this exists

Five open issues each carried a "one command on the device would settle
this" question. They were all answerable in one waking. Three of them
turned out to have **premises that were wrong**.

| issue | question | answer |
|---|---|---|
| #20 | does the digitizer report pressure/tilt? | **yes** — 12-bit pressure, ±90° tilt, hover |
| #21 | how many touch slots? | **32** advertised; 3 simultaneous observed |
| #23 | what does a 250 MHz `dclk_ebc` request round to? | `cpll_333m` is **already 250 MHz** |
| #18 | do the sound modules load? | **already loaded**; card 0 registered |
| #8 | is the hall sensor on `vcc_3v3_pmu`? | **no** — it is on `vcc_bat` |

## 1. The digitizer has everything ink needs (#20)

`w9013 2D1F:0095` (Wacom protocol) on `fe5a0000.i2c`, nodes `event3`
(Stylus) / `event4`. Distinct from `ws8100_pen` (`event5`, SPI), which
carries **no ABS axes at all** — confirming the issue's separation of the
two devices.

`EVIOCGABS`, and separately what was **emitted** during 120 s with the pen
in hand:

| axis | advertised | emitted on glass |
|---|---|---|
| `ABS_X` | 0–20966 @ 100/mm | — |
| `ABS_Y` | 0–15725 @ 100/mm | — |
| `ABS_PRESSURE` | 0–**4095** | **0..4095** (full range reached) |
| `ABS_TILT_X/Y` | ±9000 @ 5730/rad = **±90°** | **−4900..6200** (−49°..+62°) |
| `ABS_DISTANCE` | −255–0 | **−108..0** |

Keys: `BTN_TOOL_PEN`, `BTN_TOOL_RUBBER`, `BTN_TOUCH`, `BTN_STYLUS`,
`BTN_STYLUS2` — an eraser end and **two** barrel buttons. Observed
`BTN_TOOL_PEN`=24, `BTN_TOUCH`=30, `BTN_STYLUS`=8.

**The digitizer grid is 11.2× the panel in both axes** (20966/1872 =
15725/1404 = 11.20; 2540 dpi of pen against 227 dpi of panel), so stroke
geometry has real sub-pixel signal rather than quantisation noise.

Advertising an axis and emitting it are different claims; they were
measured separately for exactly that reason.

## 2. Touch: 32 slots, and the pen-slot collision is reachable (#21)

`cyttsp5` on `event6`: `ABS_MT_SLOT` **0–31**, `ABS_MT_TRACKING_ID`
0–65535, `ABS_MT_PRESSURE` 0–255, `TOUCH_MAJOR`/`MINOR` 0–255.

Live, 120 s, five-finger presses plus pinch and spread:

```
MAX SIMULTANEOUS CONTACTS : 3
distinct MT slots used    : 4 -> {0, 1, 2, 5}
```

Three separable results:

- **Multi-contact tracking works** — three concurrent tracking IDs in
  distinct slots; contacts do not collapse to slot 0.
- **Slot 5 was used.** The shipped bundle's `frontend/device/input.lua`
  has `main_finger_slot = 0` and `pen_slot = main_finger_slot + 4` = **4**.
  `mixedrouter.lua` calls the collision "latent today because nobody has
  put five fingers on the glass"; the controller demonstrably assigns
  slots above 4, so slot 4 is inside its working range. Reaching the
  collision needs one contact in slot 4 while the pen hovers.
- **Only 3 simultaneous, despite five fingers.** This is the soft number
  and is *not* claimed as a cap. It may be `max_num_of_tch_per_refresh_cycle`,
  or five flat fingers may not all have registered. Unresolved.

## 3. `cpll_333m` is already at 250 MHz (#23)

```
pll_cpll  1000000000
  cpll_333m  250000000     <- NOT 333.  CRU divider is /4, not /3.
  cpll_500m  500000000
  gpll_200m  200000000
    dclk_ebc 200000000

dclk_ebc  parent=gpll_200m  possible = gpll_400m cpll_333m gpll_200m
rockchip_ebc.dclk_select = 0
```

`doc/refresh-policy.md` reasons that a 250 MHz request rounds **down** to
200 because `DCLK_EBC` is `COMPOSITE_NODIV` without `ROUND_CLOSEST`. That
holds only if `cpll_333m` sits at 333, where round-down lands on
`gpll_200m`. At 250 there is an **exact match in the parent list**.

So `dclk_select=1` alone may deliver 79.68 Hz with no DT and no driver
change. **Not tested here** — #23's own gate is that the failure mode is
silent corruption with no underrun interrupt, so it needs the optics rig,
not a live poke.

**And the DDR gate is wider than #23 assumes.** DDR ships at
`clk_scmi_ddr = 1056000000` with no `devfreq` node registered at all —
**3.26× the 324 MHz rate at which the EBC was proven to starve**, against
a 1.25× rise in EBC demand.

## 4. Audio already loads (#18)

```
/proc/asound/cards:  0 [PineNote]: simple-card - PineNote
loaded: snd_soc_{simple_card,simple_card_utils,rockchip_i2s_tdm,
        rockchip_pdm,rk817,dmic,simple_amplifier,core}
bound:  /sys/bus/platform/devices/{sound,audio-amplifier,fe410000.i2s}
```

Card 0 is registered with no wilkbook service doing it — DT-compatible
autoloading handles it. #18's item 1 ("nothing loads the sound modules")
is already done. What is missing is narrower: `aplay`/`amixer` are not on
`PATH` (alsa-utils is in the image only as a udev rule provider), and
there is no mixer state.

## 5. The hall sensor is on the battery, not on `vcc_3v3_pmu` (#8)

Walking `vin-supply` phandles in the live `/proc/device-tree`:

```
vcc_hall_3v3   regulator-fixed, always-on, NO regulator-state-mem, 1 consumer
  --vin-supply--> vcc_sys   regulator-fixed, always-on
      --vin-supply--> vcc_bat   (battery root)
```

Meanwhile the rest of the ultra model checks out exactly:

```
LDO_REG6  vcc_3v3_pmu   OFF-IN-SUSPEND   (12 other rk817 rails likewise)
DCDC_REG3 vcc_ddr       on-in-suspend
LDO_REG9  sleep_sta_ctl on-in-suspend
/rockchip-suspend: suspend-state-override=5  wakeup-config=0x10  sleep-mode-config=0x5ec
```

#8's contradiction came from conflating **the GPIO pad's supply** with
**the supply of the thing driving it**. Only the first is off. The sensor
never loses power, so "the transition is undetectable" never followed
from the rails. What remains open is narrower and is purely SoC-side:
can the PMU latch the edge with `pmuio1`/`pmuio2` down (alive-domain
detection)?

Armed wake sources, for the record — **the pen is absent, as #9 says**:
`rk805-pwrkey`, `rk808-rtc`, `alarmtimer`, `gpio-keys` (cover),
i2c `0-0020` (rk817), `serial0-0`, `input0`, `input1`.

## 6. Two things that fell out unasked

**The cyttsp5 resume handshake fails on 100 % of suspends**, not
occasionally as `linux-pinenote-7.0-ultra-rails.patch` describes: 94
`Validation of the wakeup response failed` against 94 `PM: suspend entry`.
The patch's known-incomplete reset-and-continue recovery is therefore the
steady-state resume path, not a fallback. Filed as #24.

**The awake duty cycle is ~1.5 %.** printk timestamps stop advancing
across suspend, so comparing them to wall-clock uptime measures awake
time directly:

```
uptime                  831901 s   (9.63 d)
newest dmesg timestamp   12619 s   (3.5 h awake)
```

That corroborates the 2026-08-15 soak's ~3 % estimate by a completely
independent route, and it is the number audio playback (#18 §5) would
demolish.

Also: `power_supply ws8100_pen: driver failed to report 'status'
property: -74` (`EBADMSG`), one occurrence.

## Method note

The first two observation runs recorded **zero** events. The probe was
sound — both fds opened, and `ffi/input_evdev.lua` states outright that
KOReader does not grab its devices — nobody was touching the glass. The
first version of `evmon.lua` did not print whether `open(2)` succeeded,
which made a null result indistinguishable from a broken probe; the
committed version prints fds and a 10-second running count. Worth
copying: **an observer that cannot report its own health turns "no
signal" into "no information".**
