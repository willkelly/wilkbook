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
import sys

import numpy as np

import bundle as bundle_mod
import ingest
import optics
import testepub

REPORT_SCHEMA = "wilkbook-optics-report"
REPORT_VERSION = 1


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
            "flash": {
                "depth": round(rep.flash_depth, 4),
                "energy_refl_s": round(rep.flash_energy, 4),
                "duration_s": round(rep.flash_duration_s, 4),
                "count": rep.flash_count,
                "severity": rep.flash_severity,
            },
            "ghost": {
                "rms": round(rep.ghost_rms, 4),
                "corr": round(rep.ghost_corr, 4),
                "severity": rep.ghost_severity,
            },
            "settle": {
                "settle_s": round(rep.settle_s, 4),
                "settled": rep.settled,
                "severity": rep.settle_severity,
            },
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


def analyze_bundle(bundle_dir, frames=None, fps=None, run_id=None):
    """Full end-to-end analyze of a bundle directory. By default decodes the
    bundle's capture video with ffmpeg; `frames`/`fps` override that for tests
    that already hold the array. `run_id` selects which run's events/params
    this capture carries (unneeded for per-run bundles -- see _select_run).
    Returns the report dict, with every transition attributed to the selected
    run (run_id + that run's params)."""
    b = bundle_mod.load_bundle(bundle_dir)
    manifest = b.load_manifest()

    if frames is None:
        frames, probed_fps = ingest.frames_from_video(b.capture_path)
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
        worst["flash"] = max(worst["flash"], t["flash"]["depth"])
        worst["ghost"] = max(worst["ghost"], t["ghost"]["rms"])
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
    s = report["summary"]
    L.append(f"summary: {s['n_transitions']} transitions, "
             f"{s['n_with_defects']} with defects, "
             f"{s['n_double_flash']} double-flash;  "
             f"worst flash depth {s['worst_flash_depth']:.3f}, "
             f"worst ghost rms {s['worst_ghost_rms']:.3f}")
    L.append("")
    L.append(f"  {'pair':<20} {'flash':<16} {'ghost':<14} {'settle':<14} defects")
    L.append(f"  {'-' * 20} {'-' * 16} {'-' * 14} {'-' * 14} -------")
    for t in report["transitions"]:
        fl = f"{t['flash']['severity']}({t['flash']['depth']:.2f})"
        if t["flash"]["count"] >= 2:
            fl += f" x{t['flash']['count']}"
        gh = f"{t['ghost']['severity']}({t['ghost']['rms']:.3f})"
        st = f"{t['settle']['severity']}({t['settle']['settle_s']:.2f}s)"
        L.append(f"  {t['pair']:<20} {fl:<16} {gh:<14} {st:<14} "
                 f"{','.join(t['defects']) or '-'}")
    return "\n".join(L)


def main(argv=None):
    ap = argparse.ArgumentParser(description="Analyze an optics recording bundle.")
    ap.add_argument("bundle", help="path to the bundle directory")
    ap.add_argument("-o", "--out", help="write the JSON report here")
    ap.add_argument("--run-id", help="which run's events belong to this capture "
                    "(only needed for legacy multi-run bundles)")
    ap.add_argument("--quiet", action="store_true",
                    help="suppress the human-readable summary on stdout")
    args = ap.parse_args(argv)

    report = analyze_bundle(args.bundle, run_id=args.run_id)
    if args.out:
        with open(args.out, "w") as f:
            json.dump(report, f, indent=2)
    if not args.quiet:
        print(format_report_text(report))
    return 0


if __name__ == "__main__":
    sys.exit(main())
