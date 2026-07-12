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

    def classify(builder, **kw):
        clip, t0, before, after, tr_kw = builder(**kw)
        tr = optics.Transition(t0=t0, before=before, after=after, **tr_kw)
        return optics.classify_transition(clip, FPS, tr)

    print("case: grayscale corruption (gray ramp binarized to 1-bit) -- expect SEVERE")
    rep = classify(synth.grayscale_transition, binarized=True)
    check("gray corruption severe", rep.gray_severity == "severe",
          f"crush_frac={rep.gray_crush_frac:.3f}")
    check("gray corruption listed", "gray-corrupt:severe" in rep.defects,
          f"defects={rep.defects}")

    print("case: clean grayscale control (ramp settles to its mid-tones) -- expect NONE")
    rep = classify(synth.grayscale_transition, binarized=False)
    check("clean grayscale not flagged", rep.gray_severity == "none",
          f"crush_frac={rep.gray_crush_frac:.3f}")
    check("clean grayscale has no defects", rep.defects == [], f"defects={rep.defects}")

    print("case: contrast degraded (white dim, black washed) -- expect SEVERE")
    rep = classify(synth.contrast_transition, degraded=True)
    check("contrast flagged severe", rep.contrast_severity == "severe",
          f"contrast={rep.contrast:.3f}")
    check("contrast listed", "contrast:severe" in rep.defects, f"defects={rep.defects}")

    print("case: clean contrast control (full black/white) -- expect NONE")
    rep = classify(synth.contrast_transition, degraded=False)
    check("full contrast not flagged", rep.contrast_severity == "none",
          f"contrast={rep.contrast:.3f}")
    check("clean contrast has no defects", rep.defects == [], f"defects={rep.defects}")

    print("case: blotchy background (mottled clearing) -- expect SEVERE")
    rep = classify(synth.blotch_transition, blotchy=True)
    check("blotch flagged severe", rep.blotch_severity == "severe",
          f"std={rep.blotch_std:.4f}")
    check("blotch listed", "blotch:severe" in rep.defects, f"defects={rep.defects}")

    print("case: clean uniform background -- expect NONE")
    rep = classify(synth.blotch_transition, blotchy=False)
    check("uniform background not flagged", rep.blotch_severity == "none",
          f"std={rep.blotch_std:.4f}")
    check("clean background has no defects", rep.defects == [], f"defects={rep.defects}")

    print("case: flash metric semantics -- table-driven mask + NaN guard (defect 2)")
    # Reports had shown `flash mild(nan)`: a NaN depth graded 'mild' because
    # NaN fails BOTH severity comparisons. Detection, depth, and count must
    # read the same stays-white pixels over the same valid frames, and a
    # transition with no stays-white area is not classifiable as flash at all.
    import math
    dark = np.full((synth.H, synth.W), 0.05, np.float32)   # a full-dark page
    flash_table = [
        # (name, before, after, sim kwargs, want severity, want unclassifiable)
        ("clean GL16 partial", text, blank, dict(wash="gl16"), "none", False),
        ("true GC16 flash w/ stayed-white", text, blank,
         dict(wash="gc16", flash_depth=0.6), "severe", False),
        ("flash activity, EMPTY stays-white", dark, blank,
         dict(wash="gc16", flash_depth=0.6), "none", True),
    ]
    for name, bef, aft, kw, want_sev, want_note in flash_table:
        clip, t0 = synth.simulate_transition(bef, aft, fps=FPS, **kw)
        rep = optics.classify_transition(
            clip, FPS, optics.Transition(t0=t0, before=bef, after=aft))
        check(f"{name}: severity '{want_sev}'", rep.flash_severity == want_sev,
              f"sev={rep.flash_severity} depth={rep.flash_depth}")
        check(f"{name}: all flash numbers finite (never NaN)",
              all(math.isfinite(v) for v in (rep.flash_depth, rep.flash_energy,
                                             rep.flash_duration_s)),
              f"depth={rep.flash_depth} energy={rep.flash_energy}")
        noted = any("not classifiable" in n for n in rep.notes)
        check(f"{name}: {'flagged not-classifiable' if want_note else 'classifiable'}",
              noted == want_note, f"notes={rep.notes}")
        if want_note:
            check(f"{name}: unclassifiable -> zero depth, zero count, no defect",
                  rep.flash_depth == 0.0 and rep.flash_count == 0
                  and not any(d.startswith("flash") for d in rep.defects),
                  f"depth={rep.flash_depth} count={rep.flash_count}")

    print("case: whole-NaN frames inside the wash (unreadable mid-wash) -- the former NaN path")
    # ingest leaves a frame NaN when the camera caught it mid-wash with no
    # readable fiducials; one such frame inside the window used to poison the
    # depth into NaN AND fabricate extra flash counts (NaN gaps read as false
    # rising edges). Valid-frame filtering must keep depth ~= the pristine
    # clip's and count the dip ONCE.
    clip, t0 = synth.simulate_transition(text, blank, fps=FPS, wash="gc16",
                                         flash_depth=0.6)
    tr_ref = optics.Transition(t0=t0, before=text, after=blank)
    ref = optics.classify_transition(clip, FPS, tr_ref)
    nan_clip = clip.copy()
    nan_clip[t0 + 1] = np.nan                       # two lost frames in the dip
    nan_clip[t0 + 3] = np.nan
    rep = optics.classify_transition(
        nan_clip, FPS, optics.Transition(t0=t0, before=text, after=blank))
    check("NaN-straddled flash still detected severe",
          rep.flash_severity == "severe", f"sev={rep.flash_severity}")
    check("depth finite and close to the pristine clip's",
          math.isfinite(rep.flash_depth)
          and abs(rep.flash_depth - ref.flash_depth) < 0.1,
          f"depth={rep.flash_depth:.3f} vs ref {ref.flash_depth:.3f}")
    check("one dip counted ONCE across the NaN gaps (no fabricated x3)",
          rep.flash_count == 1, f"count={rep.flash_count}")
    # NaN frame at the segment end: the settled state must come from the last
    # VALID frames, so every downstream metric stays finite
    tail_clip = clip.copy()
    tail_clip[-1] = np.nan
    rep = optics.classify_transition(
        tail_clip, FPS, optics.Transition(t0=t0, before=text, after=blank))
    check("NaN segment tail: every reported number finite",
          all(math.isfinite(float(v)) for v in (
              rep.flash_depth, rep.flash_energy, rep.flash_duration_s,
              rep.ghost_rms, rep.ghost_corr, rep.settle_s,
              rep.gray_crush_frac, rep.contrast, rep.blotch_std)),
          f"depth={rep.flash_depth} ghost={rep.ghost_rms}")

    print("case: settled state is a temporal AVERAGE of the trailing quiet frames")
    # Camera-like per-pixel noise: a single settled frame would carry the full
    # noise sigma into blotch_std; averaging the trailing quiet run divides it
    # by ~sqrt(n). Assert the reported std is well below the last-frame std.
    clip, t0, before, after, tr_kw = synth.blotch_transition(blotchy=False)
    rng = np.random.default_rng(7)
    noisy = np.clip(clip + rng.normal(0.0, 0.005, clip.shape), 0, 1).astype(np.float32)
    tr = optics.Transition(t0=t0, before=before, after=after, **tr_kw)
    rep = optics.classify_transition(noisy, FPS, tr)
    last_std = float(noisy[-1][tr_kw["bg_mask"]].std())
    check("averaged settled state beats the single-frame noise floor",
          rep.blotch_std < 0.5 * last_std,
          f"avg std={rep.blotch_std:.4f} vs last-frame std={last_std:.4f}")
    check("noisy-but-uniform background still not flagged",
          rep.blotch_severity == "none", f"std={rep.blotch_std:.4f}")
    # the shared quiet-scan helpers behave at the edges
    check("trailing run degenerates to the last frame when never quiet",
          optics.trailing_quiet_run(np.zeros(9, bool)) == (9, 10))
    check("trailing run spans the whole segment when always quiet",
          optics.trailing_quiet_run(np.ones(9, bool)) == (0, 10))
    check("first_quiet_run finds the opening of the quiet run",
          optics.first_quiet_run(np.array([0, 0, 1, 1, 1, 1], bool)) == 2)

    print()
    if _fails:
        print(f"optics: {len(_fails)} FAILED: {', '.join(_fails)}")
        return 1
    print("optics: ok -- all defect detectors classify the synthetic clips correctly")
    return 0


if __name__ == "__main__":
    sys.exit(main())
