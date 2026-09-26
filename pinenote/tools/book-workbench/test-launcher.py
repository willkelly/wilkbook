#!/usr/bin/env python3
"""Native launcher lifetime regressions, using the real authority and FD channel.

run-tests.sh supplies cached BOOK_WORKBENCH_GUILE and KOREADER_NATIVE_BUNDLE.
SQLite is opened here only to hold a real contention lock. All source operations
go through the authority. The committed native program writes one readiness/PID
marker in this test's private directory, then loops; it never forks. Linux
pidfds and a test-local subreaper let failing tests kill/reap that exact runner
even if a broken authority or launcher has orphaned it.
"""

import ctypes
from contextlib import closing
import importlib.util
import json
import os
from pathlib import Path
import select
import shutil
import signal
import socket
import sqlite3
import subprocess
import sys
import tempfile
import threading
import time
import unittest

TOOL = Path(__file__).resolve().parent
MAX_LINE = 2 * 65536 + 32
LOOP_SOURCE = """(define (workbench marker)
  (call-with-output-file marker
    (lambda (port) (display (getpid) port) (newline port)))
  (let loop () (loop)))
"""
spec = importlib.util.spec_from_file_location("native_demo", TOOL / "native-demo.py")
launcher = importlib.util.module_from_spec(spec)
spec.loader.exec_module(launcher)


def wait_until(predicate, seconds, message):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        value = predicate()
        if value:
            return value
        time.sleep(0.01)
    raise AssertionError(message)


def process_info(pid):
    try:
        fields = Path(f"/proc/{pid}/stat").read_text().rsplit(")", 1)[1].split()
        return dict(state=fields[0], parent=int(fields[1]), group=int(fields[2]),
                    start=int(fields[19]))
    except FileNotFoundError:
        return None


def children(pid):
    # Guile has GC/helper threads; use every task's children list, not a scan or
    # process-name match against unrelated workstation processes.
    result = set()
    for task in Path(f"/proc/{pid}/task").glob("*/children"):
        try:
            result.update(map(int, task.read_text().split()))
        except FileNotFoundError:
            pass
    return result


class Identity:
    def __init__(self, pid):
        before = process_info(pid)
        self.fd = os.pidfd_open(pid)
        after = process_info(pid)
        if not before or not after or before["start"] != after["start"]:
            os.close(self.fd)
            raise AssertionError("process identity changed while capturing its pidfd")
        self.pid, self.start, self.info = pid, after["start"], after
        self.scratch = None

    def capture_scratch(self):
        path = Path(f"/proc/{self.pid}/cwd").readlink()
        if path.parent == Path("/tmp/opencode") and path.name.startswith("workbench-preview."):
            info = path.lstat()
            if info.st_uid != os.getuid() or info.st_mode & 0o7777 != 0o700:
                raise AssertionError("preview scratch root is not private")
            self.scratch = (path, info.st_dev, info.st_ino)

    def exists(self):
        info = process_info(self.pid)
        return info is not None and info["start"] == self.start

    def cleanup(self):
        try:
            # pidfd signaling remains identity-safe after reparenting or PID
            # reuse. The committed loop has no descendants of its own to kill.
            try:
                signal.pidfd_send_signal(self.fd, signal.SIGKILL)
            except ProcessLookupError:
                pass
            if not select.select([self.fd], [], [], 2)[0]:
                raise AssertionError(f"owned process {self.pid} survived SIGKILL")
            info = process_info(self.pid)
            if info and info["start"] == self.start and info["parent"] == os.getpid():
                # An adopted, unreaped child keeps this numeric PID reserved.
                # Never wait on a reused PID merely because its old pidfd exited.
                waited, _ = os.waitpid(self.pid, os.WNOHANG)
                if waited != self.pid:
                    raise AssertionError("exited adopted child was not reapable")
        finally:
            os.close(self.fd)
        # Retain the enclosing test/log directory on failure, but remove only
        # the exact private preview scratch root observed from this owned PID.
        if self.scratch:
            path, device, inode = self.scratch
            try:
                info = path.lstat()
            except FileNotFoundError:
                return
            if (info.st_dev, info.st_ino) == (device, inode):
                shutil.rmtree(path)


def reap_direct(process):
    """Independent failure cleanup; its direct PID is unreaped until wait()."""
    if process.returncode is None:
        try:
            os.killpg(process.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        try:
            process.wait(timeout=3)
        except subprocess.TimeoutExpired:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            process.wait(timeout=2)


def cleanup_identities(identities):
    failure = None
    for identity in identities:
        try:
            identity.cleanup()
        except BaseException as error:
            failure = error
    if failure:
        raise failure


class Peer:
    def __init__(self, root, guile):
        self.root, self.sequence = root, 0
        self.previews = []
        (root / "workspace").mkdir(mode=0o700, exist_ok=True)
        self.socket, remote = socket.socketpair()
        self.socket.settimeout(10)
        self.log_path = root / f"authority-{time.monotonic_ns()}.log"
        self.log = self.log_path.open("wb")
        try:
            self.process = subprocess.Popen(
                [str(guile), "--no-auto-compile", str(TOOL / "native-authority.scm"),
                 "--trusted-native-fixture", str(remote.fileno()),
                 str(root / "workspace"), str(TOOL / "seed.scm"), str(guile),
                 str(TOOL / "workbench-runner.scm"), str(TOOL.parent / "book-protocol")],
                env=launcher.environment(root, guile.parent.parent), cwd=root,
                pass_fds=(remote.fileno(),), stdin=subprocess.DEVNULL,
                stdout=self.log, stderr=self.log, start_new_session=True)
        except BaseException:
            self.socket.close()
            self.log.close()
            raise
        finally:
            remote.close()

    def send(self, op, **fields):
        self.sequence += 1
        payload = json.dumps(dict(op=op, **fields), ensure_ascii=False).encode()
        self.socket.sendall(f"command|{self.sequence}|".encode() + payload.hex().encode() + b"\n")

    def receive(self):
        data = bytearray()
        while b"\n" not in data:
            chunk = self.socket.recv(4096)
            if not chunk:
                raise AssertionError(f"authority disconnected: {self.log_path.read_text()}")
            data.extend(chunk)
            if len(data) > MAX_LINE:
                raise AssertionError("authority reply exceeded its line bound")
        record, _, extra = data.partition(b"\n")
        kind, sequence, payload = record.split(b"|")
        if extra or kind != b"reply" or int(sequence) != self.sequence:
            raise AssertionError("uncorrelated authority reply")
        reply = json.loads(bytes.fromhex(payload.decode()))
        if not reply.get("ok"):
            raise AssertionError(reply)
        return reply

    def call(self, op, **fields):
        self.send(op, **fields)
        return self.receive()

    def prepare_loop(self):
        snapshot = self.call("open")["snapshot"]
        saved = self.call("save", expected_version=snapshot["workspace_version"], source=LOOP_SOURCE)
        return saved["snapshot"]["workspace_version"]

    def preview(self, version):
        self.send("preview", expected_version=version, text=str(self.root / "loop-ready"))

    def capture_preview(self, seconds=2):
        def ready():
            try:
                value = (self.root / "loop-ready").read_text().strip()
                return int(value) if value else None
            except FileNotFoundError:
                return None

        pid = wait_until(ready, seconds, f"native loop did not start: {self.log_path}")
        identity = Identity(pid)
        self.previews.append(identity)
        if identity.info["parent"] != self.process.pid or identity.info["group"] != pid:
            raise AssertionError("loop is not the authority's separately grouped native child")
        identity.capture_scratch()
        return identity

    def cleanup(self):
        self.socket.close()
        # Capture a child that failed before the readiness marker, too. Capture
        # before signaling the authority, while its parent identity proves ours.
        known = {identity.pid for identity in self.previews}
        for pid in children(self.process.pid) if self.process.returncode is None else ():
            if pid not in known:
                try:
                    identity = Identity(pid)
                    self.previews.append(identity)
                    identity.capture_scratch()
                except (ProcessLookupError, FileNotFoundError):
                    pass
        try:
            reap_direct(self.process)
        finally:
            try:
                cleanup_identities(self.previews)
            finally:
                self.log.close()


class LauncherLifetimes(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.guile = Path(os.environ["BOOK_WORKBENCH_GUILE"])
        cls.supervisor = cls.guile.parent.parent
        cls.bundle = Path(os.environ["KOREADER_NATIVE_BUNDLE"])
        libc = ctypes.CDLL(None, use_errno=True)
        old = ctypes.c_int()
        if libc.prctl(37, ctypes.byref(old), 0, 0, 0) or libc.prctl(36, 1, 0, 0, 0):
            raise OSError(ctypes.get_errno(), "test subreaper setup failed")
        cls.addClassCleanup(lambda: libc.prctl(36, old.value, 0, 0, 0))

    def setUp(self):
        self.root = Path(tempfile.mkdtemp(
            prefix="workbench-launcher-test-",
            dir=os.environ.get("BOOK_WORKBENCH_TEST_ROOT", "/tmp/opencode")))
        self.addCleanup(self.cleanup_root)

    def cleanup_root(self):
        failures = self._outcome.result.failures + self._outcome.result.errors
        if any(case is self or getattr(case, "test_case", None) is self for case, _ in failures):
            print(f"Workbench launcher artifacts: {self.root}", file=sys.stderr)
        else:
            shutil.rmtree(self.root)

    def peer(self, name="peer"):
        root = self.root / name
        root.mkdir(mode=0o700)
        peer = Peer(root, self.guile)
        self.addCleanup(peer.cleanup)
        return peer

    def test_stop_while_idle_or_reading_a_partial_line(self):
        for signum in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
            with self.subTest(signal=signum):
                peer = self.peer(f"idle-{signum}")
                peer.call("open")  # handler and store are ready, then idle read
                if signum == signal.SIGINT:
                    peer.socket.sendall(b"command|2|")
                os.kill(peer.process.pid, signum)
                self.assertEqual(peer.process.wait(timeout=2), 0)
                self.assertEqual(peer.socket.recv(1), b"")

    def test_stop_during_active_preview_suppresses_reply_and_reaps_runner(self):
        peer = self.peer()
        peer.preview(peer.prepare_loop())
        identity = peer.capture_preview()
        for signum in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP, signal.SIGTERM):
            os.kill(peer.process.pid, signum)
        self.assertEqual(peer.process.wait(timeout=2), 0)
        self.assertFalse(identity.exists(), "authority exited without reaping the native loop")
        # The inner preview catch translates cancellation to failure. That must
        # not become a reply followed by another blocking idle read.
        self.assertEqual(peer.socket.recv(1), b"")

    def test_sqlite_delayed_preview_then_ui_eof_during_launcher_shutdown(self):
        peer = self.peer()
        version = peer.prepare_loop()
        lock = sqlite3.connect(peer.root / "workspace/book-workspace-v1.sqlite",
                               isolation_level=None, check_same_thread=False, timeout=0)
        self.addCleanup(lock.close)
        lock.execute("BEGIN EXCLUSIVE")
        # An already exited UI identity exercises the launcher's real 4s EOF
        # grace without involving KOReader input automation in a timing test.
        reader = subprocess.Popen([sys.executable, "-I", "-S", "-c", "pass"],
                                  start_new_session=True)
        self.addCleanup(reap_direct, reader)
        observed, errors = [], []

        def release_and_observe():
            try:
                time.sleep(3)
                lock.rollback()
                observed.append(peer.capture_preview())
            except BaseException as error:
                errors.append(error)
            finally:
                lock.close()

        peer.preview(version)
        peer.socket.close()
        worker = threading.Thread(target=release_and_observe)
        worker.start()
        started = time.monotonic()
        try:
            launcher.stop_children([peer.process, reader], reader)
        finally:
            worker.join(timeout=6)
        self.assertFalse(worker.is_alive(), "contention/observation worker exceeded its bound")
        if errors:
            raise errors[0]
        self.assertLess(time.monotonic() - started, 7)
        self.assertEqual(len(observed), 1, "test never reached the delayed native loop")
        self.assertFalse(observed[0].exists(), "launcher orphaned the delayed preview process")
        self.assertEqual(peer.process.returncode, 0, "authority did not cooperatively unwind")

    def test_stop_handler_is_installed_before_sqlite_store_open(self):
        initial = self.peer()
        initial.call("open")
        initial.socket.close()
        self.assertEqual(initial.process.wait(timeout=2), 0)
        database = initial.root / "workspace/book-workspace-v1.sqlite"
        with closing(sqlite3.connect(database, isolation_level=None, timeout=0)) as lock:
            lock.execute("BEGIN EXCLUSIVE")
            blocked = Peer(initial.root, self.guile)
            self.addCleanup(blocked.cleanup)

            def opened_database():
                for path in Path(f"/proc/{blocked.process.pid}/fd").glob("*"):
                    try:
                        if path.readlink() == database:
                            return True
                    except FileNotFoundError:
                        pass
                return False

            wait_until(opened_database, 2, "authority never reached its blocked store open")
            os.kill(blocked.process.pid, signal.SIGTERM)
            time.sleep(0.2)
            os.kill(blocked.process.pid, signal.SIGTERM)
            lock.rollback()
        self.assertEqual(blocked.process.wait(timeout=2), 0)
        self.assertEqual(blocked.socket.recv(1), b"")
        reopened = Peer(initial.root, self.guile)
        self.addCleanup(reopened.cleanup)
        self.assertEqual(reopened.call("open")["snapshot"]["workspace_version"], 0)

    def test_real_sdl_renderer_failure_exits_with_original_diagnostic(self):
        # The upstream reader continues into its event loop with a NULL
        # renderer. Reproduce that failure headlessly with real SDL: a working
        # offscreen window is insufficient evidence of a working renderer.
        reader_dir = self.bundle / "lib/koreader"
        env = launcher.environment(self.root, self.supervisor)
        env.update(SDL_VIDEODRIVER="offscreen", SDL_AUDIODRIVER="dummy",
                   SDL_RENDER_DRIVER="workbench-nonexistent-renderer")
        result = subprocess.run(
            [str(reader_dir / "luajit"), str(TOOL / "desktop-reader.lua")],
            env=env, cwd=reader_dir, stdin=subprocess.DEVNULL,
            capture_output=True, timeout=10)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(b"Book Workbench desktop startup: SDL_CreateRenderer:", result.stderr)
        self.assertIn(b"workbench-nonexistent-renderer not available", result.stderr)
        self.assertNotIn(b"Parameter 'renderer' is invalid", result.stderr)

    def reader_probe(self, code, **extra_env):
        reader_dir = self.bundle / "lib/koreader"
        env = launcher.environment(self.root, self.supervisor)
        env.update(SDL_VIDEODRIVER="offscreen", SDL_AUDIODRIVER="dummy", **extra_env)
        result = subprocess.run(
            [str(reader_dir / "luajit"), "-e", code], env=env, cwd=reader_dir,
            stdin=subprocess.DEVNULL, capture_output=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_unavailable_sdl_loader_preserves_device_detection(self):
        self.reader_probe("""
local util = { loadSDL3 = function() return nil end }
package.preload["setupkoenv"] = function() return true end
package.preload["ffi/util"] = function() return util end
local enter = dofile
dofile = function(name)
    assert(name == "reader.lua")
    assert(util.loadSDL3() == nil, "missing SDL became a truthy proxy")
end
enter(""" + json.dumps(str(TOOL / "desktop-reader.lua")) + ")")

    @unittest.skipUnless(os.environ.get("BOOK_WORKBENCH_GRAPHICS"),
                         "set BOOK_WORKBENCH_GRAPHICS for the optional Mesa renderer check")
    def test_explicit_mesa_gles_renderer_headlessly(self):
        # Offscreen's default software renderer misses the visible desktop's
        # EGL/GLES dependency chain. Select the actual desktop libraries here,
        # while requiring no compositor and displaying no window.
        graphics = Path(os.environ["BOOK_WORKBENCH_GRAPHICS"])
        self.reader_probe("""
local enter = dofile
dofile = function(name)
    assert(name == "reader.lua")
    local display = require("ffi/SDL3")
    display.open(600, 800)
    assert(display.screen ~= nil and display.renderer ~= nil and display.texture ~= nil)
    display.SDL.SDL_DestroyTexture(display.texture)
    display.SDL.SDL_DestroyRenderer(display.renderer)
    display.SDL.SDL_Quit()
end
enter(""" + json.dumps(str(TOOL / "desktop-reader.lua")) + ")",
                          SDL_EGL_LIBRARY=str(graphics / "lib/libEGL.so.1"),
                          SDL_OPENGL_LIBRARY=str(graphics / "lib/libGLESv2.so.2"),
                          SDL_RENDER_DRIVER="opengles2")

    def test_real_launcher_profile_cleanup_and_artifact_only_export(self):
        log_path = self.root / "launcher.log"
        env = dict(os.environ, BOOK_WORKBENCH_SUPERVISOR=str(self.supervisor),
                   KOREADER_NATIVE_BUNDLE=str(self.bundle), SDL_VIDEODRIVER="offscreen",
                   GUILE_LOAD_PATH="/invalid/injected", LUA_PATH="/invalid/injected",
                   PYTHONPATH="/invalid/injected")
        with log_path.open("wb") as log:
            process = subprocess.Popen(
                [sys.executable, "-I", "-S", str(TOOL / "native-demo.py"), str(self.root)],
                env=env, stdout=subprocess.PIPE, stderr=log, start_new_session=True)
            self.addCleanup(process.stdout.close)
            self.addCleanup(reap_direct, process)
            identities = []
            try:
                wait_until(lambda: "opening file" in log_path.read_text(), 15,
                           f"KOReader did not open the inert document: {log_path}")
                for pid in children(process.pid):
                    identities.append(Identity(pid))
                self.assertEqual(len(identities), 2)
                profiles = set()
                for identity in identities:
                    child_env = Path(f"/proc/{identity.pid}/environ").read_bytes()
                    self.assertNotIn(b"/invalid/injected", child_env)
                    values = dict(item.split(b"=", 1) for item in child_env.split(b"\0") if item)
                    profiles.add(Path(os.fsdecode(values[b"KO_HOME"])).parent)
                os.kill(process.pid, signal.SIGTERM)
                output, _ = process.communicate(timeout=10)
                self.assertEqual(process.returncode, 143)
                self.assertEqual(output, b"")
                self.assertTrue(all(not identity.exists() for identity in identities))
                self.assertEqual(len(profiles), 1)
                self.assertTrue(all(not profile.exists() for profile in profiles))
            finally:
                if not identities and process.returncode is None:
                    for pid in children(process.pid):
                        try:
                            identities.append(Identity(pid))
                        except ProcessLookupError:
                            pass
                reap_direct(process)
                cleanup_identities(identities)
        result = subprocess.run(
            [sys.executable, "-I", "-S", str(TOOL / "native-demo.py"), "--export", str(self.root)],
            env=dict(env, KOREADER_NATIVE_BUNDLE="/unavailable/reader"),
            capture_output=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        artifact = json.loads(result.stdout)
        self.assertEqual(artifact["source"], (TOOL / "seed.scm").read_text())
        self.assertEqual(artifact["environment"], self.supervisor.resolve().name)
        self.assertEqual(result.stdout.count(b"\n"), 1)


if __name__ == "__main__":
    unittest.main()
