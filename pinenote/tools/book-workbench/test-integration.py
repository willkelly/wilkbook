#!/usr/bin/env python3
"""Fresh-process Workbench proof. Python is a test peer, not the authority.

Executes only the committed test source snippets via the explicitly named
trusted-native runner. This is source/transaction/UI-channel evidence, not
gVisor or device isolation evidence.
"""

from contextlib import contextmanager
import json
import os
from pathlib import Path
import signal
import shutil
import socket
import subprocess
import tempfile
import time
import unittest

TOOL = Path(__file__).resolve().parent
GUILE = os.environ["BOOK_WORKBENCH_GUILE"]
MAX_LINE = 2 * 65536 + 32
SEED_SOURCE = '(define (workbench text) (string-append "seed: " text))\n'
SUCCESSOR = '(define (workbench text) (string-append "revised: " (string-upcase text)))\n'


@contextmanager
def private_run():
    root = Path(tempfile.mkdtemp(prefix="workbench-join-", dir="/tmp/opencode"))
    try:
        yield root
    except BaseException:
        print(f"Workbench integration artifacts: {root}", flush=True)
        raise
    else:
        shutil.rmtree(root)


class Peer:
    def __init__(self, root):
        self.root = Path(root)
        (self.root / "workspace").mkdir(mode=0o700, exist_ok=True)
        self.seq = 0
        self.socket, remote = socket.socketpair()
        self.socket.settimeout(10)
        self.log = open(self.root / f"authority-{time.monotonic_ns()}.log", "wb")
        self.process = subprocess.Popen(
            [GUILE, "--no-auto-compile", str(TOOL / "native-authority.scm"),
             "--trusted-native-fixture", str(remote.fileno()),
             str(self.root / "workspace"), str(self.root / "seed.scm"),
             GUILE, str(TOOL / "workbench-runner.scm"),
             str(TOOL.parent / "book-protocol")],
            pass_fds=(remote.fileno(),), stdin=subprocess.DEVNULL,
            stdout=self.log, stderr=self.log, start_new_session=True,
        )
        remote.close()
        self.pending = bytearray()

    def call(self, op, **fields):
        self.seq += 1
        data = json.dumps(dict(op=op, **fields), ensure_ascii=False).encode()
        self.socket.sendall(f"command|{self.seq}|".encode() + data.hex().encode() + b"\n")
        while b"\n" not in self.pending:
            chunk = self.socket.recv(4096)
            if not chunk:
                raise AssertionError("authority disconnected before reply")
            self.pending.extend(chunk)
            if len(self.pending) > MAX_LINE:
                raise AssertionError("authority exceeded private-channel bound")
        line, _, extra = self.pending.partition(b"\n")
        self.pending = bytearray(extra)
        kind, seq, payload = line.split(b"|")
        assert kind == b"reply" and int(seq) == self.seq
        return json.loads(bytes.fromhex(payload.decode()))

    def close(self, abrupt=False):
        try:
            if not abrupt and self.process.poll() is None:
                assert self.call("close")["ok"]
        finally:
            self.socket.close()
            try:
                self.process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                os.killpg(self.process.pid, signal.SIGTERM)
                try:
                    self.process.wait(timeout=2)
                except subprocess.TimeoutExpired:
                    os.killpg(self.process.pid, signal.SIGKILL)
                    self.process.wait(timeout=2)
                raise AssertionError("native authority failed to exit after UI disconnect")
            finally:
                self.log.close()
        assert self.process.returncode == 0


class WorkbenchIntegration(unittest.TestCase):
    def test_edit_preview_activate_restart_and_rollback(self):
        with private_run() as root:
            (root / "seed.scm").write_text(SEED_SOURCE)
            peer = Peer(root)
            try:
                snap = peer.call("open")["snapshot"]
                seed = snap["active_revision"]
                self.assertEqual(peer.call("run", text="alpha")["text"], "seed: alpha")
                snap = peer.call("save", expected_version=snap["workspace_version"],
                                 source=SUCCESSOR)["snapshot"]
                self.assertEqual(peer.call("run", text="alpha")["text"], "seed: alpha")
                preview = peer.call("preview", expected_version=snap["workspace_version"], text="alpha")
                self.assertTrue(preview["ok"], preview)
                self.assertEqual(preview["text"], "revised: ALPHA")
                snap = peer.call("activate", expected_version=snap["workspace_version"],
                                 expected_activation=snap["activation_generation"])["snapshot"]
                successor = snap["active_revision"]
                self.assertNotEqual(seed, successor)
                self.assertEqual(peer.call("run", text="beta")["text"], "revised: BETA")
                export = peer.call("export")["artifact"]
                self.assertIn("revised:", export)
            finally:
                peer.close(abrupt=True)

            # A new authority, SQLite connection, endpoint and interpreter recover
            # active source, independently of the previous process's memory.
            peer = Peer(root)
            try:
                snap = peer.call("open")["snapshot"]
                self.assertEqual(snap["active_revision"], successor)
                self.assertEqual(snap["source"], SUCCESSOR)
                self.assertEqual(peer.call("run", text="gamma")["text"], "revised: GAMMA")
                for broken in ["(define (workbench text)",
                               '(define (workbench text) (error "broken"))',
                               '(define (workbench text) (let loop () (loop)))']:
                    snap = peer.call("save", expected_version=snap["workspace_version"],
                                     source=broken)["snapshot"]
                    failed = peer.call("preview", expected_version=snap["workspace_version"], text="test")
                    self.assertFalse(failed["ok"])
                    self.assertFalse(peer.call("activate", expected_version=snap["workspace_version"],
                                               expected_activation=snap["activation_generation"])["ok"])
                    current = peer.call("open")["snapshot"]
                    self.assertEqual(current["source"], broken)
                    self.assertEqual(current["active_revision"], successor)
                snap = peer.call("rollback", expected_activation=snap["activation_generation"])["snapshot"]
                self.assertEqual(snap["active_revision"], seed)
                self.assertEqual(snap["source"], broken)
                self.assertEqual(peer.call("run", text="delta")["text"], "seed: delta")
            finally:
                peer.close()


if __name__ == "__main__":
    unittest.main()
