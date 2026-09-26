#!/usr/bin/env python3
"""Real runner + typed delegates + SQLite. No fake workspace backend."""
import hashlib
import importlib.util
import os
from pathlib import Path
import tempfile
import time
import unittest
import socket
import json
import contextlib
import sqlite3
import threading
from unittest import mock

TOOL = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("native_editor", TOOL / "native-editor.py")
native = importlib.util.module_from_spec(spec)
spec.loader.exec_module(native)
SUPERVISOR = Path(os.environ.get("BOOK_WORKBENCH_SUPERVISOR", native.DEFAULT_SUPERVISOR))


class Integration(unittest.TestCase):
    def setUp(self):
        native.subreaper()
        self.temporary = tempfile.TemporaryDirectory(prefix="editor-integration-", dir="/tmp/opencode")
        self.root = Path(self.temporary.name)
        self.workspace = self.root / "workspace"
        self.workspace.mkdir(mode=0o700)
        self.session = None
        self.seed = (TOOL / "editor-seed.scm").read_text()

    def tearDown(self):
        if self.session:
            self.session.close()
        self.temporary.cleanup()
        self.assertEqual(native.LIVE, set(), "all owned direct children reaped")

    def start(self, **kwargs):
        kwargs.setdefault("preview_mode", "smoke")
        self.session = native.EditorSession(self.workspace, self.root, SUPERVISOR, **kwargs)
        self.until(lambda: self.session.form is not None)
        return self.session

    def until(self, predicate, timeout=12):
        deadline = time.monotonic() + timeout
        while not predicate():
            self.session.pump()
            if self.session.failure:
                self.fail(self.session.failure)
            if time.monotonic() >= deadline:
                self.fail("editor integration observation deadline")
            time.sleep(0.005)

    def action(self, action_id, text=None):
        old = self.session.form["sequence"]
        self.session.action(action_id, text)
        self.until(lambda: self.session.form["sequence"] != old)
        return self.session.form

    def snapshot(self):
        self.session.command("host-snapshot")
        return self.session.snapshot.copy()

    def propose(self):
        self.session.action("install")
        self.until(lambda: self.session.proposal is not None)
        return self.session.proposal["proposal_id"]

    def confirm(self):
        old = self.session.form["sequence"]
        self.session.confirm()
        self.until(lambda: self.session.form["sequence"] != old)
        return self.session.form

    def reopen(self):
        self.session.command("host-reopen")
        self.until(lambda: self.session.form is not None)

    @contextlib.contextmanager
    def private_ui(self):
        parent, peer = socket.socketpair()
        channel = native.Channel(parent)
        bridge = native.UIBridge(self.session, channel)
        sequence = 0
        def request(value):
            nonlocal sequence
            sequence += 1
            raw = json.dumps(value, separators=(",", ":")).encode().hex().encode()
            bridge.request(b"command|" + str(sequence).encode() + b"|" + raw)
        def reply():
            deadline = time.monotonic() + 12
            data = bytearray()
            while b"\n" not in data:
                bridge.pump()
                if native.select.select([peer], [], [], 0)[0]:
                    data.extend(peer.recv(200000))
                if time.monotonic() >= deadline:
                    self.fail("private UI reply deadline")
                time.sleep(0.002)
            tag, seq, payload = bytes(data).strip().split(b"|")
            self.assertEqual(tag, b"reply")
            self.assertEqual(int(seq), sequence)
            return json.loads(bytes.fromhex(payload.decode()))
        try:
            self.session.ui_events.clear()
            request(dict(op="hello", protocol_version=1))
            self.assertEqual(reply()["op"], "ready")
            request(dict(op="open", view=1, text=""))
            self.assertEqual(reply()["op"], "present")
            yield bridge, request, reply
        finally:
            channel.close()
            peer.close()

    def test_interactive_preview_actions_disposal_tokens_and_author_correlation(self):
        session = self.start(preview_mode="interactive")
        # Enable and actually dispatch forbidden operations: the real preview
        # delegate must reject them even when the source ignores access mode.
        source = self.seed.replace('(define (author?) (equal? (get workspace "access") "author"))',
                                   '(define (author?) #t)')
        self.action("save", source)
        before = self.snapshot()
        author_form = session.form
        with self.private_ui() as (bridge, request, reply):
            def begin():
                request(dict(op="action", view=1, surface_handle=session.form["surface_handle"],
                    surface_generation=session.form["surface_generation"], action_id="preview", text=source))
                result = reply()
                self.assertEqual(result["op"], "preview")
                self.assertNotEqual(result["preview_view"], 1)
                return result
            first = begin()
            candidate = session.preview
            root = Path(session.preview_root.name)
            self.assertIsNone(session.deadline)
            self.assertIsNone(candidate.deadline)
            self.assertIs(session.form, author_form)
            self.assertEqual(self.snapshot(), before)
            # Neither source nor the blocked preview worker should introduce a
            # short completion poll while the operator considers the candidate.
            with mock.patch.object(session, "command", wraps=session.command) as commands:
                start = time.monotonic()
                session.pump()
                session.wait_ready(maximum=0.08)
                self.assertGreaterEqual(time.monotonic() - start, 0.07)
                self.assertFalse(any(c.args[0] == "host-poll" for c in commands.call_args_list))
            def action(action_id, text):
                form = candidate.form
                request(dict(op="preview-action", view=first["preview_view"], token=first["token"],
                    surface_handle=form["surface_handle"], surface_generation=form["surface_generation"],
                    action_id=action_id, text=text))
                return reply()["form"]
            for operation in ("preview", "install", "export"):
                self.assertIn("access-denied", action(operation, source)["status"])
                self.assertIsNone(candidate.preview)
            self.assertEqual(action("save", "candidate-only draft")["status"], "Draft saved.")
            self.assertEqual(action("read", "discarded local text")["text"], "candidate-only draft")
            self.assertEqual(self.snapshot(), before)
            candidate.command("host-snapshot")
            self.assertEqual(candidate.snapshot["source"], "candidate-only draft")
            def checked_command(operation, **fields):
                if operation == "host-preview-result":
                    self.assertFalse(root.exists(), "ticket published before filesystem disposal")
                    self.assertIsNone(candidate.child, "ticket published before execution cleanup")
                    self.assertIsNone(candidate.authority)
                return original_command(operation, **fields)
            original_command = session.command
            with mock.patch.object(session, "command", side_effect=checked_command):
                request(dict(op="preview-finish", view=first["preview_view"], token=first["token"], accept=True))
                finished = reply()
            self.assertEqual(finished["op"], "present")
            self.assertEqual(finished["view"], 1)
            self.assertEqual(finished["form"]["action_id"], "preview")
            self.assertEqual(finished["form"]["surface_handle"], author_form["surface_handle"])
            self.assertEqual(self.snapshot(), before)
            second = begin()
            second_candidate = session.preview
            for op in (dict(op="preview-finish", view=first["preview_view"], token=first["token"], accept=True),
                       dict(op="preview-action", view=first["preview_view"], token=first["token"],
                            surface_handle=first["form"]["surface_handle"], surface_generation=1,
                            action_id="save", text="stale write"),
                       dict(op="close", view=first["preview_view"])):
                request(op)
                self.assertIs(session.preview, second_candidate)
                self.assertIsNone(bridge.pending, "stale callback consumed a reply slot")
            request(dict(op="preview-finish", view=second["preview_view"], token=second["token"], accept=False))
            self.assertIn("cancelled", reply()["form"]["status"])
            self.assertIsNone(session.preview)
            self.assertEqual(self.snapshot(), before)
        self.assertIn("preview", self.action("install")["status"])
        self.assertIsNone(session.proposal, "cancelled preview authorized installation")

    def test_interactive_candidate_error_and_busy_cancel_preserve_main(self):
        session = self.start(preview_mode="interactive")
        for behavior in ('(error "candidate action exception")', '(usleep 800000)'):
            source = self.seed.replace('((equal? id "insert-header")',
                                      '((equal? id "insert-header") ' + behavior)
            self.action("save", source)
            before = self.snapshot()
            with self.private_ui() as (bridge, request, reply):
                form = session.form
                request(dict(op="action", view=1, surface_handle=form["surface_handle"],
                    surface_generation=form["surface_generation"], action_id="preview", text=source))
                opened = reply()
                candidate = session.preview
                root = Path(session.preview_root.name)
                form = candidate.form
                request(dict(op="preview-action", view=opened["preview_view"], token=opened["token"],
                    surface_handle=form["surface_handle"], surface_generation=form["surface_generation"],
                    action_id="insert-header", text=source))
                if "exception" in behavior:
                    self.assertEqual(reply()["op"], "preview-failure")
                    self.assertFalse(root.exists())
                    self.assertIsNone(candidate.child)
                else:
                    with self.assertRaisesRegex(ValueError, "busy or failed"):
                        request(dict(op="preview-finish", view=opened["preview_view"],
                                     token=opened["token"], accept=True))
                request(dict(op="preview-finish", view=opened["preview_view"], token=opened["token"], accept=False))
                self.assertEqual(reply()["form"]["action_id"], "preview")
                self.assertFalse(root.exists())
                self.assertIsNone(candidate.child)
                self.assertEqual(self.snapshot(), before)
                self.assertIsNone(session.failure)

    def test_interactive_candidate_action_deadline_and_cleanup_failure(self):
        session = self.start(preview_mode="interactive")
        source = self.seed.replace('((equal? id "insert-header")',
                                  '((equal? id "insert-header") (usleep 800000)')
        self.action("save", source)
        session.action("preview")
        self.until(lambda: session.preview is not None and session.preview.form is not None)
        candidate = session.preview
        root = Path(session.preview_root.name)
        # Human idle has no action deadline even after the configured duration.
        candidate.action_timeout = 0.05
        time.sleep(0.1)
        session.pump()
        self.assertIsNone(candidate.failure)
        candidate.action("insert-header")
        self.until(lambda: session.preview_failure is not None)
        self.assertIn("deadline", session.preview_failure)
        self.assertFalse(root.exists())
        previous = session.form["sequence"]
        session.finish_preview(False)
        self.until(lambda: session.form["sequence"] != previous)
        session.action("preview")
        self.until(lambda: session.preview is not None and session.preview.form is not None)
        candidate = session.preview
        root = Path(session.preview_root.name)
        with mock.patch.object(session, "cancel_preview", side_effect=native.CleanupError("unproved domain cleanup")):
            with mock.patch.object(session, "command", wraps=session.command) as commands:
                with self.assertRaises(native.CleanupError):
                    session.finish_preview(True)
                self.assertFalse(any(c.args[0] == "host-preview-result" for c in commands.call_args_list))
                self.assertTrue(root.exists())
                self.assertIs(session.preview, candidate)
        session.finish_preview(False)
        self.assertFalse(root.exists())

    def test_sandbox_owner_control_coalescing_bounds_and_ready_gate(self):
        # This tests the trusted control seam only; no sandbox or authored native
        # containment probe is launched. Parent gates exercise the packaged owner.
        for payload, valid in ((b"ready\nclean\n", True), (b"ready\n", True),
                               (b"ready\nready\n", False), (b"x" * 33, False),
                               (b"clean\ntrailing", False)):
            parent, peer = socket.socketpair()
            with parent, peer:
                owner = object.__new__(native.EditorSession)
                owner.child_control, owner.owner_buffer = parent, bytearray()
                owner.sandbox_command = Path("/gnu/store/controlled-owner")
                owner.owner_ready = owner.owner_clean = False
                peer.sendall(payload)
                if valid:
                    owner.read_owner_control()
                    self.assertTrue(owner.owner_ready)
                    self.assertEqual(owner.owner_clean, b"clean\n" in payload)
                    self.assertEqual(owner.owner_buffer, b"")
                else:
                    with self.assertRaises(native.CleanupError):
                        owner.read_owner_control()
        parent, peer = socket.socketpair()
        with parent, peer:
            owner = object.__new__(native.EditorSession)
            owner.child_control, owner.owner_buffer = parent, bytearray()
            owner.sandbox_command = Path("/gnu/store/controlled-owner")
            owner.owner_ready = owner.owner_clean = False
            for part in (b"rea", b"dy\ncle", b"an\n"):
                peer.sendall(part)
                owner.read_owner_control()
            self.assertTrue(owner.owner_ready and owner.owner_clean)
            self.assertEqual(owner.owner_buffer, b"")
        for command in (Path("/bin/true"), self.root / "absent-owner"):
            with self.assertRaises((ValueError, FileNotFoundError)):
                native.EditorSession(self.workspace, self.root, SUPERVISOR, sandbox_command=command)
        # Observe constructor argv only, never execute this unrelated immutable
        # executable as an owner. This pins the real store identity length cap.
        command = (SUPERVISOR / "bin/guile").resolve(strict=True)
        with mock.patch.object(native.subprocess, "Popen", side_effect=RuntimeError("capture only")) as launch:
            with self.assertRaisesRegex(RuntimeError, "capture only"):
                native.EditorSession(self.workspace, self.root, SUPERVISOR, sandbox_command=command)
            argv = launch.call_args.args[0]
            self.assertEqual(argv[3], "--workspace-authority")
            identity = argv[7]
            self.assertLessEqual(len(identity), 128)
            self.assertEqual(identity, "workbench-editor-v1-sandbox-" +
                             hashlib.sha256(os.fsencode(command)).hexdigest())
        session = self.start()
        with mock.patch.object(session, "sandbox_command", Path("/gnu/store/controlled-owner")), \
                mock.patch.object(session, "owner_ready", False), \
                mock.patch.object(session, "read_owner_control"), \
                mock.patch.object(session.child_channel, "receive") as receive:
            session.pump()
            receive.assert_not_called()
        with mock.patch.object(session, "stop_child", side_effect=native.CleanupError("missing clean ack")):
            with self.assertRaisesRegex(native.CleanupError, "missing clean ack"):
                session.close()
            self.assertTrue(session.source_file.exists(), "unproved execution source was deleted")
            self.assertTrue(session.root.exists(), "unproved execution root was deleted")

    def test_interactive_idle_candidate_error_is_reported_on_next_action_or_finish(self):
        session = self.start(preview_mode="interactive")
        source = self.seed.replace('(loop)))))',
            '(when (not (author?)) (usleep 150000) (error "idle candidate exception"))\n'
            '        (loop)))))')
        self.assertNotEqual(source, self.seed)
        self.action("save", source)
        before = self.snapshot()
        with self.private_ui() as (bridge, request, reply):
            for observe_with_action in (True, False):
                form = session.form
                request(dict(op="action", view=1, surface_handle=form["surface_handle"],
                    surface_generation=form["surface_generation"], action_id="preview", text=source))
                opened = reply()
                form = session.preview.form
                root = Path(session.preview_root.name)
                time.sleep(0.3)
                if observe_with_action:
                    bridge.pump()  # no private pending request; no unsolicited reply
                    self.assertIsNotNone(session.preview_failure)
                    self.assertFalse(root.exists())
                    request(dict(op="preview-action", view=opened["preview_view"], token=opened["token"],
                        surface_handle=form["surface_handle"], surface_generation=form["surface_generation"],
                        action_id="read", text=source))
                    self.assertEqual(reply()["op"], "preview-failure")
                # Without the intervening pump, Finish must still observe the
                # queued child failure before it can authorize a preview ticket.
                request(dict(op="preview-finish", view=opened["preview_view"],
                             token=opened["token"], accept=not observe_with_action))
                self.assertIn("preview-failed", reply()["form"]["status"])
                self.assertFalse(root.exists())
                self.assertEqual(self.snapshot(), before)

    def test_controlled_owner_early_cleanup_reaps_before_diagnostic_and_drops_frames(self):
        # Explicit trusted process fixture, not a sandbox_command constructor
        # override or a native fallback. No authored source is executed here.
        fixture = '''
import os, socket, sys, time
control = socket.socket(fileno=int(sys.argv[1]))
book = socket.socket(fileno=0)
book.sendall(bytes.fromhex(sys.argv[4]))
control.sendall(bytes.fromhex(sys.argv[5]))
control.close()
time.sleep(0.05)
fd = os.open(sys.argv[2] + ".sandbox-error", os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
os.write(fd, sys.argv[3].encode("utf-8"))
os.close(fd)
'''
        for ready in (False, True):
            source = self.root / ("controlled-ready.scm" if ready else "controlled-unready.scm")
            source.write_text("opaque unused source")
            parent, donated = socket.socketpair()
            control, control_donation = socket.socketpair()
            owner = object.__new__(native.EditorSession)
            owner.authority = owner.preview = None
            owner.authority_usable = True
            owner.child_channel = native.Channel(parent)
            owner.child_control = control
            owner.owner_buffer = bytearray()
            owner.owner_ready = owner.owner_clean = False
            owner.owner_diagnostic = owner.failure = None
            owner.source_file = source
            owner.sandbox_command = Path("/gnu/store/controlled-fixture-not-executed")
            owner.deadline = time.monotonic() + 20
            owner.ui_events = []
            owner.command = mock.Mock()
            diagnostic = "owner preparation failed: " + "λ" * 1000
            self.assertLessEqual(len(diagnostic.encode()), 2048)
            frames = native.encode_frame({"type": "hello", "version": 1})
            frames += native.encode_frame({"type": "workspace-save", "source": "never forward"})
            records = (b"ready\n" if ready else b"") + b"clean\n"
            with donated, control_donation:
                owner.child = native.subprocess.Popen(
                    [native.sys.executable, "-I", "-S", "-c", fixture,
                     str(control_donation.fileno()), str(source), diagnostic, frames.hex(), records.hex()],
                    stdin=donated, pass_fds=(control_donation.fileno(),),
                    stdout=native.subprocess.DEVNULL, stderr=native.subprocess.DEVNULL,
                    start_new_session=True)
            native.LIVE.add(owner.child.pid)
            try:
                started = time.monotonic()
                self.assertTrue(native.select.select([control], [], [], 2)[0])
                with mock.patch.object(owner.child_channel, "receive", wraps=owner.child_channel.receive) as receive:
                    owner.pump()
                    receive.assert_not_called()
                self.assertLess(time.monotonic() - started, 2, "early clean waited for startup timeout")
                self.assertIsNone(owner.child, "owner not reaped after exact cleanup ack")
                self.assertEqual(owner.owner_diagnostic, diagnostic, "diagnostic read before owner exit")
                self.assertFalse(source.exists())
                self.assertIn("sandbox owner: owner preparation failed:", owner.failure)
                self.assertLessEqual(len(owner.failure.encode()), 2048)
                self.assertNotIn("\0", owner.failure)
                if not ready:
                    self.assertIn("before readiness", owner.failure)
                owner.command.assert_called_once_with("host-retire")
                self.assertEqual(owner.ui_events[-1]["text"], owner.failure)
            finally:
                owner.stop_child()

    def test_owner_diagnostic_validation_and_missing_ack_remains_cleanup_error(self):
        source = self.root / "diagnostic-source.scm"
        source.write_text("unused")
        sidecar = Path(str(source) + ".sandbox-error")
        owner = object.__new__(native.EditorSession)
        owner.source_file = source
        self.assertIsNone(owner.read_owner_diagnostic())
        for data, valid in (("bounded λ diagnostic".encode(), True),
                            (b"x" * 2049, False), (b"bad\0diagnostic", False),
                            (b"bad\xffutf8", False)):
            sidecar.write_bytes(data)
            sidecar.chmod(0o600)
            self.assertEqual(owner.read_owner_diagnostic(), data.decode() if valid else None)
            sidecar.unlink()
        sidecar.write_text("private owner diagnostic")
        sidecar.chmod(0o644)
        self.assertIsNone(owner.read_owner_diagnostic())
        sidecar.chmod(0o600)
        link = self.root / "other-link"
        os.link(sidecar, link)
        self.assertIsNone(owner.read_owner_diagnostic())
        sidecar.unlink()
        sidecar.symlink_to(link)
        self.assertIsNone(owner.read_owner_diagnostic())
        sidecar.unlink()
        link.unlink()
        os.mkfifo(sidecar, 0o600)
        started = time.monotonic()
        self.assertIsNone(owner.read_owner_diagnostic())
        self.assertLess(time.monotonic() - started, 0.1, "diagnostic FIFO blocked")
        sidecar.unlink()
        sidecar.write_bytes(b"invalid\0diagnostic")
        sidecar.chmod(0o600)
        parent, peer = socket.socketpair()
        with parent:
            peer.close()
            owner.child = mock.Mock()
            owner.child_control = parent
            owner.owner_buffer = bytearray()
            owner.owner_ready = owner.owner_clean = False
            owner.sandbox_command = Path("/gnu/store/controlled-fixture-not-executed")
            with mock.patch.object(owner, "read_owner_diagnostic") as read:
                with self.assertRaisesRegex(native.CleanupError, "without cleanup acknowledgement"):
                    owner.stop_child()
                owner.child.wait.assert_not_called()
                read.assert_not_called()
            self.assertTrue(source.exists(), "missing ack removed runtime source")

    def test_malformed_candidate_message_family_does_not_kill_author(self):
        session = self.start(preview_mode="interactive")
        author_pid = session.child.pid
        for family in ('#()', '(("unexpected" . #t))'):
            source = '(define (workbench-main receive! send! own-source) (send! \'(("type" . %s))) (sleep 1))' % family
            self.action("save", source)
            before = self.snapshot()
            result = self.action("preview")
            self.assertIn("forbidden child message family", result["status"])
            self.assertIsNone(session.preview)
            self.assertIsNone(session.preview_root)
            self.assertEqual(session.child.pid, author_pid)
            self.assertEqual(self.snapshot(), before)
            self.assertEqual(self.action("read")["text"], source)

    def test_candidate_rpc_deadline_retires_transport_and_rejects_late_reply(self):
        session = self.start(preview_mode="interactive")
        before = self.snapshot()
        for backpressure in (False, True):
            session.action("preview")
            self.until(lambda: session.preview is not None and session.preview.form is not None)
            candidate = session.preview
            original_control = candidate.control
            parent, peer = socket.socketpair()
            candidate.control = native.Channel(parent)
            received, late = [], []
            worker = None
            if backpressure:
                parent.setsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF, 1024)
                while True:
                    try:
                        parent.send(b"x" * 4096)
                    except BlockingIOError:
                        break
            else:
                def delayed_reply():
                    authority = native.Channel(peer)
                    try:
                        received.append(authority.receive(1)[0])
                        time.sleep(0.25)
                        try:
                            authority.send({"events": [], "busy": False})
                        except (OSError, EOFError):
                            late.append("closed")
                    finally:
                        authority.close()
                worker = threading.Thread(target=delayed_reply)
                worker.start()
            try:
                candidate.deadline = time.monotonic() + 0.03
                started = time.monotonic()
                candidate.command("host-snapshot")
                self.assertLess(time.monotonic() - started, 0.18, "RPC ignored the 30 ms active clock")
                self.assertTrue(candidate.failure)
                self.assertFalse(candidate.authority_usable)
                self.assertIsNone(candidate.authority)
                self.assertIsNone(candidate.child)
                self.assertEqual(parent.fileno(), -1)
                with self.assertRaisesRegex(ValueError, "transport retired"):
                    candidate.command("host-snapshot")
                if worker:
                    worker.join(timeout=2)
                    self.assertFalse(worker.is_alive())
                    self.assertEqual(received, [{"type": "host-snapshot"}], "retire reused an unmatched exchange")
                    self.assertEqual(late, ["closed"])
                session.pump()
                self.assertIsNone(session.failure)
                previous = session.form["sequence"]
                session.finish_preview(False)
                self.until(lambda: session.form["sequence"] != previous)
                self.assertEqual(self.action("read")["text"], self.seed)
                self.assertEqual(self.snapshot(), before)
            finally:
                original_control.close()
                peer.close()
                if worker:
                    worker.join(timeout=2)

    def test_terminal_main_authority_private_ui_keeps_open_and_close_local(self):
        session = self.start(preview_mode="interactive")
        original_control = session.control
        parent, peer = socket.socketpair()
        try:
            with self.private_ui() as (bridge, request, reply):
                form = session.form
                # A safe connected peer deliberately does not answer. The real
                # UI decoder submits the request and encounters the actual RPC
                # timeout; no source exception or error-string control is used.
                session.control = native.Channel(parent)
                session.action_timeout = 0.03
                action = dict(op="action", view=1, surface_handle=form["surface_handle"],
                    surface_generation=form["surface_generation"], action_id="save", text="unsaved local draft")
                request(action)
                self.assertEqual(reply()["op"], "failure")
                self.assertFalse(session.authority_usable)
                self.assertIsNone(session.authority)
                self.assertIsNone(session.child)
                with mock.patch.object(session, "command", side_effect=AssertionError("terminal UI attempted RPC")):
                    request(dict(action, action_id="read", text="later unsaved local draft"))
                    failed = reply()
                    self.assertEqual(failed["op"], "failure")
                    self.assertLessEqual(len(failed["error"].encode()), 2048)
                    request(dict(op="decision", view=1, token="retired-token", accept=True))
                    self.assertEqual(reply()["op"], "failure")
                    request(dict(op="close", view=1))
                    bridge.pump()
                    self.assertIsNone(bridge.pending)
                    request(dict(op="open", view=2, text="later unsaved local draft"))
                    reopened = reply()
                    self.assertEqual((reopened["op"], reopened["view"]), ("failure", 2))
                    self.assertEqual(bridge.view, 2)
                    self.assertGreaterEqual(bridge.transport.sock.fileno(), 0, "terminal backend closed UI transport")
                    request(dict(op="close", view=2))
                    bridge.pump()
        finally:
            original_control.close()
            parent.close()
            peer.close()

    def test_empty_rpc_completion_and_child_backpressure_observe_action_deadline(self):
        session = self.start(preview_mode="interactive")
        for child_backpressure in (False, True):
            session.action("preview")
            self.until(lambda: session.preview is not None and session.preview.form is not None)
            candidate = session.preview
            if child_backpressure:
                original_channel = candidate.child_channel
                parent, peer = socket.socketpair()
                candidate.child_channel = native.Channel(parent)
                parent.setsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF, 1024)
                while True:
                    try:
                        parent.send(b"x" * 4096)
                    except BlockingIOError:
                        break
                try:
                    candidate.deadline = time.monotonic() + 0.03
                    started = time.monotonic()
                    candidate.event("child", {"type": "fixture", "text": "bounded output"})
                    self.assertLess(time.monotonic() - started, 0.18, "child send ignored active clock")
                    self.assertTrue(candidate.failure)
                finally:
                    original_channel.close()
                    peer.close()
            else:
                receive = candidate.control.receive
                def completed_at_deadline(timeout):
                    response = receive(timeout)
                    self.assertEqual(response[0], {"events": [], "busy": False})
                    # The real reply has been consumed: model preemption at the
                    # empty-event publication boundary, not an unmatched reply.
                    candidate.deadline = time.monotonic() - 0.01
                    return response
                candidate.deadline = time.monotonic() + 1
                with mock.patch.object(candidate.control, "receive", side_effect=completed_at_deadline):
                    # Restore receive before revocation so its own response is
                    # processed normally and does not recursively inject expiry.
                    expire = candidate.expire_if_due
                    def expire_once():
                        if candidate.deadline is not None and time.monotonic() >= candidate.deadline:
                            candidate.control.receive = receive
                        return expire()
                    with mock.patch.object(candidate, "expire_if_due", side_effect=expire_once):
                        candidate.command("host-poll")
                self.assertIn("deadline", candidate.failure)
                self.assertTrue(candidate.authority_usable, "complete reply incorrectly desynchronized transport")
            session.pump()
            previous = session.form["sequence"]
            session.finish_preview(False)
            self.until(lambda: session.form["sequence"] != previous)
            self.assertEqual(self.action("read")["text"], self.seed)

    def test_owner_terminal_status_after_final_preview_pump_controls_ticket(self):
        session = self.start(preview_mode="interactive")
        before = self.snapshot()
        fixture = '''
import socket, sys
control = socket.socket(fileno=int(sys.argv[1]))
control.sendall(b"ready\\n")
assert control.recv(16) == b"stop\\n"
control.sendall(b"clean\\n")
control.close()
sys.exit(int(sys.argv[2]))
'''
        for exit_status in (1, 0):
            session.action("preview")
            self.until(lambda: session.preview is not None and session.preview.form is not None)
            candidate = session.preview
            # Keep a real authority-accepted form and disposable store, but
            # replace its already-clean native execution with an explicit
            # controlled owner fixture. It fails only when stop is received,
            # after Finish's last pump, and deliberately writes no diagnostic.
            candidate.stop_child()
            parent, donated = socket.socketpair()
            control, control_donation = socket.socketpair()
            candidate.child_channel = native.Channel(parent)
            candidate.child_control = control
            candidate.owner_buffer.clear()
            candidate.owner_ready = candidate.owner_clean = False
            candidate.owner_exit_status = candidate.owner_diagnostic = None
            candidate.sandbox_command = Path("/gnu/store/controlled-fixture-not-executed")
            candidate.source_file = candidate.root / "late-owner.scm"
            candidate.source_file.write_text("opaque fixture source")
            with donated, control_donation:
                candidate.child = native.subprocess.Popen(
                    [native.sys.executable, "-I", "-S", "-c", fixture,
                     str(control_donation.fileno()), str(exit_status)], stdin=donated,
                    pass_fds=(control_donation.fileno(),), stdout=native.subprocess.DEVNULL,
                    stderr=native.subprocess.DEVNULL, start_new_session=True)
            native.LIVE.add(candidate.child.pid)
            self.assertTrue(native.select.select([control], [], [], 2)[0])
            candidate.read_owner_control()
            self.assertTrue(candidate.owner_ready)
            root = candidate.root
            previous = session.form["sequence"]
            with mock.patch.object(candidate, "pump", wraps=candidate.pump) as final_pump:
                session.finish_preview(True)
                final_pump.assert_called_once()
            self.until(lambda: session.form["sequence"] != previous)
            self.assertEqual(candidate.owner_exit_status, exit_status)
            self.assertIsNone(candidate.owner_diagnostic)
            self.assertFalse(root.exists())
            self.assertEqual(self.snapshot(), before)
            if exit_status:
                self.assertIn("exit status 1", session.form["status"])
                self.assertIn("preview-failed", session.form["status"])
                self.assertIn("preview", self.action("install")["status"])
                self.assertIsNone(session.proposal)
            else:
                self.assertIn("interactive preview accepted", session.form["status"])
                self.propose()
                previous = session.form["sequence"]
                session.cancel()
                self.until(lambda: session.form["sequence"] != previous)
            self.assertEqual(self.action("read")["text"], self.seed)

    def test_self_revision_reopen_rollback_seed_and_broken_draft(self):
        trusted = [TOOL / p for p in (
            "native-editor.py", "editor-authority.scm", "editor-surface.scm",
            "workspace-delegate.scm", "workspace-protocol.scm", "workbench-editor-runner.scm",
            "native-child-owner.py")]
        identities = {p: hashlib.sha256(p.read_bytes()).hexdigest() for p in trusted}
        session = self.start()
        self.assertEqual(session.form["title"], "Source Workbench")
        r0 = self.snapshot()
        self.assertEqual(self.action("successor")["text"], self.seed)
        r1_source = (self.seed.replace('"Source Workbench"', '"Authored R1"')
                     .replace('"insert-header"', '"stamp"')
                     .replace('"Insert header"', '"Stamp from R1"')
                     .replace(';;; Edited in Source Workbench', ';;; Authored R1 stamp'))
        self.assertIn("Draft saved", self.action("save", r1_source)["status"])
        saved = self.snapshot()
        self.assertEqual(saved["workspace-version"], 1)
        self.assertEqual(saved["active-revision"], r0["active-revision"])
        self.assertIn("preview", self.action("preview")["status"])
        self.assertIsNone(session.preview)
        self.assertEqual(self.snapshot(), saved, "preview must not modify author store")
        self.propose()
        self.assertEqual(self.snapshot(), saved, "proposal alone has no activation")
        old = session.form["sequence"]
        session.cancel()
        self.until(lambda: session.form["sequence"] != old)
        self.assertEqual(self.snapshot(), saved, "cancel has no activation")
        # Cancellation consumes the ticket; require a fresh successful preview.
        self.action("preview")
        self.propose()
        self.assertIn("installed", self.confirm()["status"])
        r1 = self.snapshot()
        self.assertNotEqual(r1["active-revision"], r0["active-revision"])
        self.assertEqual(r1["activation-generation"], 1)
        self.reopen()
        self.assertEqual(session.form["title"], "Authored R1")
        self.assertIn("stamp", [a["id"] for a in session.form["actions"]])
        self.assertTrue(self.action("stamp")["text"].startswith(";;; Authored R1 stamp"))
        self.assertEqual(self.action("successor")["text"], r1_source)
        r2_source = r1_source.replace("Authored R1", "Authored R2").replace('"stamp"', '"stamp2"')
        self.action("save", r2_source)
        self.action("preview")
        self.propose()
        self.confirm()
        self.reopen()
        self.assertEqual(session.form["title"], "Authored R2")
        self.assertIn("stamp2", [a["id"] for a in session.form["actions"]])
        # Process restart, not just new-view: same SQLite and pinned ABI identity.
        session.close()
        self.session = None
        session = self.start()
        self.assertEqual(session.form["title"], "Authored R2")
        broken = "(define (workbench-main receive! send! own-source) (let loop () (loop)))\n"
        self.action("save", broken)
        failed = self.action("preview")
        self.assertIn("failed", failed["status"])
        broken_snapshot = self.snapshot()
        self.assertEqual(broken_snapshot["source"], broken)
        session.command("host-recover", kind="rollback")
        self.until(lambda: session.form is not None)
        self.assertEqual(session.form["title"], "Authored R1")
        self.assertEqual(session.form["text"], broken)
        session.command("host-recover", kind="seed")
        self.until(lambda: session.form is not None)
        self.assertEqual(session.form["title"], "Source Workbench")
        self.assertEqual(session.form["text"], broken)
        recovered = self.snapshot()
        self.assertEqual(recovered["workspace-version"], broken_snapshot["workspace-version"])
        self.assertEqual(recovered["active-revision"], r0["seed-revision"])
        self.assertEqual(identities, {p: hashlib.sha256(p.read_bytes()).hexdigest() for p in trusted})
        self.assertTrue((self.workspace / "book-workspace-v1.sqlite").is_file())

    def test_stale_confirmation_and_retired_view_do_not_activate(self):
        session = self.start()
        self.action("save", self.seed.replace("Source Workbench", "Stale candidate"))
        self.action("preview")
        self.propose()
        proposal = session.proposal["proposal_id"]
        # Another real authority changes the activation epoch while the first
        # retains its private proposal. Neither bypasses SQLite or CAS.
        other_root = self.root / "other"
        other_root.mkdir(mode=0o700)
        other = native.EditorSession(self.workspace, other_root, SUPERVISOR)
        try:
            other.command("host-recover", kind="seed")
        finally:
            other.close()
        before = self.snapshot()
        self.assertIn("conflict", self.confirm()["status"])
        self.assertEqual(self.snapshot(), before)
        self.reopen()
        with self.assertRaises(ValueError):
            session.confirm(proposal)
        self.assertEqual(self.snapshot(), before)

    def test_preview_grant_denies_authority_and_isolates_saved_source(self):
        self.start()
        injection = '''(when (not (author?))
                 (for-each
                  (lambda (pair)
                    (let ((denied (operation (car pair) (cdr pair))))
                      (need (equal? (get denied "code") "access-denied") "preview escaped grant")))
                  (list (cons "workspace-export" '())
                        (cons "workspace-preview" (version))
                        (cons "workspace-install-propose"
                          (append (version) `(("expected_activation" . ,(get snapshot "activation_generation")))))))
                 (operation "workspace-save" (append (version) '(("source" . "preview-only draft")))))
               '''
        source = self.seed.replace('(present request (if snapshot', injection + '(present request (if snapshot', 1)
        source = "\n".join(line.strip() for line in source.splitlines()
                           if not line.lstrip().startswith(";")) + "\n"
        self.assertLessEqual(len(source.encode()), 8192)
        self.action("save", source)
        before = self.snapshot()
        result = self.action("preview")
        self.assertIn("initial editor form accepted", result["status"])
        self.assertEqual(self.snapshot(), before)

    def test_old_text_function_environment_is_rejected(self):
        # Build an actual old store using the old byte-storage API and identity.
        script = '(use-modules (book-workspace)) (let ((s (open-workspace-store (cadr (command-line)) "(define (workbench text) text)" #:environment (caddr (command-line))))) (close-workspace-store! s))'
        import subprocess
        subprocess.run([str(SUPERVISOR / "bin/guile"), "--no-auto-compile", "-c", script,
                        str(self.workspace), SUPERVISOR.name],
                       env=native.environment(self.root, SUPERVISOR), check=True)
        with self.assertRaises((EOFError, ValueError, ConnectionResetError)):
            self.session = native.EditorSession(self.workspace, self.root, SUPERVISOR)

    def test_action_timeout_origin_split_and_descendant_cleanup(self):
        session = self.start()
        source = self.seed.replace('((equal? id "insert-header")',
            '((equal? id "insert-header") (let loop () (loop))')
        self.action("save", source)
        self.action("preview")
        self.propose()
        self.confirm()
        self.reopen()
        # Idle is not timed as authored work.
        time.sleep(0.25)
        session.pump()
        self.assertIsNone(session.failure)
        session.action_timeout = 0.2
        session.action("insert-header")
        end = time.monotonic() + 2
        while not session.failure and time.monotonic() < end:
            session.pump()
            time.sleep(0.01)
        self.assertIn("deadline", session.failure)
        self.assertIsNone(session.child)
        session.command("host-recover", kind="seed")
        self.until(lambda: session.form is not None)
        session.action_timeout = 10
        # Try a private coordinator operation from real authored code. The
        # authoring socket cannot reach trusted recovery/confirmation dispatch.
        forged = '(define (workbench-main receive! send! own-source) (send! \'(("type" . "host-recover") ("kind" . "seed"))) (sleep 60))'
        self.action("save", forged)
        before = self.snapshot()
        self.assertIn("forbidden child message family", self.action("preview")["status"])
        self.assertEqual(self.snapshot(), before)
        # A descendant changes process group, then survives its original parent.
        forked = '(define (workbench-main receive! send! own-source) (let ((pid (primitive-fork))) (if (= pid 0) (begin (setsid) (sleep 60)) (sleep 60))))'
        self.action("save", forked)
        self.assertIn("deadline", self.action("preview")["status"])
        children = set(map(int, Path(f"/proc/self/task/{os.getpid()}/children").read_text().split()))
        self.assertEqual(children, native.LIVE, "no orphaned native preview descendants")

    def test_retire_running_preview_and_late_private_decision(self):
        session = self.start()
        source = '(define (workbench-main receive! send! own-source) (sleep 60))'
        self.action("save", source)
        before = self.snapshot()
        session.action("preview")
        self.until(lambda: session.preview is not None)
        preview_root = Path(session.preview_root.name)
        session.command("host-reopen")
        self.until(lambda: session.form is not None and session.form["action_id"] == "open")
        self.assertIsNone(session.preview)
        self.assertFalse(preview_root.exists(), "retirement cleans disposable preview store")
        self.assertEqual(self.snapshot(), before)
        session.ui_events.clear()
        parent, peer = socket.socketpair()
        with peer:
            channel = native.Channel(parent)
            bridge = native.UIBridge(session, channel)
            seq = 0
            def request(value):
                nonlocal seq
                seq += 1
                raw = json.dumps(value, separators=(",", ":")).encode().hex().encode()
                bridge.request(b"command|" + str(seq).encode() + b"|" + raw)
            try:
                request(dict(op="hello", protocol_version=1))
                request(dict(op="open", view=1, text=""))
                stale = dict(op="action", view=1, surface_handle=session.form["surface_handle"],
                             surface_generation=session.form["surface_generation"] - 1,
                             action_id="save", text="wrong lifetime")
                with self.assertRaisesRegex(ValueError, "stale surface"):
                    request(stale)
                self.assertEqual(self.snapshot(), before)
                bridge.pending = None
                with self.assertRaisesRegex(ValueError, "proposal token"):
                    request(dict(op="decision", view=1, token="forged", accept=True))
                self.assertEqual(self.snapshot(), before)
            finally:
                channel.close()

    def test_coordinator_quiet_wait_socket_wake_deadline_and_busy_worker(self):
        session = self.start()
        self.assertFalse(session.backend_busy)
        start = time.monotonic()
        end = start + 0.45
        iterations = 0
        while time.monotonic() < end:
            session.pump()
            session.wait_ready(maximum=min(0.2, max(0, end - time.monotonic())))
            iterations += 1
        self.assertLessEqual(iterations, 4, "quiet coordinator woke at busy-loop frequency")
        self.assertGreaterEqual(time.monotonic() - start, 0.43)
        parent, peer = socket.socketpair()
        with parent, peer:
            peer.sendall(b"wake")
            start = time.monotonic()
            self.assertTrue(session.wait_ready(extra=(parent,), maximum=0.2))
            self.assertLess(time.monotonic() - start, 0.05, "socket wake waited for idle poll")
        session.deadline = time.monotonic() + 0.04
        start = time.monotonic()
        try:
            self.assertFalse(session.wait_ready(maximum=0.2))
            self.assertLess(time.monotonic() - start, 0.1, "nearest action deadline was ignored")
            self.assertGreaterEqual(time.monotonic() - start, 0.03)
        finally:
            session.deadline = None
        # Exercise the short wait against a genuinely blocked SQLite task,
        # then release it and complete the real source-defined save workflow.
        lock = sqlite3.connect(self.workspace / "book-workspace-v1.sqlite")
        old = session.form["sequence"]
        try:
            lock.execute("BEGIN EXCLUSIVE")
            session.action("save")
            self.until(lambda: session.backend_busy)
            start = time.monotonic()
            self.assertFalse(session.wait_ready(maximum=0.2))
            self.assertLess(time.monotonic() - start, 0.08, "active worker waited at idle cadence")
        finally:
            lock.rollback()
            lock.close()
        self.until(lambda: session.form["sequence"] != old)
        self.assertEqual(session.form["status"], "Draft saved.")

    def test_preview_cleanup_preserves_main_detached_descendant_and_unrelated_child(self):
        pid_file = self.root / "main-support.pid"
        support = '''
(let ((first (primitive-fork)))
  (if (= first 0)
      (begin
        (setsid)
        (if (= (primitive-fork) 0)
            (begin (setsid)
              (call-with-output-file %s (lambda (p) (display (getpid) p)))
              (sleep 60))
            (primitive-exit 0)))
      (waitpid first)))
''' % json.dumps(str(pid_file))
        authored = "\n".join(line.strip() for line in (self.seed + support).splitlines()
                             if not line.lstrip().startswith(";")) + "\n"
        self.assertLessEqual(len(authored.encode()), 8192)
        seed_file = self.root / "support-seed.scm"
        seed_file.write_text(authored)
        session = self.start(seed=seed_file)
        self.until(pid_file.exists)
        support_pid = int(pid_file.read_text())
        import subprocess
        unrelated = subprocess.Popen([str(SUPERVISOR / "bin/guile"), "--no-auto-compile",
                                      "-c", "(sleep 60)"], env=session.env)
        try:
            with self.assertRaises(ChildProcessError):
                os.waitpid(support_pid, os.WNOHANG)
            self.action("save", self.seed)
            self.assertIn("initial editor form accepted", self.action("preview")["status"])
            self.assertIsNone(unrelated.poll(), "preview cleanup killed an unrelated direct child")
            os.kill(support_pid, 0)
            self.assertNotEqual(Path(f"/proc/{support_pid}/stat").read_text().split(") ", 1)[1][0], "Z")
            self.assertIsNone(native.status(session.child), "main execution owner unexpectedly exited")
            self.action("read")
            session.close()
            self.session = None
            self.assertFalse(Path(f"/proc/{support_pid}").exists(), "main owner did not reap its support process")
            self.assertIsNone(unrelated.poll(), "main cleanup killed an unrelated direct child")
        finally:
            unrelated.terminate()
            unrelated.wait(timeout=3)

    def test_ordinary_candidate_exceptions_fail_preview_without_losing_main_editor(self):
        session = self.start()
        main_pid = session.child.pid
        for source in ('(error "ordinary draft exception")',
                       '(define (workbench-main receive! send! own-source) (error "entry exception"))'):
            self.action("save", source)
            before = self.snapshot()
            result = self.action("preview")
            self.assertIn("preview-failed", result["status"])
            self.assertIsNone(session.failure)
            self.assertEqual(session.child.pid, main_pid)
            self.assertEqual(self.snapshot(), before)
            self.assertEqual(self.action("read")["text"], source)

    def test_expired_queued_source_frames_cannot_admit_save_or_publish_present(self):
        source = (self.seed.replace('((equal? id "save")',
                                   '((equal? id "save") (usleep 250000)')
                  .replace('((equal? id "insert-header")',
                           '((equal? id "insert-header") (usleep 250000)'))
        seed_file = self.root / "delayed-seed.scm"
        seed_file.write_text(source)
        session = self.start(seed=seed_file, action_timeout=0.1)
        before = self.snapshot()
        session.action("save", "must never be admitted")
        time.sleep(0.4)
        session.pump()
        self.assertIn("deadline", session.failure)
        self.assertEqual(self.snapshot(), before, "expired source request admitted a new SQLite write")
        self.reopen()
        previous_form = session.form
        session.action("insert-header")
        time.sleep(0.4)
        session.pump()
        self.assertIn("deadline", session.failure)
        self.assertIs(session.form, previous_form, "late present erased the expired deadline")
        self.assertEqual(self.snapshot(), before)

    def test_expired_admitted_completion_is_not_published_and_commit_is_not_undone(self):
        session = self.start(action_timeout=0.1)
        lock = sqlite3.connect(self.workspace / "book-workspace-v1.sqlite")
        previous_form = session.form
        try:
            lock.execute("BEGIN EXCLUSIVE")
            session.action("save", "admitted before the deadline")
            self.until(lambda: session.backend_busy)
        finally:
            lock.rollback()
            lock.close()
        time.sleep(0.3)
        # Polling isn't the only publication path: a trusted snapshot request
        # also drains completions. Check that event boundary independently.
        snapshot = self.snapshot()
        self.assertIn("deadline", session.failure)
        self.assertIs(session.form, previous_form)
        self.assertEqual(snapshot["workspace-version"], 1)
        self.assertEqual(snapshot["source"], "admitted before the deadline")
        self.assertIsNone(session.child)

    def test_cached_graphics_preflight_precedes_authority_and_offscreen_needs_none(self):
        empty = self.root / "empty-graphics"
        empty.mkdir(mode=0o700)
        with mock.patch.dict(os.environ, {"SDL_VIDEODRIVER": "wayland",
                                          "BOOK_WORKBENCH_GRAPHICS": str(empty)}):
            with mock.patch.object(native, "EditorSession") as authority:
                with mock.patch.object(native.sys, "argv", ["native-editor.py",
                        "--trusted-native-fixture", str(self.root)]):
                    previous_mask = os.umask(0o077)
                    try:
                        with self.assertRaisesRegex(ValueError, "BOOK_WORKBENCH_GRAPHICS.*libEGL"):
                            native.main()
                    finally:
                        os.umask(previous_mask)
                authority.assert_not_called()
        with mock.patch.dict(os.environ, {"SDL_VIDEODRIVER": "offscreen",
                                          "BOOK_WORKBENCH_GRAPHICS": str(empty)}):
            reader, graphics = native.reader_inputs()
            self.assertTrue((reader / "reader.lua").is_file())
            self.assertIsNone(graphics)
        with mock.patch.dict(os.environ, {"SDL_VIDEODRIVER": "wayland",
                                          "BOOK_WORKBENCH_GRAPHICS": str(native.DEFAULT_GRAPHICS)}):
            self.assertEqual(native.reader_inputs()[1], native.DEFAULT_GRAPHICS)

    def test_real_koreader_widget_private_channel(self):
        self.start(preview_mode="interactive")
        self.run_widget_probe(REAL_UI_PROBE)
        saved = self.snapshot()
        self.assertIn("UI authored R1", saved["source"])
        self.assertEqual(saved["activation-generation"], 1)

    def test_real_koreader_widget_continuation_chains(self):
        chain = '''
           ((member id '("insert-header" "successor"))
            (operation "workspace-preview" (version))
            (if (equal? id "successor")
                (begin (operation "workspace-preview" (version))
                  (present request (string-append text "\\n; transformed twice") "double preview complete"))
                (let ((result (operation "workspace-install-propose"
                        (append (version) `(("expected_activation" . ,(get snapshot "activation_generation")))))))
                  (operation "workspace-preview" (version))
                  (present request (string-append text "\\n; transformed chain")
                    (status result (or (get result "outcome") "unknown"))))))
'''
        source = self.seed.replace('           ((equal? id "successor")',
                                   chain + '           ((equal? id "successor")')
        source = "\n".join(line.strip() for line in source.splitlines()
                           if not line.lstrip().startswith(";")) + "\n"
        self.assertLessEqual(len(source.encode()), 8192)
        seed = self.root / "chain-seed.scm"
        seed.write_text(source)
        self.start(seed=seed, preview_mode="interactive")
        self.run_widget_probe(CHAIN_UI_PROBE)
        snapshot = self.snapshot()
        self.assertEqual(snapshot["activation-generation"], 1)
        self.assertEqual(snapshot["source"], source)

    def test_real_koreader_widget_terminal_authority_keeps_draft_after_reopen(self):
        session = self.start(preview_mode="interactive")
        original_control, original_action, original_command = session.control, session.action, session.command
        parent, peer = socket.socketpair()
        actions = []
        def timed_out_action(action_id, text=None):
            self.assertEqual(actions, [], "terminal bridge dispatched another authored action")
            actions.append(action_id)
            session.control = native.Channel(parent)
            session.action_timeout = 0.03
            original_action(action_id, text)
            self.assertFalse(session.authority_usable)
        def guarded_command(operation, **fields):
            self.assertTrue(session.authority_usable, "terminal widget lifecycle attempted another authority RPC")
            return original_command(operation, **fields)
        try:
            with mock.patch.object(session, "action", side_effect=timed_out_action), \
                    mock.patch.object(session, "command", side_effect=guarded_command):
                self.run_widget_probe(TERMINAL_UI_PROBE)
            self.assertEqual(actions, ["save"])
            self.assertFalse(session.authority_usable)
        finally:
            original_control.close()
            parent.close()
            peer.close()

    def run_widget_probe(self, probe_source):
        bundle = Path(os.environ.get("KOREADER_NATIVE_BUNDLE",
            "/gnu/store/p9wkiddhvifzwbm7rg82wamgipd9rgp9-koreader-bin-2026.03"))
        self.assertTrue((bundle / "lib/koreader/luajit").exists(), "cached real-widget input missing")
        session = self.session
        probe = self.root / "ko/plugins/editorintegration.koplugin"
        probe.mkdir(mode=0o700)
        (probe / "_meta.lua").write_text('return {name="editorintegration",fullname="Editor integration fixture",description="Offscreen test controller"}\n')
        (probe / "main.lua").write_text(probe_source)
        old = {name: os.environ.get(name) for name in ("KOREADER_NATIVE_BUNDLE", "SDL_VIDEODRIVER")}
        try:
            os.environ["KOREADER_NATIVE_BUNDLE"] = str(bundle)
            os.environ["SDL_VIDEODRIVER"] = "offscreen"
            deadline = time.monotonic() + 45
            with (self.root / "reader.log").open("w") as log, contextlib.redirect_stderr(log):
                try:
                    result = native.run_reader(session, self.root, 40,
                                               lambda: time.monotonic() >= deadline)
                except EOFError:
                    # The real UI's successful quit can close FD before the
                    # subprocess exit status becomes observable.
                    result = 0
            marker = self.root / "home/editor-integration-result"
            diagnostic = (self.root / "reader.log").read_text()[-12000:]
            self.assertTrue(marker.exists(), diagnostic)
            self.assertEqual(marker.read_text(), "ok", diagnostic)
            self.assertEqual(result, 0, diagnostic)
        finally:
            for key, value in old.items():
                if value is None:
                    os.environ.pop(key, None)
                else:
                    os.environ[key] = value


REAL_UI_PROBE = r'''
local Loader = require("pluginloader")
local UI = require("ui/uimanager")
local Container = require("ui/widget/container/widgetcontainer")
local Probe = Container:extend{name="editorintegration",is_doc_only=true}
local function dismiss()
    for i=1,8 do
        local top=UI:getTopmostVisibleWidget()
        if top and top.text and not top.ok_text then UI:close(top) else break end
    end
end
function Probe:await(predicate) coroutine.yield(predicate) end
function Probe:run()
    local p=assert(Loader:getPluginInstance("bookworkbencheditor"),"production plugin absent")
    dismiss()
    p:_open()
    self:await(function() return p.form and not p.pending end)
    assert(p.editor_dialog and p.editor_dialog:isTextEditable(),"native InputDialog absent")
    assert(p.form.title=="Source Workbench","seed title")
    local initial_title_height=p.editor_dialog.title_bar:getHeight()
    local title="UI authored R1\nSecond line\nThird line"
    local source=p.editor_dialog:getInputText():gsub('"Source Workbench"','"'..title..'"')
    local function click(id)
        dismiss()
        for i,a in ipairs(p.form.actions) do
            if a.id==id then
                local b=assert(p.editor_dialog.button_table:getButtonById("authored_"..i))
                assert(b.enabled,"native action disabled")
                b.callback(); return
            end
        end
        error("missing authored action "..id)
    end
    -- Full replacement is setup only: without a native Save callback,
    -- setInputText(...,true) does not prove the edited callback was called.
    p.editor_dialog:setInputText(source,false,false)
    p.editor_dialog._input_widget:goToEnd()
    local serial=p.edit_serial
    p.editor_dialog:addTextToInput("\n;;; Native edit callback proof\n")
    assert(p.edit_serial>serial,"real addTextToInput did not advance edit_serial")
    source=p.editor_dialog:getInputText()
    click("save")
    self:await(function() return not p.pending end)
    assert(p.form.status=="Draft saved.",p.form.status)
    local function edit_away_back()
        local editor=p.editor_dialog
        local before=editor:getInputText()
        local serial=p.edit_serial
        editor._input_widget:goToEnd()
        editor:addTextToInput("x")
        assert(p.edit_serial>serial,"real insertion did not notify plugin")
        local inserted=p.edit_serial
        editor._input_widget:delChar()
        assert(p.edit_serial>inserted,"real deletion did not notify plugin")
        assert(editor:getInputText()==before,"native edit-away/back did not restore bytes")
        return before
    end
    -- The event loop cannot deliver the response until this coroutine yields.
    -- The actual authored response transforms the text, so accidental late
    -- replacement cannot pass simply because both values happen to be equal.
    click("insert-header")
    assert(p.pending,"transformation must still be pending")
    local retained=edit_away_back()
    self:await(function() return not p.pending end)
    assert(p.form.text~=retained,"authored transformation did not change its result")
    assert(p.editor_dialog:getInputText()==retained,"late result replaced edited-away/back draft")
    print("EDITOR_REAL_UI: native-edit-away-back/late-transform")
    click("preview")
    self:await(function() return p.preview_editor ~= nil end)
    local candidate=p.preview_editor
    assert(candidate.editor_dialog.title:find("Disposable preview",1,true),"trusted preview chrome absent")
    local original=p
    p=candidate
    p.editor_dialog:setInputText("disposable native widget draft",false,false)
    p.editor_dialog:addTextToInput("!")
    click("save")
    self:await(function() return not p.pending end)
    click("read")
    self:await(function() return not p.pending end)
    assert(p.form.text:find("disposable native widget draft",1,true),"candidate read/save not local")
    local stale_finish=p.editor_dialog.button_table:getButtonById("host_preview_finish").callback
    stale_finish()
    p=original
    self:await(function() return not p.pending end)
    assert(p.form.status:find("interactive preview accepted",1,true),p.form.status)
    assert(p.editor_dialog:getInputText()==retained,"candidate replaced author draft")
    print("EDITOR_REAL_UI: interactive-preview/read-save/finish")
    click("install")
    self:await(function() return p.confirmation_box~=nil end)
    local confirm=p.confirmation_box
    assert(confirm.ok_text=="Install","real trusted ConfirmBox absent")
    local stale_confirm=confirm.ok_callback
    retained=edit_away_back()
    assert(not p.confirmation and p.pending,"edit must retire confirmation and send cancellation")
    local cancelled_sequence=p.sequence
    stale_confirm()
    assert(p.sequence==cancelled_sequence,"retired confirmation callback sent a decision")
    self:await(function() return not p.pending end)
    assert(p.form.status=="Installation cancelled.",p.form.status)
    assert(p.editor_dialog:getInputText()==retained,"late cancellation replaced edited draft")
    print("EDITOR_REAL_UI: native-edit-away-back/stale-confirmation")
    click("preview")
    self:await(function() return p.preview_editor ~= nil end)
    candidate=p.preview_editor
    local sequence=p.sequence
    stale_finish()
    assert(p.preview_editor==candidate and p.sequence==sequence,"stale Finish affected later preview")
    candidate.editor_dialog.button_table:getButtonById("host_preview_finish").callback()
    self:await(function() return not p.pending end)
    click("install")
    self:await(function() return p.confirmation_box~=nil end)
    confirm=p.confirmation_box
    confirm.ok_callback()
    UI:close(confirm)
    self:await(function() return not p.pending end)
    assert(p.form.status=="Installation installed.",p.form.status)
    dismiss()
    local old_editor=p.editor_dialog
    local stale_close=old_editor.button_table:getButtonById("host_close").callback
    assert(old_editor:onCloseDialog(),"native Back did not dispatch trusted Close")
    assert(not p.editor_dialog,"native Back did not retire editor")
    p:_open()
    self:await(function() return p.form and not p.pending end)
    assert(p.form.title==title,"reopened source did not define multiline title")
    local reopened=p.editor_dialog
    stale_close()
    assert(p.editor_dialog==reopened and UI:isWidgetShown(reopened),"stale Close retired reopened editor")
    print("EDITOR_REAL_UI: native-Back/stale-Close")
    dismiss()
    p.editor_dialog:toggleKeyboard(false)
    local editor=p.editor_dialog
    assert(editor.title_bar:getHeight()>initial_title_height,"multiline title did not grow")
    local content_height=editor.title_bar:getHeight()+editor._input_widget:getSize().h
        +editor.button_table:getSize().h
    assert(editor.vgroup:getSize().h>=content_height,"multiline title bypassed parent layout")
    assert(editor.dialog_frame:getSize().h<=editor.screen_height,"multiline title overflowed native screen")
    print("EDITOR_REAL_UI: multiline-title/native-height")
    local painted=false
    local inherited=p.editor_dialog.paintTo
    p.editor_dialog.paintTo=function(w,...)
        inherited(w,...)
        if w:getInputText():find("UI authored R1",1,true) then painted=true end
    end
    UI:setDirty(p.editor_dialog,"ui")
    self:await(function() return painted end)
    local channel=p.channel
    local inherited_wait,calls,elapsed=channel.waitEvent,0,false
    channel.waitEvent=function(c,...) calls=calls+1;return inherited_wait(c,...) end
    UI:scheduleIn(0.12,function() elapsed=true end)
    self:await(function() return elapsed end)
    channel.waitEvent=inherited_wait
    assert(calls==0,"idle open editor still polls its private channel")
    print("EDITOR_REAL_UI: open-idle/no-polls")
    assert(p.editor_dialog:onCloseDialog(),"reopened native Back failed")
end
function Probe:step()
    local ok,err=pcall(function()
        if self.waiting and not self.waiting() then return end
        self.waiting=nil
        local resumed,predicate=coroutine.resume(self.worker)
        assert(resumed,predicate)
        self.waiting=predicate
        if coroutine.status(self.worker)=="dead" then
            local f=assert(io.open(os.getenv("HOME").."/editor-integration-result","w"))
            f:write("ok");f:close();self.done=true;UI:quit(0)
        end
    end)
    if not ok then
        print("EDITOR_REAL_UI_FAIL: "..tostring(err));self.done=true;UI:quit(1)
    elseif not self.done then UI:scheduleIn(0.01,function() self:step() end) end
end
function Probe:onReaderReady()
    self.worker=coroutine.create(function() self:run() end)
    UI:nextTick(function() self:step() end)
end
return Probe
'''


CHAIN_UI_PROBE = REAL_UI_PROBE[:REAL_UI_PROBE.index("function Probe:run()")] + r'''
function Probe:run()
    local p=assert(Loader:getPluginInstance("bookworkbencheditor"))
    dismiss(); p:_open()
    self:await(function() return p.form and not p.pending end)
    local function click(id)
        dismiss()
        for i,a in ipairs(p.form.actions) do
            if a.id==id then
                local button=assert(p.editor_dialog.button_table:getButtonById("authored_"..i))
                assert(button.enabled); button.callback(); return
            end
        end
        error("missing action "..id)
    end
    local function finish()
        dismiss()
        local candidate=assert(p.preview_editor)
        local button=assert(candidate.editor_dialog.button_table:getButtonById("host_preview_finish"))
        assert(button.enabled); button.callback()
        return button.callback
    end
    local function edit(s)
        local serial=p.edit_serial
        p.editor_dialog._input_widget:goToEnd()
        p.editor_dialog:addTextToInput(s)
        assert(p.edit_serial>serial,"native author edit callback missing")
        return p.editor_dialog:getInputText()
    end
    -- One authored action: preview -> Finish -> install -> Confirm -> another
    -- preview -> Finish -> final presentation with the original action identity.
    click("insert-header")
    self:await(function() return p.preview_editor~=nil end)
    local original=p.preview_origin
    local stale=finish()
    self:await(function() return p.confirmation_box~=nil end)
    assert(p.confirmation.origin==original,"proposal lost original authored action")
    local box=p.confirmation_box
    box.ok_callback(); UI:close(box)
    self:await(function() return p.preview_editor~=nil end)
    assert(p.preview_origin==original,"decision-to-preview changed origin")
    stale(); assert(p.preview_editor,"stale Finish retired continuation preview")
    finish()
    self:await(function() return not p.pending end)
    assert(not p.disconnected and p.form.action_id=="insert-header" and p.form.status=="installed",p.last_error)
    assert(p.editor_dialog:getInputText():find("transformed chain",1,true),"final chain transformation lost")
    print("EDITOR_REAL_UI: preview/finish/install/confirm/preview/finish/present")
    -- Two previews in one authored action. Real late edits in the underlying
    -- author widget must survive both candidate widgets and the final response.
    click("successor")
    self:await(function() return p.preview_editor~=nil end)
    original=p.preview_origin
    edit("\n; author edited during first preview")
    stale=finish()
    self:await(function() return p.preview_editor~=nil end)
    assert(p.preview_origin==original,"second preview did not retain root origin")
    local candidate=p.preview_editor
    stale(); assert(p.preview_editor==candidate,"retired first preview affected second")
    local retained=edit("\n; author edited during second preview")
    finish()
    self:await(function() return not p.pending end)
    assert(p.form.action_id=="successor" and p.form.status=="double preview complete")
    assert(p.editor_dialog:getInputText()==retained,"double preview replaced late author edits")
    assert(p.form.text~=retained,"fixture final response did not transform")
    print("EDITOR_REAL_UI: double-preview/original-edit-serial")
    -- A late edit makes a chained proposal stale. Auto-decline must preserve
    -- that same origin through decision -> preview -> Finish -> presentation.
    click("insert-header")
    self:await(function() return p.preview_editor~=nil end)
    retained=edit("\n; decline stale chained installation")
    finish()
    self:await(function() return p.preview_editor~=nil end)
    assert(not p.confirmation_box,"stale chained installation was offered")
    finish()
    self:await(function() return not p.pending end)
    assert(not p.disconnected and p.form.status=="cancelled",p.last_error)
    assert(p.editor_dialog:getInputText()==retained,"chained cancellation erased late edits")
    print("EDITOR_REAL_UI: chained-proposal/late-edit/auto-cancel")
    dismiss(); assert(p.editor_dialog:onCloseDialog())
end
''' + REAL_UI_PROBE[REAL_UI_PROBE.index("function Probe:step()"):]


TERMINAL_UI_PROBE = REAL_UI_PROBE[:REAL_UI_PROBE.index("function Probe:run()")] + r'''
function Probe:run()
    local p=assert(Loader:getPluginInstance("bookworkbencheditor"))
    dismiss(); p:_open()
    self:await(function() return p.form and not p.pending end)
    local function click(id)
        dismiss()
        for i,a in ipairs(p.form.actions) do
            if a.id==id then
                local button=assert(p.editor_dialog.button_table:getButtonById("authored_"..i))
                assert(button.enabled); button.callback(); return
            end
        end
        error("missing action "..id)
    end
    p.editor_dialog:setInputText("unsaved terminal-backend draft",false,false)
    p.editor_dialog._input_widget:goToEnd()
    local serial=p.edit_serial
    p.editor_dialog:addTextToInput("\n; native local edit")
    assert(p.edit_serial>serial,"native edit callback absent")
    local retained=p.editor_dialog:getInputText()
    click("save")
    self:await(function() return not p.pending end)
    assert(p.last_error and not p.disconnected,"backend retirement disconnected the UI")
    assert(p.editor_dialog:getInputText()==retained,"initial timeout erased unsaved draft")
    p.editor_dialog._input_widget:goToEnd()
    p.editor_dialog:addTextToInput("\n; edited after backend timeout")
    retained=p.editor_dialog:getInputText()
    click("read")
    self:await(function() return not p.pending end)
    assert(p.last_error and not p.disconnected,"post-timeout Action killed UI connection")
    assert(p.editor_dialog:getInputText()==retained,"post-timeout Action erased local draft")
    dismiss()
    assert(p.editor_dialog:onCloseDialog())
    assert(not p.editor_dialog,"native Close did not retire local view")
    p:_open()
    self:await(function() return not p.pending end)
    assert(p.last_error and not p.disconnected,"post-timeout Open killed UI connection")
    assert(p.editor_dialog:getInputText()==retained,"Close/Open lost terminal-backend draft")
    assert(p.editor_dialog:isTextEditable(),"terminal backend made local draft inaccessible")
    assert(not p.registered,"terminal view retained idle channel polling")
    p.editor_dialog._input_widget:goToEnd()
    serial=p.edit_serial
    p.editor_dialog:addTextToInput("\n; editable after reopen")
    assert(p.edit_serial>serial,"reopened terminal draft no longer editable")
    print("EDITOR_REAL_UI: main-authority-timeout/action/close/open/draft-retained")
    dismiss(); assert(p.editor_dialog:onCloseDialog())
end
''' + REAL_UI_PROBE[REAL_UI_PROBE.index("function Probe:step()"):]


if __name__ == "__main__":
    unittest.main(verbosity=2)
