"""recorder.py -- the RECORD-side entry point for the optics harness.

Three responsibilities:

  * `record`  -- drive the test-epub scenario on a PineNote (flip rockchip_ebc
                 params, page through, emit the sync flashes) while a camera
                 films the panel -- ONE video + ONE bundle PER PARAM SET, so
                 every transition joins 1:1 to the config that produced it
                 (PLAN §3 ME1/OL8). Each run is bracketed by a panel-state
                 reset (deep_clean under baseline params, the 'clean' event),
                 panel-temp start/end samples, and a [pn-refresh] trace
                 harvest; --abba counterbalances run order; --camera-lock pins
                 the webcam's auto controls. Device-driving is factored into a
                 Transport x RenderBackend matrix in driver.py: over the USB
                 CDC-ACM console it works TETHERED TODAY (no Wi-Fi), with a
                 KOReader backend (default) or a raw-framebuffer backend. The
                 `DeviceDriver` contract + the `run_scenario` orchestration (a
                 timestamped session log) live here and are unit-tested against
                 a fake driver (test_bundle.py) and the real ShellDeviceDriver
                 (test_driver.py).
  * `package` -- REAL: take a pre-recorded video + metadata and build a bundle
                 (bundle.write_bundle). The path a friend uses: film manually,
                 then package.
  * `analyze` -- REAL: run the analyze path on a bundle (analyze.analyze_bundle).

Reflectance/waveform conventions and the bundle schema live in bundle.py; the
friend-facing rig + capture instructions live in RECORDING.md.
"""
from __future__ import annotations

import argparse
import json
import re
import sys
import time

import bundle as bundle_mod


# ===========================================================================
# The device-driving interface  --  the contract networking must satisfy.
#
# Everything below the `run_scenario` orchestration is abstract on purpose:
# when the Wi-Fi/networking story lands, implement these methods (ssh, an
# on-device agent, adb-like RPC -- transport is free) and the recorder drives a
# real capture with no other change. Keep the methods thin and idempotent.
# ===========================================================================

class DeviceDriver:
    """Abstract driver for one PineNote under test. A concrete transport
    (SSH/RPC/on-device agent) implements every method. All state the analyzer
    needs is captured through here into the session log."""

    # -- connection -------------------------------------------------------
    def connect(self):
        """Open the transport to the device. Idempotent."""
        raise NotImplementedError

    def close(self):
        """Tear down the transport."""
        raise NotImplementedError

    # -- identity / environment ------------------------------------------
    def device_info(self):
        """{'model','revision','os','kernel', ...} for session['device']."""
        raise NotImplementedError

    def read_panel_temp(self):
        """Panel temperature in C (TPS65185 sensor) or None if unavailable."""
        raise NotImplementedError

    def set_frontlight(self, level):
        """Set the frontlight to `level` (the standardized illuminant). Return
        the level actually applied."""
        raise NotImplementedError

    def waveform_summary(self):
        """Run `wbf-info` on the device's own ebc.wbf and return the DECODED
        summary dict (bundle.waveform_summary_from_wbf_info). MUST NOT return,
        transfer, or persist the raw .wbf -- repo policy. `wbf_sha256` may
        identify which waveform without shipping it."""
        raise NotImplementedError

    # -- driver params ----------------------------------------------------
    def set_ebc_params(self, params):
        """Apply rockchip_ebc params for the next run (module params / sysfs /
        debugfs). `params` is a dict; return the params actually in effect."""
        raise NotImplementedError

    # -- scenario playback ------------------------------------------------
    def open_testcard(self, epub_path=None):
        """Load the test-epub in the reader (KOReader) or map it to /dev/fb0 and
        park on the first page. Called once per run before emit_sync."""
        raise NotImplementedError

    def emit_sync(self):
        """Show the opening black/white flash sequence (clock-zero). Returns
        when the last flash is on screen."""
        raise NotImplementedError

    def goto_page(self, index):
        """Display page `index` of the test card and return when the refresh has
        been issued (not necessarily settled)."""
        raise NotImplementedError


# The concrete drivers live in driver.py: a Transport (SerialTransport over the
# USB CDC-ACM console -- tethered, no Wi-Fi -- or SSHTransport over the network)
# composed with a RenderBackend (KOReaderBackend default, or FramebufferBackend).
# `cmd_record` builds one via driver.make_driver. (The old NetworkDriver stub is
# gone: the serial transport unblocks the on-device path today.)


# ===========================================================================
# Scenario orchestration (REAL) -- driver calls -> a timestamped session log.
# ===========================================================================

class Clock:
    """Wall-clock adapter. `sleep` advances real time; `now` reads it. Injecting
    a fake makes run_scenario fully deterministic and testable offline."""

    def now(self):
        return time.monotonic()

    def sleep(self, seconds):
        time.sleep(seconds)


class FakeClock(Clock):
    """Deterministic clock: `sleep` just advances a counter, `now` reads it. No
    real time passes -- for tests and dry-runs."""

    def __init__(self, start=0.0):
        self.t = start

    def now(self):
        return self.t

    def sleep(self, seconds):
        self.t += seconds


def deep_clean(driver, n=3):
    """Panel-state reset (PLAN §3 ME3): under the CURRENT params, save the live
    refresh_waveform, flip it to 4 (GC16) via driver.set_ebc_params, fire `n`
    global refreshes through the driver's transport (`pinenote-ebc-refresh`,
    the hardware-validated GLOBAL_REFRESH tool -- works under both backends),
    then restore the saved value. Returns the number of refreshes actually
    issued.

    Drivers without a `.t` transport (pure fakes) get a full no-op (return 0):
    with no transport there is no refresh to fire and no way to read the prior
    waveform back, so flipping the param would only leave state mutated."""
    t = getattr(driver, "t", None)
    if t is None or n <= 0:
        return 0
    import driver as drv_mod          # lazy: driver.py imports recorder
    prev = None
    try:
        rc, out = t.run("cat %s 2>/dev/null" % drv_mod.REFRESH_WAVEFORM)
        if rc == 0 and out and out.strip():
            prev = out.strip()
    except Exception:
        prev = None
    driver.set_ebc_params({"refresh_waveform": 4})
    done = 0
    for _ in range(int(n)):
        try:
            rc, _out = t.run(drv_mod.EBC_REFRESH)
        except Exception:
            break
        if rc != 0:
            break
        done += 1
    if prev is not None and prev != "4":
        driver.set_ebc_params({"refresh_waveform": prev})
    return done


def abba_order(param_sets):
    """Counterbalanced run order (ME3): [A, B] -> [A, B, B, A] (generally the
    list followed by its mirror), so slow drifts -- panel temperature, ambient
    light, camera warm-up -- average out of the A-vs-B comparison instead of
    confounding it. Labels are preserved verbatim: the label is the aggregation
    key (two runs of 'A' pool by label); run ids stay distinct by position."""
    sets = list(param_sets)
    return sets + sets[::-1]


# Where the KOReader backend's launch redirects the reader's stdout/stderr --
# the [pn-refresh] intent trace lives here (NOT reader-session.log; see
# driver.KOReaderBackend.prepare).
TRACE_LOG = "/var/log/optics-koreader.log"


def pull_trace(driver):
    """Harvest the on-device [pn-refresh] trace after a run (PLAN task 6).
    Prefers the driver's own harvest_trace() when it exists (being added to
    driver.py concurrently -- duck-typed via hasattr so either lands first);
    else falls back to transport.pull of TRACE_LOG. Returns bytes or None --
    never raises, because a missing trace must not kill a hardware run."""
    fn = getattr(driver, "harvest_trace", None)
    if callable(fn):
        try:
            data = fn()
        except Exception:
            return None
    else:
        t = getattr(driver, "t", None)
        if t is None:
            return None
        try:
            data = t.pull(TRACE_LOG)
        except Exception:
            return None
    if isinstance(data, str):
        data = data.encode("utf-8")
    return data or None


def run_scenario(driver, manifest, param_sets=None, page_period_s=3.0,
                 epub_path=None, clock=None, frontlight_level=None,
                 baseline_params=None, deep_clean_n=3, run_index_start=0):
    """Drive one capture session and return the list of run dicts (each ready
    for bundle.add_run). For every param set: reset the panel state (apply the
    baseline params, then deep_clean -- logged as a 'clean' event), flip the
    candidate params, open the card, emit the sync flashes (which set
    clock-zero), then page through every non-sync page, timestamping each
    driver call from clock-zero. Pure orchestration -- all device I/O goes
    through `driver`; the timeline comes from `clock`.

    Every param set re-opens the card and re-emits its own sync flashes, so a
    per-run capture always contains exactly one sync sequence (the analyzer's
    single-find_sync assumption). Panel temperature is sampled at run start AND
    end (ME6 bin-straddle guard), and the on-device [pn-refresh] trace is
    harvested per run into the run dict's `trace_data` (bytes) -- harvested
    before the next set's open_testcard truncates the log.

    baseline_params: the known-good params the deep clean runs under; defaults
    to the first param set's params. deep_clean_n=0 disables the reset (and its
    event). run_index_start offsets the generated run ids (r0, r1, ...) so a
    caller invoking run_scenario once per param set still gets distinct ids.

    frontlight_level: if set, apply it once (the standardized illuminant) and
    record the level actually applied on each run."""
    clock = clock or Clock()
    param_sets = param_sets or [("default", {})]
    if baseline_params is None:
        baseline_params = dict(param_sets[0][1])
    content = [p for p in manifest["pages"] if not p["kind"].startswith("sync")]
    applied_fl = (driver.set_frontlight(frontlight_level)
                  if frontlight_level is not None else None)

    runs = []
    for i, (label, params) in enumerate(param_sets):
        # panel-state reset: baseline params + GC16 deep cleans, so run N does
        # not inherit run N-1's residue (comparable runs, ME3)
        cleaned = 0
        if deep_clean_n:
            driver.set_ebc_params(dict(baseline_params))
            cleaned = deep_clean(driver, n=deep_clean_n)
        applied = driver.set_ebc_params(params) or dict(params)
        driver.open_testcard(epub_path)
        temp_start = _safe(driver.read_panel_temp)

        driver.emit_sync()
        t0 = clock.now()                      # clock-zero = first sync flash
        events = []
        if deep_clean_n:
            events.append({"t": 0.0, "event": "clean", "n": cleaned})
        events.append({"t": 0.0, "event": "sync",
                       "detail": "opening black/white flashes (clock-zero)"})
        if params:
            events.append({"t": 0.0, "event": "param", "params": dict(params)})

        for p in content:
            clock.sleep(page_period_s)
            driver.goto_page(p["index"])
            events.append({"t": round(clock.now() - t0, 4), "event": "page",
                           "page_index": p["index"], "pid": p["pid"],
                           "kind": p["kind"]})
        clock.sleep(page_period_s)            # let the last transition settle

        runs.append({
            "run_id": f"r{run_index_start + i}",
            "label": label,
            "params": applied,
            "frontlight_level": applied_fl,
            "panel_temp_c": temp_start,
            "panel_temp_c_start": temp_start,
            "panel_temp_c_end": _safe(driver.read_panel_temp),
            "events_source": "measured",
            "trace_data": pull_trace(driver),
            "events": events,
        })
    return runs


def _safe(fn):
    try:
        return fn()
    except Exception:
        return None


# ===========================================================================
# Camera control lock (photometric stability, PLAN §3 OL8)
# ===========================================================================
#
# The rig camera is a Logitech Brio. Confirmed v4l2 controls: auto_exposure
# (menu; 1=manual, 3=aperture-priority DEFAULT), exposure_time_absolute,
# exposure_dynamic_framerate (bool, DEFAULT **1** -- i.e. the camera drops
# frame rate in low light = VFR unless locked!), focus_automatic_continuous,
# focus_absolute, white_balance_automatic, white_balance_temperature, gain,
# power_line_frequency. Best modes: MJPG 1920x1080@60 (default rig mode),
# MJPG 1280x720@90 (fast-mode A2/DU studies).

# (control, lock value) applied when the probe says the control exists; any
# camera missing one simply skips it (not every webcam has every control).
V4L2_LOCK_CONTROLS = (
    ("auto_exposure", 1),               # menu: 1 = manual exposure
    ("exposure_dynamic_framerate", 0),  # bool: Brio DEFAULT 1 = VFR -- lock it!
    ("focus_automatic_continuous", 0),
    ("white_balance_automatic", 0),
)


def _v4l2_runner(argv, timeout=10.0):
    """Default subprocess runner for camera_lock: returns (rc, stdout) or None
    when the binary is missing / unrunnable (camera_lock treats None as 'cannot
    lock' and no-ops gracefully)."""
    import subprocess
    try:
        p = subprocess.run(argv, capture_output=True, text=True, timeout=timeout)
    except (OSError, subprocess.SubprocessError):
        return None
    return p.returncode, p.stdout


def parse_v4l2_ctrls(text):
    """Parse `v4l2-ctl --list-ctrls` output into {control_name: value|None}.
    Lines look like:
      auto_exposure 0x009a0901 (menu) : min=0 max=3 default=3 value=3 (...)"""
    out = {}
    for line in (text or "").splitlines():
        m = re.match(r"\s*([a-z0-9_]+)\s+0x[0-9a-fA-F]+\s+\((\w+)\)\s*:\s*(.*)",
                     line)
        if not m:
            continue
        name, _typ, rest = m.groups()
        vm = re.search(r"\bvalue=(-?\d+)", rest)
        out[name] = int(vm.group(1)) if vm else None
    return out


def camera_lock(device, runner=None):
    """Lock the webcam's automatic controls so photometry is stable across a
    session: probe `v4l2-ctl -d device --list-ctrls`, apply whichever of
    V4L2_LOCK_CONTROLS exist, then read back ALL control values (the readback,
    not the request, is what gets persisted -- session camera.controls).

    Returns {'applied': {name: value set}, 'controls': {every control: its
    read-back value}, 'exposure_locked': bool} -- or None when v4l2-ctl or the
    camera is absent (graceful no-op: the capture still runs, just unlocked).
    `runner` is injectable for offline tests: callable(argv) -> (rc, stdout)
    or None."""
    runner = runner or _v4l2_runner
    probe = runner(["v4l2-ctl", "-d", device, "--list-ctrls"])
    if not probe or probe[0] != 0:
        return None
    ctrls = parse_v4l2_ctrls(probe[1])
    if not ctrls:
        return None
    applied = {}
    for name, val in V4L2_LOCK_CONTROLS:
        if name not in ctrls:
            continue
        r = runner(["v4l2-ctl", "-d", device, "--set-ctrl", "%s=%d" % (name, val)])
        if r is not None and r[0] == 0:
            applied[name] = val
    readback = runner(["v4l2-ctl", "-d", device, "--list-ctrls"])
    controls = (parse_v4l2_ctrls(readback[1])
                if readback is not None and readback[0] == 0 else ctrls)
    return {"applied": applied,
            "controls": controls,
            "exposure_locked": controls.get("auto_exposure") == 1}


# ===========================================================================
# CLI
# ===========================================================================

def _load_json(path):
    with open(path) as f:
        return json.load(f)


class _webcam:
    """Best-effort webcam capture around the scenario (hardware-only path).
    Starts ffmpeg recording `device` to `path`, stops it (graceful 'q') on exit.
    A no-op context if `device` is None -- then the operator films manually and
    supplies --video, or runs `package` afterwards."""

    def __init__(self, device, path, extra=None):
        self.device, self.path, self.extra = device, path, list(extra or [])
        self.proc = None

    def __enter__(self):
        if self.device:
            import subprocess
            argv = (["ffmpeg", "-y", "-f", "v4l2", "-i", self.device]
                    + self.extra + [self.path])
            self.proc = subprocess.Popen(argv, stdin=subprocess.PIPE,
                                         stdout=subprocess.DEVNULL,
                                         stderr=subprocess.DEVNULL)
        return self

    def __exit__(self, *exc):
        if self.proc is not None:
            try:
                self.proc.communicate(b"q", timeout=5)
            except Exception:
                self.proc.terminate()


def _run_bundle_dir(base, i, label, n_runs):
    """Per-run bundle directory. A single-run session keeps `base` verbatim
    (the smoke-run path); a multi-run session suffixes base with the run index
    + label slug, so every param set gets its OWN bundle -- the transition ->
    config join is then 1:1 by construction (the attribution blocker, ME1)."""
    if n_runs <= 1:
        return base
    slug = re.sub(r"[^A-Za-z0-9._-]+", "-", str(label)).strip("-.") or "run"
    return "%s.r%02d-%s" % (base.rstrip("/"), i, slug)


def cmd_record(args):
    """Drive a device through the test card while a camera films; write one
    bundle (own video + own sync flashes) PER PARAM SET, so every transition is
    attributable to exactly one config (PLAN §3 ME1/OL8).

    Tethered over the USB CDC-ACM console (--transport serial, default) this
    needs no Wi-Fi. All device I/O is the driver.py Transport x RenderBackend
    matrix (proven in test_driver.py); the per-run bundling/attribution here is
    proven offline in test_bundle.py against a fake driver."""
    import os
    import driver as drv_mod

    manifest = _load_json(args.manifest)
    frames = None
    if args.backend == "fb":
        import numpy as np
        import testepub as te
        Wp, Hp = manifest["resolution"]
        te.W, te.H = Wp, Hp
        frames = drv_mod.frames_from_manifest(
            manifest, lambda kind: np.asarray(
                te.render_page(te.Page(0, kind, 0)), np.float32) / 255.0)

    driver = drv_mod.make_driver(
        transport=args.transport, backend=args.backend, manifest=manifest,
        epub_local=args.epub, frames=frames,
        waveform=(int(args.waveform) if args.waveform is not None else None),
        device=args.device, host=args.host, port=args.port, identity=args.identity)

    param_sets = _load_json(args.param_sets) if args.param_sets else [["baseline", {}]]
    param_sets = [(p[0], p[1]) for p in param_sets]
    ordered = abba_order(param_sets) if args.abba else list(param_sets)
    baseline_params = dict(param_sets[0][1]) if param_sets else {}

    if args.video and len(ordered) > 1:
        print("--video is one pre-recorded clip; a multi-param-set session "
              "needs --camera (one video per run)", file=sys.stderr)
        return 2

    lock = camera_lock(args.camera) if (args.camera and args.camera_lock) else None
    if args.camera and args.camera_lock and lock is None:
        print("camera-lock: v4l2-ctl or the camera is unavailable; "
              "controls NOT locked (photometry may drift)", file=sys.stderr)
    camera_meta = {"model": args.camera_model,
                   "fps_mode": args.fps_mode,
                   "controls": lock["controls"] if lock else None,
                   "exposure_locked": bool(lock and lock["exposure_locked"])}

    driver.connect()
    captured = []                                  # (run, run_dir, video_path)
    try:
        device = _safe(driver.device_info) or {"model": args.model or "PineNote"}
        wf_ident = _safe(driver.waveform_summary) or {}
        for i, (label, params) in enumerate(ordered):
            run_dir = _run_bundle_dir(args.bundle, i, label, len(ordered))
            os.makedirs(run_dir, exist_ok=True)
            video_path = args.video or os.path.join(run_dir, "capture.mkv")
            # the webcam context wraps THIS run only: each capture holds its
            # own sync flashes (run_scenario re-opens the card + re-syncs per
            # set), so analyze's single-find_sync assumption holds per bundle
            with _webcam(args.camera, video_path,
                         args.camera_args.split() if args.camera_args else None):
                runs = run_scenario(driver, manifest, param_sets=[(label, params)],
                                    page_period_s=args.page_period,
                                    epub_path=args.epub,
                                    frontlight_level=args.frontlight_level,
                                    baseline_params=baseline_params,
                                    deep_clean_n=args.deep_clean,
                                    run_index_start=i)
            captured.append((runs[0], run_dir, video_path))
    finally:
        driver.close()

    wrote = []
    for r, run_dir, video_path in captured:
        session = bundle_mod.new_session(
            device=dict(device), illuminant_level=args.frontlight_level,
            ebc_params=baseline_params,
            panel_temp_c=r.get("panel_temp_c_start"),
            camera=dict(camera_meta))
        session["capture"]["fps"] = args.fps
        session["device"].setdefault("wbf_sha256", wf_ident.get("wbf_sha256"))
        trace_name = None
        if r.get("trace_data"):
            trace_name = "trace.%s.log" % r["run_id"]
            with open(os.path.join(run_dir, trace_name), "wb") as f:
                f.write(r["trace_data"])
        bundle_mod.add_run(session, run_id=r["run_id"], events=r["events"],
                           label=r["label"], params=r["params"],
                           frontlight_level=r["frontlight_level"],
                           panel_temp_c_start=r.get("panel_temp_c_start"),
                           panel_temp_c_end=r.get("panel_temp_c_end"),
                           events_source=r.get("events_source", "measured"),
                           trace=trace_name)
        if args.wbf_info:
            with open(args.wbf_info) as f:
                bundle_mod.set_waveform_decode(
                    session, bundle_mod.waveform_summary_from_wbf_info(
                        f.read(), wbf_sha256=wf_ident.get("wbf_sha256")))

        if not (args.camera or args.video):
            # no video captured -> emit the session for a later `package` step
            with open(os.path.join(run_dir, "session.json"), "w") as f:
                json.dump(session, f, indent=2)
            wrote.append(run_dir)
        else:
            wrote.append(bundle_mod.write_bundle(run_dir, session, video_path,
                                                 args.manifest))

    if not (args.camera or args.video):
        print(f"drove {len(captured)} run(s); wrote session.json under: "
              f"{', '.join(wrote)}\n"
              f"  no camera: film the panel, then: recorder.py package "
              f"--video CLIP --manifest {args.manifest} --bundle DIR ...",
              file=sys.stderr)
    else:
        print(f"wrote {len(wrote)} bundle(s): {', '.join(wrote)}")
    return 0


def cmd_package(args):
    """REAL: package a pre-recorded video + metadata into a bundle (the manual
    path: a friend films, then packages). Synthesized event timelines are
    marked events_source='nominal' -- only --events files count as measured."""
    device = _load_json(args.device) if args.device else {}
    if not device.get("model"):
        device["model"] = args.model or "PineNote"
    ebc_params = _load_json(args.ebc_params) if args.ebc_params else {}

    reader = {"full_refresh_count": args.full_refresh_count,
              "flash_area_fraction": args.flash_area_fraction}
    camera = {"model": args.camera_model, "fps_mode": args.fps_mode}
    session = bundle_mod.new_session(
        device=device,
        illuminant_level=args.frontlight_level,
        illuminant_cool=args.cool_level,
        illuminant_warm=args.warm_level,
        ebc_params=ebc_params,
        panel_temp_c=args.panel_temp,
        illuminant_ambient=args.ambient,
        camera=camera,
        reader=reader,
    )
    session["capture"]["fps"] = args.fps
    if args.wbf_sha256:
        # identity even without --wbf-info (was silently dropped -- PLAN ME10)
        session["device"]["wbf_sha256"] = args.wbf_sha256

    manifest = _load_json(args.manifest)
    if args.events:
        events = _load_json(args.events)
        events_source = "measured"
    else:
        events = bundle_mod.scenario_events(manifest, page_period_s=args.page_period)
        events_source = "nominal"
    bundle_mod.add_run(session, run_id="r0", events=events, label=args.label,
                       frontlight_level=args.frontlight_level,
                       panel_temp_c=args.panel_temp,
                       events_source=events_source)

    if args.wbf_info:
        with open(args.wbf_info) as f:
            summary = bundle_mod.waveform_summary_from_wbf_info(
                f.read(), wbf_sha256=args.wbf_sha256, modes_at_c=args.wbf_temp)
        bundle_mod.set_waveform_decode(session, summary)

    path = bundle_mod.write_bundle(args.bundle, session, args.video, args.manifest)
    print(f"wrote bundle {path}")
    if args.zip:
        print(f"wrote {bundle_mod.zip_bundle(path)}")
    return 0


def cmd_analyze(args):
    """REAL: analyze a bundle (delegates to analyze.analyze_bundle)."""
    import analyze                       # imports numpy/scipy only when needed
    report = analyze.analyze_bundle(args.bundle, run_id=args.run_id)
    if args.out:
        with open(args.out, "w") as f:
            json.dump(report, f, indent=2)
    if not args.quiet:
        print(analyze.format_report_text(report))
    return 0


def build_parser():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = ap.add_subparsers(dest="cmd", required=True)

    r = sub.add_parser("record", help="drive a device through the test card + capture")
    r.add_argument("--manifest", required=True, help="the test-card manifest.json")
    r.add_argument("--bundle", required=True, help="output bundle directory")
    r.add_argument("--transport", choices=["serial", "ssh"], default="serial",
                   help="serial = USB CDC-ACM console (tethered, no Wi-Fi); ssh needs networking")
    r.add_argument("--backend", choices=["koreader", "fb"], default="koreader",
                   help="koreader (what a reader sees) or fb (raw framebuffer control)")
    r.add_argument("--device", default="/dev/ttyACM0", help="host serial device (serial transport)")
    r.add_argument("--host", help="device address (ssh transport)")
    r.add_argument("--port", type=int, default=22, help="ssh port")
    r.add_argument("--identity", help="ssh key (ssh transport)")
    r.add_argument("--epub", help="test-card epub to stage on the device")
    r.add_argument("--waveform", help="refresh_waveform to force (fb backend), e.g. 4=GC16 6=GL16")
    r.add_argument("--param-sets", help="JSON [[label,{params}],...]; default one baseline run. "
                   "Each param set gets its OWN video + bundle (dir suffix .rNN-<label>)")
    r.add_argument("--abba", action="store_true",
                   help="counterbalance run order: [A,B] runs as A,B,B,A (mirrored), "
                   "so slow drifts (panel temp, ambient) average out; labels are "
                   "preserved as the aggregation key, run ids stay distinct")
    r.add_argument("--deep-clean", type=int, default=3, metavar="N",
                   help="GC16 global refreshes fired under baseline params before "
                   "each run (panel-state reset, logged as a 'clean' event); 0 disables")
    r.add_argument("--frontlight-level", type=float, help="frontlight level (the illuminant)")
    r.add_argument("--page-period", type=float, default=3.0, help="seconds/page")
    r.add_argument("--model", help="device model if identity probe fails")
    r.add_argument("--camera", help="webcam device to film with, e.g. /dev/video0 (else film manually)")
    r.add_argument("--camera-lock", action="store_true",
                   help="lock the webcam's auto controls via v4l2-ctl before filming and "
                   "persist the read-back values to session camera.controls. Applies "
                   "whichever exist of: auto_exposure=1 (manual), "
                   "exposure_dynamic_framerate=0 (Brio DEFAULT is 1 = variable frame "
                   "rate unless locked!), focus_automatic_continuous=0, "
                   "white_balance_automatic=0. Graceful no-op without v4l2-ctl. "
                   "Rig camera: Logitech Brio -- best modes MJPG 1920x1080@60 "
                   "(default) and MJPG 1280x720@90 for fast-mode (A2/DU) studies")
    r.add_argument("--camera-model", help="camera model for the bundle metadata "
                   "(the rig camera is a Logitech Brio)")
    r.add_argument("--fps-mode", help="camera mode string for the bundle metadata, "
                   "e.g. 'MJPG 1920x1080@60' (rig default) or 'MJPG 1280x720@90' "
                   "(fast-mode studies)")
    r.add_argument("--camera-args", help="extra ffmpeg input args for --camera")
    r.add_argument("--video", help="pre-recorded video instead of --camera capture (single run only)")
    r.add_argument("--fps", type=float, help="nominal capture fps (ingest re-probes)")
    r.add_argument("--wbf-info", help="text file of on-device `wbf-info` -> waveform decode")
    r.set_defaults(func=cmd_record)

    p = sub.add_parser("package", help="package a pre-recorded video into a bundle")
    p.add_argument("--bundle", required=True, help="output bundle directory")
    p.add_argument("--video", required=True, help="the capture video file")
    p.add_argument("--manifest", required=True, help="the test-card manifest.json")
    p.add_argument("--model", help="device model (default PineNote)")
    p.add_argument("--device", help="JSON file of device metadata (overrides --model)")
    p.add_argument("--frontlight-level", type=float, required=True,
                   help="frontlight level used as the illuminant (both channels "
                   "pinned equal; use --cool-level/--warm-level for a split)")
    p.add_argument("--cool-level", type=float,
                   help="cool-channel frontlight level, if it differed from --frontlight-level")
    p.add_argument("--warm-level", type=float,
                   help="warm-channel frontlight level, if it differed from --frontlight-level")
    p.add_argument("--panel-temp", type=float, help="panel temperature in C, if known")
    p.add_argument("--ambient", default="dark-box", help="how ambient light was controlled")
    p.add_argument("--camera-model", help="camera model (e.g. 'Logitech Brio', a phone model)")
    p.add_argument("--fps-mode", help="camera mode string, e.g. 'MJPG 1920x1080@60'")
    p.add_argument("--fps", type=float, help="nominal capture fps (ingest re-probes)")
    p.add_argument("--ebc-params", help="JSON file of rockchip_ebc params used")
    p.add_argument("--full-refresh-count", type=_frc_value,
                   help="KOReader full_refresh_count in effect (int or 'never')")
    p.add_argument("--flash-area-fraction", type=float,
                   help="flash_area_fraction in effect (image/package metadata "
                   "until the reader-side knob is runtime-settable)")
    p.add_argument("--events", help="JSON file of the run's MEASURED events; else a "
                   "nominal timeline is synthesized from the manifest "
                   "(runs[].events_source records which)")
    p.add_argument("--page-period", type=float, default=3.0,
                   help="seconds/page for the auto event timeline")
    p.add_argument("--label", default="", help="run label")
    p.add_argument("--wbf-info", help="text file of `wbf-info` output -> waveform summary")
    p.add_argument("--wbf-sha256", help="sha256 of the device .wbf (identity only)")
    p.add_argument("--wbf-temp", type=int, help="temperature the MODE block was decoded at")
    p.add_argument("--zip", action="store_true", help="also write a .zip to send")
    p.set_defaults(func=cmd_package)

    a = sub.add_parser("analyze", help="analyze a bundle -> defect report")
    a.add_argument("bundle", help="the bundle directory")
    a.add_argument("-o", "--out", help="write the JSON report here")
    a.add_argument("--run-id", help="which run's events belong to this capture "
                   "(only needed for legacy multi-run bundles; per-run bundles are 1:1)")
    a.add_argument("--quiet", action="store_true")
    a.set_defaults(func=cmd_analyze)
    return ap


def _frc_value(v):
    """full_refresh_count CLI value: an int, or the literal 'never'."""
    return int(v) if str(v).lstrip("-").isdigit() else str(v)


def main(argv=None):
    args = build_parser().parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
