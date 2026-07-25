#!/usr/bin/env python3
"""Offline- and hardware-proven SSH reader-energy ABBA harness.

Raw reports contain sensitive system fields.  --output is mandatory, owner-only,
outside this checkout, and must never be committed.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
import re
import shlex
import shutil
import stat
import sys
import tempfile
import time
import uuid
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
OPTICS = os.path.normpath(os.path.join(HERE, "..", "optics"))
if OPTICS not in sys.path:
    sys.path.insert(0, OPTICS)
import driver
import recorder
import bundle as bundle_mod

POLICY_GOVERNOR = "/sys/devices/system/cpu/cpufreq/policy0/scaling_governor"
CHARGER_ONLINE = "/sys/class/power_supply/rk817-charger/online"
FRONTLIGHTS = tuple(node + "/brightness" for node in driver.BACKLIGHT_NODES)
LIVE_WAVEFORM_PATH = "/lib/firmware/rockchip/ebc.wbf"
SAFE_GOVERNOR = re.compile(r"^[A-Za-z0-9_-]+$")
ROOT_DESTINATION = re.compile(
    r"^root@[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?(?:\.[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?)*$")
SYNC_BLOCK = ("sync_black", "sync_white", "sync_black", "sync_white")
STRESS_BLOCK = ("blank", "novel", "novel", "graphic", "graphic", "textbook",
                "novel", "blank", "index", "index", "ux", "novel",
                "graphic", "novel", "blank")
STRESS_LABELS = {
    ("novel", "blank"): ["ghost"],
    ("graphic", "novel"): ["ghost"],
    ("blank", "novel"): ["settle"],
    ("novel", "graphic"): ["flash", "settle"],
    ("graphic", "graphic"): ["ghost"],
    ("index", "ux"): ["flash"],
    ("ux", "novel"): ["settle"],
}


class EnergyError(RuntimeError):
    pass


class CombinedEnergyError(EnergyError):
    def __init__(self, primary, failures):
        self.primary, self.failures = primary, failures
        parts = (["primary: " + str(primary)] if primary else [])
        parts += ["recovery: " + str(error) for error in failures]
        super().__init__("; ".join(parts) or "reader-energy failed")


def _short(value, limit=240):
    value = (value or "").strip().replace("\n", " ")
    return value[:limit] + ("..." if len(value) > limit else "")


def _sha256(path):
    digest = hashlib.sha256()
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def _read_manifest(path):
    with open(path, "rb") as f:
        raw = f.read()
    return raw, json.loads(raw.decode("utf-8"))


def validate_card(manifest):
    pages, transitions = manifest.get("pages"), manifest.get("transitions")
    if not isinstance(pages, list) or len(pages) != 49:
        raise EnergyError("manifest is not the canonical 49-page card")
    if [page.get("kind") for page in pages[:4]] != list(SYNC_BLOCK):
        raise EnergyError("manifest does not have the canonical four leading sync pages")
    expected_kinds = list(SYNC_BLOCK + STRESS_BLOCK * 3)
    if [page.get("kind") for page in pages] != expected_kinds:
        raise EnergyError("manifest content does not match the canonical three stress blocks")
    if [page.get("index") for page in pages] != list(range(49)):
        raise EnergyError("manifest indices are not contiguous 0..48")
    if sorted(page.get("pid") for page in pages) != list(range(49)):
        raise EnergyError("manifest PIDs are not unique contiguous 0..48")
    if manifest.get("resolution") != [1872, 1404]:
        raise EnergyError("manifest resolution is not the canonical PineNote card resolution")
    for index, page in enumerate(pages):
        expected_rep = None if index < 4 else (index - 4) // len(STRESS_BLOCK)
        if page.get("rep") != expected_rep:
            raise EnergyError("manifest page repetition fields are not canonical")
    if not isinstance(transitions, list) or len(transitions) != 48:
        raise EnergyError("manifest does not have the canonical 48 transitions")
    for index, item in enumerate(transitions):
        before, after = pages[index], pages[index + 1]
        sync = before["kind"].startswith("sync") or after["kind"].startswith("sync")
        expected = {"from": index, "to": index + 1, "from_kind": before["kind"],
                    "to_kind": after["kind"], "pair": before["kind"] + "->" + after["kind"],
                    "is_sync": sync, "rep": None if sync else after["rep"],
                    "stress": STRESS_LABELS.get((before["kind"], after["kind"]), [])}
        if any(item.get(key) != value for key, value in expected.items()):
            raise EnergyError("manifest transition %d is not canonical" % index)
    return {"pages": len(pages), "content_pages": 45, "sync_pages": 4,
            "transitions": len(transitions)}


def validate_output(path):
    root = os.path.realpath(os.path.join(HERE, "..", "..", ".."))
    target = os.path.abspath(path)
    if os.path.commonpath((root, os.path.realpath(target))) == root:
        raise EnergyError("--output must be outside the repository")
    if not os.path.exists(target):
        os.makedirs(target, mode=0o700)
    info = os.lstat(target)
    if stat.S_ISLNK(info.st_mode) or not stat.S_ISDIR(info.st_mode):
        raise EnergyError("--output must be a real directory, not a symlink")
    if info.st_uid != os.getuid() or info.st_mode & 0o077:
        raise EnergyError("--output must be owned by this user and mode 0700")
    return target


def validate_identity(path):
    try:
        info = os.lstat(path)
    except OSError as error:
        raise EnergyError("--identity must be an existing readable regular file") from error
    if stat.S_ISLNK(info.st_mode) or not stat.S_ISREG(info.st_mode) or not os.access(path, os.R_OK):
        raise EnergyError("--identity must be a readable regular file, not a symlink")
    if info.st_uid != os.getuid() or info.st_mode & 0o077:
        raise EnergyError("--identity must be owned by this user and not group/world accessible")
    return os.path.abspath(path)


def validate_epub_binding(epub_path, manifest_bytes):
    digest = hashlib.sha256(manifest_bytes).hexdigest()
    try:
        with zipfile.ZipFile(epub_path) as archive:
            bound = archive.read("META-INF/wilkbook-manifest.sha256").decode("ascii").strip()
            names = set(archive.namelist())
    except (OSError, KeyError, UnicodeDecodeError, zipfile.BadZipFile) as error:
        raise EnergyError("EPUB lacks a readable wilkbook manifest binding") from error
    if bound != digest:
        raise EnergyError("EPUB manifest binding does not match --manifest")
    required = {"mimetype", "META-INF/container.xml", "OEBPS/content.opf"}
    required.update("OEBPS/page_%03d.xhtml" % index for index in range(49))
    if not required <= names:
        raise EnergyError("EPUB lacks canonical fixed-layout page members")


def validate_args(args):
    if not ROOT_DESTINATION.fullmatch(args.host) or args.host.startswith("-"):
        raise EnergyError("--host must be a non-option root@HOST SSH destination")
    if not isinstance(args.port, int) or not 1 <= args.port <= 65535:
        raise EnergyError("--port must be 1..65535")
    values = (args.page_period, args.settle_delay, args.restore_timeout)
    if not all(math.isfinite(value) and value >= 0 for value in values) or args.page_period <= 0:
        raise EnergyError("timing values must be finite and page period must be positive")
    if args.restore_timeout < 1800.0:
        raise EnergyError("--restore-timeout must be at least the conservative 1800-second floor")
    if args.governor_a == args.governor_b or not all(SAFE_GOVERNOR.fullmatch(value)
                                                      for value in (args.governor_a, args.governor_b)):
        raise EnergyError("governors must be distinct safe names")
    for path, label in ((args.manifest, "manifest"), (args.epub, "EPUB"),
                        (os.path.join(HERE, "power-snapshot.scm"), "snapshot source")):
        if not os.path.isfile(path) or os.path.islink(path) or not os.access(path, os.R_OK):
            raise EnergyError("%s must be a readable regular file" % label)
    validate_identity(args.identity)
    return validate_output(args.output)


class ReaderEnergyHarness:
    def __init__(self, transport, device_driver, manifest, snapshot_source, output_dir,
                 governors, page_period_s, settle_delay_s, restore_timeout_s,
                 provenance, clock_factory=recorder.Clock, sleep=time.sleep):
        self.t, self.driver, self.manifest = transport, device_driver, manifest
        self.snapshot_source, self.output_dir = snapshot_source, output_dir
        self.governors = tuple(governors)
        self.page_period_s, self.settle_delay_s = page_period_s, settle_delay_s
        self.restore_timeout_s, self.provenance = restore_timeout_s, provenance
        self.clock_factory, self.sleep = clock_factory, sleep
        self.token = uuid.uuid4().hex
        self.remote_dir = "/tmp/wilkbook-reader-energy-" + self.token
        self.remote_source = self.remote_dir + "/power-snapshot.scm"
        self.guard_script = self.remote_dir + "/restore-watchdog.sh"
        self.guard_identity = self.remote_dir + "/restore.identity"
        self.guard_log = self.remote_dir + "/restore.log"
        self.original_governor, self.guard_armed, self.mutated = None, False, False
        if len(self.governors) != 2 or self.governors[0] == self.governors[1] or not all(
                SAFE_GOVERNOR.fullmatch(value) for value in self.governors):
            raise EnergyError("governors must be two distinct safe names")
        if (not all(math.isfinite(value) and value >= 0 for value in
                    (self.page_period_s, self.settle_delay_s, self.restore_timeout_s))
                or self.page_period_s <= 0):
            raise EnergyError("harness timing values must be finite and page period positive")
        if self.restore_timeout_s < 1800.0:
            raise EnergyError("harness restore timeout is below the conservative 1800-second floor")
        if not os.path.isfile(self.snapshot_source) or os.path.islink(self.snapshot_source):
            raise EnergyError("snapshot source must be a regular file")
        validate_card(self.manifest)
        self.output_dir = validate_output(self.output_dir)

    def _command(self, command, what, timeout=30):
        try:
            rc, out = self.t.run(command, timeout=timeout)
        except Exception as error:
            raise EnergyError("%s transport error: %s" % (what, _short(str(error)))) from error
        if rc != 0:
            raise EnergyError("%s failed (rc=%s): %s" % (what, rc, _short(out)))
        return out.strip()

    def _read(self, path, what):
        value = self._command("cat " + shlex.quote(path), what)
        if not value:
            raise EnergyError("%s returned an empty value" % what)
        return value

    def _unplugged(self, phase):
        value = self._read(CHARGER_ONLINE, "read charger (%s)" % phase)
        if value != "0":
            raise EnergyError("RK817 charger attached at %s (online=%s)" % (phase, value))
        return value

    def _frontlights(self, validation_only):
        levels = {path: self._read(path, "read frontlight") for path in FRONTLIGHTS}
        if not validation_only and any(value != "0" for value in levels.values()):
            raise EnergyError("both frontlights must be zero: %s" % levels)
        return levels

    def _governor(self, expected, phase):
        value = self._read(POLICY_GOVERNOR, "read governor (%s)" % phase)
        if value != expected:
            raise EnergyError("governor changed at %s: got %s, expected %s" %
                              (phase, value, expected))
        return value

    def _set_governor(self, governor, phase):
        self._command("printf %%s %s > %s" % (shlex.quote(governor), shlex.quote(POLICY_GOVERNOR)),
                      phase + " governor")
        return self._governor(governor, phase + " readback")

    def _create_remote_dir(self):
        command = ("umask 077; mkdir {d} && chmod 700 {d} && "
                   "test -d {d} && test ! -L {d} && test \"$(stat -c '%u:%a:%F' {d})\" = '0:700:directory'").format(
                       d=shlex.quote(self.remote_dir))
        self._command(command, "create private remote directory")

    def _guard_verify_command(self):
        q = shlex.quote
        return ("set -eu; test -r {i}; read pid start sid script extra < {i}; test -z \"${{extra:-}}\"; "
                "case $pid in ''|*[!0-9]*) exit 1;; esac; test $pid -gt 0; "
                "case $start:$sid in *[!0-9:]*|:*) exit 1;; esac; test $pid = $sid; "
                "test \"$script\" = {s}; test -r /proc/$pid/stat; "
                "set -- $(cat /proc/$pid/stat); test \"${{22}}\" = \"$start\"; "
                "test \"$(ps -o sid= -p $pid | tr -d ' ')\" = \"$sid\"; "
                "tr '\\0' ' ' < /proc/$pid/cmdline | grep -F -- {s} >/dev/null; kill -0 $pid; printf OK").format(
                    i=q(self.guard_identity), s=q(self.guard_script))

    def _arm_guard(self):
        script = ("#!/bin/sh\nset -eu\npid=$$\nstart=$(awk '{print $22}' /proc/$pid/stat)\n"
                  "sid=$(ps -o sid= -p $pid | tr -d ' ')\n"
                  "case \"$pid:$start:$sid\" in *[!0-9:]*|:*) exit 1;; esac\n"
                  "test \"$pid\" -gt 0; test \"$pid\" = \"$sid\"\n"
                  "printf '%%s %%s %%s %%s\\n' \"$pid\" \"$start\" \"$sid\" \"$0\" > %s\n"
                  "sleep %s\nprintf %%s %s > %s\nactual=$(cat %s)\n"
                  "if [ \"$actual\" = %s ]; then printf 'RESTORE_OK governor=%%s\\n' \"$actual\"; "
                  "else printf 'RESTORE_FAILED governor=%%s\\n' \"$actual\" >&2; exit 1; fi\n" %
                  (shlex.quote(self.guard_identity), self.restore_timeout_s,
                   shlex.quote(self.original_governor), shlex.quote(POLICY_GOVERNOR),
                   shlex.quote(POLICY_GOVERNOR), shlex.quote(self.original_governor)))
        self.t.push(script.encode(), self.guard_script)
        self._command("chmod 700 " + shlex.quote(self.guard_script), "install watchdog script")
        self.t.run("setsid %s </dev/null >%s 2>&1 &" %
                   (shlex.quote(self.guard_script), shlex.quote(self.guard_log)), detach=True)
        for _ in range(20):
            try:
                if self._command(self._guard_verify_command(), "verify watchdog readiness", timeout=2) == "OK":
                    self.guard_armed = True
                    return
            except EnergyError:
                self.sleep(0.1)
        raise EnergyError("watchdog did not become identity-ready")

    def _verify_guard(self, phase):
        if not self.guard_armed:
            raise EnergyError("watchdog is not armed at %s" % phase)
        self._command(self._guard_verify_command(), "verify watchdog (%s)" % phase)

    def _disarm_guard(self):
        if not self.guard_armed:
            return
        verify = self._guard_verify_command()
        self._command(verify + "; set -- $(cat %s); kill -TERM -- -$1" % shlex.quote(self.guard_identity),
                      "disarm verified watchdog")
        for _ in range(20):
            rc, _ = self.t.run("set -- $(cat %s); kill -0 $1 2>/dev/null" % shlex.quote(self.guard_identity), timeout=5)
            if rc != 0:
                self.guard_armed = False
                return
            self.sleep(0.1)
        raise EnergyError("watchdog process group did not terminate")

    def _snapshot(self, phase):
        cmd = "guile -e %s -s %s snapshot --phase %s --output -" % (
            shlex.quote("(@ (pinenote tools power power-snapshot) command-line-main)"),
            shlex.quote(self.remote_source), shlex.quote(phase))
        return self._command(cmd, "collect %s snapshot" % phase, timeout=60) + "\n"

    def _epoch_anchor(self, phase, context):
        clock = context["clock"]
        host_before = clock.now()
        device_epoch = float(self._command("date +%s.%N", "read device epoch (%s)" % phase, timeout=5))
        host_after = clock.now()
        if not math.isfinite(device_epoch) or device_epoch <= 0:
            raise EnergyError("invalid device epoch anchor")
        host_midpoint = (host_before + host_after) / 2.0
        return {"device_epoch": device_epoch,
                "host_elapsed": host_midpoint - context["clock_zero"]}

    def _validate_trace(self, trace, pages, before_anchor, after_anchor):
        text = trace.decode("utf-8", "replace") if isinstance(trace, bytes) else str(trace or "")
        raw = [line for line in text.splitlines() if "[pn-refresh]" in line]
        parsed = bundle_mod.parse_pn_refresh_trace(text)
        fresh = [event for event in parsed if before_anchor["device_epoch"] < event["t"] < after_anchor["device_epoch"]]
        if len(raw) != len(parsed) or len(fresh) != 45:
            raise EnergyError("trace must contain exactly 45 fresh parseable refresh events")
        if len(pages) != 45 or any(b["t"] >= a["t"] for b, a in zip(pages, pages[1:])):
            raise EnergyError("page event timeline is not strictly monotonic")
        host_span = after_anchor["host_elapsed"] - before_anchor["host_elapsed"]
        device_span = after_anchor["device_epoch"] - before_anchor["device_epoch"]
        if host_span <= 0 or device_span <= 0:
            raise EnergyError("trace anchor interval is not monotonic")
        scale = device_span / host_span
        if not 0.98 <= scale <= 1.02:
            raise EnergyError("host/device trace clocks disagree")
        tolerance = min(max(self.page_period_s * 0.45, 0.25), 1.0)
        residuals = [event["t"] - (before_anchor["device_epoch"] +
                     (page["t"] - before_anchor["host_elapsed"]) * scale)
                     for event, page in zip(fresh, pages)]
        if any(abs(value) >= tolerance for value in residuals):
            raise EnergyError("refresh trace timing does not match content page events")
        return {"parsed": len(parsed), "fresh": len(fresh),
                "clock_scale": scale,
                "max_abs_residual_s": max(abs(x) for x in residuals),
                "anchors": {"before": before_anchor, "after": after_anchor}}

    def _delta(self, before, after, remote):
        self._command("mkdir " + shlex.quote(remote), "create remote leg directory")
        self.t.push(before.encode(), remote + "/before.scm")
        self.t.push(after.encode(), remote + "/after.scm")
        cmd = "guile -e %s -s %s delta %s %s --output -" % (
            shlex.quote("(@ (pinenote tools power power-snapshot) command-line-main)"),
            shlex.quote(self.remote_source), shlex.quote(remote + "/before.scm"), shlex.quote(remote + "/after.scm"))
        return self._command(cmd, "generate collector delta", timeout=60) + "\n"

    def _publish(self, index, governor, record):
        name = "leg-%02d-%s-%s" % (index, governor, self.token[:8])
        stage = tempfile.mkdtemp(prefix="." + name + ".", dir=self.output_dir)
        os.chmod(stage, 0o700)
        try:
            for key in ("before.scm", "after.scm", "delta.scm"):
                if key in record:
                    with open(os.path.join(stage, key), "w") as f: f.write(record[key])
            if record.get("trace"):
                with open(os.path.join(stage, "trace.log"), "wb") as f: f.write(record["trace"])
            with open(os.path.join(stage, "metadata.json"), "w") as f: json.dump(record["metadata"], f, indent=2, sort_keys=True)
            os.replace(stage, os.path.join(self.output_dir, name))
        except Exception:
            if os.path.commonpath((self.output_dir, os.path.realpath(stage))) == self.output_dir:
                shutil.rmtree(stage, ignore_errors=True)
            raise

    def _run_leg(self, index, governor, validation):
        record = {"metadata": {"index": index, "governor": governor, "status": "failed",
                  "order": [self.governors[0], self.governors[1], self.governors[1], self.governors[0]],
                  "validation": validation, "provenance": self.provenance, "workload_events": []}}
        remote = self.remote_dir + "/leg-%02d" % index
        primary = None
        try:
            self._verify_guard("leg mutation")
            self.mutated = True
            record["metadata"]["governor_applied"] = self._set_governor(governor, "apply")
            def before(context):
                self._verify_guard("before content")
                record["metadata"]["charger_before"] = self._unplugged("before content")
                record["metadata"]["frontlights_before"] = self._frontlights(validation["frontlight_validation_only"])
                record["metadata"]["governor_before"] = self._governor(governor, "before content")
                self.sleep(self.settle_delay_s)
                record["before.scm"] = self._snapshot("reader-energy-%02d-before" % index)
                record["metadata"]["before_anchor"] = self._epoch_anchor("before content", context)
            def after(context):
                record["metadata"]["after_anchor"] = self._epoch_anchor("after content", context)
                self._verify_guard("after content")
                record["metadata"]["governor_after"] = self._governor(governor, "after content")
                record["metadata"]["charger_after"] = self._unplugged("after content")
                record["metadata"]["frontlights_after"] = self._frontlights(validation["frontlight_validation_only"])
                record["after.scm"] = self._snapshot("reader-energy-%02d-after" % index)
            run = recorder.run_scenario(self.driver, self.manifest, param_sets=[(governor, {})],
                page_period_s=self.page_period_s, epub_path=getattr(self.driver, "epub_local", None),
                clock=self.clock_factory(), deep_clean_n=0, run_index_start=index,
                before_content=before, after_content=after)[0]
            record["metadata"]["workload_events"] = run["events"]
            record["trace"] = run.get("trace_data")
            backend = getattr(self.driver, "backend", None)
            record["metadata"]["provenance"]["reader_profile"] = {
                "ko_home": getattr(backend, "KO_HOME", None),
                "settings": getattr(backend, "_seeded_settings", None) or {}}
            pages = [event for event in run["events"] if event["event"] == "page"]
            record["metadata"]["trace_validation"] = self._validate_trace(
                record["trace"], pages, record["metadata"]["before_anchor"], record["metadata"]["after_anchor"])
            record["delta.scm"] = self._delta(record["before.scm"], record["after.scm"], remote)
            record["metadata"]["run"] = {key: value for key, value in run.items() if key != "trace_data"}
            record["metadata"]["status"] = "ok"
        except Exception as error:
            if isinstance(error, recorder.ScenarioRunError):
                record["metadata"]["workload_events"] = error.events
                record["trace"] = error.trace_data
            record["metadata"]["error"] = str(error)
            primary = error
        try:
            self._publish(index, governor, record)
        except Exception as error:
            if primary is not None:
                raise CombinedEnergyError(primary, [error]) from primary
            raise
        if primary is not None:
            raise primary

    def run(self, validation_only=False):
        primary, failures = None, []
        try:
            self.driver.connect()
            validation = {"charger_setup": self._unplugged("setup"),
                          "frontlights": self._frontlights(validation_only),
                          "frontlight_validation_only": bool(validation_only)}
            self.original_governor = self._read(POLICY_GOVERNOR, "read original governor")
            self._create_remote_dir()
            with open(self.snapshot_source, "rb") as f: self.t.push(f.read(), self.remote_source)
            self._arm_guard()
            device_info = self.driver.device_info()
            waveform = self.driver.waveform_summary()
            if not all(str(device_info.get(key) or "").strip() for key in ("model", "kernel", "os")):
                raise EnergyError("device identity is incomplete")
            if (waveform.get("wbf_path") != LIVE_WAVEFORM_PATH
                    or not str(waveform.get("wbf_sha256") or "").strip()
                    or not str(waveform.get("active_refresh_waveform") or "").strip()):
                raise EnergyError("non-raw waveform identity is incomplete")
            backend = getattr(self.driver, "backend", None)
            seeded = getattr(backend, "_seeded_settings", None) or {}
            provenance = {"device": device_info, "waveform": waveform,
                          "reader_profile": {"ko_home": getattr(backend, "KO_HOME", None), "settings": seeded},
                          "original_governor": self.original_governor}
            self.provenance.update(provenance)
            for index, governor in enumerate((self.governors[0], self.governors[1], self.governors[1], self.governors[0])):
                self._run_leg(index, governor, validation)
        except Exception as error:
            primary = error
        if self.mutated and self.original_governor:
            try: self._set_governor(self.original_governor, "restore")
            except Exception as error: failures.append(error)
        if not failures:
            try: self._disarm_guard()
            except Exception as error: failures.append(error)
        if not self.guard_armed:
            try: self._command("rm -rf " + shlex.quote(self.remote_dir), "remove remote evidence")
            except Exception as error: failures.append(error)
        try: self.driver.close()
        except Exception as error: failures.append(error)
        if primary or failures:
            raise CombinedEnergyError(primary, failures) from primary


def build_parser():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--host", required=True, help="key-only root@HOST maintenance endpoint (never a serial/tethered target)")
    p.add_argument("--identity", required=True, help="SSH identity for root@HOST")
    p.add_argument("--port", type=int, default=22)
    p.add_argument("--manifest", required=True); p.add_argument("--epub", required=True); p.add_argument("--output", required=True)
    p.add_argument("--governor-a", default="conservative"); p.add_argument("--governor-b", default="powersave")
    p.add_argument("--page-period", type=float, default=3.0); p.add_argument("--settle-delay", type=float, default=15.0)
    p.add_argument("--restore-timeout", type=float, default=1800.0)
    p.add_argument("--allow-nonzero-frontlight-validation-only", action="store_true")
    return p


def main(argv=None):
    args = build_parser().parse_args(argv)
    try:
        output = validate_args(args)
        raw, manifest = _read_manifest(args.manifest)
        counts = validate_card(manifest)
        validate_epub_binding(args.epub, raw)
        provenance = {"manifest_sha256": hashlib.sha256(raw).hexdigest(), "epub_sha256": _sha256(args.epub),
                      "snapshot_source_sha256": _sha256(os.path.join(HERE, "power-snapshot.scm")), "card": counts}
        device = driver.make_driver(transport="ssh", backend="koreader", manifest=manifest, epub_local=args.epub,
                                    host=args.host, port=args.port, identity=args.identity)
        ReaderEnergyHarness(device.t, device, manifest, os.path.join(HERE, "power-snapshot.scm"), output,
                            (args.governor_a, args.governor_b), args.page_period, args.settle_delay,
                            args.restore_timeout, provenance).run(args.allow_nonzero_frontlight_validation_only)
    except (EnergyError, ValueError, OSError, json.JSONDecodeError) as error:
        print("reader-energy: " + str(error), file=sys.stderr)
        return 2
    print("reader-energy: completed ABBA run under " + output)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
