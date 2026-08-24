# KOReader refresh traces — the evidence for issue #14 (2026-08-15)

Raw `[pn-refresh]` traces harvested read-only over SSH from os2 while
the device was in ordinary use. Committed because a reboot rotates
`/var/log/reader-session.log`, and these are the only recorded instances
of the repeated-refresh behaviour in issue #14 — which the operator
reports is **not reproducible on demand**.

| file | traces | source |
|---|---|---|
| `reader-session-rotated.log` | 562 | `/var/log/reader-session.log.1.zst` |
| `reader-session-current.log` | 202 | `/var/log/reader-session.log` |

Combined: **764 traces over 6.2 days**, 2026-08-09 → 2026-08-15, on
image `9a08803e…`.

Trace format, emitted at the decision point in
`pinenote/packages/koreader-device/frontend/device/pinenote/device.lua`:

```
[pn-refresh] <intent> <decision> rect=<x>,<y>,<w>,<h> dither=<d> t=<sec>.<usec>
```

Because the trace fires *before* dispatch, two traces mean **two refresh
requests**, not one request the driver split into two passes. That is
what places issue #14 above the driver rather than in the EBC path the
2026-07-31 publish-on-call work fixed.

## What the analysis found

Full findings are on issue #14. In short: 13 sub-second gaps between
consecutive full-panel `partial`/`partial` refreshes, belonging to only
**5 episodes** — the largest being **8 consecutive full-panel refreshes
in 2.26 s**. The gap distribution is a **continuum**, not bimodal, so any
fixed sub-second threshold is arbitrary; report a sweep instead.
**4 of 5 episodes begin within 15 s of both a `flashui/global` wash and
a full-panel `ui/partial`** — the signature of dismissing a menu (base
rate 7.2 %, P(≥4 of 5) ≈ 1e-4). The exception occurred during steady
reading, so there may be two distinct phenomena.

An earlier analysis of the current log alone put the rate at 2.6 % and
described the distribution as sharply separated. The rate held (3.3 %
over the full series); the sharp separation did not, and was an artifact
of the smaller sample.

## 2026-08-24 — these logs became a test input (appended)

`pinenote/tools/refresh-episodes/test-refresh-triggers.py` now runs the
trigger analyser over **these exact two files** and requires the
published numbers back, so `make refresh-trigger-check` re-derives every
figure in `doc/pageturn-program.md` §6 from this directory. That target
is in `CHECK_HOST_TARGETS`, so CI runs it too. There is no fixture
fallback: if these logs move or change, the gate fails loudly rather
than quietly measuring something else.

Consequence worth stating: **this directory is now load-bearing for a
test, not only a record.** It stays append-only either way.

The full log is the input, not a grep of it. The non-`[pn-refresh]`
lines are what separate a page turn from a document re-render —
`Inhibiting user input` / `Restoring user input handling` bracket
`ReaderRolling:onUpdatePos`, which emits a full-panel `partial/partial`
byte-identical to a page turn. The analyser prints a warning when handed
marker-free input, and the self-test pins that warning.

Two corrections to the analysis recorded above, both from these same
files (details and derivations in `doc/pageturn-program.md` §6.1):

- **The 131 ms "hard floor" is not a floor of the mechanism.** Three
  identical full-panel `ui/partial` repaints occur at 2026-08-09
  01:34:07 with gaps of 210 ms and **68 ms**.
- **The repeated-refresh behaviour is not confined to
  `partial/partial`.** Over full-panel repaints of *any* intent there
  are **11** sub-second runs here, not 5, and the largest is **10
  traces in 3.73 s**.
