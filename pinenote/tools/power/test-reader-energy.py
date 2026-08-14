#!/usr/bin/env python3
"""Offline state-machine tests for reader-energy.py; no network or device."""
import importlib.util
import json
import os
import re
import subprocess
import sys
import tempfile
import time
import types

sys.path.insert(0, os.path.normpath(os.path.join(os.path.dirname(__file__), "..", "optics")))
import recorder

spec = importlib.util.spec_from_file_location("reader_energy", os.path.join(os.path.dirname(__file__), "reader-energy.py"))
energy = importlib.util.module_from_spec(spec); spec.loader.exec_module(energy)
FAILS = []


def check(name, value):
    print("  [%s] %s" % ("ok  " if value else "FAIL", name))
    if not value: FAILS.append(name)


def card():
    kinds = list(energy.SYNC_BLOCK + energy.STRESS_BLOCK * 3)
    pages = [{"index": i, "pid": i, "kind": kind,
              "rep": None if i < 4 else (i - 4) // len(energy.STRESS_BLOCK)}
             for i, kind in enumerate(kinds)]
    transitions = []
    for i in range(48):
        before, after = pages[i], pages[i + 1]
        sync = before["kind"].startswith("sync") or after["kind"].startswith("sync")
        transitions.append({"from": i, "to": i + 1, "from_kind": before["kind"],
                            "to_kind": after["kind"], "pair": before["kind"] + "->" + after["kind"],
                            "is_sync": sync, "rep": None if sync else after["rep"],
                            "stress": energy.STRESS_LABELS.get((before["kind"], after["kind"]), [])})
    return {"resolution": [1872, 1404], "pages": pages, "transitions": transitions}


class FakeTransport:
    def __init__(self, identity="ok", trace=True, governor_change=False, restore_fail=False,
                 close_fail=False, cleanup_fail=False, ambiguous_apply=False, connect_fail=False):
        self.identity, self.trace, self.governor_change = identity, trace, governor_change
        self.restore_fail, self.close_fail, self.cleanup_fail = restore_fail, close_fail, cleanup_fail
        self.ambiguous_apply, self.connect_fail = ambiguous_apply, connect_fail
        self.governor, self.detached, self.commands, self.events = "schedutil", [], [], []
        self.directories, self.files, self.dead, self.verify_count = set(), {}, False, 0
        self.epoch_reads = 0
    def connect(self):
        self.events.append("connect")
        if self.connect_fail: raise RuntimeError("connect failed")
        return self
    def close(self):
        self.events.append("close")
        if self.close_fail: raise RuntimeError("close failed")
    def push(self, data, path):
        parent = os.path.dirname(path)
        if "/leg-" in parent and parent not in self.directories:
            raise IOError("leg parent missing")
        self.files[path] = data; self.events.append(("push", path))
    def run(self, command, timeout=None, detach=False):
        self.commands.append(command)
        self.events.append(("run", command))
        if detach:
            self.detached.append(command); self.events.append("detach"); return 0, ""
        if "create private remote directory" in command: return 0, ""
        match = re.search(r"mkdir ['\"]?(/tmp/wilkbook-reader-energy-[^ /'\"]+/leg-\d+)", command)
        if match: self.directories.add(match.group(1)); self.events.append(("mkdir", match.group(1))); return 0, ""
        if "stat -c" in command and "mkdir" in command: return 0, ""
        if "kill -TERM -- -$1" in command: self.dead = True; return 0, ""
        if "printf OK" in command:
            self.verify_count += 1
            if self.identity != "ok" or self.dead: return 1, self.identity
            return 0, "OK"
        if "kill -0 $1" in command: return (1, "") if self.dead else (0, "")
        if command.startswith("cat "):
            if energy.CHARGER_ONLINE in command: return 0, "0"
            if energy.POLICY_GOVERNOR in command: return 0, self.governor
            if any(path in command for path in energy.FRONTLIGHTS): return 0, "0"
        if command == "date +%s.%N":
            self.epoch_reads += 1
            leg = (self.epoch_reads - 1) // 2
            return 0, str(1000.0 + leg * 1000.0 + (46.0 if self.epoch_reads % 2 == 0 else 0.0))
        if command.startswith("printf %s") and energy.POLICY_GOVERNOR in command:
            wanted = next((name for name in ("conservative", "powersave", "schedutil") if name in command), None)
            if wanted == "schedutil" and self.restore_fail: return 1, "restore denied"
            self.governor = wanted
            if wanted != "schedutil" and self.ambiguous_apply: raise OSError("write result lost")
            return 0, ""
        if " snapshot " in command: return 0, "(snapshot (schema \"wilkbook-pinenote-power\"))"
        if " delta " in command: return 0, "(delta (schema \"wilkbook-pinenote-power\"))"
        if command.startswith("rm -rf") and self.cleanup_fail: return 1, "cleanup failed"
        return 0, ""


class FakeDriver(recorder.DeviceDriver):
    def __init__(self, transport, fail_turn=False):
        self.t, self.epub_local, self.fail_turn = transport, "card.epub", fail_turn
        self.backend = types.SimpleNamespace(KO_HOME="/root/.config/koreader-optics",
                                             _seeded_settings=None)
    def connect(self): return self.t.connect()
    def close(self): return self.t.close()
    def device_info(self): return {"model": "PineNote", "kernel": "test", "os": "test"}
    def waveform_summary(self):
        return {"wbf_sha256": "identity",
                "wbf_path": getattr(self.t, "waveform_path", energy.LIVE_WAVEFORM_PATH),
                "active_refresh_waveform": "6"}
    def read_panel_temp(self): return 24.0
    def set_ebc_params(self, params): return params
    def open_testcard(self, epub_path=None):
        self.t.events.append("stage")
        self.backend._seeded_settings = {"full_refresh_count": 9,
                                         "idlewasher_enabled": False}
    def emit_sync(self): self.t.events.append("sync")
    def goto_page(self, index):
        self.t.events.append(("page", index))
        if self.fail_turn: raise RuntimeError("injected page turn failure")
        if self.t.governor_change: self.t.governor = "schedutil"
    def harvest_trace(self):
        if not self.t.trace: return b""
        if hasattr(self.t, "trace_bytes"): return self.t.trace_bytes
        leg = max(0, (self.t.epoch_reads - 1) // 2)
        return "".join("x [pn-refresh] ui partial rect=0,0,1,1 dither=nil t=%0.1f\n" %
                       (1001 + leg * 1000 + i)
                       for i in range(45)).encode()


def harness(directory, transport, fail_turn=False):
    return energy.ReaderEnergyHarness(transport, FakeDriver(transport, fail_turn), card(),
        os.path.join(os.path.dirname(__file__), "power-snapshot.scm"), directory,
        ("conservative", "powersave"), 1, 0, 1800,
        {"manifest_sha256": "m", "epub_sha256": "e", "card": {"pages": 49}},
        clock_factory=recorder.FakeClock, sleep=lambda _: None)


def fails(fn):
    try: fn()
    except Exception as error: return error
    return None


class LocalShellTransport:
    """Executes only temporary local shell fixtures; never contacts a device."""

    # bash, not sh.  reader-energy.py's disarm path issues `kill -TERM -- -$1`
    # (reader-energy.py:304) to signal the guard's whole process group.  dash's
    # builtin kill rejects that -- `kill: Illegal number: -`, rc=2 -- so under a
    # distro /bin/sh these fixtures exercise a shell the reader never has: on the
    # device /bin/sh IS bash, via Guix.  Testing under dash therefore reported a
    # failure the product cannot have, and only on hosts where PATH lacks the
    # Guix profile (i.e. every CI runner; not this project's workstations, which
    # is why it stayed hidden).
    def __init__(self): self.processes = []
    def push(self, data, path):
        with open(path, "wb") as f: f.write(data)
    def run(self, command, timeout=None, detach=False):
        if detach:
            proc = subprocess.Popen(["bash", "-c", command], stdin=subprocess.DEVNULL,
                                    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                    start_new_session=True)
            self.processes.append(proc)
            return 0, ""
        proc = subprocess.run(["bash", "-c", command], capture_output=True, text=True, timeout=timeout)
        return proc.returncode, proc.stdout.strip()


def main():
    print("case: detached identity-safe watchdog and canonical content boundary")
    with tempfile.TemporaryDirectory() as d:
        t = FakeTransport(); harness(d, t).run()
        legs = sorted(x for x in os.listdir(d) if x.startswith("leg-"))
        meta = json.load(open(os.path.join(d, legs[0], "metadata.json")))
        check("watchdog launch is detached, never a blocking sleeper", len(t.detached) == 1 and "setsid" in t.detached[0])
        check("ABBA emits four complete legs", len(legs) == 4 and meta["status"] == "ok")
        check("ABBA leg governors follow conservative,powersave,powersave,conservative",
              [json.load(open(os.path.join(d, leg, "metadata.json")))["governor"]
               for leg in legs] == ["conservative", "powersave", "powersave", "conservative"])
        first_snapshot = next(i for i, event in enumerate(t.events)
                              if isinstance(event, tuple) and event[0] == "run"
                              and " snapshot " in event[1])
        check("snapshots occur after stage and sync",
              t.events.index("stage") < t.events.index("sync") < first_snapshot)
        check("metadata records device/card/actual profile provenance",
              meta["provenance"]["device"]["model"] == "PineNote"
              and meta["provenance"]["card"]["pages"] == 49
              and meta["provenance"]["reader_profile"]["ko_home"] == "/root/.config/koreader-optics"
              and meta["provenance"]["reader_profile"]["settings"]["full_refresh_count"] == 9)
        check("leg directory is created before delta pushes", any(e[0] == "mkdir" for e in t.events if isinstance(e, tuple)))

    print("case: watchdog and workload safety failures")
    for identity in ("pid-reused", "start-mismatch", "session-mismatch", "cmdline-mismatch"):
        with tempfile.TemporaryDirectory() as d:
            error = fails(lambda: harness(d, FakeTransport(identity=identity)).run())
            check(identity + " rejects before mutation", isinstance(error, energy.CombinedEnergyError))
    with tempfile.TemporaryDirectory() as d:
        t = FakeTransport(governor_change=True); error = fails(lambda: harness(d, t).run())
        check("candidate governor changed during workload fails and restores", isinstance(error, energy.CombinedEnergyError) and t.governor == "schedutil")
    with tempfile.TemporaryDirectory() as d:
        error = fails(lambda: harness(d, FakeTransport(trace=False)).run())
        check("missing trace rejects success", isinstance(error, energy.CombinedEnergyError))
    for label, lines in (
            ("stale", ["x [pn-refresh] ui partial t=999.0\n"] * 45),
            ("duplicate", ["x [pn-refresh] ui partial t=1001.0\n"] * 45),
            ("malformed", ["x [pn-refresh] broken\n"] * 45),
            ("wrong-time", ["x [pn-refresh] ui partial t=1050.0\n"] * 45)):
        with tempfile.TemporaryDirectory() as d:
            t = FakeTransport(); t.trace_bytes = "".join(lines).encode()
            error = fails(lambda: harness(d, t).run())
            check(label + " trace rejects success", isinstance(error, energy.CombinedEnergyError))
    with tempfile.TemporaryDirectory() as d:
        t = FakeTransport()
        t.trace_bytes = "".join("x [pn-refresh] ui partial t=%0.1f\n" % (1001 + index)
                                for index in range(45)).encode()
        error = fails(lambda: harness(d, t).run())
        legs = sorted(name for name in os.listdir(d) if name.startswith("leg-"))
        check("reused first-leg trace fails the second leg as stale",
              isinstance(error, energy.CombinedEnergyError) and len(legs) == 2)
    pages = [{"t": float(6 + index), "event": "page"} for index in range(45)]
    trace = "".join("x [pn-refresh] ui partial t=%0.1f\n" % (1001 + index)
                    for index in range(45)).encode()
    with tempfile.TemporaryDirectory() as d:
        mapped = harness(d, FakeTransport())._validate_trace(
            trace, pages,
            {"device_epoch": 1000.0, "host_elapsed": 5.0},
            {"device_epoch": 1046.0, "host_elapsed": 51.0})
        check("trace mapping subtracts pre-content host elapsed", mapped["max_abs_residual_s"] == 0)
    with tempfile.TemporaryDirectory() as d:
        error = fails(lambda: harness(d, FakeTransport(), fail_turn=True).run())
        legs = sorted(name for name in os.listdir(d) if name.startswith("leg-"))
        metadata = json.load(open(os.path.join(d, legs[0], "metadata.json")))
        check("failed injected page turn preserves failure, prefix, and trace",
              isinstance(error, energy.CombinedEnergyError) and "page turn" in str(error)
              and metadata["workload_events"][0]["event"] == "sync"
              and os.path.exists(os.path.join(d, legs[0], "trace.log")))
    with tempfile.TemporaryDirectory() as d:
        t = FakeTransport(restore_fail=True, close_fail=True, cleanup_fail=True)
        error = fails(lambda: harness(d, t, fail_turn=True).run())
        check("primary plus restore/close failures are combined", isinstance(error, energy.CombinedEnergyError) and "restore denied" in str(error) and "close failed" in str(error))
    with tempfile.TemporaryDirectory() as d:
        t = FakeTransport(ambiguous_apply=True); error = fails(lambda: harness(d, t).run())
        check("ambiguous candidate write still restores", isinstance(error, energy.CombinedEnergyError) and t.governor == "schedutil")
    with tempfile.TemporaryDirectory() as d:
        t = FakeTransport(); t.waveform_path = "/state/firmware/ebc.wbf"
        error = fails(lambda: harness(d, t).run())
        check("fallback-only waveform identity rejects before governor mutation",
              isinstance(error, energy.CombinedEnergyError)
              and not any(command.startswith("printf %s") and energy.POLICY_GOVERNOR in command
                          for command in t.commands))
    with tempfile.TemporaryDirectory() as d:
        t = FakeTransport(connect_fail=True); error = fails(lambda: harness(d, t).run())
        check("connect failure closes transport without restoration", isinstance(error, energy.CombinedEnergyError) and
              "close" in t.events and not any(energy.POLICY_GOVERNOR in command for command in t.commands))
    with tempfile.TemporaryDirectory() as d:
        original_replace = energy.os.replace
        energy.os.replace = lambda source, target: (_ for _ in ()).throw(OSError("publish failed"))
        try:
            error = fails(lambda: harness(d, FakeTransport(), fail_turn=True).run())
        finally:
            energy.os.replace = original_replace
        check("workload plus publication failure is combined and staging is removed",
              isinstance(error, energy.CombinedEnergyError) and "publish failed" in str(error) and
              not any(name.startswith(".") for name in os.listdir(d)))

    print("case: local validation")
    bad = card(); bad["pages"] = bad["pages"][:-1]
    check("noncanonical manifest rejected", fails(lambda: energy.validate_card(bad)) is not None)
    all_blank = card()
    for page in all_blank["pages"][4:]: page["kind"] = "blank"
    check("all-blank count-matching manifest rejected", fails(lambda: energy.validate_card(all_blank)) is not None)
    wrong_stress = card(); wrong_stress["transitions"][4]["stress"] = ["wrong"]
    check("wrong transition stress labels rejected", fails(lambda: energy.validate_card(wrong_stress)) is not None)
    parser = energy.build_parser()
    args = parser.parse_args(["--host", "root@host", "--identity", "key", "--manifest", "m", "--epub", "e", "--output", "/tmp/x"])
    check("root endpoint and timeout defaults validate", args.restore_timeout == 1800 and energy.ROOT_DESTINATION.fullmatch(args.host))
    for value in ("-oProxy", "reader@host", "root@-host", "root@host:22", "root@bad..host"):
        args.host = value
        check("unsafe host rejected " + value, fails(lambda: energy.validate_args(args)) is not None)
    args.host = "root@host"; args.port = 0
    check("invalid port rejected", fails(lambda: energy.validate_args(args)) is not None)
    args.port = 22; args.page_period = float("nan")
    check("NaN timing rejected", fails(lambda: energy.validate_args(args)) is not None)
    with tempfile.TemporaryDirectory() as d:
        link = os.path.join(d, "link"); os.symlink("/tmp", link)
        check("symlink output rejected", fails(lambda: energy.validate_output(link)) is not None)

    print("case: local shell watchdog expiry and process-group disarm")
    with tempfile.TemporaryDirectory() as d:
        policy = os.path.join(d, "governor"); open(policy, "w").write("candidate")
        source = os.path.join(d, "source.scm"); open(source, "w").write("source")
        output = os.path.join(d, "out"); os.mkdir(output, 0o700)
        old_policy = energy.POLICY_GOVERNOR
        energy.POLICY_GOVERNOR = policy
        try:
            h = energy.ReaderEnergyHarness(LocalShellTransport(), FakeDriver(FakeTransport()), card(), source,
                output, ("conservative", "powersave"), 1, 0, 1800,
                # Real sleep: _arm_guard budgets 20 x 0.1s for the detached guard
                # to write its identity file.  A no-op sleep collapses that budget
                # to zero wall time and turns the handshake into a race.
                {"manifest_sha256": "m"}, clock_factory=recorder.FakeClock, sleep=time.sleep)
            h.restore_timeout_s = 1
            h.remote_dir = os.path.join(d, "remote-expiry"); os.mkdir(h.remote_dir, 0o700)
            h.remote_source = os.path.join(h.remote_dir, "source.scm")
            h.guard_script = os.path.join(h.remote_dir, "guard.sh")
            h.guard_identity = os.path.join(h.remote_dir, "identity")
            h.guard_log = os.path.join(h.remote_dir, "guard.log")
            h.original_governor = "original"; h._arm_guard(); subprocess.run(["sleep", "1.3"])
            expired = open(policy).read() == "original" and "RESTORE_OK" in open(h.guard_log).read()
            check("timeout watchdog restores and logs readback", expired)
            h.guard_armed = False
            open(policy, "w").write("candidate")
            h2 = energy.ReaderEnergyHarness(LocalShellTransport(), FakeDriver(FakeTransport()), card(), source,
                output, ("conservative", "powersave"), 1, 0, 1800,
                {"manifest_sha256": "m"}, clock_factory=recorder.FakeClock, sleep=time.sleep)
            h2.restore_timeout_s = 5
            h2.remote_dir = os.path.join(d, "remote-disarm"); os.mkdir(h2.remote_dir, 0o700)
            h2.remote_source = os.path.join(h2.remote_dir, "source.scm")
            h2.guard_script = os.path.join(h2.remote_dir, "guard.sh")
            h2.guard_identity = os.path.join(h2.remote_dir, "identity")
            h2.guard_log = os.path.join(h2.remote_dir, "guard.log")
            h2.original_governor = "original"; h2._arm_guard(); h2._disarm_guard(); subprocess.run(["sleep", "1.1"])
            check("disarm terminates watchdog group before timeout", open(policy).read() == "candidate")
        finally:
            energy.POLICY_GOVERNOR = old_policy

    print()
    if FAILS: print("reader-energy: FAILED " + ", ".join(FAILS)); return 1
    print("reader-energy: ok -- watchdog, boundary, provenance, and recovery are offline-proven")
    return 0


if __name__ == "__main__": raise SystemExit(main())
