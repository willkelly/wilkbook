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
      trace.<run_id>.log  # optional: the harvested on-device [pn-refresh] trace

`session.json` schema (schema="wilkbook-optics-bundle", version=2):

    {
      "schema": "wilkbook-optics-bundle", "version": 2,
      "created_utc": "2026-07-10T00:00:00Z",
      "device":   {"model","revision","os","kernel","notes","wbf_sha256"?},
      "capture":  {"file","container","fps","sha256"},
      "camera":   {"model","fps_mode","controls","exposure_locked"},
      "reader":   {"full_refresh_count","flash_area_fraction"},
      "testcard": {"card_id","card_version","manifest_file","manifest_sha256"},
      "illuminant": {"source"="frontlight","cool_level","warm_level","ambient"},
      "panel_temp_c": <float|null>,          # session default; a run may override
      "ebc_params": { ... },                 # baseline rockchip_ebc params
      "runs": [ {                            # one pass of the scenario per param set
        "run_id","label","params",          # params = per-run overrides flipped first
        "frontlight_level",
        "panel_temp_c",                     # legacy mirror of _start
        "panel_temp_c_start","panel_temp_c_end",
        "events_source": "measured|nominal",  # nominal = synthesized timeline
        "trace": "trace.<run_id>.log"|null,   # harvested [pn-refresh] sidecar
        "events": [ {"t": <s from clock-zero>,
                     "event": "sync|page|param|clean", ...} ]
      } ],
      "waveform_decode": { ...summary... }   # decoded SUMMARY ONLY, never a raw .wbf
    }

Version history: v1 had a single `illuminant.level` scalar (both frontlight
channels pinned equal -- so old bundles are NOT underspecified), no camera /
reader / trace metadata and no per-run temperature endpoints. `load_bundle`
migrates v1 sessions to the v2 shape in memory (`migrate_session`); files on
disk are never rewritten.

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
VERSION = 2

# runs[].events_source: how the event timeline was produced. 'measured' = the
# recorder timestamped real driver calls (run_scenario); 'nominal' = synthesized
# from the manifest (scenario_events -- the manual `package` path). Consumers
# (e.g. the turn-latency join) must gate on this before trusting event times.
EVENTS_SOURCES = ("measured", "nominal")

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

def new_session(device, illuminant_level=None, ebc_params=None, panel_temp_c=None,
                card_id="wilkbook-optics-testcard", card_version=1,
                illuminant_ambient="dark-box", created_utc=None,
                illuminant_cool=None, illuminant_warm=None,
                camera=None, reader=None):
    """Build an in-memory session dict (no files yet). `device` is a dict with
    at least {'model'}; the rest default. `write_bundle` fills capture/manifest
    hashes when it copies the files in.

    Illuminant: pass per-channel `illuminant_cool`/`illuminant_warm`, or the
    single `illuminant_level` which pins both channels equal (the driver
    convention -- exactly what v1's scalar meant). `camera` and `reader` are
    optional dicts merged over the v2 defaults (see the module docstring)."""
    dev = {"model": None, "revision": None, "os": None, "kernel": None,
           "notes": ""}
    dev.update(device or {})
    if not dev.get("model"):
        raise ValueError("device['model'] is required")
    cool = illuminant_cool if illuminant_cool is not None else illuminant_level
    warm = illuminant_warm if illuminant_warm is not None else illuminant_level
    cam = {"model": None, "fps_mode": None, "controls": None,
           "exposure_locked": False}
    cam.update(camera or {})
    rdr = {"full_refresh_count": None, "flash_area_fraction": None}
    rdr.update(reader or {})
    return {
        "schema": SCHEMA,
        "version": VERSION,
        "created_utc": created_utc or _utc_now_iso(),
        "device": dev,
        "capture": {"file": None, "container": None, "fps": None,
                    "sha256": None},
        "camera": cam,
        "reader": rdr,
        "testcard": {"card_id": card_id, "card_version": card_version,
                     "manifest_file": MANIFEST_NAME, "manifest_sha256": None},
        "illuminant": {"source": STANDARD_ILLUMINANT,
                       "cool_level": cool, "warm_level": warm,
                       "ambient": illuminant_ambient},
        "panel_temp_c": panel_temp_c,
        "ebc_params": dict(ebc_params or {}),
        "runs": [],
        "waveform_decode": None,
    }


def add_run(session, run_id, events, label="", params=None,
            frontlight_level=None, panel_temp_c=None,
            panel_temp_c_start=None, panel_temp_c_end=None,
            events_source="measured", trace=None):
    """Append one scenario pass. `events` is a list of event dicts (see
    scenario_events / recorder.run_scenario); they are normalized and checked to
    be non-negative and time-ordered.

    `panel_temp_c_start`/`_end` bracket the run (ME6: refuse comparisons that
    straddle a waveform temp bin); the legacy `panel_temp_c` mirrors the start.
    `events_source` must be 'measured' (recorder-timestamped) or 'nominal'
    (synthesized). `trace` names the harvested [pn-refresh] log sidecar inside
    the bundle (a bare filename like 'trace.r0.log'), or None."""
    evs = [_norm_event(e) for e in events]
    ts = [e["t"] for e in evs]
    if any(t < 0 for t in ts):
        raise ValueError(f"run {run_id}: event timestamps must be >= 0")
    if ts != sorted(ts):
        raise ValueError(f"run {run_id}: events must be time-ordered")
    if events_source not in EVENTS_SOURCES:
        raise ValueError(f"run {run_id}: events_source must be one of "
                         f"{EVENTS_SOURCES} (got {events_source!r})")
    start = panel_temp_c_start if panel_temp_c_start is not None else panel_temp_c
    session["runs"].append({
        "run_id": run_id,
        "label": label,
        "params": dict(params or {}),
        "frontlight_level": frontlight_level,
        "panel_temp_c": start,
        "panel_temp_c_start": start,
        "panel_temp_c_end": panel_temp_c_end,
        "events_source": events_source,
        "trace": trace,
        "events": evs,
    })
    return session["runs"][-1]


def _norm_event(e):
    if "t" not in e or "event" not in e:
        raise ValueError(f"event needs 't' and 'event': {e!r}")
    out = {"t": round(float(e["t"]), 4), "event": str(e["event"])}
    for k in ("page_index", "pid", "kind", "params", "detail", "n"):
        if k in e and e[k] is not None:
            out[k] = e[k]
    return out


def set_waveform_decode(session, summary):
    """Attach a decoded waveform summary (from waveform_summary_from_wbf_info).
    Validated to be summary-only -- a raw-LUT-shaped payload is rejected."""
    _check_waveform_summary(summary)
    session["waveform_decode"] = summary


def scenario_events(manifest, start_t=0.0, sync_dwell_s=0.75, page_period_s=3.0,
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
    # tolerate sources already at their destination (the recorder films
    # straight into the bundle dir; copyfile would raise SameFileError)
    for src, dst in ((video_path, os.path.join(bundle_dir, cap_name)),
                     (manifest_path, os.path.join(bundle_dir, MANIFEST_NAME))):
        if os.path.abspath(src) != os.path.abspath(dst):
            shutil.copyfile(src, dst)

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


def migrate_session(session):
    """Upgrade an older session dict to the current (v2) shape IN MEMORY -- the
    file on disk is never rewritten. v1 -> v2:

      * illuminant.level -> cool_level + warm_level, split pinned-equal (the v1
        recorder drove both frontlight channels to the same value, so old
        bundles are not underspecified -- this is exact, not a guess);
      * camera / reader blocks default to unknown;
      * runs gain panel_temp_c_start (from the old panel_temp_c), a null
        panel_temp_c_end, no trace, and events_source='nominal' (v1 never
        distinguished measured from synthesized timelines, so consumers must
        not trust v1 event times as measured).

    Returns the same dict, with `migrated_from` recording the original version.
    """
    if session.get("version") == VERSION:
        return session
    if session.get("version") == 1:
        ill = dict(session.get("illuminant") or {})
        if "cool_level" not in ill:
            level = ill.pop("level", None)
            ill["cool_level"] = level
            ill["warm_level"] = level
        session["illuminant"] = ill
        session.setdefault("camera", {"model": None, "fps_mode": None,
                                      "controls": None, "exposure_locked": False})
        session.setdefault("reader", {"full_refresh_count": None,
                                      "flash_area_fraction": None})
        for r in session.get("runs") or []:
            r.setdefault("panel_temp_c_start", r.get("panel_temp_c"))
            r.setdefault("panel_temp_c_end", None)
            r.setdefault("events_source", "nominal")
            r.setdefault("trace", None)
        session["migrated_from"] = 1
        session["version"] = VERSION
    return session


def load_bundle(bundle_dir, verify_hashes=False):
    """Load and validate a bundle directory. Older schema versions are migrated
    in memory (migrate_session). Raises on a malformed session or a policy
    violation (a raw .wbf present). With verify_hashes, also re-checks the
    capture/manifest sha256 recorded at write time."""
    with open(os.path.join(bundle_dir, SESSION_NAME)) as f:
        session = json.load(f)
    session = migrate_session(session)
    problems = validate_session(session)
    if problems:
        raise ValueError("bundle invalid: " + "; ".join(problems))
    assert_no_raw_waveform(bundle_dir)
    b = Bundle(bundle_dir, session)
    if not os.path.exists(b.capture_path):
        raise ValueError(f"capture missing: {session['capture']['file']}")
    if not os.path.exists(b.manifest_path):
        raise ValueError("manifest.json missing")
    for r in session.get("runs") or []:
        tr = r.get("trace")
        if tr and not os.path.exists(os.path.join(b.path, tr)):
            raise ValueError(f"run {r.get('run_id')}: trace sidecar missing: {tr}")
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
    """Return a list of human-readable problems (empty = valid). Validates the
    CURRENT (v2) shape; older on-disk versions go through migrate_session first
    (load_bundle does this automatically)."""
    p = []
    if session.get("schema") != SCHEMA:
        p.append(f"schema must be {SCHEMA!r}")
    if session.get("version") != VERSION:
        p.append(f"version must be {VERSION} (load_bundle migrates v1)")
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
    if ill.get("cool_level") is None or ill.get("warm_level") is None:
        p.append("illuminant.cool_level + warm_level (frontlight split) required")
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
    if r.get("events_source") not in EVENTS_SOURCES:
        p.append(f"run {rid}: events_source must be one of {EVENTS_SOURCES} "
                 f"(got {r.get('events_source')!r})")
    tr = r.get("trace")
    if tr is not None:
        if not isinstance(tr, str) or not tr or os.sep in tr or "/" in tr:
            p.append(f"run {rid}: trace must be a bare filename inside the "
                     f"bundle (got {tr!r})")
        elif tr.lower().endswith(".wbf"):
            p.append(f"run {rid}: trace must not be a raw waveform (policy)")
    for k in ("panel_temp_c_start", "panel_temp_c_end"):
        v = r.get(k)
        if v is not None and not isinstance(v, (int, float)):
            p.append(f"run {rid}: {k} must be a number or null (got {v!r})")
    evs = r.get("events")
    if not isinstance(evs, list) or not evs:
        return [f"run {rid}: needs events"] + p
    ts = []
    for e in evs:
        if "t" not in e or "event" not in e:
            p.append(f"run {rid}: event missing t/event: {e!r}")
            continue
        ts.append(e["t"])
        if e["event"] not in ("sync", "page", "param", "clean"):
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


# --- the [pn-refresh] trace sidecar ------------------------------------------
#
# The KOReader pinenote device target logs one line per refresh decision (see
# pinenote/packages/koreader-device/frontend/device/pinenote/device.lua):
#
#   ... [pn-refresh] <intent> <decision> rect=X,Y,W,H dither=<d> t=<sec>.<usec>
#
# intent   = what KOReader asked for: ui / partial / full
# decision = what the device target did: partial / global
# t        = device epoch seconds (ffi gettime at the moment the refresh was
#            issued -- NOT when the panel finished washing)
# A waveform=<n> token may appear in future emitter revisions; parsed if
# present. The recorder harvests these lines per run into trace.<run_id>.log.

_PN_REFRESH_RE = re.compile(
    r"\[pn-refresh\]\s+(?P<intent>\w+)\s+(?P<decision>\w+)\s+(?P<rest>.*)")
_PN_TOKEN_RE = re.compile(r"(\w+)=(\S+)")


def parse_pn_refresh_trace(text):
    """Parse harvested trace text into refresh-event dicts, ignoring every
    non-[pn-refresh] line (KOReader logs plenty of other output around them).

    Each event: {'intent', 'decision', 'kind', 'rect': (x,y,w,h)|None,
    'dither': str|None, 'waveform': int|None, 't': float}. `kind` collapses
    the pair the analyzers care about: 'full-global' when the decision was a
    global wash, else 'partial'. Lines without a parseable t= are dropped (no
    timestamp = nothing to join on)."""
    events = []
    for line in (text or "").splitlines():
        m = _PN_REFRESH_RE.search(line)
        if not m:
            continue
        tokens = dict(_PN_TOKEN_RE.findall(m.group("rest")))
        try:
            t = float(tokens["t"])
        except (KeyError, ValueError):
            continue
        rect = None
        if "rect" in tokens:
            try:
                x, y, w, h = (int(v) for v in tokens["rect"].split(","))
                rect = (x, y, w, h)
            except ValueError:
                rect = None
        dither = tokens.get("dither")
        if dither in ("nil", "None"):
            dither = None
        waveform = None
        if "waveform" in tokens:
            try:
                waveform = int(tokens["waveform"])
            except ValueError:
                waveform = None
        decision = m.group("decision")
        events.append({
            "intent": m.group("intent"),
            "decision": decision,
            "kind": "full-global" if decision == "global" else "partial",
            "rect": rect,
            "dither": dither,
            "waveform": waveform,
            "t": t,
        })
    return events


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
