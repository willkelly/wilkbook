#!/usr/bin/env python3
"""Episode analysis for [pn-refresh] traces — the analysis half of GitHub issue #14.

Reads any stream of KOReader `[pn-refresh]` trace lines (a harvested
qemu-virt campaign log, or a copy of a device's own
/var/log/reader-session.log) and reports the structure the issue's
re-analysis established has to be reported:

  * a gap-threshold SWEEP, not a single sub-second count.  The real gap
    distribution is a continuum with no valley at 1 s — the largest
    multiplicative step anywhere in its low tail is x1.48 — so any fixed
    cutoff is a cut of convenience and one number hides that.
  * EPISODE structure.  The 13 real sub-second gaps belong to 5
    episodes, the largest being 8 consecutive full-panel refreshes in
    2.26 s.  "Two-step page turn" undercounts that by a factor of four,
    so runs are counted, not pairs.
  * the MENU-DISMISSAL antecedent.  4 of the 5 real episodes begin
    within 15 s of BOTH a flash*/global wash and a full-panel ui/partial
    repaint — the signature of opening and dismissing a KOReader menu —
    against a 7.2 % base rate over all full-panel partial traces
    (binomial P(>=4 of 5) ~ 1e-4).  This tool recomputes that
    association, and its base rate, on whatever log it is given.

Nothing here is specific to the harness: the same numbers come out of a
device log, which is the point — an offline run is only meaningful if it
is scored the same way the field data was.

This script answers "how often, how big, how clustered".  Its sibling
`refresh-triggers.py` answers "what asks twice", and needs the WHOLE
session log rather than the trace lines alone.  Two of its findings bear
on the numbers below and are recorded in `doc/pageturn-program.md` §6.1:
the 131 ms figure this script reports as a "hard floor" is the low end of
one intent's tail, not a floor of the mechanism (identical full-panel
`ui` repaints occur 68 ms apart in the same corpus); and restricting the
population to `partial`/`partial`, as this script does by design, hides
that the same behaviour appears on the `ui`, `flash*` and `full` paths.

Trace grammar (device.lua's trace(), one line per refresh DECISION,
emitted before dispatch):

    [pn-refresh] <intent> <decision> rect=<x>,<y>,<w>,<h> dither=<d> t=<sec>.<usec>

Panel extent is DISCOVERED, not assumed: the device paints 1404x1872
portrait, the qemu-virt harness 1872x1404 landscape, and hard-coding
either silently scores the other as "no full-panel refreshes at all".

CLI:  refresh-episodes.py TRACEFILE [TRACEFILE...]
        [--window 15] [--pair-cap 30] [--json out.json]
        [--ledger action-ledger.txt] [--clock-offset SECONDS]
Pure stdlib.
"""
from __future__ import annotations

import argparse
import json
import math
import re
import sys

TRACE_RE = re.compile(
    r"\[pn-refresh\]\s+(?P<intent>\S+)\s+(?P<decision>\S+)\s+"
    r"rect=(?P<x>-?\d+),(?P<y>-?\d+),(?P<w>-?\d+),(?P<h>-?\d+)\s+"
    r"dither=(?P<dither>\S+)\s+t=(?P<t>\d+\.\d+)"
)

# The sweep.  Deliberately dense below 1 s and sparse above: the question
# is where (if anywhere) a boundary exists, and a coarse grid would
# manufacture one.
DEFAULT_THRESHOLDS = [0.10, 0.15, 0.20, 0.25, 0.30, 0.40, 0.50, 0.70,
                      1.00, 1.25, 1.50, 2.00, 3.00]

HIST_EDGES = [0.0, 0.10, 0.15, 0.20, 0.30, 0.40, 0.50, 0.70, 1.00,
              1.50, 2.00, 3.00, 5.00, 10.00, 30.00, float("inf")]

# The field rates from the issue-#14 re-analysis, as (threshold_s, k, n)
# over its 399 adjacent full-panel pairs.  Used only to ask "would this
# log have shown the defect if it occurred at the field rate?" — which is
# the only honest thing a NON-reproduction can report.  Counts come from
# the published sorted low tail:
#   <0.5 s : 131 184 214 232 277 298 307 322 322 391          = 10
#   <1.0 s : the same plus 503 746 933                        = 13
FIELD_RATES = [(0.5, 10, 399), (1.0, 13, 399)]


class Trace:
    __slots__ = ("intent", "decision", "x", "y", "w", "h", "dither", "t", "line")

    def __init__(self, m, line):
        self.intent = m.group("intent")
        self.decision = m.group("decision")
        self.x = int(m.group("x"))
        self.y = int(m.group("y"))
        self.w = int(m.group("w"))
        self.h = int(m.group("h"))
        self.dither = m.group("dither")
        self.t = float(m.group("t"))
        self.line = line

    @property
    def area(self):
        return self.w * self.h

    def __repr__(self):
        return "%.6f %s/%s %dx%d" % (self.t, self.intent, self.decision,
                                     self.w, self.h)


def parse(paths):
    traces, unparsed = [], 0
    for path in paths:
        with open(path, "r", errors="replace") as fh:
            for line in fh:
                if "[pn-refresh]" not in line:
                    continue
                m = TRACE_RE.search(line)
                if m:
                    traces.append(Trace(m, line.rstrip("\n")))
                else:
                    unparsed += 1
    traces.sort(key=lambda tr: tr.t)
    return traces, unparsed


FULL_PANEL_TOL = 0.90


def panel_extent(traces):
    """Discover the panel geometry as the most common near-maximal rect.

    Two traps this has to survive, both seen in real trace streams:

     * KOReader emits rects that are LARGER than the panel.  A menu
       wash traces `rect=-28,0,1460,1872` on a 1404-wide panel — a
       negative origin and 56 px of overhang.  Anchoring on the maximum
       area alone therefore adopts 1460x1872 as "the panel", after which
       every genuine 1404x1872 page turn scores as NOT full-panel and
       the analysis silently reports zero page turns.
     * taking max width and max height independently would invent a
       geometry no trace ever had if the reader rotated mid-log.

    So: among rects within 15 % of the largest by area, take the most
    FREQUENT (w,h) — page turns are the commonest full-panel event by a
    wide margin — and break ties toward the smaller rect.
    """
    if not traces:
        return None
    best_area = max(tr.area for tr in traces)
    counts = {}
    for tr in traces:
        if tr.area >= 0.85 * best_area:
            counts[(tr.w, tr.h)] = counts.get((tr.w, tr.h), 0) + 1
    return max(counts.items(), key=lambda kv: (kv[1], -kv[0][0] * kv[0][1]))[0]


def is_full_panel(tr, extent, tol=FULL_PANEL_TOL):
    if extent is None:
        return False
    return tr.area >= tol * (extent[0] * extent[1])


def gaps_between(seq):
    return [(seq[i + 1].t - seq[i].t, seq[i], seq[i + 1])
            for i in range(len(seq) - 1)]


def episodes_at(seq, threshold):
    """Maximal runs of >=2 traces whose every internal gap is < threshold."""
    out, run = [], [seq[0]] if seq else []
    for i in range(len(seq) - 1):
        if seq[i + 1].t - seq[i].t < threshold:
            run.append(seq[i + 1])
        else:
            if len(run) >= 2:
                out.append(run)
            run = [seq[i + 1]]
    if len(run) >= 2:
        out.append(run)
    return out


def antecedents(t0, traces, extent, window):
    """The menu open/dismiss signature, reported as its two components.

    The issue's test is the CONJUNCTION: a flash*/global wash AND a
    full-panel ui/partial repaint, both within `window` before t0.  The
    conjunction matters — a wash alone is also what the every-N-pages
    full refresh produces, and a full-panel ui/partial alone is also
    what a footer promotion produces; only together are they a menu.

    The components are returned separately as well because a harness
    does not necessarily reproduce both halves.  On qemu-virt the
    KOReader top menu washes on open AND on dismiss, so the wash half
    fires and the ui half may not; reporting only the conjunction would
    turn that into a bare "0 hits" and hide the fact that half the
    signature was present.  Scoring all three keeps an offline run
    comparable to the field numbers instead of merely similar-sounding.
    """
    flash = ui = None
    for tr in traces:
        if tr.t >= t0:
            break
        if t0 - tr.t > window:
            continue
        if tr.intent.startswith("flash") and tr.decision == "global":
            flash = t0 - tr.t
        elif tr.intent == "ui" and tr.decision == "partial" and is_full_panel(tr, extent):
            ui = t0 - tr.t
    return flash, ui


def has_menu_antecedent(t0, traces, extent, window):
    flash, ui = antecedents(t0, traces, extent, window)
    return (flash is not None and ui is not None), flash, ui


def binom_at_least(k, n, p):
    if p <= 0:
        return 1.0 if k == 0 else 0.0
    if p >= 1:
        return 1.0
    return sum(math.comb(n, i) * p ** i * (1 - p) ** (n - i)
               for i in range(k, n + 1))


def histogram(values, edges):
    rows = []
    for lo, hi in zip(edges, edges[1:]):
        n = sum(1 for v in values if lo <= v < hi)
        rows.append((lo, hi, n))
    return rows


def load_ledger(path, clock_offset):
    """Host-side action ledger -> guest-clock action times.

    Secondary evidence only.  The primary antecedent test reads the
    trace stream itself, exactly as the field analysis did, so that an
    offline result and a device result are the same measurement.  The
    ledger answers a different question the field data cannot: which tap
    the harness actually issued before an episode.
    """
    actions = []
    with open(path, "r", errors="replace") as fh:
        for line in fh:
            parts = line.split()
            if len(parts) < 2:
                continue
            try:
                ts = float(parts[0])
            except ValueError:
                continue
            actions.append((ts + clock_offset, parts[1],
                            parts[2] if len(parts) > 2 else ""))
    actions.sort()
    return actions


def preceding_action(t0, actions, window):
    best = None
    for ts, verb, detail in actions:
        if ts >= t0:
            break
        if t0 - ts <= window and verb == "MARK":
            best = (t0 - ts, detail)
    return best


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("traces", nargs="+", help="file(s) containing [pn-refresh] lines")
    ap.add_argument("--window", type=float, default=15.0,
                    help="menu-antecedent lookback, seconds (default 15)")
    ap.add_argument("--pair-cap", type=float, default=30.0,
                    help="ignore adjacent pairs further apart than this (default 30 s)")
    ap.add_argument("--thresholds", type=str, default="",
                    help="comma-separated sweep thresholds in seconds")
    ap.add_argument("--report-threshold", type=float, default=1.0,
                    help="threshold whose episodes get the detailed table (default 1.0)")
    ap.add_argument("--ledger", type=str, default="")
    ap.add_argument("--clock-offset", type=float, default=0.0,
                    help="seconds to ADD to ledger host timestamps to reach guest clock")
    ap.add_argument("--json", type=str, default="")
    ap.add_argument("--no-field-bound", action="store_true",
                    help="skip the comparison against the issue-#14 field rates")
    args = ap.parse_args(argv)

    thresholds = ([float(v) for v in args.thresholds.split(",") if v.strip()]
                  if args.thresholds else DEFAULT_THRESHOLDS)

    traces, unparsed = parse(args.traces)
    out = {"traces": len(traces), "unparsed": unparsed}

    print("=" * 72)
    print("[pn-refresh] episode analysis  (issue #14 signature logic)")
    print("=" * 72)
    if not traces:
        print("no [pn-refresh] traces found in %s" % ", ".join(args.traces))
        return 1

    span = traces[-1].t - traces[0].t
    extent = panel_extent(traces)
    out["extent"] = list(extent) if extent else None
    out["span_s"] = span
    print("traces            : %d  (%d unparsed)" % (len(traces), unparsed))
    print("span              : %.1f s (%.2f h)" % (span, span / 3600.0))
    print("panel extent      : %dx%d  (discovered from the traces)" % extent)

    by_kind = {}
    for tr in traces:
        by_kind["%s/%s" % (tr.intent, tr.decision)] = \
            by_kind.get("%s/%s" % (tr.intent, tr.decision), 0) + 1
    print("trace kinds       : " + ", ".join(
        "%s=%d" % (k, v) for k, v in sorted(by_kind.items(), key=lambda kv: -kv[1])))
    out["kinds"] = by_kind

    # ---- the population the issue measured: full-panel partial/partial ----
    fullpart = [tr for tr in traces
                if tr.intent == "partial" and tr.decision == "partial"
                and is_full_panel(tr, extent)]
    print("full-panel partial/partial : %d" % len(fullpart))
    out["full_panel_partials"] = len(fullpart)
    if len(fullpart) < 2:
        print("\nfewer than two full-panel partial refreshes: nothing to pair.")
        if args.json:
            json.dump(out, open(args.json, "w"), indent=2)
        return 0

    all_gaps = gaps_between(fullpart)
    capped = [g for g in all_gaps if g[0] <= args.pair_cap]
    gv = sorted(g[0] for g in capped)
    print("adjacent pairs     : %d total, %d within the %.0f s cap"
          % (len(all_gaps), len(capped), args.pair_cap))
    if gv:
        print("gap median         : %.3f s   p10 %.3f s   min %.3f s"
              % (gv[len(gv) // 2], gv[max(0, int(0.1 * len(gv)) - 1)], gv[0]))
        out["gap_median_s"] = gv[len(gv) // 2]
        out["gap_min_s"] = gv[0]

    # ---- the sweep ----
    print("\n" + "-" * 72)
    print("GAP-THRESHOLD SWEEP  (a single cut would be arbitrary: the field")
    print("distribution is a continuum with no valley at 1 s)")
    print("-" * 72)
    print("%8s %8s %9s %9s %8s   %s"
          % ("thresh", "gaps<T", "episodes", "max run", "hits", "P(>=hits | base)"))
    # Base rate is a property of the log, not of the threshold — computing
    # it inside the sweep re-walks every trace once per threshold.
    base_hits = sum(1 for tr in fullpart
                    if has_menu_antecedent(tr.t, traces, extent, args.window)[0])
    base = base_hits / len(fullpart)
    sweep = []
    for T in thresholds:
        eps = episodes_at(fullpart, T)
        n_gaps = sum(1 for g in capped if g[0] < T)
        maxrun = max((len(e) for e in eps), default=0)
        hits = 0
        for e in eps:
            ok, _, _ = has_menu_antecedent(e[0].t, traces, extent, args.window)
            hits += 1 if ok else 0
        p = binom_at_least(hits, len(eps), base) if eps else float("nan")
        sweep.append({"threshold_s": T, "gaps_below": n_gaps,
                      "episodes": len(eps), "max_run": maxrun,
                      "menu_hits": hits, "base_rate": base, "p_value": p})
        print("%8.2f %8d %9d %9d %8s   %s"
              % (T, n_gaps, len(eps), maxrun,
                 ("%d/%d" % (hits, len(eps))) if eps else "-",
                 ("%.3g" % p) if eps else "-"))
    out["sweep"] = sweep
    out["menu_base_rate"] = sweep[0]["base_rate"] if sweep else None
    print("\nmenu-antecedent base rate over all %d full-panel partials: %.1f %%"
          % (len(fullpart), 100.0 * (sweep[0]["base_rate"] if sweep else 0)))
    print("(antecedent = a flash*/global wash AND a full-panel ui/partial,")
    print(" both within %.0f s before — the menu open/dismiss signature)" % args.window)

    # Both halves separately: a run in which only one half ever occurs
    # would otherwise report a flat 0 and look like the menu simply
    # never happened.
    n_flash = n_ui = 0
    for tr in fullpart:
        f, u = antecedents(tr.t, traces, extent, args.window)
        n_flash += 1 if f is not None else 0
        n_ui += 1 if u is not None else 0
    print("  component base rates: flash*/global %.1f %%   full-panel ui/partial %.1f %%"
          % (100.0 * n_flash / len(fullpart), 100.0 * n_ui / len(fullpart)))
    out["component_base_rates"] = {"flash_global": n_flash / len(fullpart),
                                   "ui_fullpanel": n_ui / len(fullpart)}
    if n_ui == 0:
        print("  NOTE: no full-panel ui/partial occurs anywhere in this log, so the")
        print("        conjunction CANNOT fire — read the flash*/global column instead.")

    # ---- power: would the field rate have shown up in this log? ----
    #
    # A non-reproduction is only worth anything with a bound attached.
    # "We saw none" is compatible with both "it does not happen here"
    # and "we did not look long enough"; the binomial separates them.
    if not args.no_field_bound:
        print("\n" + "-" * 72)
        print("BOUND vs the field rate  (what a NON-reproduction is worth)")
        print("-" * 72)
        bounds = []
        for T, k, n in FIELD_RATES:
            rate = k / n
            obs = sum(1 for g in capped if g[0] < T)
            p_le = sum(math.comb(len(capped), i) * rate ** i *
                       (1 - rate) ** (len(capped) - i) for i in range(obs + 1))
            bounds.append({"threshold_s": T, "field_rate": rate,
                           "observed": obs, "pairs": len(capped), "p_le": p_le})
            print("  gaps < %.2f s: field %d/%d = %.2f %%; here %d/%d.  "
                  "P(<=%d | field rate) = %.3g"
                  % (T, k, n, 100 * rate, obs, len(capped), obs, p_le))
        out["field_bound"] = bounds
        print("  (this compares RATES PER ADJACENT PAIR only; it does not")
        print("   claim the two logs sampled the same reading behaviour)")

    # ---- low tail, as ratios: is there a boundary at all? ----
    print("\n" + "-" * 72)
    print("LOW TAIL, each gap as a ratio of the previous (a real boundary")
    print("would show as a large multiplicative step)")
    print("-" * 72)
    tail = gv[:24]
    if tail:
        cells = ["%d" % round(tail[0] * 1000)]
        for a, b in zip(tail, tail[1:]):
            cells.append("%d(x%.2f)" % (round(b * 1000), (b / a) if a > 0 else float("inf")))
        line = ""
        for c in cells:
            if len(line) + len(c) + 2 > 70:
                print("  " + line); line = ""
            line += c + "  "
        if line:
            print("  " + line)
        steps = [(b / a, a, b) for a, b in zip(tail, tail[1:]) if a > 0]
        if steps:
            biggest = max(steps)
            print("  largest step in the low tail: x%.2f at %d -> %d ms"
                  % (biggest[0], round(biggest[1] * 1000), round(biggest[2] * 1000)))
            out["largest_low_tail_step"] = biggest[0]
        print("  hard floor (fastest gap ever seen): %d ms" % round(gv[0] * 1000))

    # ---- histogram ----
    print("\n" + "-" * 72)
    print("HISTOGRAM of all %d adjacent gaps within the %.0f s cap"
          % (len(capped), args.pair_cap))
    print("-" * 72)
    rows = histogram([g[0] for g in capped], HIST_EDGES)
    scale = max((n for _, _, n in rows), default=1) or 1
    for lo, hi, n in rows:
        hi_s = "inf" if hi == float("inf") else "%.2f" % hi
        print("  [%5.2f,%6s) %5d %s" % (lo, hi_s, n, "#" * int(40 * n / scale)))
    out["histogram"] = [{"lo": lo, "hi": None if hi == float("inf") else hi, "n": n}
                        for lo, hi, n in rows]

    # ---- episode detail at the reporting threshold ----
    T = args.report_threshold
    eps = episodes_at(fullpart, T)
    print("\n" + "-" * 72)
    print("EPISODES at T = %.2f s  (runs of >=2; >2 is the structure the" % T)
    print("field data showed and 'two-step page turn' misses)")
    print("-" * 72)
    actions = load_ledger(args.ledger, args.clock_offset) if args.ledger else []
    detail = []
    if not eps:
        print("  none.")
    for e in eps:
        internal = [round(1000 * (e[i + 1].t - e[i].t)) for i in range(len(e) - 1)]
        ok, dflash, dui = has_menu_antecedent(e[0].t, traces, extent, args.window)
        rec = {"t0": e[0].t, "n": len(e), "gaps_ms": internal,
               "menu_antecedent": ok,
               "flash_global_s": dflash, "ui_fullpanel_s": dui}
        line = "  t=%.3f  n=%d  gaps=%s ms  %s" % (
            e[0].t, len(e), ",".join(str(g) for g in internal),
            "HIT" if ok else "miss")
        line += "  (flash_global %s, ui_fullpanel %s)" % (
            ("%.2fs" % dflash) if dflash is not None else "--",
            ("%.2fs" % dui) if dui is not None else "--")
        if actions:
            pa = preceding_action(e[0].t, actions, args.window)
            if pa:
                line += "  [last MARK %.2fs before: %s]" % pa
                rec["preceding_mark"] = {"dt": pa[0], "label": pa[1]}
        print(line)
        detail.append(rec)
    out["episodes_at_report_threshold"] = {"threshold_s": T, "episodes": detail}

    runs_gt2 = [d for d in detail if d["n"] > 2]
    print("\n  episodes with more than 2 refreshes: %d" % len(runs_gt2))
    if eps:
        hits = sum(1 for d in detail if d["menu_antecedent"])
        base = out["menu_base_rate"] or 0.0
        p = binom_at_least(hits, len(eps), base)
        print("  menu antecedent: %d of %d episodes (base rate %.1f %%), "
              "P(>=%d) = %.3g" % (hits, len(eps), 100 * base, hits, p))
        out["report_threshold_summary"] = {
            "episodes": len(eps), "menu_hits": hits,
            "base_rate": base, "p_value": p, "runs_gt2": len(runs_gt2)}

    # ---- repeated washes: the issue's incidental finding ----
    washes = [tr for tr in traces if tr.decision == "global"]
    wash_gaps = [round(1000 * g[0]) for g in gaps_between(washes) if g[0] < 2.0]
    print("\n  repeated global washes < 2 s apart: %d  %s"
          % (len(wash_gaps), wash_gaps[:20] if wash_gaps else ""))
    out["rapid_wash_gaps_ms"] = wash_gaps

    if args.json:
        with open(args.json, "w") as fh:
            json.dump(out, fh, indent=2, default=str)
        print("\njson -> %s" % args.json)
    return 0


if __name__ == "__main__":
    sys.exit(main())
