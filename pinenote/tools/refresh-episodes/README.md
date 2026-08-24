# refresh-episodes — `[pn-refresh]` trace analysis (issue #14)

Two analysers over the same input: KOReader `[pn-refresh]` traces, from
a device's `/var/log/reader-session.log` or from a rung-4vc qemu
campaign harvest.

| script | question | run |
| --- | --- | --- |
| `refresh-episodes.py` | **how often, how big, how clustered** — gap-threshold sweep, episode runs, the menu antecedent, and the bound a non-reproduction is worth | `make refresh-episodes-check` (self-test); `python3 refresh-episodes.py LOG…` |
| `refresh-triggers.py` | **what asks twice** — the candidate triggers, each scored against the signature it would have to leave | `make refresh-trigger-check` (self-test); `python3 refresh-triggers.py LOG…` |

Both are pure stdlib. Neither needs a device, a waveform, or a build.

## The input, and the one way to get it wrong

`refresh-triggers.py` wants **the whole session log**, not a grep of the
`[pn-refresh]` lines. KOReader's other INFO lines are load-bearing:

* `Inhibiting user input` / `Restoring user input handling`
  (`input.lua:1610/1650`) bracket `ReaderRolling:onUpdatePos`, the
  document re-render — which emits a full-panel region-less `partial`
  that is **byte-identical to a page turn** in the trace stream. Without
  the brackets there is no way to tell the two apart.
* `[idlewasher] …` marks every wash the wilkbook plugin fires.
* `opening file …` separates a document open from a re-render.

Hand it a grep and sections D and E go vacuous. The tool prints a
warning when it sees no marker lines at all; the self-test pins that
warning, because a silent 0-of-0 would read as an elimination.

## Committed evidence

`doc/artifacts/pinenote-refresh-traces-20260815/` holds the 764 traces
from six days of the author's reading (2026-08-09 → 08-15, image
`9a08803e…`). `test-refresh-triggers.py` runs the analyser over exactly
those files and requires the published numbers back, so every figure in
the issue-#14 trigger writeup is one command from being re-derived. That
is the whole reason the logs are in the tree.

`test-refresh-episodes.py` instead replays a **synthetic** fixture
reconstructed from the issue's published structure — see its docstring
for why, and for what that does and does not prove.

## What the trigger analysis covers

Five candidates, each with a trace-level signature:

| | candidate | signature it must leave |
| --- | --- | --- |
| A | footer / progress bar promoted to full page | a bottom-strip repaint in or beside an episode |
| B | a second paint from the animation / partial-rerendering path | `fast`/`a2` traces; ≥3 repeats of one small `ui` rect (the crengine rerender status icon) |
| C | a genuine double input event | none — no input is logged; only the repeats' cadence can be characterised |
| D | a document re-render (`ReaderRolling:onUpdatePos`) | an episode trace inside an `INHIBIT`/`RESTORE` bracket |
| E | the wilkbook idle washer | an `[idlewasher]` line beside an episode |

The output is a scorecard, and `NOT SEPARABLE FROM THIS DATA` is one of
its verdicts. A candidate that the data cannot reach is reported as
unreachable rather than quietly dropped.

## What neither script covers

* **Anything optical.** These are refresh *requests*. Whether the panel
  visibly drew twice is a camera question (`pinenote/tools/optics`).
* **Input.** No `[pn-refresh]` trace can see a tap, a swipe, or a pen
  button, so no amount of this analysis settles candidate C.
* **Causation.** Every association here is an association in one
  operator's six days on one image. Nothing in it is hardware-proven.
* **The panel's own timing.** `refreshPartialImp` traces and then
  `fsync`s; `fsync` runs the deferred-io flush and returns, it does not
  wait out the e-ink pass. Trace-to-trace gaps are therefore caller
  timing, not panel service time.
