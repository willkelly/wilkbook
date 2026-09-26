#!/usr/bin/env python3
"""Controlled native lifecycle seam: no runsc or authored workloads execute."""
import json
import os
from pathlib import Path
import select
import signal
import socket
import subprocess
import sys
import tempfile
import time
import unittest

HERE = Path(__file__).resolve().parent
GUILE = os.environ.get("BOOK_WORKBENCH_GUILE", "/gnu/store/nlkcijvhrj9xfz4dz134iwlc9z52mb4s-wilkbook-book-state-device-supervisor/bin/guile")
PROFILE = Path(GUILE).parent.parent
ENV = dict(os.environ, GUILE_AUTO_COMPILE="0",
           GUILE_LOAD_PATH=":".join(str(p) for p in [HERE, HERE.parent / "book-protocol", HERE.parent / "book-session",
                                                    HERE.parent / "book-execution-spike", HERE.parent / "book-state-guest",
                                                    PROFILE / "share/guile/site/3.0"]),
           GUILE_LOAD_COMPILED_PATH=str(PROFILE / "lib/guile/3.0/site-ccache"))

# A fixed test executable, never authored source. kill writes a cooperative stop
# file; the attached run performs its modeled Destroy. No numeric PID signalling.
FAKE = '''import os, subprocess, sys, time
from pathlib import Path
bundle = Path(sys.argv[1]); command = sys.argv[2]; mode = sys.argv[-1] if command == "run" else sys.argv[-2]
if command == "run":
    (bundle / "started").write_text(str(os.getpid()))
    (bundle / "runsc-state" / "fake-container").write_text("owned")
    if mode == "descendant":
        child = subprocess.Popen([sys.executable, "-c", "import os,time; os.setsid(); time.sleep(.8)"])
        (bundle / "descendant").write_text(str(child.pid))
    if mode == "overflow": os.write(2, b"x" * 300000)
    if mode == "runtime-death": sys.exit(7)
    if mode.startswith("exit-race-"):
        while not (bundle / "exit-now").exists(): time.sleep(.01)
        (bundle / "runsc-state" / "fake-container").unlink()
        sys.exit(int(mode.rsplit("-", 1)[1]))
    while not (bundle / "fake-stop").exists(): time.sleep(.01)
    if mode in ("late-overflow", "late-overflow-out"):
        os.write(1 if mode == "late-overflow-out" else 2, b"x" * 300000)
    if mode != "stale": (bundle / "runsc-state" / "fake-container").unlink()
    if mode == "normal-stop137": sys.exit(137)
elif command == "kill":
    if mode == "force": sys.exit(19)
    (bundle / "fake-stop").write_text("stop")
else: sys.exit(90)
'''

ENTRY = r'''
(primitive-load (search-path %load-path "guest-book-protocol.scm"))
(use-modules (workbench-editor-sandbox) (workbench-sandbox) (workbench-preview) (rnrs io ports))
(define args (cdr (command-line)))
(define root (list-ref args 0))
(define bundle (string-append root "/bundle"))
(define mode (list-ref args 2))
(define editor (resolve-module '(workbench-editor-sandbox)))
(define sandbox (resolve-module '(workbench-sandbox)))
(define old-base (module-ref editor 'base))
(define old-smoke (module-ref editor 'smoke))
(define old-control-reader (module-ref editor 'control-reader))
;; Deterministically order a stop request before the outer loop's next reap,
;; while allowing the helper to observe the fake runtime exit and publish proof.
;; This explicit test seam never changes production control parsing or verdicts.
(when (member mode '("exit-race-0" "exit-race-7" "exit-race-137"))
  (module-set! editor 'control-reader
    (lambda (port)
      (let ((reader (old-control-reader port)))
        (lambda ()
          (let ((stop? (reader)))
            (when stop?
              (call-with-output-file (string-append bundle "/exit-now")
                (lambda (port) (display "exit" port)))
              (let ((end (+ ((module-ref sandbox 'now)) 3)))
                (let wait-proof ()
                  (unless (file-exists? (string-append bundle "/owner-result.scm"))
                    (when (>= ((module-ref sandbox 'now)) end) (error "test helper proof deadline"))
                    (usleep 1000) (wait-proof)))))
            stop?))))))
;; Explicit private seam: only unavailable mount/cgroup boundaries replaced.
;; Real helper, FD adapter, spawn, pidfds, stop, proof and tree cleanup execute.
(module-set! editor 'base
 (lambda (name) (if (eq? name 'prepare-owned-runtime-state!)
                   (lambda _ (string-append bundle "/runsc-state")) (old-base name))))
(module-set! editor 'smoke
 (lambda (name) (if (eq? name 'diagnostic-stores) (lambda _ '()) (old-smoke name))))
(module-set! sandbox 'cleanup-runtime!
 (lambda _ (when (file-exists? (string-append bundle "/runsc-state/fake-container"))
             (error "fake runtime failed Destroy"))))
(define observations 0)
(module-set! sandbox 'observe-cgroup
 (lambda _
   (and (file-exists? (string-append bundle "/started"))
        (not (equal? mode "no-controls"))
        (begin
          (set! observations (+ observations 1))
          (call-with-output-file (string-append bundle "/observations")
            (lambda (port) (display observations port)))
          `((controls-match? . ,(not (or (equal? mode "bad-controls")
                                        (and (equal? mode "staged-controls") (= observations 1))
                                        (file-exists? (string-append bundle "/invalidate")))))
            (members . ,(if (and (equal? mode "staged-controls") (= observations 2))
                            '() '(((pid . 1)))))
            (synthetic-test-only . #t))))))
(define control ((module-ref editor 'control-port) (string->number (cadr args))))
(define result
 ((module-ref editor 'execute-session!) root bundle "controlled-editor-seam"
  (list (list-ref args 3) (list-ref args 4) bundle "run" mode)
  (let ((profile (dirname (dirname (list-ref args 5)))))
    (list "GUILE_AUTO_COMPILE=0" "LANG=C.UTF-8" "PATH=/usr/bin:/bin"
          (string-append "GUILE_LOAD_PATH=" profile "/share/guile/site/3.0")
          (string-append "GUILE_LOAD_COMPILED_PATH=" profile "/lib/guile/3.0/site-ccache")))
  (list-ref args 5) (list-ref args 6) (list-ref args 7)
  control (+ ((module-ref sandbox 'now))
             (if (member mode '("no-controls" "delayed-helper")) .3 5))))
(write result) (newline)
(close-port control)
'''

# Fixed trusted adapter seam. Its marker proves it is still before the adapter's
# SIGSTOP/exec gate. No authored code is loaded, and only tests select this file.
DELAY_ADAPTER = r'''
(use-modules (rnrs io ports))
(define bundle (caddr (command-line)))
(call-with-output-file (string-append bundle "/adapter-waiting")
  (lambda (port) (display (getpid) port)))
(let loop ()
  (unless (file-exists? (string-append bundle "/release-adapter"))
    (usleep 10000) (loop)))
(primitive-load REAL_ADAPTER)
(runsc-fd3-exec-main (cdr (command-line)))
'''

DELAY_HELPER = r'''
;; Model interpreter/module startup after spawn, before owner-main begins.
(call-with-output-file (string-append (cadr (member "--directory" (command-line))) "/helper-waiting")
  (lambda (port) (display (getpid) port)))
(usleep 500000)
(primitive-load REAL_HELPER)
'''


class EditorOwner(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="editor-owner-test.", dir="/tmp/opencode")
        self.base = Path(self.temp.name)
        self.fake = self.base / "fake.py"
        self.fake.write_text(FAKE)
        self.entry = self.base / "entry.scm"
        self.entry.write_text(ENTRY)
        self.adapter = self.base / "delaying-adapter.scm"
        self.adapter.write_text(DELAY_ADAPTER.replace(
            "REAL_ADAPTER", json.dumps(str(HERE.parent / "book-state-guest/runsc-fd3-exec.scm"))))
        self.helper = self.base / "delaying-helper.scm"
        self.helper.write_text(DELAY_HELPER.replace(
            "REAL_HELPER", json.dumps(str(HERE / "workbench-runtime-owner.scm"))))
        self.failed_adapter = self.base / "failed-adapter.scm"
        self.failed_adapter.write_text("(primitive-exit 7)\n")
        self.processes = []
        self.sockets = []

    def tearDown(self):
        for process in self.processes:
            if process.poll() is None:
                process.kill()
                process.wait()
            if process.stdout:
                process.stdout.close()
            if process.stderr:
                process.stderr.close()
        for sock in self.sockets:
            sock.close()
        self.temp.cleanup()

    def launch(self, mode="normal", delay_adapter=False):
        root = self.base / ("root-" + mode)
        bundle = root / "bundle"
        bundle.mkdir(parents=True, mode=0o700)
        (bundle / "runsc-state").mkdir(mode=0o700)
        control, donated = socket.socketpair()
        book, guest = socket.socketpair()
        self.sockets += [control, book]
        process = subprocess.Popen(
            [GUILE, "--no-auto-compile", str(self.entry), str(root), str(donated.fileno()), mode,
             sys.executable, str(self.fake), GUILE,
             str(self.failed_adapter if mode == "adapter-failure" else
                 self.adapter if delay_adapter else HERE.parent / "book-state-guest/runsc-fd3-exec.scm"),
             str(self.helper if mode == "delayed-helper" else HERE / "workbench-runtime-owner.scm")],
            stdin=guest, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            pass_fds=(donated.fileno(),), env=ENV)
        self.processes.append(process)
        donated.close()
        guest.close()
        return process, control, root

    def line(self, control, timeout=12):
        end = time.monotonic() + timeout
        result = b""
        while not result.endswith(b"\n"):
            self.assertGreater(end - time.monotonic(), 0, repr(result))
            self.assertTrue(select.select([control], [], [], max(0, end - time.monotonic()))[0], repr(result))
            part = control.recv(1)
            if not part:
                break
            result += part
        return result

    def finish(self, process, root, clean=True):
        out, err = process.communicate(timeout=12)
        self.assertEqual(process.returncode, 0, err.decode())
        self.assertIn(b"(cleanup-complete? . " + (b"#t" if clean else b"#f") + b")", out, (out, err))
        self.assertEqual(root.exists(), not clean, (out, err))
        return out

    def wait_file(self, path, timeout=3):
        end = time.monotonic() + timeout
        while time.monotonic() < end and not path.exists():
            time.sleep(.01)
        self.assertTrue(path.exists(), str(path))
        return path.read_text()

    def test_stop_fragment_idle_and_proof(self):
        process, control, root = self.launch()
        self.assertEqual(self.line(control), b"ready\n")
        control.sendall(b"sto")
        time.sleep(.4)
        self.assertIsNone(process.poll())
        self.assertFalse(select.select([control], [], [], 0)[0])
        control.sendall(b"p\n")
        self.assertEqual(self.line(control), b"clean\n")
        out = self.finish(process, root)
        self.assertIn(b"(children-empty? . #t)", out)
        self.assertIn(b"(forced? . #f)", out)

    def test_control_eof(self):
        process, control, root = self.launch()
        self.assertEqual(self.line(control), b"ready\n")
        control.shutdown(socket.SHUT_WR)
        self.assertEqual(self.line(control), b"clean\n")
        self.finish(process, root)

    def test_known_helper_failure_survives_outer_stop_race(self):
        for mode in ("exit-race-0", "exit-race-7", "exit-race-137"):
            with self.subTest(mode=mode):
                process, control, root = self.launch(mode)
                self.assertEqual(self.line(control), b"ready\n")
                control.sendall(b"stop\n")
                self.assertEqual(self.line(control), b"clean\n")
                out = self.finish(process, root)
                self.assertIn(b"(status . failed)", out)
                self.assertIn(b"(execution-failed? . #t)", out)
                self.assertIn(b"runtime-owner-execution-failed", out)

    def test_expected_137_during_requested_cleanup_is_not_execution_failure(self):
        process, control, root = self.launch("normal-stop137")
        self.assertEqual(self.line(control), b"ready\n")
        control.sendall(b"stop\n")
        self.assertEqual(self.line(control), b"clean\n")
        out = self.finish(process, root)
        self.assertIn(b"(status . ok)", out)
        self.assertIn(b"(execution-failed? . #f)", out)
        self.assertIn(b"(runtime-status . 35072)", out)  # host wait status for exit 137

    def test_adapter_failure_has_failed_verdict_and_valid_preexec_cleanup(self):
        process, control, root = self.launch("adapter-failure")
        self.assertEqual(self.line(control), b"clean\n")
        out = self.finish(process, root)
        self.assertIn(b"(status . failed)", out)
        self.assertIn(b"(execution-failed? . #t)", out)
        self.assertIn(b"(runtime-started? . #f)", out)
        self.assertIn(b"(children-reaped . 1)", out)
        self.assertIn(b"(controls)", out)

    def test_cancel_before_adapter_handshake_never_starts_runtime(self):
        process, control, root = self.launch(delay_adapter=True)
        adapter_pid = int(self.wait_file(root / "bundle/adapter-waiting"))
        self.assertFalse((root / "bundle/started").exists())
        start = time.monotonic()
        control.sendall(b"stop\n")
        self.assertEqual(self.line(control, timeout=3), b"clean\n")
        out = self.finish(process, root)
        self.assertLess(time.monotonic() - start, 3)
        self.assertIn(b"(status . ok)", out)
        self.assertIn(b"(runtime-started? . #f)", out)
        self.assertIn(b"(controls)", out)
        self.assertIn(b"(children-reaped . 1)", out)
        self.assertFalse(Path(f"/proc/{adapter_pid}").exists())

    def test_delayed_helper_observes_preexisting_stop_before_spawn(self):
        process, control, root = self.launch("delayed-helper")
        self.assertEqual(self.line(control, timeout=3), b"clean\n")
        out = self.finish(process, root)
        self.assertIn(b"(status . failed)", out)  # original startup budget expired
        self.assertIn(b"(runtime-started? . #f)", out)
        self.assertIn(b"(children-reaped . 0)", out)
        self.assertIn(b"(controls)", out)

    def test_parent_loss_before_adapter_handshake(self):
        process, control, root = self.launch(delay_adapter=True)
        adapter_pid = int(self.wait_file(root / "bundle/adapter-waiting"))
        start = time.monotonic()
        process.kill()
        process.wait()
        proof = self.wait_file(root / "bundle/owner-result.scm")
        self.assertLess(time.monotonic() - start, 3)
        self.assertIn("(runtime-started? . #f)", proof)
        self.assertIn("(children-reaped . 1)", proof)
        self.assertIn("(controls)", proof)
        self.assertIn("(forced? . #f)", proof)
        self.assertFalse((root / "bundle/started").exists())
        self.assertFalse(Path(f"/proc/{adapter_pid}").exists())

    def test_parent_loss_before_helper_initializes(self):
        process, control, root = self.launch("delayed-helper")
        self.wait_file(root / "bundle/helper-waiting")
        start = time.monotonic()
        process.kill()
        process.wait()
        proof = self.wait_file(root / "bundle/owner-result.scm")
        self.assertLess(time.monotonic() - start, 3)
        self.assertIn("(runtime-started? . #f)", proof)
        self.assertIn("(children-reaped . 0)", proof)
        self.assertIn("(controls)", proof)
        self.assertFalse((root / "bundle/started").exists())

    def test_helper_uses_original_absolute_startup_deadline(self):
        # Exercise the helper without an outer owner's stop-file timer. The
        # supplied deadline alone must stop a delayed adapter, without 20s reset.
        root = self.base / "direct-deadline"
        root.mkdir(mode=0o700)
        (root / "runsc-state").mkdir(mode=0o700)
        book, guest = socket.socketpair()
        self.sockets.append(book)
        stat = Path("/proc/self/stat").read_text().rsplit(") ", 1)[1].split()
        token = f"{os.getpid()}:{stat[19]}"
        end = time.monotonic() + .5
        child_env = dict(ENV, GUILE_LOAD_PATH=str(PROFILE / "share/guile/site/3.0"))
        process = subprocess.Popen(
            [GUILE, "--no-auto-compile", str(HERE / "workbench-runtime-owner.scm"),
             "--guile", GUILE, "--adapter", str(self.adapter), "--session", token,
             "--startup-deadline", str(end), "--directory", str(root), "--",
             sys.executable, str(self.fake), str(root), "run", "normal"],
            stdin=guest, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=child_env)
        guest.close()
        self.processes.append(process)
        adapter_pid = int(self.wait_file(root / "adapter-waiting"))
        out, err = process.communicate(timeout=3)
        self.assertEqual(process.returncode, 1, (out, err))
        self.assertLess(time.monotonic() - end, 1)
        proof = (root / "owner-result.scm").read_text()
        self.assertIn("(runtime-started? . #f)", proof)
        self.assertIn("(controls)", proof)
        self.assertFalse((root / "started").exists())
        self.assertFalse((root / "owner-stop").exists())
        self.assertFalse(Path(f"/proc/{adapter_pid}").exists())

    def test_late_capture_overflow_fails_but_cleanup_is_complete(self):
        for mode in ("late-overflow", "late-overflow-out"):
            with self.subTest(mode=mode):
                process, control, root = self.launch(mode)
                self.assertEqual(self.line(control), b"ready\n")
                control.sendall(b"stop\n")
                self.assertEqual(self.line(control), b"clean\n")
                out = self.finish(process, root)
                self.assertIn(b"(status . failed)", out)
                self.assertIn(b"exceeded 256 KiB", out)
                self.assertIn(b"(children-empty? . #t)", out)

    def test_startup_waits_for_configured_populated_group(self):
        process, control, root = self.launch("staged-controls")
        self.assertEqual(self.line(control), b"ready\n")
        self.assertGreaterEqual(int((root / "bundle/observations").read_text()), 3)
        control.sendall(b"stop\n")
        self.assertEqual(self.line(control), b"clean\n")
        self.finish(process, root)

    def test_detached_descendant_reaped(self):
        process, control, root = self.launch("descendant")
        self.assertEqual(self.line(control), b"ready\n")
        descendant = int((root / "bundle/descendant").read_text())
        control.sendall(b"stop\n")
        self.assertEqual(self.line(control), b"clean\n")
        self.finish(process, root)
        self.assertFalse(Path(f"/proc/{descendant}").exists())

    def test_malformed_control_is_bounded_and_cleans(self):
        process, control, root = self.launch()
        self.assertEqual(self.line(control), b"ready\n")
        control.sendall(b"x" * 4096)
        self.assertEqual(self.line(control), b"clean\n")
        self.finish(process, root)

    def test_refusals_cleanup_without_ready(self):
        for mode in ("no-controls", "bad-controls"):
            with self.subTest(mode=mode):
                process, control, root = self.launch(mode)
                self.assertEqual(self.line(control), b"clean\n")
                self.finish(process, root)

    def test_resource_change_after_ready(self):
        process, control, root = self.launch()
        self.assertEqual(self.line(control), b"ready\n")
        (root / "bundle/invalidate").touch()
        self.assertEqual(self.line(control), b"clean\n")
        self.finish(process, root)

    def test_overflow_and_runtime_death(self):
        for mode in ("overflow", "runtime-death"):
            with self.subTest(mode=mode):
                process, control, root = self.launch(mode)
                receipt = self.line(control)
                if receipt == b"ready\n":
                    receipt = self.line(control)
                # Deliberately early runtime death leaves its modeled state,
                # exactly as an unproven real Destroy must retain the root.
                self.assertEqual(receipt, b"" if mode == "runtime-death" else b"clean\n")
                self.finish(process, root, clean=mode != "runtime-death")

    def test_cleanup_failure_withholds_receipt(self):
        for mode in ("stale", "force"):
            with self.subTest(mode=mode):
                process, control, root = self.launch(mode)
                self.assertEqual(self.line(control), b"ready\n")
                control.sendall(b"stop\n")
                self.assertEqual(self.line(control), b"")
                self.finish(process, root, clean=False)

    def test_outer_owner_crash_helper_stops_runtime(self):
        process, control, root = self.launch()
        self.assertEqual(self.line(control), b"ready\n")
        runtime_pid = int((root / "bundle/started").read_text())
        process.kill()
        process.wait()
        end = time.monotonic() + 10
        while time.monotonic() < end and not (root / "bundle/owner-result.scm").exists():
            time.sleep(.05)
        self.assertTrue((root / "bundle/owner-result.scm").exists())
        self.assertFalse((root / "bundle/runsc-state/fake-container").exists())
        self.assertFalse(Path(f"/proc/{runtime_pid}").exists())
        self.assertTrue(root.exists(), "dead outer owner cannot claim tree cleanup")


if __name__ == "__main__":
    unittest.main()
