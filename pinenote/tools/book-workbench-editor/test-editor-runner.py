#!/usr/bin/env python3
"""Child/socketpair proof; fake workspace receipts do not prove DB authority."""
import hashlib
import json
import os
from pathlib import Path
import signal
import socket
import struct
import subprocess
import tempfile
import time
import unittest

HERE = Path(__file__).resolve().parent
PROTOCOL = HERE.parent / "book-protocol"
RUNNER = HERE / "workbench-editor-runner.scm"
SEED = (HERE / "editor-seed.scm").read_text()
PROFILE = Path("/gnu/store/nlkcijvhrj9xfz4dz134iwlc9z52mb4s-wilkbook-book-state-device-supervisor")
GUILE = os.environ.get("GUILE", str(PROFILE / "bin/guile"))
ENV = {**os.environ, "GUILE_AUTO_COMPILE": "0", "BOOK_SESSION_FD": "3"}
if "GUILE" not in os.environ:
    ENV["GUILE_LOAD_PATH"] = str(PROFILE / "share/guile/site/3.0")
    ENV["GUILE_LOAD_COMPILED_PATH"] = str(PROFILE / "lib/guile/3.0/site-ccache")


def digest(source):
    return hashlib.sha256(source.encode()).hexdigest()


class Child:
    def __init__(self, source):
        self.directory = tempfile.TemporaryDirectory(prefix="editor-runner-", dir="/tmp/opencode")
        self.source = Path(self.directory.name) / "program.scm"
        self.source.write_bytes(source.encode() if isinstance(source, str) else source)
        self.socket, donated = socket.socketpair()
        self.socket.settimeout(5)
        self.log = tempfile.TemporaryFile()
        self.process = subprocess.Popen(
            [GUILE, "--no-auto-compile", "-L", str(PROTOCOL), str(RUNNER),
             "--trusted-native-fixture", str(self.source), GUILE, str(PROTOCOL)],
            stdin=donated, stdout=self.log, stderr=self.log,
            env=ENV)
        donated.close()
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            pid, status = os.waitpid(self.process.pid, os.WNOHANG | os.WUNTRACED)
            if pid:
                if not os.WIFSTOPPED(status):
                    self.process.returncode = os.waitstatus_to_exitcode(status)
                    diagnostic = self.diagnostic()
                    self.close()
                    raise AssertionError(diagnostic)
                os.killpg(pid, signal.SIGCONT)
                break
            time.sleep(.01)
        else:
            self.close()
            raise AssertionError("native child failed to stop")

    def diagnostic(self):
        self.log.seek(0)
        return self.log.read().decode(errors="replace")

    def send_raw(self, payload):
        self.socket.sendall(struct.pack("!I", len(payload)) + payload)

    def send(self, message):
        self.send_raw(json.dumps(message, ensure_ascii=False, separators=(",", ":")).encode())

    def exactly(self, count):
        data = b""
        while len(data) < count:
            chunk = self.socket.recv(count - len(data))
            if not chunk:
                raise EOFError(self.diagnostic())
            data += chunk
        return data

    def receive(self):
        length, = struct.unpack("!I", self.exactly(4))
        assert 0 < length <= 65536, length
        return json.loads(self.exactly(length))

    def initialize(self):
        assert self.receive() == {"type": "hello", "version": 1}
        self.send({"type": "initialize", "version": 1, "grant_count": 1,
                   "surface_handle": "ordinary", "surface_generation": 1,
                   "max_pending_requests": 4, "max_present_text_bytes": 4096})

    def rejected(self):
        # A bounded wait catches accidental acceptance/blocking after bad input.
        code = self.process.wait(timeout=5)
        assert code != 0, self.diagnostic()

    def close(self):
        self.socket.close()
        if self.process.poll() is None:
            os.killpg(self.process.pid, signal.SIGKILL)
        self.process.wait(timeout=5)
        self.log.close()
        self.directory.cleanup()


class FakeHost:
    """Validate authored wire requests; no filesystem/DB/install implementation."""
    def __init__(self, child, draft, access="author", reversed_ready=False):
        self.child, self.access = child, access
        self.source, self.version, self.activation = draft, 0, 0
        self.installed_source = SEED
        self.active, self.previous = digest(self.installed_source), False
        self.sequence, self.operation_sequence = 0, 0
        self.ops, self.last_text = [], ""
        self.artifacts, self.replies = {}, []
        self.diagnostic = "fixture refusal"
        child.initialize()
        ready = [dict(type="workspace-ready", protocol_version=1, grant_handle="opaque-workspace",
                      grant_generation=1, access=access, max_source_bytes=8192,
                      max_pending_operations=1),
                 dict(type="editor-ready", protocol_version=1, surface_handle="opaque-editor",
                      surface_generation=3, max_text_bytes=8192, max_actions=8)]
        for message in reversed(ready) if reversed_ready else ready:
            child.send(message)

    def snapshot(self):
        return dict(workspace_version=self.version, source=self.source, source_digest=digest(self.source),
                    active_revision=self.active, previous_revision=self.previous,
                    activation_generation=self.activation)

    def action(self, action, text=None, failure=None, outcome="installed"):
        self.sequence += 1
        request = dict(type="editor-action", protocol_version=1, request_id=100 + self.sequence,
                       action_id=action, surface_handle="opaque-editor", surface_generation=3,
                       sequence=self.sequence, text=self.last_text if text is None else text)
        self.child.send(request)
        message = self.child.receive()
        if message["type"].startswith("workspace-"):
            self.reply(message, failure, outcome)
            message = self.child.receive()
        assert message["type"] == "editor-present", message
        assert set(message) == set(request) | {"title", "status", "actions"}, message
        for key in ("protocol_version", "request_id", "action_id", "surface_handle",
                    "surface_generation", "sequence"):
            assert message[key] == request[key], (key, message)
        for key, limit in (("text", 8192), ("title", 128), ("status", 2048)):
            assert isinstance(message[key], str) and len(message[key].encode()) <= limit
        actions = message["actions"]
        assert isinstance(actions, list) and len(actions) <= 8
        assert len({a["id"] for a in actions}) == len(actions)
        for item in actions:
            assert set(item) == {"id", "label", "enabled"}
            assert item["id"].isascii() and item["id"] != "open"
            assert isinstance(item["enabled"], bool)
        self.last_text = message["text"]
        return message

    def reply(self, message, failure=None, outcome="installed"):
        self.operation_sequence += 1
        common = {"type", "protocol_version", "grant_handle", "grant_generation", "operation_sequence"}
        extras = {"workspace-read": set(), "workspace-save": {"expected_version", "source"},
                  "workspace-preview": {"expected_version"},
                  "workspace-install-propose": {"expected_version", "expected_activation"},
                  "workspace-export": set()}
        kind = message["type"]
        assert kind in extras, "source requested non-granted authority"
        assert set(message) == common | extras[kind], message
        assert message["protocol_version"] == message["grant_generation"] == 1
        assert message["grant_handle"] == "opaque-workspace"
        assert message["operation_sequence"] == self.operation_sequence
        if self.access == "preview":
            assert kind in ("workspace-read", "workspace-save")
        if "expected_version" in message:
            assert message["expected_version"] == self.version
        self.ops.append(message)
        result = dict(protocol_version=1, operation_sequence=self.operation_sequence)
        if failure:
            result.update(type="workspace-failed", operation=kind, code=failure, diagnostic=self.diagnostic)
        elif kind == "workspace-save":
            assert len(message["source"].encode()) <= 8192
            self.source, self.version = message["source"], self.version + 1
            result.update(type="workspace-saved", snapshot=self.snapshot())
        elif kind == "workspace-read":
            result.update(type="workspace-snapshot", snapshot=self.snapshot())
        elif kind == "workspace-install-propose":
            assert message["expected_activation"] == self.activation
            if outcome == "installed":
                self.previous, self.active = self.active, digest(self.source)
                self.installed_source = self.source
                self.activation += 1
            result.update(type="workspace-install-result", outcome=outcome, snapshot=self.snapshot())
        else:
            result.update(workspace_version=self.version, source_digest=digest(self.source),
                          activation_generation=self.activation)
            if kind == "workspace-preview":
                result.update(type="workspace-previewed", diagnostic="Preview child completed.")
            else:
                artifact = "fixture-artifact-" + self.active
                self.artifacts[artifact] = self.installed_source
                result.update(type="workspace-exported", exported_revision=self.active, artifact=artifact)
        self.replies.append(result)
        self.child.send(result)


class RunnerTests(unittest.TestCase):
    def child(self, source=SEED):
        child = Child(source)
        self.addCleanup(child.close)
        return child

    def test_successor_changed_behavior_authors_next_successor(self):
        self.assertLessEqual(len(SEED.encode()), 8192)
        host = FakeHost(self.child(), "unrelated draft")
        self.assertEqual(host.action("open")["text"], "unrelated draft")
        self.assertEqual(host.action("successor")["text"], SEED)
        r1 = SEED.replace('"Source Workbench"', '"Successor R1"').replace(
            '";;; Edited in Source Workbench\\n"', '";;; R1 custom header\\n"')
        host.action("save", r1)
        host.action("preview")
        host.action("install")
        self.assertEqual(host.source, r1)
        # A new process evaluates R1 bytes, with the identical fixed adapter.
        successor = FakeHost(self.child(host.source), "other current draft", reversed_ready=True)
        self.assertEqual(successor.action("open")["title"], "Successor R1")
        self.assertEqual(successor.action("successor")["text"], r1)
        r2 = successor.action("insert-header")["text"]
        self.assertEqual(r2, ";;; R1 custom header\n" + r1)
        successor.action("save")
        successor.action("preview")
        successor.action("install")
        self.assertEqual(successor.source, r2)
        self.assertEqual([x["type"] for x in successor.ops], ["workspace-read", "workspace-save",
                         "workspace-preview", "workspace-install-propose"])
        r2host = FakeHost(self.child(r2), r2)
        self.assertEqual(r2host.action("open")["title"], "Successor R1")
        self.assertEqual(r2host.action("successor")["text"], r2)

    def test_preview_access_and_unsaved_edits(self):
        host = FakeHost(self.child(), SEED, access="preview")
        form = host.action("open")
        for action in form["actions"]:
            if action["id"] in ("preview", "install", "export"):
                self.assertFalse(action["enabled"])
        for action in ("preview", "install", "export"):
            self.assertIn("only read and save", host.action(action)["status"])
        host.action("successor")
        host.action("save")
        self.assertEqual([x["type"] for x in host.ops], ["workspace-read", "workspace-save"])
        author = FakeHost(self.child(), SEED)
        author.action("open")
        for action in ("preview", "install"):
            self.assertIn("Save or read", author.action(action, "unsaved")["status"])
        self.assertEqual(len(author.ops), 1)
        self.assertIn("Installed revision", author.action("export", "unsaved")["status"])
        self.assertEqual(author.last_text, "unsaved")

    def test_failures_cancel_export_and_utf8_limit(self):
        host = FakeHost(self.child(), SEED)
        host.action("open")
        form = host.action("save", "draft", failure="stale-version")
        self.assertIn("stale-version", form["status"])
        self.assertEqual(host.source, SEED)
        host.action("read")
        for action in ("preview", "install", "export"):
            self.assertIn("fixture refusal", host.action(action, failure="operation-failed")["status"])
        host.diagnostic = "😀" * 512
        self.assertLessEqual(len(host.action("preview", failure="preview-failed")["status"].encode()), 2048)
        self.assertIn("cancelled", host.action("install", outcome="cancelled")["status"])
        self.assertEqual(host.activation, 0)
        host.action("save", "different saved draft")
        form = host.action("export")
        reply = host.replies[-1]
        self.assertEqual(reply["exported_revision"], digest(SEED))
        self.assertEqual(reply["source_digest"], digest("different saved draft"))
        self.assertNotEqual(reply["exported_revision"], reply["source_digest"])
        self.assertEqual(reply["workspace_version"], host.version)
        self.assertEqual(reply["activation_generation"], host.activation)
        self.assertEqual(host.artifacts[reply["artifact"]], SEED)
        self.assertIn(reply["exported_revision"], form["status"])
        self.assertEqual(next(a["label"] for a in form["actions"] if a["id"] == "export"),
                         "Export installed revision")
        self.assertEqual(host.last_text, "different saved draft")
        boundary = "é" * 4096
        host.action("save", boundary)
        self.assertEqual(host.action("insert-header")["text"], boundary)
        host.action("save", "")
        self.assertEqual(host.source, "")

    def test_snapshot_read_once_before_evaluation(self):
        child = self.child()
        self.assertEqual(child.receive()["type"], "hello")
        child.source.write_text('(error "reopened source")')
        child.send(dict(type="initialize", version=1, grant_count=1,
                        surface_handle="ordinary", surface_generation=1,
                        max_pending_requests=4, max_present_text_bytes=4096))
        child.send(dict(type="workspace-ready", protocol_version=1, grant_handle="g",
                        grant_generation=1, access="author", max_source_bytes=8192,
                        max_pending_operations=1))
        child.send(dict(type="editor-ready", protocol_version=1, surface_handle="s",
                        surface_generation=1, max_text_bytes=8192, max_actions=8))
        child.send(dict(type="editor-action", protocol_version=1, request_id=1, action_id="open",
                        surface_handle="s", surface_generation=1, sequence=1, text=""))
        self.assertEqual(child.receive()["type"], "workspace-read")

    def test_bad_source_boundaries_and_entry(self):
        for source in (b"", b";" * 8193, b"\xff", b";\x00", "(define (workbench text) text)"):
            with self.subTest(source=repr(source[:50])):
                child = self.child(source)
                if isinstance(source, str):
                    child.initialize()
                child.rejected()
        # Exact byte boundary remains executable; bytes, not character count.
        minimal = '(define (workbench-main receive! send! own-source) (send! `(("n" . ,(string-length own-source)))))\n;'
        child = self.child(minimal + "x" * (8192 - len(minimal)))
        child.initialize()
        self.assertEqual(child.receive(), {"n": 8192})
        self.assertEqual(child.process.wait(timeout=5), 0)

    def test_send_convenience_enforces_frame_budget(self):
        child = self.child('(define (workbench-main receive! send! own-source) '
                           '(send! `(("text" . ,(make-string 65537 #\\x)))))')
        child.initialize()
        child.rejected()
        self.assertIn("budget", child.diagnostic())

    def test_lexical_numbers_duplicate_keys_and_oversized_frames(self):
        for raw in (b'{"type":"initialize","version":1e0}',
                    b'{"type":"initialize","type":"initialize"}',
                    b'{"n":9007199254740992}'):
            with self.subTest(raw=raw):
                child = self.child()
                child.receive()
                child.send_raw(raw)
                child.rejected()
        child = self.child()
        child.receive()
        child.socket.sendall(struct.pack("!I", 65537))
        child.rejected()
        # Alias rejection also applies after the ordinary handshake.
        child = self.child()
        host = FakeHost(child, SEED)
        child.send_raw(b'{"type":"editor-action","protocol_version":1,"request_id":1,'
                       b'"action_id":"open","surface_handle":"opaque-editor",'
                       b'"surface_generation":3,"sequence":1.0,"text":""}')
        child.rejected()
        child = self.child()
        FakeHost(child, SEED)
        child.send(dict(type="editor-action", protocol_version=1, request_id=1, action_id="open",
                        surface_handle="opaque-editor", surface_generation=3, sequence=1, text=""))
        self.assertEqual(child.receive()["type"], "workspace-read")
        child.send_raw(b'{"type":"workspace-snapshot","protocol_version":1,"operation_sequence":1,'
                       b'"snapshot":{"workspace_version":0e0,"source":"draft"}}')
        child.rejected()

    def test_truncated_frame_and_clean_close(self):
        child = self.child()
        child.receive()
        child.socket.sendall(b"\x00\x00\x00\x10{}")
        child.socket.shutdown(socket.SHUT_WR)
        child.rejected()
        child = self.child()
        host = FakeHost(child, SEED)
        host.action("open")
        child.socket.shutdown(socket.SHUT_WR)
        self.assertEqual(child.process.wait(timeout=5), 0, child.diagnostic())


if __name__ == "__main__":
    unittest.main(verbosity=2)
