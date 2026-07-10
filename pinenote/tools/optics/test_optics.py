#!/usr/bin/env python3
"""Deterministic validation of the optics defect detectors against synthetic
clips with known injected defects. Run: python3 test_optics.py  (needs numpy).

Each case builds a transition whose defects we control, then asserts
classify_transition reports exactly them. This is the offline proof that the
"defect detection scripts" are correct before any real capture exists.
"""
import sys
import numpy as np

import optics
import synth

FPS = 30.0
_fails = []


def check(name, cond, detail=""):
    status = "ok  " if cond else "FAIL"
    if not cond:
        _fails.append(name)
    print(f"  [{status}] {name}{('  -- ' + detail) if detail else ''}")


def transition_for(before, after, **kw):
    clip, t0 = synth.simulate_transition(before, after, fps=FPS, **kw)
    tr = optics.Transition(t0=t0, before=before, after=after)
    return optics.classify_transition(clip, FPS, tr), clip


def main():
    text = synth.text_page(seed=1)
    blank = synth.blank_page()
    img = synth.image_page(0.45)

    print("case: GC16 wash (text -> blank) -- expect SEVERE black flash, clean settle")
    rep, _ = transition_for(text, blank, wash="gc16", flash_depth=0.6)
    check("gc16 flash severe", rep.flash_severity == "severe",
          f"depth={rep.flash_depth:.3f} energy={rep.flash_energy:.3f}")
    check("gc16 single flash", rep.flash_count == 1, f"count={rep.flash_count}")
    check("gc16 no ghost", rep.ghost_severity == "none", f"rms={rep.ghost_rms:.3f}")
    check("gc16 settles on time", rep.settle_severity == "none",
          f"settle={rep.settle_s:.3f}s")

    print("case: GL16 wash (text -> blank) -- expect NO flash, clean")
    rep, _ = transition_for(text, blank, wash="gl16")
    check("gl16 no flash", rep.flash_severity == "none",
          f"depth={rep.flash_depth:.3f} energy={rep.flash_energy:.3f}")
    check("gl16 no defects at all", rep.defects == [], f"defects={rep.defects}")

    print("case: ghosting (gl16 + strong residue) -- expect GHOST, no flash")
    rep, _ = transition_for(text, blank, wash="gl16", ghost_strength=0.5)
    check("ghost detected", rep.ghost_severity in ("mild", "severe"),
          f"rms={rep.ghost_rms:.3f} corr={rep.ghost_corr:.2f}")
    check("ghost correlates with prior page", abs(rep.ghost_corr) >= optics.GHOST_CORR_MIN,
          f"corr={rep.ghost_corr:.2f}")
    check("ghost run has no flash", rep.flash_severity == "none")

    print("case: slow settle (gc16, long wash) -- expect SLOW settle")
    rep, _ = transition_for(text, img, wash="gc16", settle_frames=30)
    check("settle flagged slow", rep.settle_severity == "slow",
          f"settle={rep.settle_s:.3f}s")

    print("case: incomplete settle (never quiesces) -- expect INCOMPLETE")
    rep, _ = transition_for(text, img, wash="gc16", incomplete=True)
    check("settle incomplete", (not rep.settled) and rep.settle_severity == "incomplete",
          f"settled={rep.settled}")

    print("case: double flash (two washes for one turn) -- expect count>=2")
    rep, _ = transition_for(text, blank, wash="gc16", flash_depth=0.6, double=True)
    check("double flash counted", rep.flash_count >= 2, f"count={rep.flash_count}")

    print("case: clean baseline (gl16, no ghost, text->text small diff)")
    rep, _ = transition_for(text, synth.text_page(seed=1), wash="gl16")
    check("baseline has no defects", rep.defects == [], f"defects={rep.defects}")

    print()
    if _fails:
        print(f"optics: {len(_fails)} FAILED: {', '.join(_fails)}")
        return 1
    print("optics: ok -- all defect detectors classify the synthetic clips correctly")
    return 0


if __name__ == "__main__":
    sys.exit(main())
