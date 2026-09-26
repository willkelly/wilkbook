# refresh-episodes — `[pn-refresh]` trace analysis (issue #14)

Two analysers over the same input: KOReader `[pn-refresh]` traces, from
a device's `/var/log/reader-session.log` or from a rung-4vc qemu
campaign harvest.

| script | question | run |
| --- | --- | --- |
| `refresh-episodes.py` | **how often, how big, how clustered** — request gap-threshold sweep, episode runs, menu-antecedent coverage, conditional field comparisons | `make refresh-episodes-check` (self-test); `python3 refresh-episodes.py LOG…` |
| `refresh-triggers.py` | **what asks twice** — the candidate triggers, each scored against the signature it would have to leave | `make refresh-trigger-check` (self-test); `python3 refresh-triggers.py LOG…` |
| `campaign-report.scm` | **was the capture complete, and did analysis succeed?** — validate the snapshot and run both analysers with checked exit status | `guile --no-auto-compile -e main -s campaign-report.scm HARVEST OUT LEDGER` |

The analysers use Python's standard library. The capture/report stage uses
Guile 3 and coreutils (`base64`, `sha256sum`). Tests need no device,
waveform or build. New capture/system tooling is Guile. The two existing
Python analysers remain **legacy migration work**: replacing the episode
analyser in this correction would combine transport changes with a rewrite
of its statistical arithmetic. A later Guile migration must preserve the
CLI/JSON compatibility below and pass both the synthetic and committed
corpus gates. The trigger analyser does not need a wholesale rewrite here.

## Capture fidelity and failure handling

`run-virt-pageturn-campaign.sh` snapshots the guest's current
`/var/log/reader-session.log` once, then harvests that **complete snapshot**
as base64 between line-delimited `WBCAMP-LOG-BEGIN`/`WBCAMP-LOG-END`
markers. `WBCAMP-LOGSTAT` gives its original byte count and SHA-256. Encoding
avoids console CRLF processing, split UTF-8, control bytes and unterminated
last-line loss. Metadata and payload refer to the same snapshot, so reader
appends during transport cannot create a count race.

The Guile report stage rejects missing/duplicate framing, invalid encoding,
size/hash mismatch, missing clock metadata and failed analyzers. The console
harvester exits nonzero on timeout. There is no successful `tee` status to
hide an analyzer failure. Malformed refresh lines and backwards timestamps
within a source log fail analysis instead of silently dropping/reordering
events. A failed QMP driver or missing `PLAN-END` also fails the campaign.

Artifacts under the campaign output directory:

* `harvest.txt`: raw console transport, including host clock samples;
* `reader-session.base64`, `reader-session.log`: encoded and validated full log;
* `reader-session.log.partial`: retained on decode/validation failure;
* `capture-validation.txt`: byte/hash validation and harvest clock interval;
* `episodes.txt` / `episodes.json`, `triggers.txt` / `triggers.json`: both
  analyses of the full log; failed analyzer stdout/stderr stays in its text file;
* `report-driver.out`: validation/analysis failure diagnostics.

`pn-refresh.log` (grep-only input) and the unqualified `clock-offset.txt` are
replaced by the full log and the clock interval report. A validated snapshot
does not recover already rotated logs or prove that every publishing path
emits `[pn-refresh]`.

Run the transport/error-path gate with:

```
guile --no-auto-compile -s pinenote/tools/refresh-episodes/test-campaign-capture.scm
```

It covers complete UTF-8/binary logs, CRLF transport, missing/truncated/
corrupted captures, console noise, duplicate framing, missing clocks, and
failing/missing analyzers (including failure of the second analyzer). Test
artifacts stay in this tool's ignored `build/` directory.

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

`test-refresh-episodes.py` replays a **synthetic** fixture reconstructed
from the issue's published structure, and pins CLI results against the
committed corpus: 764 traces, 412 full-panel partials, 283 pairs within
the default 30 s cap (distinct from the issue's historical 399 denominator),
five episodes, four menu hits and a 131 ms observed partial/partial minimum.
The context fixture tests missing antecedents and uncertain input attribution.

## Interpretation and output compatibility

* **Request-only semantics.** A trace is emitted before dispatch. The
  reports do not count completed refreshes, visible double draws or a
  visible-defect rate. A wash-then-ui sequence is two requests; it does not
  by itself identify one dismissal or two visible passes.
* **Antecedent coverage.** Zero eligible flash/global or full-panel
  ui/partial lookbacks explicitly means the conjunction was unexercised.
  Leading lookback windows are reported as unverified; a truncated history
  cannot establish that no antecedent occurred.
* **Context.** Missing bracket/wash markers or missing/inconsistent marker
  clock alignment prevent D/E exclusion verdicts. A source-based exclusion
  still depends on the recorded reader context. A notebook may publish ink
  or Refresh directly, outside `[pn-refresh]`; neither tool measures those
  requests, even when the full session log contains notebook activity.
* **Clock alignment.** No `--clock-offset` means no ledger attribution.
  An offset alone has unknown uncertainty. `--clock-uncertainty WIDTH`
  specifies an offset interval `[offset, offset+WIDTH]`. The campaign
  bounds this interval with host command-send/receipt stamps around guest
  `date`; it assumes no wall-clock step during the exchange and does not
  measure drift over the campaign. Host command timestamps are not guest
  input or gesture timestamps. Preceding MARKs are nominal, conditional
  associations; the report flags when the interval can reverse their order.
  Trigger markers have second-resolution stamps; offset range and discarded
  unstamped markers are reported, rather than treating median alignment as exact.
* **Conditional statistics.** Published binomial calculations are retained
  for reproducibility, not presented as iid population evidence. Adjacent
  pairs overlap, episodes cluster, reading behaviour differs, and the field
  corpus is one selected operator/image. These calculations do not bound
  non-reproduction or establish a defect rate. Observed minima are sample
  statistics, not hard floors of a mechanism.

Existing numerical JSON keys are preserved, including `field_bound`,
`p_value` and `identical_repeat_floor_ms`. Their interpretation is qualified
by new `semantics`, `statistical_interpretation` and `coverage` fields.
`identical_repeat_min_ms` aliases the last key under an accurate name.
Episodes also include `clock_alignment` and `antecedent_coverage`; a
`preceding_mark` is explicitly conditional and can carry `dt_interval_s`.

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
