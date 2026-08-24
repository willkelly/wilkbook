#!/usr/bin/env python3
"""Trigger analysis for [pn-refresh] episodes -- the *cause* half of issue #14.

`refresh-episodes.py` answers "how often, how big, how clustered".  This
answers the question that one leaves open: **what asks for the second
refresh**.  It mines a KOReader session log for the signature each
candidate trigger would have to leave, and scores the candidates against
what is actually there.

It reads the WHOLE session log, not just the `[pn-refresh]` lines.  That
is the point.  KOReader's own INFO lines ("Inhibiting user input",
"[idlewasher] ...", "opening file ...", "TOC had N bogus page numbers")
bracket code paths that ALSO emit full-panel repaints, and the trace
stream alone cannot tell a page turn from a document re-render: both are
`partial partial rect=0,0,1404,1872`, identical in every field but the
timestamp.  Feeding this tool a grep of the trace lines silently
disables sections D and E.

Candidates, and the signature each would leave.  Sources are the
KOReader 2026.03 bundle this image ships plus
pinenote/packages/koreader-device:

  A. footer / progress-bar repaint promoted to full page.
     ReaderFooter's repaint paths (readerfooter.lua ~2339/2344) always
     pass a REGION -- `footer_content.dimen`, or the footer strip -- and
     always mode "ui"/"fast", never a region-less "partial".  The one
     region-less "partial" it can ask for (`refreshFooter`'s signal
     branch, readerfooter.lua:2619) is guarded on
     `document.provider ~= "crengine"`, which an epub cannot reach.
     UIManager never ENLARGES a region except by merging with a
     colliding refresh already enqueued in the same `_repaint` drain --
     and a merge yields ONE trace, not two.  Signature: footer-strip
     traces exist and each traces at its own rect; if the footer were
     the second painter, footer-strip traces would appear inside or
     beside the episodes.  Measured below.

  B. a second paint from the page-turn / animation path.
     Every animation-ish path downgrades to "fast" or "a2"
     (uimanager.lua's `currently_scrolling`, ReaderScrolling), and
     crengine's partial-rerendering automation cycles a status icon at
     ReaderFlipping's rect with mode "ui" on each state change
     (readerrolling.lua ~1872) -- at least three per automation run.
     Signature: `fast`/`a2` traces, and >=3 repeats of one small rect.
     Both counted below.

  C. a genuine double input event.
     Nothing in the log records input, so this cannot be confirmed or
     refuted here.  It can be CHARACTERISED: a machine-paced repeat (a
     bouncing contact, a driver-level double report) produces runs with
     a tight internal cadence; two independent human actions do not.
     Reported as each episode's internal-gap coefficient of variation
     against the same statistic over ordinary reading.

  D. a document re-render (ReaderRolling:onUpdatePos).
     Emits a full-panel region-less "partial" (readerrolling.lua:1056)
     that is INDISTINGUISHABLE from a page turn in the trace stream --
     but it is bracketed by Input:inhibitInput(true)/(false), which log
     "Inhibiting user input" / "Restoring user input handling"
     (input.lua:1610/1650).  Signature: an episode trace inside such a
     bracket.  Every episode trace is tested against every bracket.

  E. the wilkbook idle washer.
     Its three actions each log a "[idlewasher] ..." line and each fires
     `setDirty("all","full")` -> a `full`/`global` trace, never a
     partial.  Signature: an "[idlewasher]" line beside an episode.

Nothing here decides anything on its own.  The output is a scorecard:
per candidate, the measurement, and whether that measurement excludes
it, leaves it open, or cannot separate it at all.  "Cannot separate" is
a real answer and is printed as one.

CLI:  refresh-triggers.py LOGFILE [LOGFILE...]
        [--threshold 1.0] [--window 15] [--json out.json]
Pure stdlib.
"""
from __future__ import annotations

import argparse
import bisect
import calendar
import json
import math
import re
import statistics
import sys
import time as _time

TRACE_RE = re.compile(
    r"\[pn-refresh\]\s+(?P<intent>\S+)\s+(?P<decision>\S+)\s+"
    r"rect=(?P<x>-?\d+),(?P<y>-?\d+),(?P<w>-?\d+),(?P<h>-?\d+)\s+"
    r"dither=(?P<dither>\S+)\s+t=(?P<t>\d+\.\d+)")

# The stamp every line in a harvested reader-session.log carries.
# Second resolution only -- which is why trace times come from the
# trace's own `t=` and marker times are aligned onto that clock.
STAMP_RE = re.compile(r"^(?P<d>\d{4}-\d{2}-\d{2}) (?P<t>\d{2}:\d{2}:\d{2})\b")

# KOReader / wilkbook INFO lines that mark a code path which also paints.
MARKERS = (
    ("INHIBIT", re.compile(r"Inhibiting user input")),
    ("RESTORE", re.compile(r"Restoring user input handling")),
    ("OPEN", re.compile(r"opening file ")),
    ("TOCFIX", re.compile(r"bogus page numbers")),
    ("IDLEWASH", re.compile(r"\[idlewasher\] idle wash")),
    ("BUNDLEDWASH", re.compile(r"\[idlewasher\] bundled wash")),
    ("DEEPCLEAN", re.compile(r"\[idlewasher\] deep clean \(")),
    ("DEEPRESTORE", re.compile(r"\[idlewasher\] deep clean restore")),
    ("IDLEWASHER_ON", re.compile(r"\[idlewasher\] enabled")),
    ("LAUNCH", re.compile(r"Current time:")),
    ("WARN", re.compile(r"\bWARN\b")),
)

WASH_TAGS = frozenset(("IDLEWASH", "BUNDLEDWASH", "DEEPCLEAN", "DEEPRESTORE"))

FULL_PANEL_TOL = 0.90
# A "reading session" boundary.  Nothing hinges on the exact value; it
# only groups traces for reporting, and is printed alongside.
SESSION_GAP_S = 900.0


class Trace:
    __slots__ = ("intent", "decision", "x", "y", "w", "h", "dither", "t",
                 "cls", "idx")

    def __init__(self, m):
        self.intent = m.group("intent")
        self.decision = m.group("decision")
        self.x = int(m.group("x"))
        self.y = int(m.group("y"))
        self.w = int(m.group("w"))
        self.h = int(m.group("h"))
        self.dither = m.group("dither")
        self.t = float(m.group("t"))
        self.cls = None
        self.idx = -1

    @property
    def area(self):
        return self.w * self.h

    @property
    def kind(self):
        return "%s/%s" % (self.intent, self.decision)

    @property
    def rect(self):
        return (self.x, self.y, self.w, self.h)

    def __repr__(self):
        return "%.3f %s %d,%d,%d,%d" % (self.t, self.kind,
                                        self.x, self.y, self.w, self.h)


def stamp_epoch(line):
    """The line's stamp as an epoch second, or None.

    Read as UTC and then corrected by the offset measured against the
    traces' own `t=`, so a device on a non-UTC clock still lines up and
    the tool never has to be told the timezone.
    """
    m = STAMP_RE.match(line)
    if not m:
        return None
    y, mo, d = (int(v) for v in m.group("d").split("-"))
    hh, mm, ss = (int(v) for v in m.group("t").split(":"))
    return float(calendar.timegm((y, mo, d, hh, mm, ss, 0, 0, 0)))


def parse(paths):
    """-> (traces, markers, clock_offset, unparsed)

    Marker times carry the +-1 s of a second-resolution stamp; every
    test below is tolerant of that by design (see `in_any_bracket`).
    """
    traces, raw_markers, offsets, unparsed = [], [], [], 0
    for path in paths:
        with open(path, "r", errors="replace") as fh:
            for line in fh:
                stamp = stamp_epoch(line)
                if "[pn-refresh]" in line:
                    m = TRACE_RE.search(line)
                    if not m:
                        unparsed += 1
                        continue
                    tr = Trace(m)
                    traces.append(tr)
                    if stamp is not None:
                        offsets.append(math.floor(tr.t) - stamp)
                    continue
                for tag, rx in MARKERS:
                    if rx.search(line):
                        raw_markers.append((stamp, tag, line.rstrip("\n")))
                        break
    traces.sort(key=lambda tr: tr.t)
    for i, tr in enumerate(traces):
        tr.idx = i
    offset = statistics.median(offsets) if offsets else 0.0
    markers = [(s + offset, tag, line)
               for (s, tag, line) in raw_markers if s is not None]
    markers.sort(key=lambda m: m[0])
    return traces, markers, offset, unparsed


def panel_extent(traces):
    """Most frequent near-maximal rect -- same discovery as refresh-episodes.

    KOReader emits OVER-panel rects (a menu wash traces -28,0,1460,1872
    on a 1404-wide panel), so anchoring on max area alone adopts the
    overhang as "the panel", after which every real page turn scores as
    not-full-panel and the analysis reports zero page turns.
    """
    if not traces:
        return None
    best = max(tr.area for tr in traces)
    counts = {}
    for tr in traces:
        if tr.area >= 0.85 * best:
            counts[(tr.w, tr.h)] = counts.get((tr.w, tr.h), 0) + 1
    return max(counts.items(), key=lambda kv: (kv[1], -kv[0][0] * kv[0][1]))[0]


def classify(traces, extent):
    """Tag every trace with a GEOMETRIC rect class.

    Deliberately geometric rather than semantic: the point is to be able
    to say "no footer-strip repaint occurs inside any episode" without
    having hard-coded 0,1836,1404,36 out of this one device's layout.
    """
    pw, ph = extent
    area = pw * ph
    short, long_ = min(pw, ph), max(pw, ph)
    for tr in traces:
        origin_out = tr.x < 0 or tr.y < 0
        # Compare shortest-to-shortest: the reader rotates, so a
        # landscape full-panel rect is 1872x1404 against a 1404x1872
        # extent and a naive w>pw test would file it as over-panel.
        rw, rh = sorted((tr.w, tr.h))
        oversize = rw > short or rh > long_
        if tr.area >= FULL_PANEL_TOL * area:
            tr.cls = "over-panel" if (origin_out or oversize) else "full-panel"
        elif origin_out or oversize:
            tr.cls = "over-panel"
        elif (tr.h <= 0.05 * long_ and tr.w >= 0.90 * short
              and tr.y + tr.h >= long_ - 4):
            tr.cls = "bottom-strip"
        elif tr.h <= 0.10 * long_ and tr.y <= 0.10 * long_:
            tr.cls = "top-strip"
        elif tr.area >= 0.25 * area:
            tr.cls = "large-box"
        else:
            tr.cls = "small-box"


ICON_SIDE = 59          # Screen:scaleBySize(32) on a 1404x1872 panel


def looks_like_icon(r):
    """Is this rect ReaderFlipping's top-left corner status icon?

    Module scope on purpose: test-refresh-triggers.py imports THIS
    function for its positive control.  A copy in the test would let the
    two drift, and the bug this replaced was precisely a detector that
    had stopped matching the thing it was named for.
    """
    x, y, w, h = r
    if w <= 0 or h <= 0:
        return False
    return (x <= 40 and y <= 40                      # top-left corner
            and abs(w - h) <= 0.35 * max(w, h)       # square-ish
            and 0.5 * ICON_SIDE <= max(w, h) <= 2.0 * ICON_SIDE)


def is_full_panel(tr, extent):
    return tr.area >= FULL_PANEL_TOL * extent[0] * extent[1]


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


def cv(values):
    """Coefficient of variation; None when it would be meaningless."""
    if len(values) < 2:
        return None
    mean = statistics.fmean(values)
    if mean <= 0:
        return None
    return statistics.pstdev(values) / mean


def brackets(markers):
    """INHIBIT ... RESTORE spans.

    Three call sites reach Input:inhibitInput(true) in this bundle:
    ReaderRolling:onUpdatePos (readerrolling.lua:999), ReaderUI's
    document open (readerui.lua:118), and the generic suspend path --
    which this image does not use, KOReader's suspend policy module
    being the disabled `return false` fixture.  An "opening file" marker
    inside a span separates the second from the first.
    """
    out, open_at = [], None
    for t, tag, _line in markers:
        if tag == "INHIBIT" and open_at is None:
            open_at = t
        elif tag == "RESTORE" and open_at is not None:
            out.append((open_at, t))
            open_at = None
    return out


def in_any_bracket(t, spans, slack=1.0):
    """Slack absorbs the +-1 s of the marker lines' second resolution."""
    for a, b in spans:
        if a - slack <= t <= b + slack:
            return (a, b)
    return None


def nearest_marker(t, markers, tags, window):
    best = None
    for mt, tag, _line in markers:
        if tag not in tags:
            continue
        d = abs(t - mt)
        if d <= window and (best is None or d < best[0]):
            best = (d, tag, mt - t)
    return best


def binom_at_least(k, n, p):
    if n <= 0:
        return float("nan")
    if p <= 0:
        return 1.0 if k <= 0 else 0.0
    if p >= 1:
        return 1.0
    return sum(math.comb(n, i) * p ** i * (1 - p) ** (n - i)
               for i in range(k, n + 1))


def when(t):
    return _time.strftime("%Y-%m-%d %H:%M:%S", _time.gmtime(t))


def hdr(title):
    print("\n" + "-" * 72)
    print(title)
    print("-" * 72)


def predecessor_census(seq, traces):
    c = {}
    for tr in seq:
        if tr.idx == 0:
            continue
        p = traces[tr.idx - 1]
        key = "%s %s" % (p.kind, p.cls)
        c[key] = c.get(key, 0) + 1
    return c


def print_census(c, label):
    total = sum(c.values())
    print("\n  predecessor census -- %s (n=%d)" % (label, total))
    for k, v in sorted(c.items(), key=lambda kv: -kv[1]):
        print("    %-32s %4d  %5.1f %%" % (k, v, 100.0 * v / max(1, total)))


def main(argv=None):
    ap = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("logs", nargs="+",
                    help="KOReader session log(s) -- the WHOLE log, not a "
                         "grep of the [pn-refresh] lines")
    ap.add_argument("--threshold", type=float, default=1.0,
                    help="episode gap threshold, seconds (default 1.0)")
    ap.add_argument("--window", type=float, default=15.0,
                    help="antecedent lookback, seconds (default 15)")
    ap.add_argument("--json", type=str, default="")
    args = ap.parse_args(argv)

    traces, markers, offset, unparsed = parse(args.logs)
    out = {"traces": len(traces), "unparsed": unparsed,
           "clock_offset_s": offset, "marker_lines": len(markers)}

    print("=" * 72)
    print("[pn-refresh] TRIGGER analysis  (issue #14: what asks twice?)")
    print("=" * 72)
    if len(traces) < 2:
        print("fewer than two [pn-refresh] traces in %s" % ", ".join(args.logs))
        return 1

    extent = panel_extent(traces)
    classify(traces, extent)
    span = traces[-1].t - traces[0].t
    out["extent"] = list(extent)
    out["span_s"] = span
    print("traces           : %d  (%d unparsed)" % (len(traces), unparsed))
    print("marker lines     : %d  (non-[pn-refresh] KOReader INFO/WARN)"
          % len(markers))
    if not markers:
        print("  WARNING: no marker lines at all.  This looks like a grep of")
        print("  the trace lines rather than a session log; sections D and E")
        print("  are then vacuous and their verdicts mean nothing.")
    print("span             : %.1f s (%.2f d)" % (span, span / 86400.0))
    print("panel extent     : %dx%d  (discovered)" % extent)
    print("stamp->trace clock offset: %+.0f s" % offset)

    kinds = {}
    for tr in traces:
        kinds[tr.kind] = kinds.get(tr.kind, 0) + 1
    print("trace kinds      : " + ", ".join(
        "%s=%d" % kv for kv in sorted(kinds.items(), key=lambda kv: -kv[1])))
    out["kinds"] = kinds

    classes = {}
    for tr in traces:
        classes[tr.cls] = classes.get(tr.cls, 0) + 1
    print("rect classes     : " + ", ".join(
        "%s=%d" % kv for kv in sorted(classes.items(), key=lambda kv: -kv[1])))
    out["rect_classes"] = classes

    mcounts = {}
    for _t, tag, _l in markers:
        mcounts[tag] = mcounts.get(tag, 0) + 1
    print("markers          : " + (", ".join(
        "%s=%d" % kv for kv in sorted(mcounts.items(), key=lambda kv: -kv[1]))
        or "(none)"))
    out["marker_counts"] = mcounts

    fullpart = [tr for tr in traces
                if tr.kind == "partial/partial" and is_full_panel(tr, extent)]
    eps = episodes_at(fullpart, args.threshold)
    out["full_panel_partials"] = len(fullpart)
    out["episodes"] = len(eps)
    ep_traces = [tr for e in eps for tr in e]

    # ---------------------------------------------------------------
    hdr("0. MERGE SEMANTICS: two identical full-panel traces cannot come\n"
        "   from one repaint drain, so the second request is genuinely later")
    # UIManager:_refresh merges any enqueued refresh whose region
    # openIntersectWith's the new one, and two identical rects always
    # intersect -- so a same-drain duplicate is impossible by
    # construction.  Disjoint rects do NOT merge, and the log shows what
    # that looks like: pairs milliseconds apart.
    same_rect_gaps, disj_gaps, all_gaps = [], [], []
    for a, b in zip(traces, traces[1:]):
        g = b.t - a.t
        all_gaps.append(g)
        if a.rect == b.rect and a.kind == b.kind:
            same_rect_gaps.append(g)
        elif (a.x + a.w <= b.x or b.x + b.w <= a.x
              or a.y + a.h <= b.y or b.y + b.h <= a.y):
            disj_gaps.append(g)
    print("  adjacent trace gaps            : n=%d  min %.1f ms"
          % (len(all_gaps), 1000 * min(all_gaps)))
    if disj_gaps:
        print("  ... between DISJOINT rects     : n=%d  min %.1f ms"
              % (len(disj_gaps), 1000 * min(disj_gaps)))
        print("      (these legitimately share one repaint drain)")
    if same_rect_gaps:
        print("  ... between IDENTICAL rect+kind: n=%d  min %.1f ms"
              % (len(same_rect_gaps), 1000 * min(same_rect_gaps)))
        print("      (these cannot: same drain would have merged them)")
        print("  => the logger resolves %.1f ms, so any floor above that is a"
              % (1000 * min(all_gaps)))
        print("     property of the CALLER, not of the instrument.")
    out["min_gap_ms"] = 1000 * min(all_gaps)
    out["min_disjoint_gap_ms"] = 1000 * min(disj_gaps) if disj_gaps else None
    out["min_identical_gap_ms"] = (1000 * min(same_rect_gaps)
                                   if same_rect_gaps else None)

    # How fast can the reader re-issue an IDENTICAL repaint, split by how
    # much of the panel it covers and by intent?  This is the test of
    # issue #14's "hard floor at 131 ms": a floor of the mechanism would
    # hold across intents, whereas a floor that only the `partial` intent
    # respects is just the low end of a 10-sample tail.
    by_bucket = {}
    for a, b in zip(traces, traces[1:]):
        if a.rect == b.rect and a.kind == b.kind:
            key = (a.cls, a.kind)
            by_bucket.setdefault(key, []).append(b.t - a.t)
    print("\n  fastest IDENTICAL repeat, by rect class and intent:")
    for (cls, kind), gs in sorted(by_bucket.items(),
                                  key=lambda kv: min(kv[1])):
        print("    %-12s %-16s n=%-4d min %7.1f ms   median %8.1f ms"
              % (cls, kind, len(gs), 1000 * min(gs),
                 1000 * statistics.median(gs)))
    out["identical_repeat_floor_ms"] = {
        "%s|%s" % k: 1000 * min(v) for k, v in by_bucket.items()}

    # ---------------------------------------------------------------
    hdr("1. EPISODES at T = %.2f s, and what immediately PRECEDES each"
        % args.threshold)
    spans = brackets(markers)
    detail = []
    for e in eps:
        internal = [1000 * (e[i + 1].t - e[i].t) for i in range(len(e) - 1)]
        prev = traces[e[0].idx - 1] if e[0].idx > 0 else None
        rec = {
            "t0": e[0].t, "when": when(e[0].t), "n": len(e),
            "gaps_ms": [round(g) for g in internal],
            "cv": cv(internal),
            "prev_kind": prev.kind if prev else None,
            "prev_cls": prev.cls if prev else None,
            "prev_gap_s": (e[0].t - prev.t) if prev else None,
            "in_bracket": bool(in_any_bracket(e[0].t, spans)),
        }
        detail.append(rec)
        print("  %s  n=%d  gaps=%s ms  CV=%s" % (
            rec["when"], rec["n"],
            ",".join(str(g) for g in rec["gaps_ms"]),
            ("%.3f" % rec["cv"]) if rec["cv"] is not None else "-"))
        if prev:
            print("      predecessor: %-22s %.2f s before"
                  % ("%s %s" % (rec["prev_kind"], rec["prev_cls"]),
                     rec["prev_gap_s"]))
        else:
            print("      predecessor: (none -- first trace in the log)")
    out["episode_detail"] = detail
    if not eps:
        print("  none.")

    all_census = predecessor_census(fullpart, traces)
    print_census(all_census, "all full-panel partial/partial")
    out["predecessors_all"] = all_census
    if ep_traces:
        ep_census = predecessor_census(ep_traces, traces)
        print_census(ep_census, "traces belonging to an episode")
        out["predecessors_episode"] = ep_census

    # The question the issue asks -- "what intents precede them" -- is
    # about episode STARTS, not about the repeats inside an episode
    # (whose predecessor is trivially the previous repeat).  Score each
    # start's predecessor class against its own base rate in the
    # population, so an enrichment is a number rather than an impression.
    if eps:
        starts = [e[0] for e in eps]
        start_census = predecessor_census(starts, traces)
        print_census(start_census, "EPISODE STARTS only")
        total_all = sum(all_census.values()) or 1
        print("    enrichment vs the population base rate:")
        enrich = {}
        for key, k in sorted(start_census.items(), key=lambda kv: -kv[1]):
            base = all_census.get(key, 0) / total_all
            p = binom_at_least(k, len(starts), base)
            enrich[key] = {"k": k, "n": len(starts), "base_rate": base,
                           "p_value": p}
            print("      %-32s %d/%d  base %5.2f %%  P(>=%d) = %.3g"
                  % (key, k, len(starts), 100 * base, k, p))
        out["predecessors_episode_start"] = enrich

    # ---------------------------------------------------------------
    hdr("1b. THE WIDER POPULATION: runs of full-panel repaints of ANY intent\n"
        "    (restricting to partial/partial hides that the same thing\n"
        "     happens on the ui and flash* paths)")
    fullany = [tr for tr in traces if is_full_panel(tr, extent)]
    wide = episodes_at(fullany, args.threshold)
    print("  full-panel repaints of any intent : %d" % len(fullany))
    print("  runs of >=2 within %.2f s          : %d  (vs %d restricted to "
          "partial/partial)" % (args.threshold, len(wide), len(eps)))
    wide_detail = []
    for r in wide:
        gaps = [round(1000 * (r[i + 1].t - r[i].t)) for i in range(len(r) - 1)]
        seq = "+".join(t.kind for t in r)
        wide_detail.append({"when": when(r[0].t), "n": len(r),
                            "gaps_ms": gaps, "kinds": seq})
        print("    %s n=%d gaps=%s" % (when(r[0].t), len(r), gaps))
        print("        %s" % seq)
    out["wide_runs"] = wide_detail

    # The menu-dismissal two-step, isolated: a full-panel flash*/global
    # wash and then ANOTHER full-screen update shortly after.  This is
    # the "weaker instance" issue #14 sets aside; it has its own, very
    # tight latency, which is what makes it a separate phenomenon rather
    # than the same one.
    washes_fp = [tr for tr in traces
                 if tr.intent.startswith("flash") and tr.decision == "global"]
    lat = []
    for tr in washes_fp:
        for nxt in traces[tr.idx + 1:]:
            if nxt.t - tr.t > 3.0:
                break
            if is_full_panel(nxt, extent) and nxt.intent == "ui":
                lat.append(nxt.t - tr.t)
                break
    print("\n  flash*/global washes                        : %d" % len(washes_fp))
    print("  ... followed by a full-panel ui repaint <3 s: %d" % len(lat))
    if lat:
        print("      latency: %s s" % ", ".join("%.3f" % v for v in sorted(lat)))
        tight = [v for v in lat if v < 1.0]
        if len(tight) > 1:
            print("      %d of %d under 1 s, at %.3f +- %.3f s"
                  % (len(tight), len(lat), statistics.fmean(tight),
                     statistics.pstdev(tight)))
        print("      A wash plus a second full-screen update is TWO visible")
        print("      passes for one dismissal.  Reported because it is a")
        print("      different, far more regular shape than the page-turn")
        print("      doubling -- not because anything here says it is a defect.")
    out["wash_then_ui_latency_s"] = lat

    # ---------------------------------------------------------------
    hdr("A. footer / progress-bar repaint promoted to full page")
    bottom = [tr for tr in traces if tr.cls == "bottom-strip"]
    print("  bottom-strip repaints in the log : %d" % len(bottom))
    if bottom:
        rects = {}
        kinds_b = {}
        for tr in bottom:
            rects[tr.rect] = rects.get(tr.rect, 0) + 1
            kinds_b[tr.kind] = kinds_b.get(tr.kind, 0) + 1
        for r, n in sorted(rects.items(), key=lambda kv: -kv[1])[:4]:
            print("    rect=%d,%d,%d,%d  x%d  (%.1f %% of the panel)"
                  % (r[0], r[1], r[2], r[3], n,
                     100.0 * r[2] * r[3] / (extent[0] * extent[1])))
        print("    kinds: " + ", ".join("%s=%d" % kv
                                        for kv in sorted(kinds_b.items())))
    inside = 0
    near = 0
    for e in eps:
        lo, hi = e[0].t, e[-1].t
        inside += sum(1 for tr in bottom if lo <= tr.t <= hi)
        near += sum(1 for tr in bottom if abs(tr.t - e[0].t) <= 2.0)
    print("  bottom-strip repaints INSIDE an episode : %d" % inside)
    print("  ... within 2 s of an episode start      : %d" % near)
    # How often does an ordinary page turn drag a footer repaint with it?
    bt = sorted(tr.t for tr in bottom)
    with_footer = 0
    for tr in fullpart:
        i = bisect.bisect_left(bt, tr.t)
        for j in (i - 1, i):
            if 0 <= j < len(bt) and abs(bt[j] - tr.t) <= 0.5:
                with_footer += 1
                break
    print("  full-panel partials with a bottom-strip repaint within 0.5 s:")
    print("    %d of %d (%.1f %%)"
          % (with_footer, len(fullpart),
             100.0 * with_footer / max(1, len(fullpart))))
    out["candidate_A"] = {"bottom_strip": len(bottom),
                          "inside_episode": inside, "near_episode": near,
                          "turns_with_footer": with_footer}

    # ---------------------------------------------------------------
    hdr("B. a second paint from the page-turn / animation path")
    anim = [tr for tr in traces if tr.intent in ("fast", "a2")]
    print("  fast/a2 traces anywhere in the log : %d" % len(anim))
    for tr in anim:
        print("    %s  %s rect=%d,%d,%d,%d [%s]"
              % (when(tr.t), tr.kind, tr.x, tr.y, tr.w, tr.h, tr.cls))
    anim_near = sum(1 for e in eps for tr in anim
                    if abs(tr.t - e[0].t) <= args.window)
    print("  ... within %.0f s of an episode start: %d"
          % (args.window, anim_near))
    # crengine partial-rerendering automation: >=3 same-small-rect "ui"
    # traces, seconds apart, as the status icon cycles states.
    # Detect the icon GEOMETRICALLY, not by cls.  ReaderFlipping paints it
    # as the top-left corner indicator (readerview.lua:259) through a
    # LeftContainer, so y == 0 and the side is Screen:scaleBySize(32) = 59 px
    # here -- which classify() files as "top-strip" (h <= 0.10*long_ and
    # y <= 0.10*long_), NEVER as "small-box".  Filtering on small-box could
    # not see the thing it was named for.  Widening to top-strip is also
    # wrong: that bucket holds the crengine top status bar (e.g.
    # 477,12,449,131), which is variable-width text, not a square icon.
    icon_rects = {}
    for tr in traces:
        if tr.kind == "ui/partial" and looks_like_icon(tr.rect):
            icon_rects[tr.rect] = icon_rects.get(tr.rect, 0) + 1
    repeated_icons = {r: n for r, n in icon_rects.items() if n >= 3}
    print("  distinct corner-icon ui/partial rects: %d" % len(icon_rects))
    print("  ... seen >=3 times (the crengine rerendering-automation")
    print("      status-icon signature)          : %d" % len(repeated_icons))
    for r, n in sorted(repeated_icons.items(), key=lambda kv: -kv[1])[:5]:
        print("        rect=%d,%d,%d,%d x%d" % (r[0], r[1], r[2], r[3], n))
    out["candidate_B"] = {"fast_a2": len(anim),
                          "fast_a2_near_episode": anim_near,
                          "corner_icon_ui_rects": len(icon_rects),
                          "repeated_icon_rects": len(repeated_icons)}

    # ---------------------------------------------------------------
    hdr("C. a genuine double input event  (cadence characterisation only)")
    # The null: every run of >=4 consecutive full-panel partials whose
    # gaps are all ordinary reading gaps.  If the episodes' cadence were
    # no tighter than ordinary reading, "the user turned pages fast"
    # would be a sufficient explanation.
    null_cvs, run = [], []
    for a, b in zip(fullpart, fullpart[1:]):
        g = b.t - a.t
        if args.threshold <= g <= 30.0:
            if not run:
                run = [a]
            run.append(b)
        else:
            if len(run) >= 4:
                null_cvs.append(cv([run[i + 1].t - run[i].t
                                    for i in range(len(run) - 1)]))
            run = []
    if len(run) >= 4:
        null_cvs.append(cv([run[i + 1].t - run[i].t
                            for i in range(len(run) - 1)]))
    null_cvs = [c for c in null_cvs if c is not None]
    ep_cvs = [d["cv"] for d in detail if d["cv"] is not None and d["n"] >= 3]
    print("  ordinary-reading runs (>=4 turns, %.2f-30 s gaps): n=%d"
          % (args.threshold, len(null_cvs)))
    if null_cvs:
        print("      CV range %.3f-%.3f, median %.3f"
              % (min(null_cvs), max(null_cvs), statistics.median(null_cvs)))
    print("  episodes with >=3 traces                         : n=%d, CVs %s"
          % (len(ep_cvs), ", ".join("%.3f" % c for c in ep_cvs) or "-"))
    for c in ep_cvs:
        tighter = sum(1 for n in null_cvs if n <= c)
        print("      CV %.3f: %d of %d ordinary runs are at least this tight"
              % (c, tighter, len(null_cvs)))
    fastest = min((min(d["gaps_ms"]) for d in detail), default=None)
    print("  fastest repeat anywhere                          : %s ms"
          % (fastest if fastest is not None else "-"))
    print("  NOTE: no input event is logged, so this section cannot confirm")
    print("        or exclude C.  It only says which SHAPE the repeats have,")
    print("        and even that is weak: a repeat rate near the reader's own")
    print("        render+publish cost is what ANY producer faster than the")
    print("        reader looks like, human or not.")
    out["candidate_C"] = {"null_cvs": null_cvs, "episode_cvs": ep_cvs,
                          "fastest_repeat_ms": fastest}

    # ---------------------------------------------------------------
    hdr("D. a document re-render (ReaderRolling:onUpdatePos)")
    print("  INHIBIT/RESTORE brackets in the log : %d" % len(spans))
    if spans:
        durs = [b - a for a, b in spans]
        print("    bracket duration: median %.1f s, max %.1f s"
              % (statistics.median(durs), max(durs)))
    inb = [tr for tr in fullpart if in_any_bracket(tr.t, spans)]
    print("  full-panel partials INSIDE a bracket: %d of %d (%.1f %%)"
          % (len(inb), len(fullpart),
             100.0 * len(inb) / max(1, len(fullpart))))
    per_bracket = [sum(1 for tr in fullpart if a - 1.0 <= tr.t <= b + 1.0)
                   for a, b in spans]
    if per_bracket:
        print("  full-panel partials per bracket     : min %d, max %d;"
              % (min(per_bracket), max(per_bracket)))
        print("    brackets holding more than one    : %d"
              % sum(1 for n in per_bracket if n > 1))
    ep_in_b = [tr for tr in ep_traces if in_any_bracket(tr.t, spans)]
    print("  EPISODE traces inside a bracket     : %d of %d"
          % (len(ep_in_b), len(ep_traces)))
    out["candidate_D"] = {"brackets": len(spans), "in_bracket": len(inb),
                          "episode_in_bracket": len(ep_in_b),
                          "max_per_bracket": max(per_bracket, default=0)}

    # ---------------------------------------------------------------
    hdr("E. the wilkbook idle washer")
    washes = [(t, tag) for t, tag, _l in markers if tag in WASH_TAGS]
    print("  [idlewasher] action lines          : %d" % len(washes))
    hits = 0
    for e in eps:
        n = nearest_marker(e[0].t, markers, WASH_TAGS, args.window)
        if n:
            hits += 1
            print("    episode %s: %s %+.1f s" % (when(e[0].t), n[1], n[2]))
    print("  episodes with an [idlewasher] line within %.0f s: %d of %d"
          % (args.window, hits, len(eps)))
    globals_ = [tr for tr in traces if tr.decision == "global"]
    washed = sum(1 for tr in globals_
                 if nearest_marker(tr.t, markers, WASH_TAGS, 2.0))
    print("  global (wash) traces               : %d, of which %d land"
          % (len(globals_), washed))
    print("    within 2 s of an [idlewasher] line -- the rest are KOReader's")
    print("    own promotion and menu washes, not the plugin's")
    out["candidate_E"] = {"idlewasher_lines": len(washes),
                          "episodes_near_idlewasher": hits,
                          "global_traces": len(globals_),
                          "globals_near_idlewasher": washed}

    # ---------------------------------------------------------------
    hdr("2. CLUSTERING: orientation, time of day, preceding gap, session")
    orient = {}
    for tr in traces:
        if is_full_panel(tr, extent):
            k = "portrait" if tr.w < tr.h else "landscape"
            orient[k] = orient.get(k, 0) + 1
    print("  full-panel traces by orientation: " + ", ".join(
        "%s=%d" % kv for kv in sorted(orient.items())))
    ep_orient = sorted(set("portrait" if tr.w < tr.h else "landscape"
                           for tr in ep_traces))
    print("  orientations represented among episode traces: %s"
          % (", ".join(ep_orient) or "-"))
    out["orientation"] = orient
    out["episode_orientations"] = ep_orient

    hours_all = [0] * 24
    for tr in fullpart:
        hours_all[_time.gmtime(tr.t).tm_hour] += 1
    hours_ep = [0] * 24
    for e in eps:
        hours_ep[_time.gmtime(e[0].t).tm_hour] += 1
    print("  hour of day (device clock), turns/episode-starts:")
    line = "   "
    for h in range(24):
        if hours_all[h] or hours_ep[h]:
            line += " %02d:%d/%d" % (h, hours_all[h], hours_ep[h])
    print(line)
    if sum(hours_ep) < 10:
        print("    (%d episode starts over %d hours with any reading: too few"
              % (sum(hours_ep), sum(1 for h in hours_all if h)))
        print("     for a time-of-day claim either way -- reported, not read)")
    out["hours_turns"] = hours_all
    out["hours_episodes"] = hours_ep

    pre_gaps = [d["prev_gap_s"] for d in detail if d["prev_gap_s"] is not None]
    all_pre = [b.t - a.t for a, b in zip(fullpart, fullpart[1:])
               if b.t - a.t >= args.threshold]
    if pre_gaps and all_pre:
        print("  gap BEFORE an episode start : %s s"
              % ", ".join("%.1f" % g for g in pre_gaps))
        print("  ordinary inter-turn gap     : median %.1f s (n=%d)"
              % (statistics.median(all_pre), len(all_pre)))
    out["episode_preceding_gaps_s"] = pre_gaps

    sessions, cur = [], [traces[0]]
    for a, b in zip(traces, traces[1:]):
        if b.t - a.t > SESSION_GAP_S:
            sessions.append(cur)
            cur = [b]
        else:
            cur.append(b)
    sessions.append(cur)
    ep_idx = set(tr.idx for tr in ep_traces)
    ep_sessions = set(i for i, s in enumerate(sessions)
                      if any(tr.idx in ep_idx for tr in s))
    print("  reading sessions (a gap >%.0f s splits): %d, of which %d contain"
          % (SESSION_GAP_S, len(sessions), len(ep_sessions)))
    print("    an episode")
    menu_sessions = set(i for i, s in enumerate(sessions)
                        if any(tr.intent.startswith("flash") for tr in s))
    print("  sessions containing a flash* (menu) trace: %d of %d"
          % (len(menu_sessions), len(sessions)))
    k = len(ep_sessions & menu_sessions)
    base = len(menu_sessions) / max(1, len(sessions))
    p = binom_at_least(k, len(ep_sessions), base)
    print("  episode-bearing sessions that also had menu activity:")
    print("    %d of %d (base rate %.1f %%, P(>=%d) = %.3g)"
          % (k, len(ep_sessions), 100 * base, k, p))
    out["sessions"] = len(sessions)
    out["sessions_with_episode"] = len(ep_sessions)
    out["menu_session_assoc"] = {"with_menu": k, "base_rate": base,
                                 "p_value": p}

    # ---------------------------------------------------------------
    hdr("SCORECARD  (measurement -> verdict; nothing here is hardware-proven)")
    verdicts = []

    def say(name, verdict, why):
        verdicts.append({"candidate": name, "verdict": verdict,
                         "evidence": why})
        print("  %-42s %s" % (name, verdict))
        for l in why:
            print("      %s" % l)

    say("A. footer promoted to full page",
        "EXCLUDED" if (inside == 0 and with_footer == 0) else "OPEN",
        ["%d bottom-strip repaints exist; every one traces at its own rect"
         % len(bottom),
         "%d fall inside an episode; %d full-panel partials have one within "
         "0.5 s" % (inside, with_footer),
         "source: the footer's repaint paths always pass a region and mode "
         "ui/fast; its one region-less partial is guarded on a non-crengine "
         "document"])

    say("B. second paint from the animation path",
        "EXCLUDED" if (anim_near == 0 and not repeated_icons) else "OPEN",
        ["%d fast/a2 traces in the whole log; %d within %.0f s of an episode"
         % (len(anim), anim_near, args.window),
         "%d repeated corner-icon ui rects (the rerendering-automation icon "
         "signature)" % len(repeated_icons),
         "the image also seeds cre_partial_rerendering=false "
         "(pinenote/services/reader-session.scm)"])

    say("C. genuine double input",
        "NOT SEPARABLE FROM THIS DATA",
        ["no input event is logged; a refresh trace cannot see a tap",
         "episode CVs %s vs ordinary-reading CVs %s (n=%d)"
         % (", ".join("%.3f" % c for c in ep_cvs) or "-",
            ("%.3f-%.3f, median %.3f"
             % (min(null_cvs), max(null_cvs), statistics.median(null_cvs)))
            if null_cvs else "-", len(null_cvs)),
         "settling it needs an input-side trace, not a refresh-side one"])

    say("D. document re-render (onUpdatePos)",
        "EXCLUDED for these episodes" if not ep_in_b else "OPEN",
        ["%d INHIBIT/RESTORE brackets; %d full-panel partials sit inside one"
         % (len(spans), len(inb)),
         "%d episode traces sit inside one" % len(ep_in_b),
         "so re-renders DO emit page-turn-shaped traces -- but not these"])

    say("E. idle washer",
        "EXCLUDED" if hits == 0 else "OPEN",
        ["%d [idlewasher] action lines; %d episodes have one within %.0f s"
         % (len(washes), hits, args.window),
         "the washer only ever asks setDirty(\"all\",\"full\") -> a global "
         "trace, never a partial"])

    out["scorecard"] = verdicts

    if args.json:
        with open(args.json, "w") as fh:
            json.dump(out, fh, indent=2, default=str)
        print("\njson -> %s" % args.json)
    return 0


if __name__ == "__main__":
    sys.exit(main())
