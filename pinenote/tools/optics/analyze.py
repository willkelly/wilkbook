"""Analyze a contributor's recording bundle end-to-end -> a per-panel defect report.

This is the real ANALYZE path (README.md's analyze half), wired to the bundle
format. Given a bundle directory it:

  1. loads + validates the bundle (bundle.load_bundle) and its test-card manifest,
  2. decodes the capture video to frames (ingest.frames_from_video, ffmpeg),
  3. runs the full ingest pipeline (fiducial homography -> reflectance ->
     page-ID segmentation into transitions), and
  4. classifies every transition with optics.classify_transition,

emitting a structured JSON defect report plus a human-readable summary. One
bundle is one panel, so the report is a per-panel record: it echoes the device /
illuminant / temperature / param context from the session so results stay
comparable across the friends who contribute.

CLI:  python3 analyze.py BUNDLE_DIR [-o report.json] [--quiet]
Needs numpy + scipy + Pillow, and ffmpeg on PATH to decode the capture.
"""
from __future__ import annotations

import argparse
import json
import math
import os
import sys

import numpy as np

import bundle as bundle_mod
import ingest
import optics
import testepub

REPORT_SCHEMA = "wilkbook-optics-report"
REPORT_VERSION = 1


def _num(x, digits=4):
    """Round for the report; a non-finite value becomes None (JSON null) --
    NaN must never reach a report (defect-2 guard; the detectors themselves
    now return finite values, this is the belt on top of those braces)."""
    x = float(x)
    return round(x, digits) if math.isfinite(x) else None


def _render_page_factory(manifest):
    """A render_page(kind, pid) -> reflectance [Hp,Wp] closure at the
    manifest's resolution, for ingest to re-render the intended before/after
    pages. Sets the testepub module dims from the manifest (its geometry is
    fraction-based, so this is resolution-independent -- same trick
    test_ingest.py uses).

    Contract: the NEW two-arg form render_page(kind, pid) so pid-varied
    content (card v2) re-renders exactly; pid defaults to 0 so an ingest that
    still calls render_page(kind) keeps working, and the inner testepub call
    falls back through TypeError while testepub/ingest are restructured
    concurrently."""
    Wp, Hp = manifest["resolution"]
    testepub.W, testepub.H = Wp, Hp

    def render_page(kind, pid=0):
        try:
            img = testepub.render_page(testepub.Page(0, kind, pid))
        except TypeError:
            # a testepub revision without the pid slot in Page/render_page
            img = testepub.render_page(testepub.Page(0, kind))
        return np.asarray(img, np.float32) / 255.0

    return render_page


def _transition_index(manifest):
    """(from_index,to_index) -> transition metadata (pair label, stress tags)."""
    return {(t["from"], t["to"]): t for t in manifest["transitions"]}


def analyze_frames(frames, fps, manifest):
    """Core analysis on already-decoded frames (the array pipeline, no ffmpeg).
    Returns the report dict's `transitions` list plus (n_frames, sync_end)."""
    render_page = _render_page_factory(manifest)
    results, _warped, sync_end = ingest.ingest(frames, fps, manifest, render_page)

    pid_to_index = {p["pid"]: p["index"] for p in manifest["pages"]}
    kind_by_pid = {p["pid"]: p["kind"] for p in manifest["pages"]}
    tmeta = _transition_index(manifest)

    out = []
    for (tr, seg, fr, to) in results:
        rep = optics.classify_transition(seg, fps, tr)
        meta = tmeta.get((pid_to_index.get(fr), pid_to_index.get(to)), {})
        out.append({
            "from_pid": int(fr), "to_pid": int(to),
            "from_kind": kind_by_pid.get(fr), "to_kind": kind_by_pid.get(to),
            "pair": meta.get("pair", f"{kind_by_pid.get(fr)}->{kind_by_pid.get(to)}"),
            "stress": meta.get("stress", []),
            "n_frames": int(seg.shape[0]),
            "onset_frame": int(tr.onset_frame),
            "flash": {
                "depth": _num(rep.flash_depth),
                "energy_refl_s": _num(rep.flash_energy),
                "duration_s": _num(rep.flash_duration_s),
                "count": rep.flash_count,
                "severity": rep.flash_severity,
            },
            "ghost": {
                "rms": _num(rep.ghost_rms),
                "corr": _num(rep.ghost_corr),
                "severity": rep.ghost_severity,
            },
            "settle": {
                "settle_s": _num(rep.settle_s),
                "settled": rep.settled,
                "severity": rep.settle_severity,
            },
            "notes": list(rep.notes),
            "defects": rep.defects,
        })
    return out, len(frames), sync_end


def _select_run(session, run_id=None):
    """Pick the run whose events belong to THIS capture, explicitly. Per-run
    bundles (schema v2 recorder) hold exactly one run, so the join is 1:1 by
    construction; a legacy pooled bundle (several runs filmed into one video)
    is genuinely ambiguous -- we take the first run and say so in the report
    rather than silently pretending. `run_id` forces the choice."""
    runs = session.get("runs") or []
    if not runs:
        raise ValueError("session has no runs")
    if run_id is not None:
        for r in runs:
            if r.get("run_id") == run_id:
                return r, "explicit"
        raise ValueError(f"run_id {run_id!r} not in session "
                         f"(have {[r.get('run_id') for r in runs]})")
    if len(runs) == 1:
        return runs[0], "single"
    return runs[0], f"ambiguous-first-of-{len(runs)}"


# ===========================================================================
# Trace -> transition join (defect attribution: KOReader vs driver)
#
# The harvested [pn-refresh] trace timestamps every refresh KOReader ISSUED in
# device epoch seconds; the camera transitions live on the capture frame
# clock. Joining them is what lets a report say which washes KOReader asked
# for (src=ko-full / ko-partial) and which the panel showed with NO issuing
# line -- a driver-initiated global (or a trace gap), itself a finding.
#
# Alignment anchor (documented decision): the k-th page turn's [pn-refresh]
# line vs that turn's camera wash onset (the change-point ingest already
# detects). One rigid offset maps device epoch to capture seconds; it is
# recovered with a mode-of-pairwise-differences scan (no seed needed, robust
# to missing camera onsets, extra trace lines, and under/over-segmentation)
# and refined as the median over the mode-consistent pairs.
#
# Why not the sync anchor the bundle format suggests (events t=0 = clock-zero
# = opening sync flash, capture side = find_sync's sync_end)? Measured on the
# real captures, sync_end lands at the END of the settled sync-white dwell --
# anywhere from ~0 s to a full page period after the moment emit_sync
# returned -- so `sync_end + t*fps` carries up to ~4 s of systematic error,
# useless for a sub-second match window. The onset fit measures the offset
# instead of assuming it; find_sync remains the report's scenario-start
# marker and a coarse sanity check.
#
# Expected error: the fitted offset absorbs the constant part of the
# issue-to-visible-wash latency; what remains per pair is its jitter plus
# onset-detection granularity (+-1-2 frames). The join reports its own
# median/max |residual| per bundle -- on synthetic fixtures the recovery is
# exact; on the rig expect ~0.1-0.3 s, an order of magnitude inside the
# TRACE_MATCH_WINDOW_S=1.0 matching window (page periods are >=3 s, so
# matches stay unambiguous).
# ===========================================================================

TRACE_MATCH_WINDOW_S = 1.0   # |trace - onset| tolerance for attributing an
                             # issued refresh to a camera transition; must stay
                             # well under half the page period (>=3 s)
TRACE_MIN_PAIRS = 3          # fewer mode-consistent pairs than this = no fit
                             # (a 1-2 pair "mode" is indistinguishable from a
                             # coincidence with a sync/ui line)


def _mode_offset(ts_a, ts_b, bin_s=0.5):
    """The most-supported rigid offset a-b over all pairs (coarse histogram
    vote, then the median of the winning neighborhood). Returns
    (offset_s, support) or (None, 0)."""
    a = np.asarray(ts_a, float)
    b = np.asarray(ts_b, float)
    if a.size == 0 or b.size == 0:
        return None, 0
    diffs = (a[:, None] - b[None, :]).ravel()
    bins = np.round(diffs / bin_s)
    vals, counts = np.unique(bins, return_counts=True)
    center = float(vals[np.argmax(counts)]) * bin_s
    sel = diffs[np.abs(diffs - center) <= 1.5 * bin_s]   # winning bin + edges
    return float(np.median(sel)), int(sel.size)


def align_trace(trace_events, onsets_s, window_s=TRACE_MATCH_WINDOW_S,
                min_pairs=TRACE_MIN_PAIRS):
    """Fit the device-epoch -> capture-seconds offset from the trace's refresh
    timestamps and the camera onsets (see the anchor discussion above).
    Returns an alignment dict, or None when there is not enough overlap for an
    unambiguous fit. capture_time(ev) = ev['t'] - alignment['offset_s']."""
    ts = [e["t"] for e in trace_events]
    off, _support = _mode_offset(ts, onsets_s)
    if off is None:
        return None
    # refine: nearest trace line per onset under the coarse offset
    resid = []
    for o in onsets_s:
        d = np.asarray(ts, float) - off - o
        i = int(np.argmin(np.abs(d)))
        if abs(d[i]) <= window_s:
            resid.append(float(d[i]))
    if len(resid) < min_pairs:
        return None
    off = off + float(np.median(resid))
    resid = [r - float(np.median(resid)) for r in resid]
    return {
        "anchor": "page-turn [pn-refresh] lines vs camera wash onsets "
                  "(mode-of-differences fit, median-refined)",
        "offset_s": round(off, 4),
        "n_pairs": len(resid),
        "median_abs_residual_s": round(float(np.median(np.abs(resid))), 4),
        "max_abs_residual_s": round(float(np.max(np.abs(resid))), 4),
        "match_window_s": window_s,
    }


def join_trace(transitions, trace_events, fps,
               window_s=TRACE_MATCH_WINDOW_S):
    """Annotate every transition dict with its matching trace event(s) under a
    fitted alignment. Adds t['trace'] = {'src', 'events': [...]} where src is:

      ko-full     -- a [pn-refresh] full-global line matches this wash
      ko-partial  -- only partial line(s) match (KOReader-issued partial)
      ko-ui       -- only a ui paint matches
      none        -- NO [pn-refresh] line near this wash: the panel changed
                     without KOReader issuing anything -- a driver-initiated
                     global (or a trace gap); itself a finding.

    Each trace event is attributed to its NEAREST onset only, so one line can
    never explain two transitions. Returns the join summary dict (also carrying
    the alignment), or a {'status': ...} dict when the join cannot run."""
    onsets = [t.get("onset_frame") for t in transitions]
    if not trace_events:
        return {"status": "no-trace-events"}
    if not transitions or any(o is None for o in onsets):
        return {"status": "no-onsets"}
    onsets_s = [o / fps for o in onsets]
    alignment = align_trace(trace_events, onsets_s, window_s=window_s)
    if alignment is None:
        return {"status": "no-alignment (insufficient mode-consistent pairs)"}
    off = alignment["offset_s"]
    matched = {i: [] for i in range(len(transitions))}
    n_unmatched = 0
    for ev in trace_events:
        cap_t = ev["t"] - off
        d = [abs(cap_t - o) for o in onsets_s]
        i = int(np.argmin(d))
        if d[i] <= window_s:
            matched[i].append((cap_t - onsets_s[i], ev))
        else:
            n_unmatched += 1
    for i, t in enumerate(transitions):
        evs = sorted(matched[i], key=lambda p: p[0])
        kinds = [ev["kind"] for _, ev in evs]
        intents = [ev["intent"] for _, ev in evs]
        if "full-global" in kinds:
            src = "ko-full"
        elif any(k == "partial" and it != "ui"
                 for k, it in zip(kinds, intents)):
            src = "ko-partial"
        elif kinds:
            src = "ko-ui"
        else:
            src = "none"
        t["trace"] = {
            "src": src,
            "events": [{
                "kind": ev["kind"], "intent": ev["intent"],
                "decision": ev["decision"], "t": ev["t"],
                "dt_s": round(dt, 4), "rect": list(ev["rect"]) if ev["rect"] else None,
                "waveform": ev["waveform"],
            } for dt, ev in evs],
        }
    return {
        "status": "ok",
        "alignment": alignment,
        "n_trace_events": len(trace_events),
        "n_unmatched_trace_events": n_unmatched,
        "n_transitions_without_trace": sum(
            1 for t in transitions if t["trace"]["src"] == "none"),
    }


def analyze_bundle(bundle_dir, frames=None, fps=None, run_id=None,
                   max_fps=None, analysis_scale=None):
    """Full end-to-end analyze of a bundle directory. By default decodes the
    bundle's capture video with ffmpeg; `frames`/`fps` override that for tests
    that already hold the array. `run_id` selects which run's events/params
    this capture carries (unneeded for per-run bundles -- see _select_run).
    Returns the report dict, with every transition attributed to the selected
    run (run_id + that run's params)."""
    b = bundle_mod.load_bundle(bundle_dir)
    manifest = b.load_manifest()
    if analysis_scale and analysis_scale != 1.0:
        # scale the panel-space working resolution to match the decode scale:
        # all marker geometry is fractional, so a proportional resolution keeps
        # ingest/render consistent while bounding the warped-array memory
        Wp, Hp = manifest["resolution"]
        manifest = dict(manifest, resolution=[
            max(2, int(Wp * analysis_scale) // 2 * 2),
            max(2, int(Hp * analysis_scale) // 2 * 2)])

    if frames is None:
        frames, probed_fps = ingest.frames_from_video(
            b.capture_path, max_fps=max_fps, scale=analysis_scale)
        if fps is None:
            fps = probed_fps or b.session["capture"].get("fps") or 30.0
    if not fps:
        fps = b.session["capture"].get("fps") or 30.0

    transitions, n_frames, sync_end = analyze_frames(frames, float(fps), manifest)

    sess = b.session
    run, selection = _select_run(sess, run_id=run_id)
    run_params = dict(run.get("params") or {})
    for t in transitions:
        t["run_id"] = run.get("run_id")
        t["params"] = run_params

    # trace -> transition join (see the anchor discussion above join_trace)
    trace_events = []
    trace_name = run.get("trace")
    if trace_name:
        try:
            with open(os.path.join(b.path, trace_name), errors="replace") as f:
                trace_events = bundle_mod.parse_pn_refresh_trace(f.read())
        except OSError:
            trace_events = []
    trace_join = join_trace(transitions, trace_events, float(fps))
    for t in transitions:                     # stable shape even without a join
        t.setdefault("trace", None)
    report = {
        "schema": REPORT_SCHEMA,
        "version": REPORT_VERSION,
        "bundle_path": b.path,
        "device": sess["device"],
        "illuminant": sess["illuminant"],
        "panel_temp_c": sess["panel_temp_c"],
        "ebc_params": sess["ebc_params"],
        "waveform_decode": sess.get("waveform_decode"),
        "run": {
            "run_id": run.get("run_id"),
            "label": run.get("label", ""),
            "params": run_params,
            "events_source": run.get("events_source"),
            "panel_temp_c_start": run.get("panel_temp_c_start"),
            "panel_temp_c_end": run.get("panel_temp_c_end"),
            "trace": run.get("trace"),
            "selection": selection,
        },
        "capture": {"fps": float(fps), "n_frames": int(n_frames),
                    "sync_end_frame": int(sync_end)},
        "trace_join": trace_join,
        "transitions": transitions,
        "summary": _summarize(transitions, run=run),
    }
    return report


def _summarize(transitions, run=None):
    """Roll the per-transition reports into a per-panel headline, attributed to
    the run (config) that produced the capture."""
    counts = {"flash": {}, "ghost": {}, "settle": {}}
    worst = {"flash": 0.0, "ghost": 0.0}
    n_double = 0
    n_with_defects = 0
    for t in transitions:
        for k in ("flash", "ghost", "settle"):
            s = t[k]["severity"]
            counts[k][s] = counts[k].get(s, 0) + 1
        worst["flash"] = max(worst["flash"], t["flash"]["depth"] or 0.0)
        worst["ghost"] = max(worst["ghost"], t["ghost"]["rms"] or 0.0)
        if t["flash"]["count"] >= 2:
            n_double += 1
        if t["defects"]:
            n_with_defects += 1
    return {
        "run_id": (run or {}).get("run_id"),
        "label": (run or {}).get("label", ""),
        "params": dict((run or {}).get("params") or {}),
        "n_transitions": len(transitions),
        "n_with_defects": n_with_defects,
        "n_double_flash": n_double,
        "worst_flash_depth": round(worst["flash"], 4),
        "worst_ghost_rms": round(worst["ghost"], 4),
        "severity_counts": counts,
    }


def format_report_text(report):
    """Human-readable rendering of the report dict."""
    L = []
    dev = report["device"]
    L.append(f"optics defect report -- {dev.get('model')} "
             f"rev {dev.get('revision')}  ({dev.get('os') or 'os?'})")
    ill = report["illuminant"]
    if "cool_level" in ill or "warm_level" in ill:
        level = f"cool {ill.get('cool_level')} / warm {ill.get('warm_level')}"
    else:                                 # a pre-v2 report dict
        level = f"level {ill.get('level')}"
    L.append(f"illuminant: {ill.get('source')} @ {level} "
             f"({ill.get('ambient')});  panel_temp: {report['panel_temp_c']} C")
    if report["ebc_params"]:
        L.append(f"ebc params: {report['ebc_params']}")
    run = report.get("run")
    if run:
        temps = ""
        if run.get("panel_temp_c_start") is not None:
            temps = (f";  panel {run.get('panel_temp_c_start')} -> "
                     f"{run.get('panel_temp_c_end')} C")
        L.append(f"run: {run.get('run_id')} "
                 f"{('(' + run['label'] + ') ') if run.get('label') else ''}"
                 f"params {run.get('params') or {}} "
                 f"[{run.get('events_source')} events, {run.get('selection')}]"
                 f"{temps}")
    wd = report.get("waveform_decode")
    if wd:
        L.append(f"waveform: {wd.get('panel', '?')}  mode_version "
                 f"{wd.get('mode_version', '?')}  "
                 f"{wd.get('frame_rate_hz', '?')} Hz")
    cap = report["capture"]
    L.append(f"capture: {cap['n_frames']} frames @ {cap['fps']:.1f} fps, "
             f"sync ends frame {cap['sync_end_frame']}")
    tj = report.get("trace_join") or {}
    if tj.get("status") == "ok":
        al = tj["alignment"]
        L.append(f"trace join: ok -- {al['n_pairs']} turns matched to "
                 f"[pn-refresh] (offset {al['offset_s']:.2f} s, median |resid| "
                 f"{al['median_abs_residual_s']:.2f} s, max "
                 f"{al['max_abs_residual_s']:.2f} s); "
                 f"{tj['n_transitions_without_trace']} washes with NO trace "
                 f"line.  src: full/part = KOReader-issued wash; '-' = no "
                 f"[pn-refresh] line (driver-initiated global, or trace gap)")
    else:
        L.append(f"trace join: {tj.get('status', 'not run')} -- src column "
                 f"unavailable")
    s = report["summary"]
    L.append(f"summary: {s['n_transitions']} transitions, "
             f"{s['n_with_defects']} with defects, "
             f"{s['n_double_flash']} double-flash;  "
             f"worst flash depth {s['worst_flash_depth']:.3f}, "
             f"worst ghost rms {s['worst_ghost_rms']:.3f}")
    L.append("")
    L.append(f"  {'pair':<20} {'flash':<16} {'ghost':<14} {'settle':<14} "
             f"{'src':<7} defects")
    L.append(f"  {'-' * 20} {'-' * 16} {'-' * 14} {'-' * 14} {'-' * 7} -------")
    src_short = {"ko-full": "full", "ko-partial": "part", "ko-ui": "ui",
                 "none": "-"}
    for t in report["transitions"]:
        fl = f"{t['flash']['severity']}({_fmt(t['flash']['depth'], '.2f')})"
        if t["flash"]["count"] >= 2:
            fl += f" x{t['flash']['count']}"
        gh = f"{t['ghost']['severity']}({_fmt(t['ghost']['rms'], '.3f')})"
        st = f"{t['settle']['severity']}({_fmt(t['settle']['settle_s'], '.2f')}s)"
        tr = t.get("trace")
        if tr is None:
            src = "?"
        else:
            src = src_short.get(tr["src"], tr["src"])
            if len(tr["events"]) > 1:
                src += f" x{len(tr['events'])}"
        L.append(f"  {t['pair']:<20} {fl:<16} {gh:<14} {st:<14} {src:<7} "
                 f"{','.join(t['defects']) or '-'}")
    return "\n".join(L)


def _fmt(x, spec):
    """Format a report number that may be None (the JSON-null NaN guard)."""
    return format(x, spec) if x is not None else "?"


def main(argv=None):
    ap = argparse.ArgumentParser(description="Analyze an optics recording bundle.")
    ap.add_argument("bundle", help="path to the bundle directory")
    ap.add_argument("-o", "--out", help="write the JSON report here")
    ap.add_argument("--run-id", help="which run's events belong to this capture "
                    "(only needed for legacy multi-run bundles)")
    ap.add_argument("--max-fps", type=float, default=None,
                    help="decimate decode to this fps (memory bound; 30 is "
                         "plenty for GC16/GL16 envelopes)")
    ap.add_argument("--analysis-scale", type=float, default=None,
                    help="downscale decode + panel working resolution by this "
                         "factor (memory bound; 0.5 halves both dimensions)")
    ap.add_argument("--quiet", action="store_true",
                    help="suppress the human-readable summary on stdout")
    args = ap.parse_args(argv)

    report = analyze_bundle(args.bundle, run_id=args.run_id,
                            max_fps=args.max_fps,
                            analysis_scale=args.analysis_scale)
    if args.out:
        with open(args.out, "w") as f:
            json.dump(report, f, indent=2)
    if not args.quiet:
        print(format_report_text(report))
    return 0


if __name__ == "__main__":
    sys.exit(main())
