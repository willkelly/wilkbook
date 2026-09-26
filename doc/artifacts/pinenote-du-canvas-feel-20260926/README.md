# DU ink through a per-region hint, judged blind by feel — 2026-09-26

wkelly's PineNote, generation 21 (`iv1div03…`, `book-state-device-reader`,
7.1.8 direct driver + USER_NS), boot ID `06f2d463-0f31-4a46-86b8-209ee35b1d65`
(the 2026-09-11 kexec, 14 days up). Operator holding the tablet and stylus;
no camera, no UART, no deploy, no reboot. Device times 06:57–07:13 UTC.

## Why

The pen-canvas design under discussion draws ink inside a KOReader region
hinted `0x00` (Y1 → the DU slot) through `RECT_HINTS`, leaving the rest of
the screen at the product's hint 32 (Y4 → GL16), all in NORMAL mode. Before
this session nobody had looked at a mixed-hint screen on glass, and DU ink
latency in NORMAL had never been measured. The one filmed pen number
(D8, `../pinenote-d8-pen-latency-20260826/`) was FAST mode: ~20 ms to first
ink. FAST is whole-screen, and entering it redraws the page as dithered
1-bit, so it cannot be the mode for a canvas inside a reading UI.

## Method

- Tools staged to `/tmp/du-test` on the device, SHA-256 matching the tree at
  `6b9c101`: `pinenote/tools/pen/{scribble,ebc-mode}.lua`,
  `pinenote/tools/ebc-lab/{rect-hints,ebclib,frame-clock}.lua`, plus the
  session helpers here (`arm.sh`, `stop.sh`, `divider.lua`). Run with the
  running KOReader's own `luajit`.
- Auto-suspend paused (`enabled=1` → `0`, backup kept), `herd stop
  reader-session`. No fbcon was bound (only `vtcon0`, the dummy console).
- Each arm (`arm.sh`): set hints through the ioctl (never sysfs), start
  `scribble.lua --clear`, draw the divider for split arms, one GC16 wash
  (`frame-clock.lua --wash`) so both halves start clean, and capture the
  raw Stylus evdev stream in parallel. `scribble.lua` writes black runs with
  `write()` and one `fsync` per SYN batch, radius-2 square brush, no
  pressure.
- Blinding: the device picks each assignment with a coin from
  `/dev/urandom` and writes it to `assign-N`; nothing printed it until the
  operator had answered. Arm 2 got a fresh coin rather than a swap, so
  learning arm 1's answer could not reveal arm 2. Arms 4 and 5 were a
  FAST / whole-screen-DU pair in random order (`pair-order`); each clears
  to white and then flashes once (FAST's entry refresh, or the wash), so
  the flash count does not give the order away.
- Orientation: the operator drew a shaded triangle in their upper-left
  corner. In both split arms it landed at framebuffer x < 400, y < 400, so
  the operator's left was framebuffer x < 936 and the divider read as
  vertical (they held the tablet in landscape).
- Arms 1–3 ran the first `arm.sh` (sha256 `0e347319…`); before arm 4 it
  gained the pair modes and a `ebc-mode.lua --normal` at the start of every
  arm (`358930d1…`, the copy here). The first version had no FAST path and
  never left NORMAL, so arms 1–3 are unaffected.

## Results

| Arm | Screen | Blind | Operator | Truth |
|---|---|---|---|---|
| 1 | split: default 32, one half 0 | yes | "The left section is MUCH faster than the right section and feels plenty speedy. The right section has notable latency when writing." | DU on the left (fb x < 936) — correct |
| 2 | split, fresh coin | yes | "right side is much faster this time, left lags" | DU on the right — correct |
| 3 | whole screen hint 0 (DU) | no | "du over whole screen feels great!" | — |
| 4 | pair, first | yes | "I think this is FAST but it doesn't feel a lot better to me and I am not sure yet" | FAST |
| 5 | pair, second | yes | final verdict on the pair: "honestly, I can't tell" | whole-screen DU, NORMAL |

- Two of two blinded split arms were called correctly (one in four by
  chance), and the operator described the gap as large both times.
- FAST against DU in NORMAL: not told apart by feel. The operator's lean in
  arm 4 was right, but they declined to call it.
- Software path, last event timestamp to `fsync` returned: median 0.7 ms,
  p95 1.3–1.5 ms in every arm (65,669 batches; max 23.1 ms, once).
- **Digitizer report rate: 2.77 ms median, about 360 Hz** (p10–p90
  2.54–2.98 ms), the same pen-down and hovering, in all five captures. This
  is the first measurement of it in the repo. Earlier storage estimates
  assumed 133–200 Hz. Every capture carries X, Y, pressure, tilt X/Y and
  distance.
- The eraser end reports on the Stylus node itself: seven `BTN_TOOL_RUBBER`
  intervals (arm 1: 0.75 s and 1.02 s; arm 3: 0.12, 0.11, 0.34, 0.09 and
  0.78 s), each begun with `BTN_TOOL_PEN` released, carrying `BTN_TOUCH` contact
  (11–310 reports), position and pressure up to ~880 at the same 2.77 ms
  cadence. The operator's pen has a rubber end. The 2026-08-24 capture
  (`../pinenote-input-clocks-20260824/RESULT.md`) had it advertised but not
  observed. `scribble.lua` ignores the tool, so these strokes drew black.
- Washes in NORMAL: 47 frames at ~11.9 ms each. The first wash after leaving
  FAST (arm 5) counted 192 frame interrupts over 2.28 s, with a few frames
  stretched to 17.7–20.3 ms. Unexplained; not investigated.
- `dmesg` over the session: only the periodic temperature-override lines.

Numbers in `stats.txt`, recomputable with `report-rate.py` from the raw
captures, whose hashes it lists. The captures themselves are not committed:
they are the operator's handwriting.

## Restored

`ebc-mode.lua --normal`, `rect-hints.lua --default 32`; sysfs read back
`default_hint` 32 and `redraw_delay` 0, `--query` read mode 0. `herd start
reader-session` (fresh PID; it lands in the file manager by design).
`autosuspend.conf` restored byte for byte (`enabled=1`). Same boot ID at the
end. Battery 73 % → 81 %, charging throughout.

## What this does and does not show

It shows, by blinded feel, three things. On this panel and driver, a region
hinted DU in NORMAL inks much faster than GL16 beside it on the same screen.
The mixed-hint screen works on glass. And this operator cannot feel the
difference between DU in NORMAL and FAST. So a pen canvas does not need
FAST's whole-screen mode switch.

It does not give a latency number (no camera). It does not cover ink drawn
by KOReader: `scribble.lua` writes with `write()`, which bypasses the
250 ms deferred-io timer, while a KOReader canvas draws into the mmap and
must publish every input batch. It also leaves out the gray settle after
pen-up, DC balance and ghosting over long sessions, and the dithered-black
holes the source reading predicts for FAST, which nobody looked for.
