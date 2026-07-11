#!/usr/bin/env python3
"""End-to-end validation of the recording-bundle format + analyze path, offline.

No device, no camera, no network: forward-warp a known panel scenario (opening
sync flashes + a GC16 page turn + a GL16 page turn) through the synthetic camera
(synthcam.py, same approach as test_ingest.py), encode it to a real video with
ffmpeg, wrap it in a bundle with realistic session metadata + a decoded waveform
summary, then run analyze.analyze_bundle over the bundle and assert the defect
report comes out sensibly (GC16 -> flash severe, GL16 -> flash none). Also checks
the waveform-summary parser, the scenario orchestration against a fake driver
(panel reset, ABBA ordering, temp endpoints, trace harvest), the schema-v2
session shape + v1 migration, the v4l2 camera lock against a fake runner, the
per-param-set bundling in cmd_record, and the no-raw-waveform policy guard.

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
import driver as drvmod
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


def first_adjacent_pair(manifest, from_kind, to_kind):
    """(from_pid, to_pid) of the first adjacent from_kind->to_kind pair in the
    card. The card sequence is being restructured (card v2), so tests must
    search the manifest instead of hardcoding page positions."""
    pages = manifest["pages"]
    for a, b in zip(pages, pages[1:]):
        if a["kind"] == from_kind and b["kind"] == to_kind:
            return a["pid"], b["pid"]
    raise AssertionError(f"no adjacent {from_kind}->{to_kind} pair in the card")


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
    orchestration follows the protocol without any device. Has NO transport
    (.t), so deep_clean must no-op and trace harvest must return None."""

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


class FakeT:
    """Transport-shaped fake for the recorder-side helpers: records commands,
    scripts the live refresh_waveform readback, serves pull() from a dict."""

    def __init__(self, wf="6"):
        self.cmds = []
        self.wf = wf
        self.files = {}
        self.pulled = []

    def run(self, cmd, timeout=None):
        self.cmds.append(cmd)
        if cmd.startswith("cat ") and "refresh_waveform" in cmd:
            return 0, self.wf
        return 0, ""

    def pull(self, remote_path):
        self.pulled.append(remote_path)
        return self.files.get(remote_path, b"")


class TransportFakeDriver(FakeDriver):
    """FakeDriver + a FakeT transport, so deep_clean's save/flip/refresh/
    restore protocol and the trace-pull fallback are observable."""

    def __init__(self, wf="6"):
        super().__init__()
        self.t = FakeT(wf)

    def set_ebc_params(self, params):
        if "refresh_waveform" in params:
            self.t.wf = str(params["refresh_waveform"])
        return super().set_ebc_params(params)


class HarvestFakeDriver(TransportFakeDriver):
    """A driver exposing harvest_trace() (the API landing concurrently in
    driver.py) -- pull_trace must prefer it over transport.pull, and must
    normalize a str return to bytes."""

    def harvest_trace(self):
        return "[pn-refresh] via-harvest intent=full page=1\n"


def encode_video(frames_float, path, fps):
    """Encode float[0,1] grayscale frames to a lossless ffv1 mkv (like the
    ffmpeg round-trip in test_ingest.py) so analyze decodes a REAL file."""
    n, h, w = frames_float.shape
    raw = (np.clip(frames_float, 0, 1) * 255).astype(np.uint8).tobytes()
    subprocess.run(["ffmpeg", "-v", "quiet", "-y", "-f", "rawvideo",
                    "-pix_fmt", "gray", "-s", f"{w}x{h}", "-r", str(fps),
                    "-i", "-", "-c:v", "ffv1", path], input=raw, check=True)


def build_single_panel_clip(wash, fps, from_pid, to_pid):
    """Panel-space clip: opening sync flashes, then one novel->blank page turn
    (the manifest's first adjacent such pair) under `wash`. Isolated
    single-transition (the proven pattern from test_ingest.py) so segmentation
    is robust. Returns the [T,Hp,Wp] clip."""
    Hp, Wp = te.H, te.W
    before = page_refl("novel", pid=from_pid)
    after = page_refl("blank", pid=to_pid)
    panel, _ = synth.simulate_transition(before, after, fps=fps, pre_frames=3,
                                         settle_frames=8, wash=wash, flash_depth=0.6)
    sync = np.stack([np.zeros((Hp, Wp), np.float32), np.ones((Hp, Wp), np.float32),
                     np.zeros((Hp, Wp), np.float32), np.ones((Hp, Wp), np.float32)])
    return np.concatenate([sync, panel], axis=0)


def make_bundle(tmpdir, wash, manifest, summ, fps):
    """Render -> synthetic camera -> ffv1 video -> a fully-populated v2 bundle
    dir, with per-run params (the attribution under test) and a fake harvested
    trace sidecar."""
    Wp, Hp = manifest["resolution"]
    from_pid, to_pid = first_adjacent_pair(manifest, "novel", "blank")
    panel_clip = build_single_panel_clip(wash, fps, from_pid, to_pid)
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
        camera={"model": "synthcam", "fps_mode": f"gray {Wc}x{Hc}@{fps:g}"},
        created_utc="2026-07-10T00:00:00Z")
    B.set_waveform_decode(session, summ)
    trace_name = "trace.r0.log"
    B.add_run(session, run_id="r0",
              events=B.scenario_events(manifest, page_period_s=1.5),
              label=f"{wash} baseline",
              params={"refresh_waveform": 4 if wash == "gc16" else 6},
              frontlight_level=60, panel_temp_c_start=24.0, panel_temp_c_end=24.4,
              events_source="nominal", trace=trace_name)

    bundle_dir = os.path.join(tmpdir, f"bundle_{wash}")
    os.makedirs(bundle_dir, exist_ok=True)
    with open(os.path.join(bundle_dir, trace_name), "w") as f:
        f.write("[pn-refresh] intent=full page=1\n[pn-refresh] intent=partial page=2\n")
    B.write_bundle(bundle_dir, session, video, manifest_path)
    return bundle_dir


def fake_v4l2(state):
    """A camera_lock runner over a fake control table {name: (type, value)}.
    Renders --list-ctrls in the real v4l2-ctl format; applies --set-ctrl only
    to controls that exist. Records every argv on runner.calls."""
    calls = []

    def runner(argv, timeout=None):
        calls.append(list(argv))
        if argv[0] != "v4l2-ctl":
            return None
        if "--list-ctrls" in argv:
            lines = []
            for j, (name, (typ, val)) in enumerate(state.items()):
                extra = " (Manual Mode)" if (name == "auto_exposure" and val == 1) else ""
                lines.append(f"{name:>31} 0x009a{j:04x} ({typ})   : "
                             f"min=0 max=255 step=1 default=3 value={val}{extra}")
            return 0, "\n".join(lines)
        if "--set-ctrl" in argv:
            kv = argv[argv.index("--set-ctrl") + 1]
            name, val = kv.split("=", 1)
            if name not in state:
                return 1, ""
            state[name] = (state[name][0], int(val))
            return 0, ""
        return 1, ""

    runner.calls = calls
    return runner


BRIO_STATE = {                       # the real rig camera's confirmed controls
    "brightness": ("int", 128),
    "gain": ("int", 0),
    "power_line_frequency": ("menu", 2),
    "white_balance_automatic": ("bool", 1),
    "white_balance_temperature": ("int", 4600),
    "auto_exposure": ("menu", 3),                # 3 = aperture priority DEFAULT
    "exposure_time_absolute": ("int", 333),
    "exposure_dynamic_framerate": ("bool", 1),   # DEFAULT 1 = VFR unless locked
    "focus_automatic_continuous": ("bool", 1),
    "focus_absolute": ("int", 60),
}


def main():
    manifest = te.build_manifest(te.build_pages())
    Wp, Hp = manifest["resolution"]
    n_content = sum(1 for p in manifest["pages"] if not p["kind"].startswith("sync"))

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

    print("case: schema v2 session shape + v1 read migration")
    s2 = B.new_session(device={"model": "PineNote"}, illuminant_level=60,
                       camera={"model": "Logitech Brio",
                               "fps_mode": "MJPG 1920x1080@60"},
                       reader={"full_refresh_count": "never",
                               "flash_area_fraction": 0.6})
    check("v2 session splits the illuminant pinned-equal",
          s2["version"] == 2 and s2["illuminant"]["cool_level"] == 60
          and s2["illuminant"]["warm_level"] == 60
          and "level" not in s2["illuminant"], f"{s2['illuminant']}")
    check("camera/reader blocks merge over v2 defaults",
          s2["camera"]["model"] == "Logitech Brio"
          and s2["camera"]["exposure_locked"] is False
          and s2["reader"]["full_refresh_count"] == "never"
          and s2["reader"]["flash_area_fraction"] == 0.6)
    r2 = B.add_run(s2, "r0",
                   [{"t": 0.0, "event": "clean", "n": 3},
                    {"t": 0.0, "event": "sync"},
                    {"t": 3.0, "event": "page", "page_index": 4, "pid": 4,
                     "kind": "blank"}],
                   panel_temp_c_start=24.0, panel_temp_c_end=24.6,
                   events_source="measured", trace="trace.r0.log")
    check("clean event + temps + trace survive add_run and validate",
          B._validate_run(r2) == [] and r2["events"][0]["n"] == 3
          and r2["panel_temp_c_start"] == 24.0 and r2["panel_temp_c_end"] == 24.6
          and r2["panel_temp_c"] == 24.0, f"{B._validate_run(r2)}")
    bad_source = False
    try:
        B.add_run(s2, "rX", [{"t": 0.0, "event": "sync"}], events_source="guessed")
    except ValueError:
        bad_source = True
    check("events_source enum enforced", bad_source)
    escaped = dict(r2, trace="../../etc/passwd")
    check("trace path traversal rejected",
          any("trace" in prob for prob in B._validate_run(escaped)))

    v1 = {"schema": B.SCHEMA, "version": 1,
          "created_utc": "2026-07-01T00:00:00Z",
          "device": {"model": "PineNote", "revision": "1.2", "os": None,
                     "kernel": None, "notes": ""},
          "capture": {"file": "capture.mkv", "container": "mkv", "fps": 30,
                      "sha256": "0" * 64},
          "testcard": {"card_id": "wilkbook-optics-testcard", "card_version": 1,
                       "manifest_file": "manifest.json", "manifest_sha256": "0" * 64},
          "illuminant": {"source": "frontlight", "level": 55, "ambient": "dark-box"},
          "panel_temp_c": 24.0, "ebc_params": {},
          "runs": [{"run_id": "r0", "label": "", "params": {},
                    "frontlight_level": 55, "panel_temp_c": 24.0,
                    "events": [{"t": 0.0, "event": "sync"}]}],
          "waveform_decode": None}
    m = B.migrate_session(json.loads(json.dumps(v1)))
    check("v1 migrates: pinned-equal split + temp start + nominal events",
          m["version"] == 2 and m["migrated_from"] == 1
          and m["illuminant"]["cool_level"] == 55
          and m["illuminant"]["warm_level"] == 55
          and m["runs"][0]["panel_temp_c_start"] == 24.0
          and m["runs"][0]["events_source"] == "nominal"
          and m["runs"][0]["trace"] is None, f"{m['illuminant']}")
    check("migrated v1 session validates clean", B.validate_session(m) == [],
          "; ".join(B.validate_session(m)))

    print("case: scenario orchestration drives the protocol + logs a timeline")
    drv = FakeDriver()
    runs = recorder.run_scenario(
        drv, manifest, param_sets=[("baseline", {}), ("gl16", {"default_waveform": "GL16"})],
        page_period_s=1.5, clock=recorder.FakeClock())
    check("one run per param set", len(runs) == 2, f"{len(runs)}")
    check("run0 logs clean then sync at clock-zero, then every content page",
          sum(1 for e in runs[0]["events"] if e["event"] == "page") == n_content
          and runs[0]["events"][0]["event"] == "clean"
          and runs[0]["events"][0]["t"] == 0.0
          and runs[0]["events"][1]["event"] == "sync",
          f"{len(runs[0]['events'])} events")
    check("run1 records the flipped param",
          any(e["event"] == "param" and e.get("params", {}).get("default_waveform") == "GL16"
              for e in runs[1]["events"]))
    check("event timeline is monotonic from clock-zero",
          all([e["t"] for e in r["events"]] == sorted(e["t"] for e in r["events"])
              for r in runs))
    check("driver saw baseline-params->params->open->sync->page in order",
          [c[0] for c in drv.calls[:5]] == ["params", "params", "open", "sync", "page"],
          f"{[c[0] for c in drv.calls[:6]]}")
    check("panel temp sampled at run start AND end (ME6)",
          all(r["panel_temp_c_start"] == 24.0 and r["panel_temp_c_end"] == 24.0
              for r in runs))
    check("recorder timelines are marked measured",
          all(r["events_source"] == "measured" for r in runs))
    check("no-transport driver: deep_clean no-ops (clean n=0), no trace",
          runs[0]["events"][0]["n"] == 0 and runs[0]["trace_data"] is None)

    print("case: deep_clean saves/flips/refreshes/restores via the transport")
    tdrv = TransportFakeDriver(wf="6")
    n = recorder.deep_clean(tdrv, n=3)
    refreshes = [c for c in tdrv.t.cmds if c == drvmod.EBC_REFRESH]
    param_calls = [c for c in tdrv.calls if c[0] == "params"]
    check("three GC16 global refreshes issued", n == 3 and len(refreshes) == 3,
          f"n={n} refreshes={len(refreshes)}")
    check("prior waveform read before the flip",
          tdrv.t.cmds[0].startswith("cat ") and "refresh_waveform" in tdrv.t.cmds[0])
    check("flip to GC16 then restore the saved value",
          param_calls[0][1] == {"refresh_waveform": 4}
          and param_calls[-1][1] == {"refresh_waveform": "6"}
          and tdrv.t.wf == "6", f"{param_calls}")
    plain = FakeDriver()
    n0 = recorder.deep_clean(plain, n=3)
    check("driver without a transport: full no-op", n0 == 0 and plain.calls == [])

    print("case: trace harvest -- harvest_trace preferred, transport.pull fallback")
    tdrv2 = TransportFakeDriver(wf="6")
    tdrv2.t.files[recorder.TRACE_LOG] = b"[pn-refresh] intent=partial page=2\n"
    runs2 = recorder.run_scenario(tdrv2, manifest,
                                  param_sets=[("gl16", {"refresh_waveform": 6})],
                                  page_period_s=0.5, clock=recorder.FakeClock(),
                                  baseline_params={}, run_index_start=5)
    check("clean event records the 3 GC16 refreshes",
          runs2[0]["events"][0] == {"t": 0.0, "event": "clean", "n": 3},
          f"{runs2[0]['events'][0]}")
    check("run id honors run_index_start (distinct ids across per-set calls)",
          runs2[0]["run_id"] == "r5")
    check("trace harvested via transport.pull of the koreader log",
          runs2[0]["trace_data"] == b"[pn-refresh] intent=partial page=2\n"
          and recorder.TRACE_LOG in tdrv2.t.pulled)
    hdrv = HarvestFakeDriver()
    hdrv.t.files[recorder.TRACE_LOG] = b"WRONG: pull must not be used\n"
    runs3 = recorder.run_scenario(hdrv, manifest, param_sets=[("x", {})],
                                  page_period_s=0.5, clock=recorder.FakeClock())
    check("driver.harvest_trace preferred over pull; str return normalized to bytes",
          runs3[0]["trace_data"] == b"[pn-refresh] via-harvest intent=full page=1\n"
          and hdrv.t.pulled == [], f"{runs3[0]['trace_data']!r}")

    print("case: ABBA counterbalancing expands [A,B] -> A,B,B,A")
    ab = [("A", {}), ("B", {"refresh_waveform": 6})]
    check("abba_order mirrors the list, labels preserved for aggregation",
          recorder.abba_order(ab) == [ab[0], ab[1], ab[1], ab[0]])

    print("case: --camera-lock probes/applies/reads back v4l2 controls (fake runner)")
    state = {k: tuple(v) for k, v in BRIO_STATE.items()}
    runner = fake_v4l2(state)
    lock = recorder.camera_lock("/dev/video9", runner=runner)
    check("all four auto controls locked",
          lock["applied"] == {"auto_exposure": 1, "exposure_dynamic_framerate": 0,
                              "focus_automatic_continuous": 0,
                              "white_balance_automatic": 0}, f"{lock['applied']}")
    check("readback persists ALL controls, incl. untouched ones",
          lock["controls"]["exposure_time_absolute"] == 333
          and lock["controls"]["gain"] == 0
          and lock["controls"]["power_line_frequency"] == 2
          and lock["controls"]["auto_exposure"] == 1
          and lock["controls"]["exposure_dynamic_framerate"] == 0,
          f"{lock['controls']}")
    check("exposure_locked reflects the manual-exposure readback",
          lock["exposure_locked"] is True)
    partial = {k: tuple(v) for k, v in BRIO_STATE.items()
               if k != "focus_automatic_continuous"}
    prunner = fake_v4l2(partial)
    plock = recorder.camera_lock("/dev/video9", runner=prunner)
    check("missing control skipped, not force-set",
          "focus_automatic_continuous" not in plock["applied"]
          and not any("focus_automatic_continuous" in " ".join(c)
                      for c in prunner.calls if "--set-ctrl" in c))
    check("no v4l2-ctl / no camera -> graceful None",
          recorder.camera_lock("/dev/video9", runner=lambda argv, timeout=None: None) is None)

    print("case: cmd_record writes ONE bundle per param set (attribution blocker)")
    orig_make = drvmod.make_driver
    drvmod.make_driver = lambda **kw: HarvestFakeDriver()
    try:
        with tempfile.TemporaryDirectory() as d:
            mpath = os.path.join(d, "manifest.json")
            with open(mpath, "w") as f:
                json.dump(manifest, f)
            pspath = os.path.join(d, "param_sets.json")
            with open(pspath, "w") as f:
                json.dump([["A", {}], ["B", {"refresh_waveform": 6}]], f)
            base = os.path.join(d, "bun")
            rc = recorder.main(["record", "--manifest", mpath, "--bundle", base,
                                "--param-sets", pspath, "--abba",
                                "--frontlight-level", "60", "--page-period", "0"])
            dirs = sorted(x for x in os.listdir(d) if x.startswith("bun"))
            check("ABBA [A,B] -> four per-run bundle dirs, label-slugged",
                  rc == 0 and dirs == ["bun.r00-A", "bun.r01-B",
                                       "bun.r02-B", "bun.r03-A"], f"rc={rc} {dirs}")
            with open(os.path.join(d, "bun.r02-B", "session.json")) as f:
                sess = json.load(f)
            run = sess["runs"][0]
            check("run r2 attributed to ITS param set (add_run params fix)",
                  run["run_id"] == "r2" and run["label"] == "B"
                  and run["params"] == {"refresh_waveform": 6},
                  f"{run['run_id']} {run['params']}")
            check("per-run session is v2 with measured events + temp endpoints",
                  sess["version"] == 2 and run["events_source"] == "measured"
                  and run["panel_temp_c_start"] == 24.0
                  and run["panel_temp_c_end"] == 24.0)
            check("per-run trace sidecar written + referenced",
                  run["trace"] == "trace.r2.log"
                  and os.path.exists(os.path.join(d, "bun.r02-B", "trace.r2.log")))
            check("single-param-set --video multi-run guard trips on --abba",
                  recorder.main(["record", "--manifest", mpath, "--bundle", base,
                                 "--param-sets", pspath, "--abba",
                                 "--frontlight-level", "60", "--page-period", "0",
                                 "--video", mpath]) == 2)
    finally:
        drvmod.make_driver = orig_make

    print("case: build a synthetic bundle + validate it")
    if not (shutil.which("ffmpeg") and shutil.which("ffprobe")):
        print("  [skip] ffmpeg not on PATH (run inside guix shell ... ffmpeg)")
        print()
        return 1 if _fails else 0

    fps = 20.0
    from_pid, to_pid = first_adjacent_pair(manifest, "novel", "blank")
    pid_by_index = {p["index"]: p["pid"] for p in manifest["pages"]}
    tr_by_pids = {(pid_by_index[t["from"]], pid_by_index[t["to"]]): t
                  for t in manifest["transitions"]}
    expected_stress = tr_by_pids[(from_pid, to_pid)]["stress"]
    with tempfile.TemporaryDirectory() as d:
        gc16_dir = make_bundle(d, "gc16", manifest, summ, fps)
        gl16_dir = make_bundle(d, "gl16", manifest, summ, fps)

        loaded = B.load_bundle(gc16_dir, verify_hashes=True)
        check("bundle validates + hashes verify",
              loaded.session["schema"] == B.SCHEMA
              and loaded.session["version"] == 2)
        check("waveform summary survives round-trip",
              loaded.session["waveform_decode"]["gc16_phases_by_temp"]["0"] == 131)
        check("trace sidecar referenced by the run and present on disk",
              loaded.session["runs"][0]["trace"] == "trace.r0.log"
              and os.path.exists(os.path.join(gc16_dir, "trace.r0.log")))

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
              (from_pid, to_pid) in pairs, f"{sorted(pairs)}")
        if (from_pid, to_pid) in pairs:
            gc = pairs[(from_pid, to_pid)]
            check("GC16 novel->blank classified flash severe",
                  gc["flash"]["severity"] == "severe",
                  f"depth={gc['flash']['depth']} sev={gc['flash']['severity']}")
            check("GC16 transition carries its stress label from the manifest",
                  gc["stress"] == expected_stress, f"{gc['stress']}")
            check("every transition attributed to its run (run_id + params)",
                  all(t["run_id"] == "r0"
                      and t["params"] == {"refresh_waveform": 4}
                      for t in report["transitions"]),
                  f"{gc.get('run_id')} {gc.get('params')}")
        check("report echoes device identity",
              report["device"]["model"] == "PineNote")
        check("report selects the capture's run explicitly (1:1 per-run bundle)",
              report["run"]["run_id"] == "r0"
              and report["run"]["selection"] == "single"
              and report["run"]["trace"] == "trace.r0.log"
              and report["run"]["panel_temp_c_start"] == 24.0
              and report["run"]["panel_temp_c_end"] == 24.4, f"{report['run']}")
        check("summary carries the run attribution",
              report["summary"]["run_id"] == "r0"
              and report["summary"]["params"] == {"refresh_waveform": 4})
        check("report summary flags the worst flash",
              report["summary"]["worst_flash_depth"] >= optics_severe(),
              f"worst={report['summary']['worst_flash_depth']}")
        text = analyze.format_report_text(report)
        check("human-readable summary renders with run attribution",
              "defect report" in text and "PineNote" in text.splitlines()[0]
              and "run: r0" in text)

        print("case: END-TO-END -- analyze the GL16 bundle -> no flash report")
        report2 = analyze.analyze_bundle(gl16_dir)
        pairs2 = {(t["from_pid"], t["to_pid"]): t for t in report2["transitions"]}
        gl = pairs2.get((from_pid, to_pid))
        check("GL16 novel->blank classified no flash",
              gl is not None and gl["flash"]["severity"] == "none",
              f"severity={gl['flash']['severity'] if gl else 'missing'}")
        check("GL16 transitions attributed to the GL16 config",
              gl is not None and gl["params"] == {"refresh_waveform": 6})

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
