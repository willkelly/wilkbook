#!/usr/bin/env python3
"""End-to-end validation of the recording-bundle format + analyze path, offline.

No device, no camera, no network: forward-warp a known panel scenario (opening
sync flashes + a GC16 page turn + a GL16 page turn) through the synthetic camera
(synthcam.py, same approach as test_ingest.py), encode it to a real video with
ffmpeg, wrap it in a bundle with realistic session metadata + a decoded waveform
summary, then run analyze.analyze_bundle over the bundle and assert the defect
report comes out sensibly (GC16 -> flash severe, GL16 -> flash none). Also checks
the waveform-summary parser, the scenario orchestration against a fake driver,
and the no-raw-waveform policy guard.

Run: python3 test_bundle.py  (needs numpy + scipy + Pillow; ffmpeg for the
end-to-end video path, else that case is skipped).
"""
import json
import os
import shutil
import subprocess
import sys
import tempfile

import numpy as np

# small panel keeps the warp fast; ingest works off fractions so size is free
import testepub as te
te.W, te.H = 300, 400

import analyze
import bundle as B
import recorder
import synth
import synthcam

_fails = []


def check(name, cond, detail=""):
    print(f"  [{'ok  ' if cond else 'FAIL'}] {name}{('  -- ' + detail) if detail else ''}")
    if not cond:
        _fails.append(name)


def page_refl(kind, pid=0):
    return np.asarray(te.render_page(te.Page(0, kind, pid)), np.float32) / 255.0


# a canned `wbf-info` report (the tool's line-oriented output) mirroring the
# PineNote golden numbers in ../wbf/README.md -- so the parser is exercised
# without ever opening a raw .wbf.
WBF_INFO_TEXT = """\
file_size: 262144 (fw size 262144)
checksum_stored: 0xba3d4883
serial: 305419896
run_type: 0x01 fpl_platform: 0x02 fpl_lot: 3300
mode_version: 0x19
wf: version 0x02 subversion 0x00 type 0x03 rev 0x01
panel_size: 0 amepd_part_number: 0
frame_rate: bcd 0x85 hex 85
vcom_offset: 0
mode_count: 9
lut_format: 4BIT_PACKED
xwia: R474_AF4831_ED103TC2C6_VB3300-KCD_TC
temp_range_count: 13
temp_bin 0: >= 0 C
temp_bin 1: >= 3 C
temp_bin 2: >= 6 C
temp_bin 8: >= 24 C
temp_bin 12: >= 38 C
temp_index(28): 9
temp_index_below_first: -1
temp_index_above_last: 12
lut_init: ok (RESET mode_index=0 temp_index=9 phases=1)
MODE RESET: index=0 phases=1
MODE A2: index=1 phases=10
MODE DU: index=2 phases=19
MODE DU4: index=3 phases=24
MODE GC16: index=4 phases=38
MODE GCC16: index=5 phases=38
MODE GL16: index=6 phases=38
MODE GLR16: index=7 phases=38
MODE GLD16: index=8 phases=38
GC16 bin 0 (0 C): temp_index=0 phases=131
GC16 bin 1 (3 C): temp_index=1 phases=112
GC16 bin 8 (24 C): temp_index=8 phases=38
GC16 bin 12 (38 C): temp_index=12 phases=38
RESULT: ok
"""


class FakeDriver(recorder.DeviceDriver):
    """A no-op driver that records the calls run_scenario makes -- proves the
    orchestration follows the protocol without any device."""

    def __init__(self):
        self.calls = []

    def connect(self): self.calls.append(("connect",))
    def close(self): self.calls.append(("close",))
    def device_info(self): return {"model": "PineNote", "revision": "1.2"}
    def read_panel_temp(self): return 24.0
    def set_frontlight(self, level): return level
    def waveform_summary(self):
        return B.waveform_summary_from_wbf_info(WBF_INFO_TEXT)
    def set_ebc_params(self, params):
        self.calls.append(("params", dict(params)))
        return dict(params)
    def open_testcard(self, epub_path=None): self.calls.append(("open",))
    def emit_sync(self): self.calls.append(("sync",))
    def goto_page(self, index): self.calls.append(("page", index))


def encode_video(frames_float, path, fps):
    """Encode float[0,1] grayscale frames to a lossless ffv1 mkv (like the
    ffmpeg round-trip in test_ingest.py) so analyze decodes a REAL file."""
    n, h, w = frames_float.shape
    raw = (np.clip(frames_float, 0, 1) * 255).astype(np.uint8).tobytes()
    subprocess.run(["ffmpeg", "-v", "quiet", "-y", "-f", "rawvideo",
                    "-pix_fmt", "gray", "-s", f"{w}x{h}", "-r", str(fps),
                    "-i", "-", "-c:v", "ffv1", path], input=raw, check=True)


def build_single_panel_clip(wash, fps):
    """Panel-space clip: opening sync flashes, then one novel(10)->blank(11)
    page turn under `wash`. Isolated single-transition (the proven pattern from
    test_ingest.py) so segmentation is robust. Returns the [T,Hp,Wp] clip."""
    Hp, Wp = te.H, te.W
    before = page_refl("novel", pid=10)      # sequence idx10 novel -> idx11 blank
    after = page_refl("blank", pid=11)
    panel, _ = synth.simulate_transition(before, after, fps=fps, pre_frames=3,
                                         settle_frames=8, wash=wash, flash_depth=0.6)
    sync = np.stack([np.zeros((Hp, Wp), np.float32), np.ones((Hp, Wp), np.float32),
                     np.zeros((Hp, Wp), np.float32), np.ones((Hp, Wp), np.float32)])
    return np.concatenate([sync, panel], axis=0)


def make_bundle(tmpdir, wash, manifest, summ, fps):
    """Render -> synthetic camera -> ffv1 video -> a fully-populated bundle dir."""
    Wp, Hp = manifest["resolution"]
    panel_clip = build_single_panel_clip(wash, fps)
    Hc, Wc = int(Hp * 1.3), int(Wp * 1.3)
    H_true = synthcam.make_H_panel_to_cam(Wp, Hp, Wc, Hc)
    cam_clip, _ = synthcam.make_camera_clip(panel_clip, H_true, Wp, Hp, (Hc, Wc))

    video = os.path.join(tmpdir, f"cap_{wash}.mkv")
    encode_video(cam_clip, video, fps)
    manifest_path = os.path.join(tmpdir, "manifest.json")
    with open(manifest_path, "w") as f:
        json.dump(manifest, f)

    session = B.new_session(
        device={"model": "PineNote", "revision": "1.2",
                "os": "wilkbook os2 7.0.x", "kernel": "7.0.14-pinenote"},
        illuminant_level=60, panel_temp_c=24.0,
        ebc_params={"default_waveform": wash.upper(), "direct_mode": 0},
        created_utc="2026-07-10T00:00:00Z")
    B.set_waveform_decode(session, summ)
    B.add_run(session, run_id="r0",
              events=B.scenario_events(manifest, page_period_s=1.5),
              label=f"{wash} baseline", frontlight_level=60, panel_temp_c=24.0)

    bundle_dir = os.path.join(tmpdir, f"bundle_{wash}")
    B.write_bundle(bundle_dir, session, video, manifest_path)
    return bundle_dir


def main():
    manifest = te.build_manifest(te.build_pages())
    Wp, Hp = manifest["resolution"]

    print("case: waveform summary parses from wbf-info text (no raw .wbf)")
    summ = B.waveform_summary_from_wbf_info(
        WBF_INFO_TEXT, wbf_sha256="ba3d4883deadbeef", modes_at_c=28)
    check("mode_version parsed", summ.get("mode_version") == "0x19",
          f"{summ.get('mode_version')}")
    check("frame rate parsed", summ.get("frame_rate_hz") == 85)
    check("panel string parsed", "ED103TC2C6" in (summ.get("panel") or ""))
    check("per-mode phase counts parsed",
          summ.get("phases_by_mode", {}).get("GC16") == 38
          and summ["phases_by_mode"].get("A2") == 10,
          f"{summ.get('phases_by_mode')}")
    check("gc16 phases-per-temp parsed (cold panel ~3.4x)",
          summ.get("gc16_phases_by_temp", {}).get("0") == 131
          and summ["gc16_phases_by_temp"].get("24") == 38,
          f"{summ.get('gc16_phases_by_temp')}")

    print("case: a raw-LUT-shaped waveform payload is rejected (policy)")
    rejected = False
    try:
        B._check_waveform_summary({"lut_codes": [1, 2, 3]})
    except ValueError:
        rejected = True
    check("raw-LUT summary rejected", rejected)

    print("case: scenario orchestration drives the protocol + logs a timeline")
    drv = FakeDriver()
    runs = recorder.run_scenario(
        drv, manifest, param_sets=[("baseline", {}), ("gl16", {"default_waveform": "GL16"})],
        page_period_s=1.5, clock=recorder.FakeClock())
    n_content = sum(1 for p in manifest["pages"] if not p["kind"].startswith("sync"))
    check("one run per param set", len(runs) == 2, f"{len(runs)}")
    check("run0 logs sync + every content page",
          sum(1 for e in runs[0]["events"] if e["event"] == "page") == n_content
          and runs[0]["events"][0]["event"] == "sync",
          f"{len(runs[0]['events'])} events")
    check("run1 records the flipped param",
          any(e["event"] == "param" and e.get("params", {}).get("default_waveform") == "GL16"
              for e in runs[1]["events"]))
    check("event timeline is monotonic from clock-zero",
          all([e["t"] for e in r["events"]] == sorted(e["t"] for e in r["events"])
              for r in runs))
    check("driver saw params->open->sync->pages in order",
          [c[0] for c in drv.calls[:4]] == ["params", "open", "sync", "page"],
          f"{[c[0] for c in drv.calls[:5]]}")

    print("case: build a synthetic bundle + validate it")
    if not (shutil.which("ffmpeg") and shutil.which("ffprobe")):
        print("  [skip] ffmpeg not on PATH (run inside guix shell ... ffmpeg)")
        print()
        return 1 if _fails else 0

    fps = 20.0
    with tempfile.TemporaryDirectory() as d:
        gc16_dir = make_bundle(d, "gc16", manifest, summ, fps)
        gl16_dir = make_bundle(d, "gl16", manifest, summ, fps)

        loaded = B.load_bundle(gc16_dir, verify_hashes=True)
        check("bundle validates + hashes verify", loaded.session["schema"] == B.SCHEMA)
        check("waveform summary survives round-trip",
              loaded.session["waveform_decode"]["gc16_phases_by_temp"]["0"] == 131)

        print("case: the no-raw-waveform policy guard fires on a planted .wbf")
        planted = os.path.join(gc16_dir, "ebc.wbf")
        with open(planted, "wb") as f:
            f.write(b"\x00" * 16)
        guarded = False
        try:
            B.load_bundle(gc16_dir)
        except ValueError as e:
            guarded = "policy" in str(e) or "waveform" in str(e)
        check("planted .wbf is rejected by policy guard", guarded)
        os.remove(planted)

        print("case: END-TO-END -- analyze the GC16 bundle -> severe flash report")
        report = analyze.analyze_bundle(gc16_dir)
        pairs = {(t["from_pid"], t["to_pid"]): t for t in report["transitions"]}
        check("novel->blank page turn recovered from the capture",
              (10, 11) in pairs, f"{sorted(pairs)}")
        if (10, 11) in pairs:
            gc = pairs[(10, 11)]
            check("GC16 novel->blank classified flash severe",
                  gc["flash"]["severity"] == "severe",
                  f"depth={gc['flash']['depth']} sev={gc['flash']['severity']}")
            check("GC16 transition carries its stress label from the manifest",
                  gc["stress"] == ["ghost"], f"{gc['stress']}")
        check("report echoes device identity",
              report["device"]["model"] == "PineNote")
        check("report summary flags the worst flash",
              report["summary"]["worst_flash_depth"] >= optics_severe(),
              f"worst={report['summary']['worst_flash_depth']}")
        text = analyze.format_report_text(report)
        check("human-readable summary renders",
              "defect report" in text and "PineNote" in text.splitlines()[0])

        print("case: END-TO-END -- analyze the GL16 bundle -> no flash report")
        report2 = analyze.analyze_bundle(gl16_dir)
        pairs2 = {(t["from_pid"], t["to_pid"]): t for t in report2["transitions"]}
        gl_sev = pairs2[(10, 11)]["flash"]["severity"] if (10, 11) in pairs2 else "missing"
        check("GL16 novel->blank classified no flash", gl_sev == "none",
              f"severity={gl_sev}")

    print()
    if _fails:
        print(f"bundle: {len(_fails)} FAILED: {', '.join(_fails)}")
        return 1
    print("bundle: ok -- synthetic capture -> bundle -> analyze -> defect report round-trips")
    return 0


def optics_severe():
    import optics
    return optics.FLASH_DEPTH_SEVERE


if __name__ == "__main__":
    sys.exit(main())
