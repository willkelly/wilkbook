#!/usr/bin/env python3
"""Self-test for refresh-episodes.py against the issue-#14 field structure.

WHAT THIS FIXTURE IS, EXACTLY.  It is a SYNTHETIC log RECONSTRUCTED from
the numbers published in the issue-#14 re-analysis comment — the five
episodes, their internal gaps in ms, the 15 s menu-antecedent deltas, the
399 adjacent pairs and the 7.2 % base rate.  It is NOT the device's raw
/var/log/reader-session.log; that log lives on the operator's device and
was never copied into this repo.  Every timestamp outside the published
episode structure is invented by this generator.

So this test proves ONE thing, and it is the thing worth proving: that
the analyser's arithmetic — episode grouping, the conjunction that
defines the menu antecedent, the base rate, the binomial — returns the
published answers when handed data with the published structure.  It
proves nothing whatsoever about the device.  Its value is that an
offline campaign result and the field result are then known to be the
same measurement rather than two similar-sounding ones.

Run:  python3 test-refresh-episodes.py     (or: make refresh-episodes-check)
"""
from __future__ import annotations

import importlib.util
import os
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location(
    "refresh_episodes", os.path.join(HERE, "refresh-episodes.py"))
RE_MOD = importlib.util.module_from_spec(spec)
spec.loader.exec_module(RE_MOD)

PANEL_W, PANEL_H = 1404, 1872

# The five episodes exactly as published (internal gaps, milliseconds).
EPISODES_MS = [
    [503, 277, 232, 307, 298, 322, 322],   # n=8, 2.26 s total
    [131],                                  # n=2, the "cleanest instance"
    [933],                                  # n=2
    [184, 746, 214],                        # n=4
    [391],                                  # n=2
]
# Published antecedent deltas (flash_global, ui_fullpanel), seconds before
# the episode start.  Episode 2 is the published MISS — pure steady reading.
ANTECEDENTS = [(1.47, 0.62), None, (9.45, 8.66), (6.08, 8.05), (6.93, 10.31)]

TRACE = "t=%.6f  [pn-refresh] %s %s rect=0,0,%d,%d dither=nil t=%.6f"


def line(t, intent, decision, w=PANEL_W, h=PANEL_H):
    # The real log carries a leading logger timestamp AND the trace's own
    # t=; the parser must take the trace's own, so the fixture carries
    # both and deliberately makes the leading one wrong.
    return TRACE % (t - 999.0, intent, decision, w, h, t)


def build_fixture(path):
    """400 full-panel partial/partial traces containing the five episodes,
    with the menu signature placed on 29 of them (7.25 % base rate)."""
    out = []
    t = 1786300000.0
    fullpanel_times = []

    # The base rate is per-TRACE, not per-menu: one menu interaction marks
    # every full-panel partial inside the following 15 s, which during fast
    # flipping is several.  Five ordinary menu interactions is what lands
    # the per-trace base at the published ~7 %; four of the episode starts
    # carry the signature on top of that.
    ordinary_menu_at = set(sorted(set(range(12, 400, 15)))[:5])

    episode_at = {40: 0, 120: 1, 200: 2, 280: 3, 340: 4}

    n = 0
    while n < 400:
        if n in episode_at:
            idx = episode_at[n]
            ante = ANTECEDENTS[idx]
            if ante:
                flash_dt, ui_dt = ante
                base = t
                out.append((base - flash_dt, line(base - flash_dt, "flashui", "global")))
                out.append((base - ui_dt, line(base - ui_dt, "ui", "partial")))
            out.append((t, line(t, "partial", "partial")))
            fullpanel_times.append(t)
            n += 1
            for gap_ms in EPISODES_MS[idx]:
                t += gap_ms / 1000.0
                out.append((t, line(t, "partial", "partial")))
                fullpanel_times.append(t)
                n += 1
            t += 12.0
            continue

        if n in ordinary_menu_at:
            out.append((t - 5.0, line(t - 5.0, "flashui", "global")))
            out.append((t - 4.0, line(t - 4.0, "ui", "partial")))
        out.append((t, line(t, "partial", "partial")))
        fullpanel_times.append(t)
        n += 1
        # ordinary reading cadence: a spread that puts the median near the
        # published 8.89 s and the mode in 1.5-2.0 s
        t += [1.7, 1.8, 1.9, 2.4, 3.6, 5.2, 8.9, 12.0, 16.0, 22.0][n % 10]

    out.sort(key=lambda p: p[0])
    with open(path, "w") as fh:
        for _, text in out:
            fh.write(text + "\n")
    return len(fullpanel_times)


FAILURES = []


def check(label, got, want, tol=None):
    ok = (abs(got - want) <= tol) if tol is not None else (got == want)
    print("  %-4s %-52s got=%s want=%s" % ("PASS" if ok else "FAIL", label, got, want))
    if not ok:
        FAILURES.append(label)


def main():
    print("refresh-episodes self-test (synthetic issue-#14 field structure)")
    tmp = tempfile.mkdtemp(prefix="refresh-episodes-test-")
    fixture = os.path.join(tmp, "field-structure.log")
    n_full = build_fixture(fixture)

    traces, unparsed = RE_MOD.parse([fixture])
    extent = RE_MOD.panel_extent(traces)
    fullpart = [tr for tr in traces
                if tr.intent == "partial" and tr.decision == "partial"
                and RE_MOD.is_full_panel(tr, extent)]

    check("parser: nothing unparsed", unparsed, 0)
    check("parser: panel extent discovered", extent, (PANEL_W, PANEL_H))
    check("population: full-panel partial/partial", len(fullpart), 400)
    check("population: adjacent pairs", len(fullpart) - 1, 399)

    gaps = [g[0] for g in RE_MOD.gaps_between(fullpart)]
    check("sweep: gaps below 1.0 s (published 13)",
          sum(1 for g in gaps if g < 1.0), 13)

    eps = RE_MOD.episodes_at(fullpart, 1.0)
    check("episodes at T=1.0 s (published 5)", len(eps), 5)
    check("largest episode (published 8 refreshes)",
          max(len(e) for e in eps), 8)
    check("episodes with more than 2 refreshes", sum(1 for e in eps if len(e) > 2), 2)

    largest = max(eps, key=len)
    span_ms = round(1000 * (largest[-1].t - largest[0].t))
    check("largest episode span (published 2.26 s)", span_ms, 2261, tol=3)

    internal = [round(1000 * (largest[i + 1].t - largest[i].t))
                for i in range(len(largest) - 1)]
    check("largest episode internal gaps", internal, EPISODES_MS[0])

    hits = sum(1 for e in eps
               if RE_MOD.has_menu_antecedent(e[0].t, traces, extent, 15.0)[0])
    check("menu antecedent hits (published 4 of 5)", hits, 4)

    base_hits = sum(1 for tr in fullpart
                    if RE_MOD.has_menu_antecedent(tr.t, traces, extent, 15.0)[0])
    base = base_hits / len(fullpart)
    check("menu base rate (published 7.2 %)", round(100 * base, 1), 7.2, tol=0.6)

    p = RE_MOD.binom_at_least(4, 5, 0.072)
    check("binomial P(>=4 of 5 | p=0.072) ~ 1e-4",
          round(p, 6), 0.000122, tol=2e-5)

    # The floor and the continuum claim: the fastest gap is 131 ms and no
    # multiplicative step in the low tail is large enough to be a boundary.
    check("hard floor (published 131 ms)", round(1000 * min(gaps)), 131)
    tail = sorted(gaps)[:13]
    steps = [b / a for a, b in zip(tail, tail[1:])]
    check("no low-tail step above x1.5 (continuum, not bimodal)",
          max(steps) < 1.5, True)

    # A negative control: an analyser that scored ANY antecedent instead of
    # the conjunction would call this significant on noise, so require the
    # conjunction to actually discriminate.
    lone_flash = sum(1 for tr in fullpart
                     if any(o.intent.startswith("flash") and o.decision == "global"
                            and 0 < tr.t - o.t <= 15.0 for o in traces))
    check("conjunction is stricter than a lone wash",
          base_hits <= lone_flash, True)

    print()
    if FAILURES:
        print("FAILED: %s" % ", ".join(FAILURES))
        return 1
    print("refresh-episodes self-test: OK (fixture in %s)" % fixture)
    return 0


if __name__ == "__main__":
    sys.exit(main())
