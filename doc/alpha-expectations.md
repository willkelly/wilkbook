# What to expect from the alpha

You have a PineNote running wilkbook's reader image. This page says what
it should *feel* like, what is known-broken, and what to report. It is
the operator's calibration, written 2026-08-08 — if your device does
worse than this, that's a bug report; if it does better, brag.

## The feel

- **Page turns should feel snappier than the stock Debian image.** One
  pass per turn: the page draws once, completely. No settle-then-redraw.
- **Few or no full-screen flashes.** The black-white-black inversion
  flash should be rare — not on ordinary page turns, not on menus. An
  occasional deliberate full wash (ghost-clearing) is normal after many
  pages or on resume.
- **Few or no two-part updates.** You should not see a page write partly,
  pause, and then finish in a second write. That defect class is what a
  lot of this repo's display work killed; seeing it again matters.
- **Menus open and close fast, without blinking.** Tapping into the menu
  and back out should not flash the screen.
- **Touch works.** Taps, swipes, the file browser.
- **The stylus works as a pointer** — taps and UI interaction — but
  **there is no drawing or writing yet**. No notes app, no annotation.
  That's roadmap, not regression.
- **Auto-rotation works.** The accelerometer is live and the screen
  follows the device through all four orientations (hardware-validated
  2026-07-19, re-verified on the 2026-08-07 acceptance). Rotation can be
  locked from KOReader if you prefer it pinned.

## The battery

- **Active reading: roughly 1.3× stock Debian's runtime.** Measured
  awake floor is 156.9 mA (frontlight off) against ~230 mA stock idle on
  the same hardware; the 1.3× is the operator's conservative real-use
  estimate, not the raw ratio.
- **Suspend: the target is more than 30 days.** Measured suspend draw is
  4.64 mA (2026-08-08, doc/artifacts/pinenote-ultra-r12-20260808/),
  which is ~36 days of pure suspend on paper. A multi-day real-use soak
  is in progress; until it concludes, treat ">30 days" as arithmetic
  with one good measurement behind it, not a promise.
- The device suspends itself after ~5 idle minutes (page + SUSPENDED
  banner, frontlight off), and a short power press suspends or wakes it
  on demand.
- **If it never sleeps at all** — no banner, Wi-Fi stays up, the power
  button does nothing — auto-suspend is *paused*, not broken. Check
  `/data/wilkbook/autosuspend.conf` and
  `/var/lib/pinenote/autosuspend.conf`; either holding `enabled=0`
  pauses everything, and the second one wins. Set `enabled=1` or delete
  it (no restart needed). An earlier version of the install page told
  people to create that file and never told them to undo it, so this is
  the most likely first-boot symptom rather than an exotic one.
- **Closing the cover suspends it — if your cover's magnet reaches the
  sensor.** The switch is wired, armed, and the software treats a close
  as a suspend request; but the author's own cover does not actuate it
  (`gpio-23` never changes state), so this path is **untested on real
  hardware**. If yours works, that is genuinely new information. Waking is a single short press. **If a press ever fails to
  wake it, note the time and tell the operator before force-restarting
  it** — a stuck device carries forensic evidence that a 10-second
  power-hold destroys.

## Known not-working (told to you rather than discovered by you)

- **The Wi-Fi UI does not work.** There is no on-device network picker.
  Credentials are staged out of band (a file on the data partition —
  `doc/install.md`); once staged, Wi-Fi associates at boot on its own.
- **The brightness UI may or may not work.** The frontlight comes on at
  boot and turns off in suspend; adjusting it from KOReader's own
  slider is unvalidated. If it works for you, say so — that's data.
- **No Wi-Fi UI also means no on-device book downloads.** Books arrive
  by `scp` to `/data/books`, or were already in your library.
- Settings you change in KOReader menus persist across suspends but
  **reset on a reflash** (they live on the OS partition; your books and
  reading positions live on the data partition and survive).

## Reporting

Three kinds of report, in descending urgency:

1. **It won't wake / it needed a 10-second hold** — timestamp, what you
   were doing, don't force it off until asked (see above).
2. **Display artifacts** — flashes on ordinary turns, two-part draws,
   residue that builds up page over page: describe or photograph.
3. **Anything on the known-not-working list behaving *better* than
   documented** — genuinely useful, the docs get updated.
