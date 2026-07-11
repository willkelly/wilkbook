"""recorder.py -- the RECORD-side entry point for the optics harness.

Three responsibilities, split by how ready each is:

  * `record`  -- drive the test-epub scenario on a PineNote over the network
                 (flip rockchip_ebc params, page through, emit the sync flashes)
                 while a camera films the panel. The device-driving is BLOCKED
                 on Wi-Fi/networking (a separate effort), so it lives behind the
                 abstract `DeviceDriver` interface below and ships as a
                 documented STUB (`NetworkDriver`). The scenario *orchestration*
                 (`run_scenario`) that turns driver calls into a timestamped
                 session log is real and unit-tested against a fake driver.
  * `package` -- REAL: take a pre-recorded video + metadata and build a bundle
                 (bundle.write_bundle). This is the path a friend uses today:
                 film manually, then package.
  * `analyze` -- REAL: run the analyze path on a bundle (analyze.analyze_bundle).

Reflectance/waveform conventions and the bundle schema live in bundle.py; the
friend-facing rig + capture instructions live in RECORDING.md.
"""
from __future__ import annotations

import argparse
import json
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


class NetworkDriver(DeviceDriver):
    """STUB. The intended real driver, blocked on Wi-Fi/networking.

    Left as an explicit boundary so `record` fails loudly with a pointer, rather
    than silently. Fill these in once a device is reachable; the `run_scenario`
    orchestration above needs no change.
    """
    _BLOCKED = ("on-device driving is blocked on Wi-Fi/networking (see README "
                "'Recording & bundles'); until then film manually and use "
                "`recorder.py package`. TODO: implement over the device transport.")

    def __init__(self, host, epub_path=None):
        self.host = host
        self.epub_path = epub_path

    def connect(self):
        raise NotImplementedError(NetworkDriver._BLOCKED)

    def close(self):
        pass

    def device_info(self):
        raise NotImplementedError(NetworkDriver._BLOCKED)

    def read_panel_temp(self):
        raise NotImplementedError(NetworkDriver._BLOCKED)

    def set_frontlight(self, level):
        raise NotImplementedError(NetworkDriver._BLOCKED)

    def waveform_summary(self):
        raise NotImplementedError(NetworkDriver._BLOCKED)

    def set_ebc_params(self, params):
        raise NotImplementedError(NetworkDriver._BLOCKED)

    def open_testcard(self, epub_path=None):
        raise NotImplementedError(NetworkDriver._BLOCKED)

    def emit_sync(self):
        raise NotImplementedError(NetworkDriver._BLOCKED)

    def goto_page(self, index):
        raise NotImplementedError(NetworkDriver._BLOCKED)


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


def run_scenario(driver, manifest, param_sets=None, page_period_s=1.5,
                 epub_path=None, clock=None):
    """Drive one capture session and return the list of run dicts (each ready
    for bundle.add_run). For every param set: flip params, open the card, emit
    the sync flashes (which set clock-zero), then page through every non-sync
    page, timestamping each driver call from clock-zero. Pure orchestration --
    all device I/O goes through `driver`; the timeline comes from `clock`."""
    clock = clock or Clock()
    param_sets = param_sets or [("default", {})]
    content = [p for p in manifest["pages"] if not p["kind"].startswith("sync")]

    runs = []
    for i, (label, params) in enumerate(param_sets):
        applied = driver.set_ebc_params(params) or dict(params)
        driver.open_testcard(epub_path)

        driver.emit_sync()
        t0 = clock.now()                      # clock-zero = first sync flash
        events = [{"t": 0.0, "event": "sync",
                   "detail": "opening black/white flashes (clock-zero)"}]
        if params:
            events.append({"t": 0.0, "event": "param", "params": dict(params)})

        for p in content:
            clock.sleep(page_period_s)
            driver.goto_page(p["index"])
            events.append({"t": round(clock.now() - t0, 4), "event": "page",
                           "page_index": p["index"], "pid": p["pid"],
                           "kind": p["kind"]})

        runs.append({
            "run_id": f"r{i}",
            "label": label,
            "params": applied,
            "frontlight_level": None,
            "panel_temp_c": _safe(driver.read_panel_temp),
            "events": events,
        })
    return runs


def _safe(fn):
    try:
        return fn()
    except Exception:
        return None


# ===========================================================================
# CLI
# ===========================================================================

def _load_json(path):
    with open(path) as f:
        return json.load(f)


def cmd_record(args):
    """Drive a device + capture. Blocked on networking -> loud pointer."""
    print("recorder record: on-device driving is not available yet.\n"
          "  The device-driving interface (DeviceDriver) is defined and the\n"
          "  scenario orchestration (run_scenario) is implemented and tested,\n"
          "  but the network transport (NetworkDriver) is BLOCKED on the\n"
          "  Wi-Fi/networking effort. See RECORDING.md for the manual capture\n"
          "  flow, then package it:\n"
          "    python3 recorder.py package --video CLIP --manifest manifest.json ...",
          file=sys.stderr)
    return 2


def cmd_package(args):
    """REAL: package a pre-recorded video + metadata into a bundle."""
    device = _load_json(args.device) if args.device else {}
    if not device.get("model"):
        device["model"] = args.model or "PineNote"
    ebc_params = _load_json(args.ebc_params) if args.ebc_params else {}

    session = bundle_mod.new_session(
        device=device,
        illuminant_level=args.frontlight_level,
        ebc_params=ebc_params,
        panel_temp_c=args.panel_temp,
        illuminant_ambient=args.ambient,
    )
    session["capture"]["fps"] = args.fps

    manifest = _load_json(args.manifest)
    if args.events:
        events = _load_json(args.events)
    else:
        events = bundle_mod.scenario_events(manifest, page_period_s=args.page_period)
    bundle_mod.add_run(session, run_id="r0", events=events, label=args.label,
                       frontlight_level=args.frontlight_level,
                       panel_temp_c=args.panel_temp)

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
    report = analyze.analyze_bundle(args.bundle)
    if args.out:
        with open(args.out, "w") as f:
            json.dump(report, f, indent=2)
    if not args.quiet:
        print(analyze.format_report_text(report))
    return 0


def build_parser():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = ap.add_subparsers(dest="cmd", required=True)

    r = sub.add_parser("record", help="drive a device + capture (blocked on networking)")
    r.add_argument("--host", help="device address (once networking lands)")
    r.set_defaults(func=cmd_record)

    p = sub.add_parser("package", help="package a pre-recorded video into a bundle")
    p.add_argument("--bundle", required=True, help="output bundle directory")
    p.add_argument("--video", required=True, help="the capture video file")
    p.add_argument("--manifest", required=True, help="the test-card manifest.json")
    p.add_argument("--model", help="device model (default PineNote)")
    p.add_argument("--device", help="JSON file of device metadata (overrides --model)")
    p.add_argument("--frontlight-level", type=float, required=True,
                   help="frontlight level used as the illuminant")
    p.add_argument("--panel-temp", type=float, help="panel temperature in C, if known")
    p.add_argument("--ambient", default="dark-box", help="how ambient light was controlled")
    p.add_argument("--fps", type=float, help="nominal capture fps (ingest re-probes)")
    p.add_argument("--ebc-params", help="JSON file of rockchip_ebc params used")
    p.add_argument("--events", help="JSON file of the run's events; else auto from manifest")
    p.add_argument("--page-period", type=float, default=1.5,
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
    a.add_argument("--quiet", action="store_true")
    a.set_defaults(func=cmd_analyze)
    return ap


def main(argv=None):
    args = build_parser().parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
