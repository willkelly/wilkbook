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
