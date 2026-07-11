"""Recording-bundle format for the optics harness (the record/analyze seam).

A contributor with a PineNote records their display and sends us a **bundle**: a
self-describing directory holding one capture and the metadata needed to analyze
it *without* their hardware. This module defines that structure, its JSON
session schema, and the helpers to create / write / load / validate one. It is
pure stdlib (json, os, shutil, hashlib) -- no numpy, no camera, no device.

Bundle layout (a directory; a friend zips it and sends the zip):

    <bundle>/
      session.json      # the metadata + per-run log (schema below)
      capture.<ext>     # the panel capture video (mkv/mp4/mov/...)
      manifest.json     # the test-card manifest (the analyzer's ground truth)

`session.json` schema (schema="wilkbook-optics-bundle", version=1):

    {
      "schema": "wilkbook-optics-bundle", "version": 1,
      "created_utc": "2026-07-10T00:00:00Z",
      "device":   {"model","revision","os","kernel","notes"},
      "capture":  {"file","container","fps","sha256"},
      "testcard": {"card_id","card_version","manifest_file","manifest_sha256"},
      "illuminant": {"source"="frontlight","level","ambient"},
      "panel_temp_c": <float|null>,          # session default; a run may override
      "ebc_params": { ... },                 # baseline rockchip_ebc params
      "runs": [ {                            # one pass of the scenario per param set
        "run_id","label","params",          # params = per-run overrides flipped first
        "frontlight_level","panel_temp_c",
        "events": [ {"t": <s from clock-zero>, "event": "sync|page|param", ...} ]
      } ],
      "waveform_decode": { ...summary... }   # decoded SUMMARY ONLY, never a raw .wbf
    }

Why these fields
----------------
* Every panel carries its own waveform calibration, so a per-panel report is
  only comparable next to the *device* identity (`device`), the *illuminant*
  (`illuminant` -- the frontlight is the standardized lamp), the *temperature*
  (`panel_temp_c`; e-ink phase counts triple cold), and the *driver params*
  (`ebc_params` + per-run `params`) that shaped the refresh.
* `events` timestamps are seconds from **clock-zero = the opening sync flash**,
  not wall time -- so a shaky phone clip with no device-clock sync still lines
  up (ingest.find_sync recovers the same zero from the video).
* `waveform_decode` is the *decoded* mode/phase-per-temp-bin summary from
  `../wbf` (wbf-info), never the raw per-device `.wbf`. The raw waveform is
  per-device calibration firmware and is NEVER read, bundled, or committed
  (repo policy, CLAUDE.md). `wbf_sha256` identifies which waveform produced the
  summary without shipping a byte of it.
"""
from __future__ import annotations

import datetime
import hashlib
import json
import os
import re
import shutil

SCHEMA = "wilkbook-optics-bundle"
VERSION = 1

SESSION_NAME = "session.json"
MANIFEST_NAME = "manifest.json"

# The harness is only comparable across panels under the PineNote's own
# frontlight; other illuminants are recorded but flagged by validation.
STANDARD_ILLUMINANT = "frontlight"

# Keys a waveform_decode summary may carry. Anything holding raw per-phase LUT
# data (drive codes, packed buffers) is forbidden -- summary scalars only.
_WAVEFORM_ALLOWED = {
    "source", "wbf_sha256", "mode_version", "wf_type", "frame_rate_hz",
    "panel", "modes_at_c", "temp_bins_c", "phases_by_mode",
    "gc16_phases_by_temp",
}
_WAVEFORM_FORBIDDEN_HINT = re.compile(r"(lut|codes|packed|buf|phases\[)",
                                      re.IGNORECASE)


# --- hashing / io -----------------------------------------------------------

def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def _utc_now_iso():
    return datetime.datetime.now(datetime.timezone.utc).strftime(
        "%Y-%m-%dT%H:%M:%SZ")


# --- session construction ---------------------------------------------------

def new_session(device, illuminant_level, ebc_params=None, panel_temp_c=None,
                card_id="wilkbook-optics-testcard", card_version=1,
                illuminant_ambient="dark-box", created_utc=None):
    """Build an in-memory session dict (no files yet). `device` is a dict with
    at least {'model'}; the rest default. `write_bundle` fills capture/manifest
    hashes when it copies the files in."""
    dev = {"model": None, "revision": None, "os": None, "kernel": None,
           "notes": ""}
    dev.update(device or {})
    if not dev.get("model"):
        raise ValueError("device['model'] is required")
    return {
        "schema": SCHEMA,
        "version": VERSION,
        "created_utc": created_utc or _utc_now_iso(),
        "device": dev,
        "capture": {"file": None, "container": None, "fps": None,
                    "sha256": None},
        "testcard": {"card_id": card_id, "card_version": card_version,
                     "manifest_file": MANIFEST_NAME, "manifest_sha256": None},
        "illuminant": {"source": STANDARD_ILLUMINANT,
                       "level": illuminant_level, "ambient": illuminant_ambient},
        "panel_temp_c": panel_temp_c,
        "ebc_params": dict(ebc_params or {}),
        "runs": [],
        "waveform_decode": None,
    }


def add_run(session, run_id, events, label="", params=None,
            frontlight_level=None, panel_temp_c=None):
    """Append one scenario pass. `events` is a list of event dicts (see
    scenario_events / recorder.run_scenario); they are normalized and checked to
    be non-negative and time-ordered."""
    evs = [_norm_event(e) for e in events]
    ts = [e["t"] for e in evs]
    if any(t < 0 for t in ts):
        raise ValueError(f"run {run_id}: event timestamps must be >= 0")
    if ts != sorted(ts):
        raise ValueError(f"run {run_id}: events must be time-ordered")
    session["runs"].append({
        "run_id": run_id,
        "label": label,
        "params": dict(params or {}),
        "frontlight_level": frontlight_level,
        "panel_temp_c": panel_temp_c,
        "events": evs,
    })
    return session["runs"][-1]


def _norm_event(e):
    if "t" not in e or "event" not in e:
        raise ValueError(f"event needs 't' and 'event': {e!r}")
    out = {"t": round(float(e["t"]), 4), "event": str(e["event"])}
    for k in ("page_index", "pid", "kind", "params", "detail"):
        if k in e and e[k] is not None:
            out[k] = e[k]
    return out


def set_waveform_decode(session, summary):
    """Attach a decoded waveform summary (from waveform_summary_from_wbf_info).
    Validated to be summary-only -- a raw-LUT-shaped payload is rejected."""
    _check_waveform_summary(summary)
    session["waveform_decode"] = summary


def scenario_events(manifest, start_t=0.0, sync_dwell_s=0.75, page_period_s=1.5,
                    include_sync=True):
    """A default event list for one scenario pass, derived from the manifest's
    page sequence. Real driving happens in recorder.run_scenario (which times
    the driver's actual calls); this is the deterministic reference/preview and
    what a manual capture should follow. Sync pages become 'sync' events; the
    rest become 'page' events one page_period_s apart."""
    events = []
    t = start_t
    pages = manifest["pages"]
    if include_sync:
        n_sync = sum(1 for p in pages if p["kind"].startswith("sync"))
        if n_sync:
            events.append({"t": round(t, 4), "event": "sync",
                           "detail": f"{n_sync} black/white flashes (clock-zero)"})
            t += sync_dwell_s * max(1, n_sync)
    for p in pages:
        if p["kind"].startswith("sync"):
            continue
        events.append({"t": round(t, 4), "event": "page",
                       "page_index": p["index"], "pid": p["pid"],
                       "kind": p["kind"]})
        t += page_period_s
    return events


# --- write / load -----------------------------------------------------------

def write_bundle(bundle_dir, session, video_path, manifest_path):
    """Create the bundle directory, copy the capture video and test-card
    manifest into it, fill their hashes/paths in the session, and write
    session.json. Refuses to copy a raw `.wbf` (repo policy). Returns the
    absolute bundle path."""
    if video_path.lower().endswith(".wbf") or manifest_path.lower().endswith(".wbf"):
        raise ValueError("refusing to bundle a raw .wbf (repo waveform policy)")
    os.makedirs(bundle_dir, exist_ok=True)

    ext = os.path.splitext(video_path)[1].lstrip(".").lower() or "bin"
    cap_name = f"capture.{ext}"
    shutil.copyfile(video_path, os.path.join(bundle_dir, cap_name))
    shutil.copyfile(manifest_path, os.path.join(bundle_dir, MANIFEST_NAME))

    session["capture"]["file"] = cap_name
    session["capture"]["container"] = ext
    session["capture"]["sha256"] = sha256_file(os.path.join(bundle_dir, cap_name))
    session["testcard"]["manifest_file"] = MANIFEST_NAME
    session["testcard"]["manifest_sha256"] = sha256_file(
        os.path.join(bundle_dir, MANIFEST_NAME))

    problems = validate_session(session)
    if problems:
        raise ValueError("session invalid: " + "; ".join(problems))
    with open(os.path.join(bundle_dir, SESSION_NAME), "w") as f:
        json.dump(session, f, indent=2)
    assert_no_raw_waveform(bundle_dir)
    return os.path.abspath(bundle_dir)


class Bundle:
    """A loaded bundle: the session dict plus resolved absolute paths."""

    def __init__(self, path, session):
        self.path = os.path.abspath(path)
        self.session = session

    @property
    def capture_path(self):
        return os.path.join(self.path, self.session["capture"]["file"])

    @property
    def manifest_path(self):
        return os.path.join(self.path, self.session["testcard"]["manifest_file"])

    def load_manifest(self):
        with open(self.manifest_path) as f:
            return json.load(f)


def load_bundle(bundle_dir, verify_hashes=False):
    """Load and validate a bundle directory. Raises on a malformed session or a
    policy violation (a raw .wbf present). With verify_hashes, also re-checks the
    capture/manifest sha256 recorded at write time."""
    with open(os.path.join(bundle_dir, SESSION_NAME)) as f:
        session = json.load(f)
    problems = validate_session(session)
    if problems:
        raise ValueError("bundle invalid: " + "; ".join(problems))
    assert_no_raw_waveform(bundle_dir)
    b = Bundle(bundle_dir, session)
    if not os.path.exists(b.capture_path):
        raise ValueError(f"capture missing: {session['capture']['file']}")
    if not os.path.exists(b.manifest_path):
        raise ValueError("manifest.json missing")
    if verify_hashes:
        got = sha256_file(b.capture_path)
        if got != session["capture"]["sha256"]:
            raise ValueError("capture sha256 mismatch (bundle corrupted)")
        got = sha256_file(b.manifest_path)
        if got != session["testcard"]["manifest_sha256"]:
            raise ValueError("manifest sha256 mismatch (bundle corrupted)")
    return b


def zip_bundle(bundle_dir, out_zip=None):
    """Zip a bundle directory for sending. Returns the archive path. Guards the
    no-raw-waveform policy first."""
    assert_no_raw_waveform(bundle_dir)
    base = out_zip[:-4] if out_zip and out_zip.endswith(".zip") else (
        out_zip or bundle_dir.rstrip("/"))
    return shutil.make_archive(base, "zip", root_dir=bundle_dir)


# --- validation / policy ----------------------------------------------------

def assert_no_raw_waveform(bundle_dir):
    """Enforce the repo waveform policy: a bundle must never carry a raw `.wbf`.
    Only its decoded summary belongs in session.json."""
    for root, _dirs, files in os.walk(bundle_dir):
        for name in files:
            if name.lower().endswith(".wbf"):
                raise ValueError(
                    f"bundle contains a raw waveform '{name}' -- forbidden by "
                    "repo policy; ship only the decoded waveform_decode summary")


def validate_session(session):
    """Return a list of human-readable problems (empty = valid)."""
    p = []
    if session.get("schema") != SCHEMA:
        p.append(f"schema must be {SCHEMA!r}")
    if session.get("version") != VERSION:
        p.append(f"version must be {VERSION}")
    dev = session.get("device") or {}
    if not dev.get("model"):
        p.append("device.model required")
    cap = session.get("capture") or {}
    if not cap.get("file"):
        p.append("capture.file required")
    ill = session.get("illuminant") or {}
    if ill.get("source") != STANDARD_ILLUMINANT:
        p.append(f"illuminant.source should be {STANDARD_ILLUMINANT!r} for "
                 f"comparability (got {ill.get('source')!r})")
    if ill.get("level") is None:
        p.append("illuminant.level (frontlight level) required")
    runs = session.get("runs")
    if not isinstance(runs, list) or not runs:
        p.append("at least one run required")
    else:
        for r in runs:
            p += _validate_run(r)
    wd = session.get("waveform_decode")
    if wd is not None:
        try:
            _check_waveform_summary(wd)
        except ValueError as e:
            p.append(str(e))
    return p


def _validate_run(r):
    p = []
    rid = r.get("run_id", "?")
    evs = r.get("events")
    if not isinstance(evs, list) or not evs:
        return [f"run {rid}: needs events"]
    ts = []
    for e in evs:
        if "t" not in e or "event" not in e:
            p.append(f"run {rid}: event missing t/event: {e!r}")
            continue
        ts.append(e["t"])
        if e["event"] not in ("sync", "page", "param"):
            p.append(f"run {rid}: unknown event {e['event']!r}")
    if any(t < 0 for t in ts):
        p.append(f"run {rid}: negative timestamp")
    if ts != sorted(ts):
        p.append(f"run {rid}: events not time-ordered")
    return p


def _check_waveform_summary(wd):
    if not isinstance(wd, dict):
        raise ValueError("waveform_decode must be an object")
    extra = set(wd) - _WAVEFORM_ALLOWED
    if extra:
        raise ValueError(f"waveform_decode has non-summary keys {sorted(extra)} "
                         "(only the decoded summary is allowed, never raw LUTs)")
    for k, v in wd.items():
        if isinstance(v, (list, dict)) and _WAVEFORM_FORBIDDEN_HINT.search(k):
            raise ValueError(f"waveform_decode[{k!r}] looks like raw LUT data")


# --- waveform-decode summary from ../wbf ------------------------------------

def waveform_summary_from_wbf_info(text, wbf_sha256=None, modes_at_c=None):
    """Parse the *text* output of `pinenote/tools/wbf/wbf-info FILE.wbf [TEMP]`
    into the compact waveform_decode summary a bundle carries.

    This consumes only wbf-info's decoded, line-oriented report -- mode/phase
    counts, temp bins, header scalars. It never sees, and this file never opens,
    a raw `.wbf`: the raw waveform stays on the device (repo policy). Pass
    `wbf_sha256` (e.g. the device's own `sha256sum ebc.wbf`) to identify *which*
    waveform without shipping it, and `modes_at_c` to record the temperature the
    per-mode `MODE ...` block was decoded at.
    """
    summary = {"source": "wbf-info"}
    if wbf_sha256:
        summary["wbf_sha256"] = wbf_sha256
    if modes_at_c is not None:
        summary["modes_at_c"] = modes_at_c

    temp_bins, phases_by_mode, gc16_by_temp = [], {}, {}
    for line in text.splitlines():
        line = line.strip()
        m = re.match(r"mode_version:\s*(0x[0-9a-fA-F]+|\d+)", line)
        if m:
            summary["mode_version"] = m.group(1)
        m = re.match(r"wf:\s*version\s+\S+\s+subversion\s+\S+\s+type\s+(\S+)", line)
        if m:
            summary["wf_type"] = m.group(1)
        m = re.match(r"frame_rate:\s*bcd\s+\S+\s+hex\s+(\d+)", line)
        if m:
            summary["frame_rate_hz"] = int(m.group(1))
        m = re.match(r"xwia:\s*(.+)", line)
        if m and m.group(1) != "(unreadable)":
            summary["panel"] = m.group(1)
        m = re.match(r"temp_bin\s+\d+:\s*>=\s*(-?\d+)\s*C", line)
        if m:
            temp_bins.append(int(m.group(1)))
        m = re.match(r"MODE\s+(\w+):\s*index=-?\d+\s+phases=(\d+)", line)
        if m:
            phases_by_mode[m.group(1)] = int(m.group(2))
        m = re.match(r"GC16\s+bin\s+\d+\s*\((-?\d+)\s*C\):.*phases=(\d+)", line)
        if m:
            gc16_by_temp[str(int(m.group(1)))] = int(m.group(2))

    if temp_bins:
        summary["temp_bins_c"] = temp_bins
    if phases_by_mode:
        summary["phases_by_mode"] = phases_by_mode
    if gc16_by_temp:
        summary["gc16_phases_by_temp"] = gc16_by_temp
    _check_waveform_summary(summary)
    return summary
