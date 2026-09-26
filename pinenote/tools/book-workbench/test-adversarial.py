#!/usr/bin/env python3
"""Independent UI-peer tests against the real Guile Workbench composition root.

Use the BOOK_WORKBENCH_GUILE and Guile module paths supplied by run-tests.sh.
Python never opens SQLite or implements an authority/preview substitute. Native
execution is limited to the harmless functions below, also used by the ordinary
integration fixture, with inert comment padding for serialization boundaries.
"""

import json
import os
from pathlib import Path
import re
import select
import shutil
import signal
import socket
import subprocess
import tempfile
import time
import unittest


TOOL = Path(__file__).resolve().parent
MAX_PAYLOAD = 65536
MAX_LINE = 2 * MAX_PAYLOAD + 32
IO_SECONDS = 10
EXIT_SECONDS = 5
SEED = '(define (workbench text) (string-append "seed: " text))\n'
SUCCESSOR = '(define (workbench text) (string-append "revised: " (string-upcase text)))\n'
SNAPSHOT_FIELDS = {
    "workspace_version", "source", "source_digest", "active_revision",
    "previous_revision", "activation_generation",
}
READ_FIELDS = {"ok", "op", "workspace_version", "source_digest", "activation_generation"}


def json_bytes(value, *, ascii_json=False):
    return json.dumps(value, ensure_ascii=ascii_json, allow_nan=False,
                      separators=(",", ":")).encode("utf-8")


def line(sequence, payload, kind=b"command"):
    return kind + b"|" + str(sequence).encode("ascii") + b"|" + payload.hex().encode("ascii") + b"\n"


def unique_object(pairs):
    value = {}
    for key, item in pairs:
        if key in value:
            raise AssertionError(f"duplicate authority reply key: {key!r}")
        value[key] = item
    return value


class NativePeer:
    """One pending request, bounded reads/writes, and a dedicated real endpoint.

    send()/receive() are separate so loss of an unread write acknowledgement can
    be tested without a fake transport or a storage fault-injection hook.
    """

    def __init__(self, root):
        self.sequence = 0
        self.pending = None
        self.received = 0
        self.closed = False
        self.last_request_bytes = 0
        self.last_reply_bytes = 0
        self.socket, remote = socket.socketpair()
        self.socket.settimeout(IO_SECONDS)
        self.log_path = root / f"authority-{time.monotonic_ns()}.log"
        self.log = self.log_path.open("wb")
        guile = os.environ["BOOK_WORKBENCH_GUILE"]
        try:
            self.process = subprocess.Popen(
                [guile, "--no-auto-compile", str(TOOL / "native-authority.scm"),
                 "--trusted-native-fixture", str(remote.fileno()),
                 str(root / "workspace"), str(root / "seed.scm"), guile,
                 str(TOOL / "workbench-runner.scm"), str(TOOL.parent / "book-protocol")],
                pass_fds=(remote.fileno(),), stdin=subprocess.DEVNULL,
                stdout=self.log, stderr=self.log, start_new_session=True,
            )
        except BaseException:
            self.socket.close()
            self.log.close()
            raise
        finally:
            remote.close()

    def send(self, op, *, ascii_json=False, **fields):
        if self.pending is not None:
            raise AssertionError("test peer already has a pending request")
        payload = json_bytes(dict(op=op, **fields), ascii_json=ascii_json)
        if not 0 < len(payload) <= MAX_PAYLOAD:
            raise AssertionError("test request exceeds the private JSON bound")
        self.sequence += 1
        self.pending = self.sequence
        self.last_request_bytes = len(payload)
        self.socket.settimeout(IO_SECONDS)
        self.socket.sendall(line(self.sequence, payload))

    def receive(self):
        if self.pending is None:
            raise AssertionError("test peer has no pending request")
        deadline = time.monotonic() + IO_SECONDS
        data = bytearray()
        while b"\n" not in data:
            remaining = deadline - time.monotonic()
            if remaining <= 0 or len(data) >= MAX_LINE:
                raise AssertionError(f"reply exceeded time/line bound; {self.log_path}")
            self.socket.settimeout(remaining)
            chunk = self.socket.recv(min(4096, MAX_LINE - len(data)))
            if not chunk:
                raise AssertionError(f"authority disconnected before reply; {self.log_path}")
            data.extend(chunk)
        record, _, extra = data.partition(b"\n")
        if extra:
            raise AssertionError("unsolicited second reply to one request")
        parts = record.split(b"|")
        if (len(parts) != 3 or parts[0] != b"reply"
                or parts[1] != str(self.pending).encode("ascii")):
            raise AssertionError(f"uncorrelated authority reply; {self.log_path}")
        payload = parts[2]
        if (len(payload) % 2 or not re.fullmatch(rb"[0-9a-f]+", payload)
                or len(payload) > 2 * MAX_PAYLOAD):
            raise AssertionError("invalid or oversized authority hex payload")
        decoded = bytes.fromhex(payload.decode("ascii"))
        self.last_reply_bytes = len(decoded)
        reply = json.loads(decoded.decode("utf-8"), object_pairs_hook=unique_object)
        if not isinstance(reply, dict):
            raise AssertionError("authority reply is not a JSON object")
        self.pending = None
        self.received += 1
        return reply

    def call(self, op, **fields):
        self.send(op, **fields)
        return self.receive()

    def wait_exit(self):
        try:
            return self.process.wait(timeout=EXIT_SECONDS)
        except subprocess.TimeoutExpired as exc:
            raise AssertionError(f"authority did not exit within {EXIT_SECONDS}s; {self.log_path}") from exc

    def assert_dead_without_reply(self):
        # Malformed framing is a connection failure, not a recoverable command
        # failure. A queued valid write after it must never be acknowledged.
        self.socket.settimeout(EXIT_SECONDS)
        try:
            data = self.socket.recv(1)
        except ConnectionResetError:
            data = b""
        if data:
            raise AssertionError(f"malformed input received a reply; {self.log_path}")
        self.wait_exit()

    def disconnect(self, *, clean=False):
        self.socket.close()
        status = self.wait_exit()
        if clean and status != 0:
            raise AssertionError(f"clean authority close exited {status}; {self.log_path}")

    def cleanup(self):
        if self.closed:
            return
        self.closed = True
        self.socket.close()
        try:
            self.wait_exit()
        finally:
            # A failed bound remains a test failure even though cleanup reaps
            # the owned process. Successful cases never need these signals.
            if self.process.poll() is None:
                try:
                    os.killpg(self.process.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                self.process.wait(timeout=EXIT_SECONDS)
            self.log.close()


def padded_source(pattern):
    """Exactly 8192 UTF-8 bytes; all added characters are inside a block comment."""
    prefix, suffix = SEED + "#|\n", "\n|#\n"
    budget = 8192 - len((prefix + suffix).encode("utf-8"))
    count, remainder = divmod(budget, len(pattern.encode("utf-8")))
    return prefix + pattern * count + "x" * remainder + suffix


class WorkbenchAdversarial(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if not os.environ.get("BOOK_WORKBENCH_GUILE"):
            raise RuntimeError("Integration tests pending: set BOOK_WORKBENCH_GUILE and "
                               "GUILE_LOAD_PATH using the real run-tests.sh dependencies")

    def setUp(self):
        self.root = Path(tempfile.mkdtemp(prefix="workbench-adversarial-", dir="/tmp/opencode"))
        (self.root / "workspace").mkdir(mode=0o700)
        (self.root / "seed.scm").write_text(SEED, encoding="utf-8")
        self.addCleanup(self.cleanup_root)

    def cleanup_root(self):
        # Keep real authority logs on test/subtest/cleanup failures. No artifacts
        # are put in the checkout, and ordinary successful runs remove theirs.
        result = self._outcome.result
        failures = result.failures + result.errors
        if any(case is self or getattr(case, "test_case", None) is self
               for case, _ in failures):
            print(f"Workbench adversarial artifacts: {self.root}", flush=True)
        else:
            shutil.rmtree(self.root)

    def peer(self):
        peer = NativePeer(self.root)
        self.addCleanup(peer.cleanup)
        return peer

    def snapshot(self, peer, op="open", **fields):
        reply = peer.call(op, **fields)
        self.assertIs(reply.get("ok"), True, reply)
        self.assertEqual(set(reply), {"ok", "op", "snapshot"})
        self.assertEqual(reply["op"], op)
        snap = reply["snapshot"]
        self.assertEqual(set(snap), SNAPSHOT_FIELDS)
        for key in ("workspace_version", "activation_generation"):
            self.assertIs(type(snap[key]), int)
            self.assertGreaterEqual(snap[key], 0)
        self.assertIsInstance(snap["source"], str)
        self.assertLessEqual(len(snap["source"].encode("utf-8")), 8192)
        for key in ("source_digest", "active_revision"):
            self.assertRegex(snap[key], r"^[0-9a-f]{64}$")
        return snap

    def read_result(self, peer, op, snap, **fields):
        reply = peer.call(op, **fields)
        self.assertIs(reply.get("ok"), True, reply)
        extra = {"artifact"} if op == "export" else {"text", "diagnostic"}
        self.assertEqual(set(reply), READ_FIELDS | extra)
        self.assertEqual(reply["op"], op)
        for key in ("workspace_version", "source_digest", "activation_generation"):
            self.assertEqual(reply[key], snap[key])
        return reply

    def failure(self, peer, op, code, **fields):
        reply = peer.call(op, **fields)
        self.assertIs(reply.get("ok"), False, reply)
        self.assertEqual(reply.get("error"), code, reply)
        self.assertNotIn("snapshot", reply)
        return reply

    def save(self, peer, snap, source, **options):
        after = self.snapshot(peer, "save", expected_version=snap["workspace_version"],
                              source=source, **options)
        self.assertEqual(after["workspace_version"], snap["workspace_version"] + 1)
        self.assertEqual(after["source"], source)
        for key in ("activation_generation", "active_revision", "previous_revision"):
            self.assertEqual(after[key], snap[key])
        return after

    def preview(self, peer, snap, text="alpha", expected="revised: ALPHA"):
        reply = self.read_result(peer, "preview", snap,
                                 expected_version=snap["workspace_version"], text=text)
        self.assertEqual(reply["text"], expected)
        return reply

    def activate(self, peer, snap):
        after = self.snapshot(peer, "activate", expected_version=snap["workspace_version"],
                              expected_activation=snap["activation_generation"])
        self.assertEqual(after["activation_generation"], snap["activation_generation"] + 1)
        self.assertEqual(after["active_revision"], snap["source_digest"])
        for key in ("workspace_version", "source", "source_digest"):
            self.assertEqual(after[key], snap[key])
        return after

    def unpreviewed(self, peer, snap):
        self.failure(peer, "activate", "preview-required-for-this-draft",
                     expected_version=snap["workspace_version"],
                     expected_activation=snap["activation_generation"])
        self.assertEqual(self.snapshot(peer), snap)

    def test_two_endpoints_reject_stale_source_and_foreign_preview(self):
        first = self.peer()
        initial = self.snapshot(first)
        second = self.peer()
        self.assertEqual(self.snapshot(second), initial)
        self.unpreviewed(first, initial)
        current = self.save(first, initial, SUCCESSOR)

        # Save's CAS is a backend error; preview/activate check their version in
        # the authority and have the more specific documented refusal code.
        self.failure(second, "save", "workspace-operation-failed",
                     expected_version=initial["workspace_version"], source=SEED)
        self.failure(second, "preview", "workspace-conflict",
                     expected_version=initial["workspace_version"], text="alpha")
        self.failure(second, "activate", "workspace-conflict",
                     expected_version=initial["workspace_version"],
                     expected_activation=initial["activation_generation"])
        self.assertEqual(self.snapshot(first), current)
        self.preview(first, current)
        # Knowing all of the successful preview's public metadata grants the
        # second endpoint nothing, even though it uses the very same store.
        self.unpreviewed(second, current)
        installed = self.activate(first, current)
        self.assertEqual(self.snapshot(second), installed)
        self.assertEqual(installed["previous_revision"], initial["active_revision"])
        self.unpreviewed(first, installed)  # Successful activation consumes it.

    def test_identical_save_and_run_cannot_reuse_preview(self):
        peer = self.peer()
        initial = self.snapshot(peer)
        current = self.save(peer, initial, SUCCESSOR)
        self.preview(peer, current)
        same_bytes = self.save(peer, current, SUCCESSOR)
        self.assertEqual(same_bytes["source_digest"], current["source_digest"])
        self.unpreviewed(peer, same_bytes)
        self.assertEqual(self.read_result(peer, "run", same_bytes, text="alpha")["text"],
                         "seed: alpha")
        self.unpreviewed(peer, same_bytes)  # Run installed is not draft preview.
        self.preview(peer, same_bytes)
        installed = self.activate(peer, same_bytes)
        self.assertEqual(self.snapshot(peer, "close"), installed)
        peer.disconnect(clean=True)

    def test_source_aba_preserves_digest_but_invalidates_preview_version(self):
        first = self.peer()
        original = self.save(first, self.snapshot(first), SUCCESSOR)
        self.preview(first, original)
        second = self.peer()
        middle = self.save(second, self.snapshot(second), SEED)
        restored = self.save(second, middle, SUCCESSOR)
        self.assertEqual(restored["source_digest"], original["source_digest"])
        self.assertEqual(restored["activation_generation"], original["activation_generation"])
        self.assertEqual(restored["workspace_version"], original["workspace_version"] + 2)
        self.failure(first, "activate", "workspace-conflict",
                     expected_version=original["workspace_version"],
                     expected_activation=original["activation_generation"])
        self.unpreviewed(first, restored)

    def test_activation_aba_requires_new_preview_and_fresh_epoch(self):
        first = self.peer()
        initial = self.snapshot(first)
        original = self.save(first, initial, SUCCESSOR)
        self.preview(first, original)
        second = self.peer()
        self.assertEqual(self.snapshot(second), original)
        self.preview(second, original)
        installed = self.activate(second, original)
        restored = self.snapshot(second, "rollback",
                                 expected_activation=installed["activation_generation"])
        self.assertEqual(restored["active_revision"], original["active_revision"])
        self.assertEqual(restored["previous_revision"], installed["active_revision"])
        self.assertEqual(restored["activation_generation"], original["activation_generation"] + 2)
        for key in ("workspace_version", "source", "source_digest"):
            self.assertEqual(restored[key], original[key])

        # Only the epoch changed in the preview identity: neither content nor
        # workspace-version comparisons can detect this R1 -> R2 -> R1 cycle.
        self.failure(first, "activate", "preview-required-for-this-draft",
                     expected_version=original["workspace_version"],
                     expected_activation=original["activation_generation"])
        self.unpreviewed(first, restored)  # Refreshing request metadata is insufficient.
        self.failure(second, "rollback", "workspace-operation-failed",
                     expected_activation=original["activation_generation"])
        self.assertEqual(self.snapshot(second), restored)

        self.preview(first, restored)
        self.failure(first, "activate", "activation-conflict",
                     expected_version=restored["workspace_version"],
                     expected_activation=original["activation_generation"])
        self.assertEqual(self.snapshot(first), restored)
        self.preview(first, restored)
        self.activate(first, restored)

    def test_disconnect_discards_an_existing_preview_authorization(self):
        peer = self.peer()
        current = self.save(peer, self.snapshot(peer), SUCCESSOR)
        self.preview(peer, current)
        peer.disconnect(clean=True)
        fresh = self.peer()
        self.assertEqual(self.snapshot(fresh), current)
        self.unpreviewed(fresh, current)
        self.preview(fresh, current)
        self.activate(fresh, current)

    def test_lost_save_reply_recovers_one_durable_write_without_retry_privilege(self):
        writer = self.peer()
        initial = self.snapshot(writer)
        observer = self.peer()
        self.assertEqual(self.snapshot(observer), initial)
        received_before = writer.received
        writer.send("save", expected_version=initial["workspace_version"], source=SUCCESSOR)

        # Observe the actual commit through another authority. The writer's
        # response stays unread; readiness alone neither parses nor consumes it.
        deadline = time.monotonic() + IO_SECONDS
        while True:
            durable = self.snapshot(observer)
            if durable["workspace_version"] != initial["workspace_version"]:
                break
            self.assertLess(time.monotonic(), deadline, "save never became visible")
            time.sleep(0.01)
        self.assertEqual(durable["workspace_version"], initial["workspace_version"] + 1)
        self.assertEqual(durable["source"], SUCCESSOR)
        self.assertEqual(durable["active_revision"], initial["active_revision"])
        self.assertEqual(durable["activation_generation"], initial["activation_generation"])
        self.assertTrue(select.select([writer.socket], [], [], IO_SECONDS)[0],
                        "committed writer never made its reply available")
        self.assertEqual(writer.received, received_before)
        self.assertIsNotNone(writer.pending)
        writer.disconnect()
        self.assertEqual(self.snapshot(observer, "close"), durable)
        observer.disconnect(clean=True)

        fresh = self.peer()
        self.assertEqual(self.snapshot(fresh), durable)
        self.unpreviewed(fresh, durable)
        # An explicitly adversarial stale resend is not an automatic UI retry:
        # there is no cross-connection receipt privilege in the source store.
        self.failure(fresh, "save", "workspace-operation-failed",
                     expected_version=initial["workspace_version"], source=SUCCESSOR)
        self.assertEqual(self.snapshot(fresh), durable)
        self.assertEqual(self.read_result(fresh, "run", durable, text="still installed")["text"],
                         "seed: still installed")
        self.assertEqual(self.snapshot(fresh), durable)

    def test_schema_refusals_are_exact_recoverable_and_nonmutating(self):
        peer = self.peer()
        initial = self.snapshot(peer)
        version = initial["workspace_version"]
        cases = [
            ("missing-source", "save", {"expected_version": version}, "invalid-request-fields"),
            ("unknown-path", "save", {"expected_version": version, "source": SUCCESSOR,
                                     "path": "/tmp/opencode/not-a-ui-selected-path"}, "invalid-request-fields"),
            ("unknown-op", "seal", {}, "invalid-request-fields"),
            ("boolean-version", "save", {"expected_version": False, "source": SUCCESSOR}, "invalid-version"),
            ("negative-version", "save", {"expected_version": -1, "source": SUCCESSOR}, "invalid-version"),
            ("string-version", "save", {"expected_version": str(version), "source": SUCCESSOR}, "invalid-version"),
            ("oversized-version", "save", {"expected_version": 2147483648, "source": SUCCESSOR}, "invalid-version"),
            ("boolean-epoch", "rollback", {"expected_activation": True}, "invalid-version"),
            ("nul-source", "save", {"expected_version": version, "source": SEED + "\0"}, "invalid-source"),
            ("utf8-source-limit", "save", {"expected_version": version, "source": "\u0100" * 4097}, "invalid-source"),
            ("null-source", "save", {"expected_version": version, "source": None}, "invalid-source"),
            ("nul-input", "run", {"text": "a\0b"}, "invalid-input-text"),
            ("utf8-input-limit", "run", {"text": "\U0001f642" * 513}, "invalid-input-text"),
        ]
        for name, op, fields, code in cases:
            with self.subTest(name=name):
                self.failure(peer, op, code, **fields)
                self.assertEqual(self.snapshot(peer), initial)
        current = self.save(peer, initial, SUCCESSOR)
        self.unpreviewed(peer, current)

    def test_malformed_json_and_line_sequence_kill_only_that_connection(self):
        observer = self.peer()
        initial = self.snapshot(observer)
        save = json_bytes({"op": "save", "expected_version": initial["workspace_version"],
                           "source": SUCCESSOR})
        # All candidates arrive after a successful open (sequence 1). A valid
        # save follows each bad record to detect accidental stream resync.
        duplicate = save[:-1] + b',"source":' + json_bytes(SEED) + b"}"
        escaped_duplicate = save[:-1] + b',"so\\u0075rce":' + json_bytes(SEED) + b"}"
        cases = [
            ("missing-comma", line(2, save.replace(b',"expected_version"', b' "expected_version"')), False),
            ("duplicate-key", line(2, duplicate), False),
            ("escaped-duplicate-key", line(2, escaped_duplicate), False),
            ("nested-duplicate-key", line(2, b'{"op":"save","expected_version":0,"source":{"x":1,"x":2}}'), False),
            ("truncated-json", line(2, save[:-1]), False),
            ("non-object", line(2, b"[]"), False),
            ("invalid-utf8", line(2, b'{"op":"save","expected_version":0,"source":"\xff"}'), False),
            ("lone-surrogate", line(2, b'{"op":"save","expected_version":0,"source":"\\ud800"}'), False),
            ("duplicate-sequence", line(1, save), False),
            ("skipped-sequence", line(3, save), False),
            ("zero-sequence", line(0, save), False),
            ("leading-zero-sequence", line("02", save), False),
            ("out-of-range-sequence", line(2147483648, save), False),
            ("wrong-kind", line(2, save, kind=b"reply"), False),
            ("uppercase-hex", b"command|2|" + save.hex().upper().encode("ascii") + b"\n", False),
            ("odd-hex", b"command|2|7\n", False),
            ("oversized-json", line(2, save + b" " * (MAX_PAYLOAD + 1 - len(save))), False),
            ("oversized-line", b"x" * (MAX_LINE + 1) + b"\n", False),
            ("eof-mid-line", line(2, save)[:-1], True),
        ]
        for name, bad, half_close in cases:
            with self.subTest(name=name):
                peer = self.peer()
                self.assertEqual(self.snapshot(peer), initial)
                wire = bad if half_close else bad + line(2, save)
                try:
                    peer.socket.sendall(wire)
                    if half_close:
                        peer.socket.shutdown(socket.SHUT_WR)
                except (BrokenPipeError, ConnectionResetError):
                    pass  # Early rejection of an oversized line is permitted.
                peer.assert_dead_without_reply()
                peer.disconnect()
                self.assertEqual(self.snapshot(observer), initial)
        self.assertEqual(self.snapshot(observer, "close"), initial)
        observer.disconnect(clean=True)
        self.assertEqual(self.snapshot(self.peer()), initial)

    def test_unread_installation_and_rollback_replies_recover_exact_transition(self):
        publisher = self.peer()
        seed = self.snapshot(publisher)
        draft = self.save(publisher, seed, SUCCESSOR)
        self.preview(publisher, draft)
        publisher.send("activate", expected_version=draft["workspace_version"],
                       expected_activation=draft["activation_generation"])
        self.assertTrue(select.select([publisher.socket], [], [], IO_SECONDS)[0])
        received = publisher.received
        recovered = self.peer()
        active = self.snapshot(recovered)
        self.assertEqual(publisher.received, received)  # No receipt was consumed.
        publisher.disconnect()
        self.assertEqual(active, dict(
            draft, active_revision=draft["source_digest"],
            previous_revision=seed["active_revision"],
            activation_generation=draft["activation_generation"] + 1,
        ))

        recovered.send("rollback", expected_activation=active["activation_generation"])
        self.assertTrue(select.select([recovered.socket], [], [], IO_SECONDS)[0])
        received = recovered.received
        fresh = self.peer()
        rolled = self.snapshot(fresh)
        self.assertEqual(recovered.received, received)
        recovered.disconnect()
        self.assertEqual(rolled, dict(
            active, active_revision=seed["active_revision"],
            previous_revision=active["active_revision"],
            activation_generation=active["activation_generation"] + 1,
        ))
        self.failure(fresh, "rollback", "workspace-operation-failed",
                     expected_activation=active["activation_generation"])
        self.preview(fresh, rolled)
        self.failure(fresh, "activate", "activation-conflict",
                     expected_version=rolled["workspace_version"],
                     expected_activation=draft["activation_generation"])
        self.assertEqual(self.snapshot(fresh), rolled)

    def test_maximum_source_roundtrips_snapshot_and_nested_export_under_codec_bound(self):
        # U+0001 costs six JSON bytes and seven when the exported JSON string is
        # itself encoded as a reply. Supplementary Unicode also exercises the
        # Guile codec's surrogate-pair spelling. Only comments vary in execution.
        patterns = [("worst-c0-escaping", "\x01"),
                    ("unicode-and-escapes", '\u0100\u6e90\U0001f642"\\\t\r\n\x01')]
        last_snapshot = None
        last_artifact = None
        for name, pattern in patterns:
            with self.subTest(name=name):
                peer = self.peer()
                before = self.snapshot(peer)
                if last_snapshot is not None:
                    self.assertEqual(before, last_snapshot)
                source = padded_source(pattern)
                self.assertEqual(len(source.encode("utf-8")), 8192)
                current = self.save(peer, before, source, ascii_json=True)
                self.assertLessEqual(peer.last_request_bytes, MAX_PAYLOAD)
                self.assertLessEqual(peer.last_reply_bytes, MAX_PAYLOAD)
                if name == "worst-c0-escaping":
                    self.assertGreater(peer.last_request_bytes, 48000)
                    self.assertGreater(peer.last_reply_bytes, 48000)
                self.assertEqual(self.snapshot(peer), current)
                text = '\u0100\U0001f642"\\'
                self.preview(peer, current, text=text, expected="seed: " + text)
                installed = self.activate(peer, current)
                exported = self.read_result(peer, "export", installed)["artifact"]
                self.assertLessEqual(peer.last_reply_bytes, MAX_PAYLOAD)
                if name == "worst-c0-escaping":
                    self.assertGreater(peer.last_reply_bytes, 55000)
                self.assertTrue(exported.endswith("\n"))
                artifact = json.loads(exported, object_pairs_hook=unique_object)
                self.assertEqual(set(artifact), {"format", "source-format", "environment", "revision", "source"})
                self.assertEqual(artifact["format"], "wilkbook-workbench-export-v1")
                self.assertEqual(artifact["source-format"], "guile-source-v1")
                self.assertEqual(
                    artifact["environment"],
                    Path(os.environ["BOOK_WORKBENCH_GUILE"]).parent.parent.resolve().name,
                )
                self.assertEqual(artifact["revision"], installed["active_revision"])
                self.assertEqual(artifact["source"].encode("utf-8"), source.encode("utf-8"))
                self.assertEqual(self.read_result(peer, "export", installed)["artifact"], exported)
                self.assertEqual(self.read_result(peer, "run", installed, text=text)["text"], "seed: " + text)
                self.assertEqual(self.snapshot(peer, "close"), installed)
                peer.disconnect(clean=True)
                last_snapshot, last_artifact = installed, exported
        fresh = self.peer()
        self.assertEqual(self.snapshot(fresh), last_snapshot)
        self.assertEqual(self.read_result(fresh, "export", last_snapshot)["artifact"], last_artifact)


if __name__ == "__main__":
    unittest.main()
