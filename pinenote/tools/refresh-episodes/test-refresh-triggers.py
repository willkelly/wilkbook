#!/usr/bin/env python3
"""Self-test for refresh-triggers.py against the COMMITTED issue-#14 traces.

Unlike `test-refresh-episodes.py`, which replays a synthetic fixture
reconstructed from the issue's published structure, this one runs the
analyser over the real evidence in
`doc/artifacts/pinenote-refresh-traces-20260815/` and requires the
numbers this repo has published back out of it.  That is possible only
because those logs are committed; it is the whole reason they were.

What it therefore proves, and does not:

  * PROVES the analyser's arithmetic is stable, and that every number
    quoted in the issue-#14 trigger writeup is re-derivable from
    committed data by one command.  Issue #4 exists because the last
    audit's numbers were not.
  * PROVES the two candidate eliminations that rest on counting
    (A: no bottom-strip repaint anywhere near an episode; D: no episode
    trace inside an INHIBIT/RESTORE bracket) still hold if the analyser
    changes.
  * PROVES NOTHING about the device.  These are six days of one
    operator's reading on one image; nothing here is hardware-proven,
    and no trace can see an input event.

The second half also guards the traps that make this analysis wrong
when done carelessly: feeding the tool a grep of the trace lines
(markers vanish, sections D and E silently go vacuous), and the
over-panel rect that makes naive panel discovery score zero page turns.

Run:  python3 test-refresh-triggers.py   (or: make refresh-trigger-check)
"""
from __future__ import annotations

import importlib.util
import io
import json
import os
import sys
import tempfile
from contextlib import redirect_stdout

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", "..", ".."))
ARTIFACT = os.path.join(REPO, "doc", "artifacts",
                        "pinenote-refresh-traces-20260815")
LOGS = [os.path.join(ARTIFACT, "reader-session-rotated.log"),
        os.path.join(ARTIFACT, "reader-session-current.log")]

spec = importlib.util.spec_from_file_location(
    "refresh_triggers", os.path.join(HERE, "refresh-triggers.py"))
RT = importlib.util.module_from_spec(spec)
spec.loader.exec_module(RT)


FAILURES = []


def check(label, got, want, tol=None):
    ok = (abs(got - want) <= tol) if tol is not None else (got == want)
    print("  %-4s %-56s got=%s want=%s"
          % ("PASS" if ok else "FAIL", label, got, want))
    if not ok:
        FAILURES.append(label)


def run(logs):
    """Run the analyser, returning its JSON summary (stdout suppressed)."""
    fd, path = tempfile.mkstemp(prefix="refresh-triggers-", suffix=".json")
    os.close(fd)
    buf = io.StringIO()
    with redirect_stdout(buf):
        rc = RT.main(list(logs) + ["--json", path])
    if rc != 0:
        raise SystemExit("analyser returned %d\n%s" % (rc, buf.getvalue()))
    with open(path) as fh:
        return json.load(fh), buf.getvalue()


def main():
    print("refresh-triggers self-test (committed issue-#14 field traces)")
    missing = [p for p in LOGS if not os.path.exists(p)]
    if missing:
        print("FAILED: committed evidence missing: %s" % ", ".join(missing))
        print("  These logs ARE the test input; there is no fixture fallback.")
        return 1

    out, text = run(LOGS)

    print("\n  -- the corpus, as committed --")
    check("traces parsed", out["traces"], 764)
    check("unparsed trace lines", out["unparsed"], 0)
    check("panel extent discovered (not the -28,0,1460,1872 overhang)",
          tuple(out["extent"]), (1404, 1872))
    check("full-panel partial/partial", out["full_panel_partials"], 412)
    check("episodes at T=1 s", out["episodes"], 5)
    check("largest episode", max(d["n"] for d in out["episode_detail"]), 8)
    check("marker lines found (D and E depend on these)",
          out["marker_lines"], 84)

    print("\n  -- merge semantics: the second request really is later --")
    check("finest adjacent gap (logger resolution), ms",
          round(out["min_gap_ms"], 1), 2.2, tol=0.05)
    check("finest DISJOINT-rect gap (one drain, two traces), ms",
          round(out["min_disjoint_gap_ms"], 1), 2.2, tol=0.05)
    check("finest IDENTICAL-rect gap (two drains), ms",
          round(out["min_identical_gap_ms"], 1), 68.3, tol=0.05)
    # The correction this test exists to pin: 131 ms is NOT a floor of
    # the mechanism.  A full-panel identical repaint at 68 ms is in the
    # same corpus, on the ui path.
    floors = out["identical_repeat_floor_ms"]
    check("full-panel ui repeat floor is BELOW the 131 ms 'hard floor'",
          floors["full-panel|ui/partial"] < floors["full-panel|partial/partial"],
          True)
    check("full-panel partial/partial floor (the issue's 131 ms), ms",
          round(floors["full-panel|partial/partial"]), 131)

    print("\n  -- candidate A: footer promoted to full page --")
    a = out["candidate_A"]
    check("bottom-strip repaints in the corpus", a["bottom_strip"], 100)
    check("...inside an episode", a["inside_episode"], 0)
    check("...within 2 s of an episode start", a["near_episode"], 0)
    check("page turns carrying a footer repaint within 0.5 s",
          a["turns_with_footer"], 0)

    print("\n  -- candidate B: animation / partial-rerendering path --")
    b = out["candidate_B"]
    check("fast+a2 traces in 6.2 days", b["fast_a2"], 1)
    check("...within 15 s of an episode", b["fast_a2_near_episode"], 0)
    check("repeated corner-icon ui rects (rerender status icon)",
          b["repeated_icon_rects"], 0)

    # POSITIVE CONTROL.  The assertion above is `== 0`, which a detector
    # that can see nothing at all also satisfies -- and the first version
    # of this detector was exactly that: it filtered on cls == "small-box",
    # but classify() files the icon (y == 0, side 59) as "top-strip", so it
    # could never match the signature it was named for.  A zero is only
    # evidence if the detector demonstrably fires on the real shape.
    icon = (0, 0, 59, 59)
    other = (477, 12, 449, 131)          # crengine top status bar: NOT an icon
    check("detector fires on the real corner-icon geometry",
          RT.looks_like_icon(icon), True)
    check("detector rejects the variable-width top status bar",
          RT.looks_like_icon(other), False)

    print("\n  -- candidate C: cadence only, cannot be settled here --")
    c = out["candidate_C"]
    check("fastest repeat anywhere, ms", c["fastest_repeat_ms"], 131)
    check("episodes with >=3 traces (CV is defined)", len(c["episode_cvs"]), 2)
    check("ordinary-reading control runs", len(c["null_cvs"]), 28)
    check("verdict is 'not separable'",
          [v["verdict"] for v in out["scorecard"]
           if v["candidate"].startswith("C.")][0],
          "NOT SEPARABLE FROM THIS DATA")

    print("\n  -- candidate D: document re-render (onUpdatePos) --")
    d = out["candidate_D"]
    check("INHIBIT/RESTORE brackets", d["brackets"], 14)
    check("full-panel partials inside a bracket", d["in_bracket"], 7)
    check("EPISODE traces inside a bracket", d["episode_in_bracket"], 0)

    print("\n  -- candidate E: idle washer --")
    e = out["candidate_E"]
    check("[idlewasher] action lines", e["idlewasher_lines"], 28)
    check("episodes within 15 s of one", e["episodes_near_idlewasher"], 0)

    print("\n  -- the wider population and the episode-start enrichment --")
    check("runs of full-panel repaints of ANY intent",
          len(out["wide_runs"]), 11)
    check("largest such run", max(r["n"] for r in out["wide_runs"]), 10)
    enrich = out["predecessors_episode_start"]
    check("episode starts preceded by a full-panel ui repaint",
          enrich["ui/partial full-panel"]["k"], 2)
    check("...against a 1.46 % base rate, P(>=2) < 0.01",
          enrich["ui/partial full-panel"]["p_value"] < 0.01, True)
    check("washes followed by a full-panel ui repaint within 3 s",
          len(out["wash_then_ui_latency_s"]), 6)

    print("\n  -- clustering --")
    check("orientations among episode traces (device stayed portrait)",
          out["episode_orientations"], ["portrait"])
    check("reading sessions", out["sessions"], 36)
    check("sessions containing an episode", out["sessions_with_episode"], 4)

    print("\n  -- traps --")
    # A grep of the trace lines loses every marker, which silently
    # vacates D and E.  The tool must say so rather than report 0/0 as
    # if it had looked.
    tmp = tempfile.mkdtemp(prefix="refresh-triggers-trap-")
    grepped = os.path.join(tmp, "traces-only.log")
    with open(grepped, "w") as fh:
        for p in LOGS:
            for line in open(p, errors="replace"):
                if "[pn-refresh]" in line:
                    fh.write(line)
    g_out, g_text = run([grepped])
    check("grepped input: same trace count", g_out["traces"], out["traces"])
    check("grepped input: markers all gone", g_out["marker_lines"], 0)
    check("grepped input: brackets vacated",
          g_out["candidate_D"]["brackets"], 0)
    check("grepped input: the tool WARNS instead of reporting a verdict",
          "WARNING: no marker lines at all" in g_text, True)

    print()
    if FAILURES:
        print("FAILED: %s" % ", ".join(FAILURES))
        return 1
    print("refresh-triggers self-test: OK "
          "(%d traces, %d markers, %d episodes over %.2f d)"
          % (out["traces"], out["marker_lines"], out["episodes"],
             out["span_s"] / 86400.0))
    return 0


if __name__ == "__main__":
    sys.exit(main())
