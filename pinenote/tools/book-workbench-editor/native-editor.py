#!/usr/bin/env python3
"""Source-defined editor coordinator with an explicitly selected execution owner.

The trusted-native fixture provides no containment; the immutable sandbox owner
is a separate backend with mandatory readiness, cleanup and terminal verdicts.

The Guile authority owns durable state and typed grants. This coordinator never
interprets Scheme; it passes source snapshots only to the child runner. FD3 uses
BookProtocol framing, with closed editor/workspace successor message families.
"""
import argparse
import ctypes
import hashlib
import os
from pathlib import Path
import select
import shutil
import signal
import socket
import stat
import subprocess
import sys
import tempfile
import time

TOOL = Path(__file__).resolve().parent
TEMP_PARENT = Path("/tmp/opencode")
DEFAULT_SUPERVISOR = Path("/gnu/store/nlkcijvhrj9xfz4dz134iwlc9z52mb4s-wilkbook-book-state-device-supervisor")
DEFAULT_BUNDLE = Path("/gnu/store/p9wkiddhvifzwbm7rg82wamgipd9rgp9-koreader-bin-2026.03")
DEFAULT_GRAPHICS = Path("/gnu/store/ikfz8dkfrhijll2i929d9ws4ldz0i5qi-mesa-26.0.2")
sys.path.insert(0, str(TOOL.parent / "book-protocol"))
from book_protocol import encode_frame, FrameDecoder  # noqa: E402

LIVE = set()


class CleanupError(RuntimeError):
    """Execution cleanup was not proved; never a failed-preview receipt."""


class PrivateTree:
    """Exclusive fixture directory with bounded, incremental cleanup."""
    def __init__(self, prefix):
        self.name = tempfile.mkdtemp(prefix=prefix, dir=TEMP_PARENT)

    def cleanup(self):
        deadline = time.monotonic() + 2

        def remove(path):
            if time.monotonic() >= deadline:
                raise CleanupError(f"native runtime cleanup incomplete; retained {self.name}")
            try:
                info = path.lstat()
            except FileNotFoundError:
                return
            if stat.S_ISDIR(info.st_mode):
                # Descendants are already dead. Never follow a symlink left by
                # the fixture and never enumerate a whole directory at once.
                with os.scandir(path) as entries:
                    for entry in entries:
                        remove(Path(entry.path))
                path.rmdir()
            else:
                path.unlink()
        remove(Path(self.name))

    def __enter__(self):
        return self.name

    def __exit__(self, exception_type, *_):
        if exception_type is None:
            self.cleanup()
        else:
            print(f"native runtime retained after failure: {self.name}", file=sys.stderr)


def private_directory(path):
    info = path.lstat()
    if (not path.is_absolute() or path.resolve() != path
            or not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid()
            or stat.S_IMODE(info.st_mode) != 0o700
            or any(ord(c) < 32 for c in str(path))):
        raise ValueError(f"expected canonical user-owned mode-0700 directory: {path}")
    return path


def environment(root, supervisor):
    for name in ("home", "home/.config", "home/.cache", "home/.local/share", "ko/plugins", "tmp"):
        (root / name).mkdir(mode=0o700, parents=True, exist_ok=True)
    return {"HOME": str(root / "home"), "KO_HOME": str(root / "ko"), "KO_MULTIUSER": "1",
            "XDG_CONFIG_HOME": str(root / "home/.config"),
            "XDG_CACHE_HOME": str(root / "home/.cache"),
            "XDG_DATA_HOME": str(root / "home/.local/share"),
            "TMPDIR": str(root / "tmp"), "LANG": "C.UTF-8", "LC_ALL": "C.UTF-8",
            "PATH": str(supervisor / "bin"), "GUILE_AUTO_COMPILE": "0",
            "GUILE_LOAD_PATH": ":".join(map(str, (TOOL, TOOL.parent / "book-workbench",
                TOOL.parent / "book-protocol", supervisor / "share/guile/site/3.0"))),
            "GUILE_LOAD_COMPILED_PATH": str(supervisor / "lib/guile/3.0/site-ccache")}


def reader_inputs():
    """Validate explicit cached reader/graphics inputs before native acquisition."""
    def directory(name, default):
        path = Path(os.environ.get(name, default))
        if not path.is_absolute() or not path.is_dir():
            raise ValueError(f"{name} must name an existing absolute cached directory: {path}")
        return path.resolve(strict=True)

    reader = directory("KOREADER_NATIVE_BUNDLE", DEFAULT_BUNDLE) / "lib/koreader"
    if not (reader / "reader.lua").is_file() or not os.access(reader / "luajit", os.X_OK):
        raise ValueError(f"KOREADER_NATIVE_BUNDLE is missing reader.lua or executable luajit: {reader}")
    graphics = None
    if os.environ.get("SDL_VIDEODRIVER") != "offscreen":
        graphics = directory("BOOK_WORKBENCH_GRAPHICS", DEFAULT_GRAPHICS)
        for name in ("libEGL.so.1", "libGLESv2.so.2"):
            path = graphics / "lib" / name
            if not path.is_file():
                raise ValueError(f"BOOK_WORKBENCH_GRAPHICS is missing {path}; select a cached Mesa output")
    return reader, graphics


def subreaper():
    if ctypes.CDLL(None, use_errno=True).prctl(36, 1, 0, 0, 0) != 0:
        raise OSError(ctypes.get_errno(), "PR_SET_CHILD_SUBREAPER")


def status(process):
    info = os.waitid(os.P_PID, process.pid, os.WEXITED | os.WNOHANG | os.WNOWAIT)
    return None if info is None else info.si_status


def kill_group(process):
    # Keep the leader unreaped until group kill, avoiding recycled PGIDs.
    try:
        os.killpg(process.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    try:
        os.kill(process.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    process.wait(timeout=2)
    LIVE.discard(process.pid)
    # Only reap the trusted process's own group. Authored executions instead
    # have dedicated owners; never classify global children by subtraction.
    deadline = time.monotonic() + 2
    while True:
        try:
            pid, _ = os.waitpid(-process.pid, os.WNOHANG)
        except ChildProcessError:
            return
        if pid:
            continue
        if time.monotonic() >= deadline:
            raise CleanupError("trusted process-group cleanup incomplete")
        time.sleep(0.005)


class Channel:
    """Incremental bounded frames. Partial frames never extend the caller clock."""
    def __init__(self, sock):
        self.sock = sock
        sock.setblocking(False)
        self.buffer = bytearray()

    def send(self, message, timeout=2):
        self.send_bytes(encode_frame(message), timeout)

    def send_bytes(self, data, timeout=2):
        deadline = time.monotonic() + timeout
        view = memoryview(data)
        while view:
            remaining = deadline - time.monotonic()
            if remaining <= 0 or not select.select([], [self.sock], [], remaining)[1]:
                raise TimeoutError("bounded frame output timed out")
            try:
                count = self.sock.send(view)
            except BlockingIOError:
                continue
            if not count:
                raise EOFError("closed frame output")
            view = view[count:]

    def receive(self, timeout=0):
        deadline = time.monotonic() + timeout
        while True:
            if len(self.buffer) >= 4:
                length = int.from_bytes(self.buffer[:4], "big")
                if not 0 < length <= 65536:
                    raise ValueError("invalid BookProtocol frame length")
                if len(self.buffer) >= length + 4:
                    payload = bytes(self.buffer[4:length + 4])
                    del self.buffer[:length + 4]
                    decoder = FrameDecoder()
                    message, = list(decoder.feed(length.to_bytes(4, "big") + payload))
                    decoder.finish()
                    return message, payload
            remaining = max(0, deadline - time.monotonic())
            if not select.select([self.sock], [], [], remaining)[0]:
                return None
            # At most one maximum frame plus a small read-ahead chunk retained.
            data = self.sock.recv(4096)
            if not data:
                raise EOFError("frame input closed")
            self.buffer.extend(data)
            if len(self.buffer) > 65540 + 4096:
                raise ValueError("input buffer bound exceeded")

    def close(self):
        self.sock.close()

    def frame_buffered(self):
        if len(self.buffer) < 4:
            return False
        length = int.from_bytes(self.buffer[:4], "big")
        return not 0 < length <= 65536 or len(self.buffer) >= length + 4


class EditorSession:
    def __init__(self, workspace, root, supervisor, *, seed=None, access="author",
                 startup_timeout=None, action_timeout=10, preview_mode="interactive",
                 sandbox_command=None):
        if preview_mode not in ("interactive", "smoke"):
            raise ValueError("invalid preview mode")
        self.sandbox_command = None
        if sandbox_command is not None:
            command = Path(sandbox_command)
            info = command.stat()
            if (not command.is_absolute() or command.resolve(strict=True) != command
                    or not str(command).startswith("/gnu/store/")
                    or not stat.S_ISREG(info.st_mode) or info.st_mode & 0o222
                    or not os.access(command, os.X_OK)):
                raise ValueError("sandbox_command must be an immutable canonical Guix store executable")
            self.sandbox_command = command
        self.preview_mode = preview_mode
        if startup_timeout is None:
            startup_timeout = 20 if self.sandbox_command else 3
        self.root, self.supervisor = root, supervisor
        self.guile = str(supervisor / "bin/guile")
        self.env = environment(root, supervisor)
        self.env["BOOK_SESSION_FD"] = "3"
        self.startup_timeout, self.action_timeout = startup_timeout, action_timeout
        self.deadline = None
        self.child = self.child_channel = self.authority = None
        self.child_control = None
        self.owner_buffer = bytearray()
        self.owner_ready = False
        self.owner_clean = False
        self.owner_diagnostic = None
        self.owner_exit_status = None
        self.source_file = None
        self.ui_events = []
        self.preview = None
        self.preview_root = None
        self.preview_id = None
        self.preview_failure = None
        self.form = self.proposal = self.snapshot = None
        self.failure = None
        self.revision_count = 0
        self.access = access
        self.backend_busy = False
        self.authority_usable = True
        self.failing = False
        parent, donated = socket.socketpair()
        self.control = Channel(parent)
        # Distinct ABI identity prevents opening old text-function stores. The
        # pinned Guix output identity remains part of every revision digest.
        identity = "workbench-editor-v1-" + supervisor.name
        if self.sandbox_command:
            # The immutable command captures the supervisor/execution closure.
            # Keep the environment identity below the workspace's 128-byte cap.
            identity = "workbench-editor-v1-sandbox-" + hashlib.sha256(
                os.fsencode(self.sandbox_command)).hexdigest()
        try:
            with donated:
                self.authority = subprocess.Popen(
                    [self.guile, "--no-auto-compile", str(TOOL / "editor-authority.scm"),
                     "--workspace-authority" if self.sandbox_command else "--trusted-native-fixture",
                     str(donated.fileno()), str(workspace),
                     str(seed or TOOL / "editor-seed.scm"), identity, access],
                    pass_fds=(donated.fileno(),), env=self.env, cwd=root,
                    stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                    stderr=None, start_new_session=True)
                LIVE.add(self.authority.pid)
            self.command("host-start")
            if not self.authority_usable:
                raise ValueError(self.failure or "authority startup failed")
        except BaseException:
            self.close()
            raise

    def rpc(self, message=None, raw=None):
        if not self.authority_usable:
            raise ValueError("authority transport retired; reopen a new session")
        if self.expire_if_due() and (raw is not None or (message and message["type"] == "host-poll")):
            return
        try:
            if raw is not None:
                self.control.send_bytes(len(raw).to_bytes(4, "big") + raw, self.io_budget(2))
            else:
                self.control.send(message, self.io_budget(2))
            answer = self.control.receive(self.io_budget(7))
            if answer is None:
                raise TimeoutError("authority operation deadline expired")
        except (OSError, EOFError, TimeoutError, ValueError) as error:
            self.retire_authority_transport(str(error))
            return
        except BaseException:
            self.retire_authority_transport("authority exchange interrupted")
            raise
        reply = answer[0]
        if "error" in reply:
            raise ValueError(reply["error"])
        self.backend_busy = reply["busy"]
        # Even an empty event response cannot conceal an expired active clock.
        # This complete reply is synchronized, so ordinary revocation is safe.
        self.expire_if_due()
        if not self.authority_usable:
            return
        for event in reply["events"]:
            if event["target"] in ("child", "ui", "preview"):
                # Receipt publication is a separate deadline boundary: the
                # authority may have completed work while this host was delayed.
                if self.expire_if_due() or self.failure:
                    continue
            self.event(event["target"], event["message"])

    def io_budget(self, maximum):
        if self.deadline is None:
            return maximum
        remaining = self.deadline - time.monotonic()
        if remaining <= 0:
            raise TimeoutError("authored startup/action deadline expired")
        return min(maximum, remaining)

    def retire_authority_transport(self, diagnostic):
        # An incomplete exchange has no correlation ID. Close it permanently:
        # neither host-retire nor a later snapshot may consume its stale reply.
        # Killing this authority may interrupt an admitted SQLite transaction;
        # an already committed write remains committed, never claimed undone.
        self.authority_usable = False
        self.backend_busy = False
        self.control.close()
        if self.authority is not None:
            try:
                kill_group(self.authority)
                self.authority = None
            except Exception as error:
                raise CleanupError("retired authority cleanup incomplete") from error
        if not self.failing:
            self.fail_source(diagnostic)

    def command(self, operation, **fields):
        self.rpc(dict(type=operation, **fields))

    def event(self, target, message):
        if target == "launch":
            self.launch(message["source"])
        elif target == "stop":
            self.stop_child()
        elif target == "child":
            try:
                self.child_channel.send(message, self.io_budget(2))
                self.expire_if_due()
            except (EOFError, BrokenPipeError, ConnectionResetError,
                    ConnectionAbortedError, TimeoutError) as error:
                self.fail_source(str(error))
        elif target == "ui":
            if message["type"] == "editor-present":
                self.form = message
                self.deadline = None
            elif message["type"] == "editor-host-proposal":
                self.proposal = message
                # Human confirmation is not charged to the authored action.
                self.deadline = None
            self.ui_events.append(message)
        elif target == "snapshot":
            self.snapshot = message
        elif target == "cancel-preview":
            self.cancel_preview()
            self.preview_id = None
            self.preview_failure = None
        elif target == "preview":
            if self.preview is not None or self.access != "author":
                raise ValueError("recursive or overlapping preview")
            self.preview_id = message["id"]
            self.preview_failure = None
            # The live author is blocked in its workspace-preview operation.
            # Only the independent candidate's startup/action clocks run now.
            self.deadline = None
            self.preview_root = PrivateTree("editor-preview-")
            root = Path(self.preview_root.name)
            workspace = root / "workspace"
            workspace.mkdir(mode=0o700)
            seed = root / "candidate.scm"
            seed.write_text(message["source"], encoding="utf-8")
            try:
                self.preview = EditorSession(workspace, root, self.supervisor,
                    seed=seed, access="preview", startup_timeout=self.startup_timeout,
                    action_timeout=self.action_timeout, preview_mode=self.preview_mode,
                    sandbox_command=self.sandbox_command)
            except CleanupError:
                raise
            except Exception as error:
                self.finish_preview(False, str(error))
        else:
            raise ValueError("unknown authority event")

    def launch(self, source):
        self.stop_child()
        self.failure = self.form = self.proposal = None
        self.revision_count += 1
        fd, filename = tempfile.mkstemp(prefix="program-", suffix=".scm", dir=self.root)
        source_file = Path(filename)
        self.source_file = source_file
        # Only write opaque source bytes. No parser, evaluator or source rewrite
        # exists in the coordinator or authority.
        with os.fdopen(fd, "w", encoding="utf-8") as output:
            output.write(source)
        source_file.chmod(0o400)
        parent, donated = socket.socketpair()
        self.child_channel = Channel(parent)
        self.deadline = time.monotonic() + self.startup_timeout
        owner_control, owner_donation = socket.socketpair()
        self.child_control = owner_control
        self.owner_buffer.clear()
        self.owner_ready = not bool(self.sandbox_command)
        self.owner_clean = False
        self.owner_diagnostic = None
        self.owner_exit_status = None
        argv = ([str(self.sandbox_command), str(owner_donation.fileno()), str(source_file)]
                if self.sandbox_command else
                [sys.executable, "-I", "-S", str(TOOL / "native-child-owner.py"),
                 str(owner_donation.fileno()), self.guile,
                 str(TOOL / "workbench-editor-runner.scm"),
                 str(source_file), str(TOOL.parent / "book-protocol")])
        with donated, owner_donation:
            self.child = subprocess.Popen(
                argv,
                stdin=donated, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                pass_fds=(owner_donation.fileno(),), start_new_session=True,
                env=self.env, cwd=self.root)
            LIVE.add(self.child.pid)

    def cancel_preview(self):
        if self.preview is not None:
            self.preview.close()
            self.preview = None
        if self.preview_root is not None:
            self.preview_root.cleanup()
            self.preview_root = None

    def finish_preview(self, ok, diagnostic=None):
        # No preview receipt reaches the live delegate until complete execution
        # cleanup; cleanup exceptions therefore cannot authorize installation.
        if self.preview_id is None:
            raise ValueError("no pending preview")
        if ok and self.preview is not None:
            # Finish can arrive before the next host pump. Observe queued errors
            # and expired candidate work before issuing a successful receipt.
            self.preview.pump()
            if self.preview.failure:
                self.preview_failure = self.preview.failure
        if self.preview_failure:
            ok, diagnostic = False, self.preview_failure
        if ok and (self.preview is None or not self.preview.form
                   or self.preview.deadline is not None):
            raise ValueError("cannot accept busy or failed preview")
        if diagnostic is None:
            diagnostic = self.preview_failure or ("interactive preview accepted; child reaped"
                if ok else "interactive preview cancelled")
        candidate = self.preview
        self.cancel_preview()
        if ok and candidate is not None and candidate.sandbox_command and candidate.owner_exit_status != 0:
            # clean proves disposal, not successful execution. The owner can
            # discover failure after the final pump, during teardown itself.
            ok = False
            diagnostic = "sandbox execution owner failed (exit status %s)" % candidate.owner_exit_status
            if candidate.owner_diagnostic:
                diagnostic += ": " + candidate.owner_diagnostic
        self.deadline = time.monotonic() + self.action_timeout
        self.command("host-preview-result", id=self.preview_id, ok=ok,
                     diagnostic=("editor preview: " + diagnostic)[:512])
        self.preview_id = None
        self.preview_failure = None

    def pump(self):
        if self.authority is not None and status(self.authority) is not None:
            self.retire_authority_transport("editor authority exited")
            return
        if self.expire_if_due():
            return
        if self.preview is not None:
            self.preview.pump()
            if self.preview.failure:
                diagnostic = self.preview.failure
                if self.preview_mode == "smoke" or not self.preview.form:
                    self.finish_preview(False, diagnostic)
                else:
                    self.cancel_preview()
                    self.preview_failure = diagnostic
            elif self.preview.form and self.preview_mode == "smoke":
                self.finish_preview(True, "initial editor form accepted; child reaped")
        if self.child_control is not None and self.sandbox_command:
            self.read_owner_control()
            if self.owner_clean:
                # Preparation may fail before ready, or a running domain may
                # end while its last frames are buffered. Neither can authorize
                # more source work after the owner's exact cleanup record.
                self.fail_source("sandbox execution ended" if self.owner_ready
                                 else "sandbox execution ended before readiness")
                return
        if self.child_channel is not None and self.owner_ready:
            try:
                for _ in range(16):
                    if self.expire_if_due():
                        break
                    incoming = self.child_channel.receive()
                    if incoming is None:
                        break
                    message, raw = incoming
                    # Critical origin split: child bytes cannot invoke private
                    # coordinator controls, confirmation, recovery or snapshots.
                    family = message.get("type")
                    if not isinstance(family, str) or family not in {
                            "hello", "editor-present", "workspace-read", "workspace-save",
                            "workspace-preview", "workspace-install-propose", "workspace-export"}:
                        raise ValueError("forbidden child message family")
                    self.rpc(raw=raw)
                    if self.failure:
                        break
            except (EOFError, ValueError, TimeoutError, BrokenPipeError,
                    ConnectionResetError, ConnectionAbortedError) as error:
                self.fail_source(str(error))
        if self.backend_busy and self.preview_id is None:
            self.command("host-poll")

    def fail_source(self, diagnostic):
        self.failure = diagnostic
        self.deadline = None
        self.failing = True
        # Revoke first. Cleanup errors must propagate, rather than become an
        # ordinary failed candidate and accidentally authorize a fresh trial.
        try:
            if self.authority_usable:
                self.command("host-retire")
            if not self.authority_usable:
                self.cancel_preview()
                self.preview_id = self.preview_failure = None
        finally:
            try:
                self.stop_child()
            finally:
                self.failing = False
        if self.owner_diagnostic:
            diagnostic += "; sandbox owner: " + self.owner_diagnostic
        if self.sandbox_command and self.owner_exit_status not in (None, 0):
            diagnostic += "; sandbox owner exit status " + str(self.owner_exit_status)
        self.failure = diagnostic.replace("\0", "").encode("utf-8", "replace")[:2048].decode("utf-8", "ignore")
        self.ui_events.append({"type": "editor-host-status", "text": self.failure})

    def expire_if_due(self):
        if self.deadline is None or time.monotonic() < self.deadline:
            return False
        self.fail_source("authored startup/action deadline expired")
        return True

    def wait_ready(self, *, extra=(), maximum=0.2, buffered=False):
        """Block on real sockets, bounded by work deadlines and child-exit checks.

        Guile worker completion currently has no wake descriptor, so only an
        active worker uses the short poll. Human idle and closed views do not.
        """
        readers = list(extra)
        timeout = max(0, maximum)
        now = time.monotonic()

        def include(session):
            nonlocal timeout
            if session.control.sock.fileno() >= 0:
                readers.append(session.control.sock)
            if session.child_channel is not None:
                if session.owner_ready:
                    readers.append(session.child_channel.sock)
                if session.owner_ready and session.child_channel.frame_buffered():
                    timeout = 0
            if session.child_control is not None and session.sandbox_command and not session.owner_clean:
                readers.append(session.child_control)
            if session.backend_busy and session.preview_id is None:
                timeout = min(timeout, 0.01)
            if session.deadline is not None:
                timeout = min(timeout, max(0, session.deadline - now))
            if session.preview is not None:
                include(session.preview)

        include(self)
        if buffered:
            timeout = 0
        return bool(select.select(readers, [], [], timeout)[0])

    def action(self, action_id, text=None):
        previous = self.deadline
        self.deadline = time.monotonic() + self.action_timeout
        try:
            self.command("host-action", action_id=action_id,
                         text=self.form["text"] if text is None else text)
        except Exception:
            if not self.failure:
                self.deadline = previous
            raise

    def confirm(self, proposal_id=None):
        previous = self.deadline
        self.deadline = time.monotonic() + self.action_timeout
        try:
            self.command("host-confirm", proposal_id=proposal_id or self.proposal["proposal_id"])
        except Exception:
            if not self.failure:
                self.deadline = previous
            raise
        self.proposal = None

    def cancel(self):
        self.deadline = time.monotonic() + self.action_timeout
        self.command("host-cancel", proposal_id=self.proposal["proposal_id"])
        self.proposal = None

    def read_owner_control(self):
        """Bounded exact owner records, retaining coalesced ready+clean."""
        if self.owner_clean:
            return
        if not select.select([self.child_control], [], [], 0)[0]:
            return
        try:
            part = self.child_control.recv(33)
        except ConnectionResetError:
            part = b""
        if not part:
            raise CleanupError("child owner exited without cleanup acknowledgement")
        self.owner_buffer.extend(part)
        if len(self.owner_buffer) > 32:
            raise CleanupError("invalid child owner control framing")
        while b"\n" in self.owner_buffer:
            line, _, rest = self.owner_buffer.partition(b"\n")
            self.owner_buffer = bytearray(rest)
            if line == b"ready" and self.sandbox_command and not self.owner_ready:
                self.owner_ready = True
            elif line == b"clean" and not self.owner_clean:
                self.owner_clean = True
            else:
                raise CleanupError("invalid child owner acknowledgement")
        if self.owner_clean and self.owner_buffer:
            raise CleanupError("trailing child owner acknowledgement bytes")

    def stop_child(self):
        if self.child is not None:
            deadline = time.monotonic() + (12 if self.sandbox_command else 3)
            self.child_control.settimeout(0.2)
            try:
                self.child_control.sendall(b"stop\n")
            except (BrokenPipeError, ConnectionResetError):
                pass
            while not self.owner_clean:
                remaining = deadline - time.monotonic()
                if remaining <= 0 or not select.select([self.child_control], [], [], remaining)[0]:
                    raise CleanupError("child owner cleanup incomplete; owner retained")
                self.read_owner_control()
            try:
                self.owner_exit_status = self.child.wait(timeout=max(0.01, deadline - time.monotonic()))
            except subprocess.TimeoutExpired as error:
                raise CleanupError("child owner did not exit after cleanup acknowledgement") from error
            if self.sandbox_command:
                self.owner_diagnostic = self.read_owner_diagnostic()
            LIVE.discard(self.child.pid)
            self.child = None
        if self.child_control is not None:
            self.child_control.close()
            self.child_control = None
        if self.child_channel is not None:
            self.child_channel.close()
            self.child_channel = None
        if self.source_file is not None:
            self.source_file.unlink(missing_ok=True)
            self.source_file = None
        self.deadline = None

    def read_owner_diagnostic(self):
        """Read the owner's bounded sidecar only after cleanup and owner exit.

        This is diagnostic data, never authority input. Missing or malformed
        sidecars cannot replace an execution/cleanup failure with another error.
        """
        if self.source_file is None:
            return None
        descriptor = None
        try:
            descriptor = os.open(str(self.source_file) + ".sandbox-error",
                                 os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC)
            info = os.fstat(descriptor)
            if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid()
                    or info.st_nlink != 1 or stat.S_IMODE(info.st_mode) != 0o600
                    or info.st_size > 2048):
                return None
            data = bytearray()
            while len(data) <= 2048:
                part = os.read(descriptor, 2049 - len(data))
                if not part:
                    break
                data.extend(part)
            if len(data) != info.st_size or len(data) > 2048 or b"\0" in data:
                return None
            return data.decode("utf-8") or None
        except (OSError, UnicodeError):
            return None
        finally:
            if descriptor is not None:
                os.close(descriptor)

    def close(self):
        failures = []
        try:
            if self.preview is not None:
                try:
                    self.preview.close()
                    self.preview = None
                except Exception as error:
                    failures.append(error)
            try:
                self.stop_child()
            except Exception as error:
                failures.append(error)
            if self.authority is not None:
                try:
                    if self.authority_usable:
                        self.command("host-close")
                except (OSError, EOFError, TimeoutError, ValueError):
                    pass
                finally:
                    try:
                        if self.authority is not None:
                            kill_group(self.authority)
                            self.authority = None
                    except Exception as error:
                        failures.append(error)
        finally:
            self.control.close()
            if self.preview_root is not None and self.preview is None:
                try:
                    self.preview_root.cleanup()
                    self.preview_root = None
                except Exception as error:
                    failures.append(error)
        if failures:
            raise CleanupError(str(failures[0])) from failures[0]


def main():
    parser = argparse.ArgumentParser(description="Trusted-native self-authoring editor fixture")
    backend = parser.add_mutually_exclusive_group(required=True)
    backend.add_argument("--trusted-native-fixture", action="store_true")
    backend.add_argument("--sandbox-command", type=Path,
                         help="trusted immutable Guix store execution owner")
    parser.add_argument("directory", type=Path, help="existing private mode-0700 parent")
    parser.add_argument("--idle-seconds", type=float, default=0,
                        help="opt-in protocol-inactivity timeout; 0 disables it (default). "
                             "Cannot observe unsaved local typing.")
    parser.add_argument("--recover", choices=("rollback", "seed"),
                        help="trusted recovery before opening; retain the saved draft")
    args = parser.parse_args()
    os.umask(0o077)
    subreaper()
    private_directory(args.directory)
    workspace = args.directory / "workspace"
    workspace.mkdir(mode=0o700, exist_ok=True)
    private_directory(workspace)
    supervisor = Path(os.environ.get("BOOK_WORKBENCH_SUPERVISOR", DEFAULT_SUPERVISOR)).resolve(strict=True)
    if not str(supervisor).startswith("/gnu/store/"):
        parser.error("supervisor must be an explicit pinned Guix store output")
    # A missing desktop dependency must fail before starting the authority or
    # evaluating any installed source. Offscreen runs do not require graphics.
    reader_inputs()
    if args.trusted_native_fixture:
        print("trusted-native fixture: authored Guile has your host user privileges", file=sys.stderr)
    stopped = False

    def stop(_signum, _frame):
        nonlocal stopped
        stopped = True

    for signum in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
        signal.signal(signum, stop)
    with PrivateTree("editor-native-") as name:
        root = Path(name)
        session = EditorSession(workspace, root, supervisor, sandbox_command=args.sandbox_command)
        try:
            if args.recover:
                session.command("host-recover", kind=args.recover)
            return run_reader(session, root, args.idle_seconds, lambda: stopped)
        finally:
            session.close()


def run_reader(session, root, idle_seconds, stopped):
    # The private UI schema and generic plugin are provided by SURFACE.md. Keep
    # this launcher separate from the original native Workbench demo/profile.
    reader_dir, graphics = reader_inputs()
    plugin = TOOL / "plugin/bookworkbencheditor.koplugin"
    shutil.copytree(plugin, root / "ko/plugins/bookworkbencheditor.koplugin")
    book = root / "editor.txt"
    backend = "sandboxed execution" if session.sandbox_command else "trusted-native fixture"
    book.write_text(f"Self-authoring Book Workbench — {backend}\n\n"
                    "Open More tools → Book editor (experimental).\n", encoding="utf-8")
    env = session.env.copy()
    env["PATH"] += os.pathsep + str(reader_dir)
    env["SDL_AUDIODRIVER"] = "dummy"
    for name in ("DISPLAY", "WAYLAND_DISPLAY", "XAUTHORITY", "XDG_RUNTIME_DIR",
                 "SDL_VIDEODRIVER", "SDL_AUDIODRIVER"):
        if name in os.environ:
            env[name] = os.environ[name]
    if env.get("SDL_VIDEODRIVER") != "offscreen":
        env.update(SDL_EGL_LIBRARY=str(graphics / "lib/libEGL.so.1"),
                   SDL_OPENGL_LIBRARY=str(graphics / "lib/libGLESv2.so.2"),
                   SDL_RENDER_DRIVER="opengles2")
    if "XAUTHORITY" not in env and (Path.home() / ".Xauthority").is_file():
        env["XAUTHORITY"] = str(Path.home() / ".Xauthority")
    parent, donated = socket.socketpair()
    transport = Channel(parent)
    env["BOOK_WORKBENCH_EDITOR_UI_FD"] = str(donated.fileno())
    reader = None
    try:
        with donated:
            reader = subprocess.Popen(
                [str(reader_dir / "luajit"), str(TOOL.parent / "book-workbench/desktop-reader.lua"), str(book)],
                cwd=reader_dir, env=env, pass_fds=(donated.fileno(),),
                stdin=subprocess.DEVNULL, stdout=sys.stderr, stderr=sys.stderr, start_new_session=True)
            LIVE.add(reader.pid)
        bridge = UIBridge(session, transport)
        last_activity = time.monotonic()
        while not stopped() and status(reader) is None:
            try:
                if bridge.pump():
                    last_activity = time.monotonic()
            except EOFError:
                # Closing the real document retires its private UI channel.
                # The process may not have published its exit status yet.
                break
            if idle_seconds > 0 and time.monotonic() - last_activity >= idle_seconds:
                break
            maximum = 0.2
            if idle_seconds > 0:
                maximum = min(maximum, max(0, last_activity + idle_seconds - time.monotonic()))
            session.wait_ready(extra=(transport.sock,), maximum=maximum,
                               buffered=b"\n" in bridge.buffer)
        return status(reader) or 0
    finally:
        transport.close()
        if reader is not None:
            kill_group(reader)


class UIBridge:
    """SURFACE.md's closed command|sequence|hex-JSON private channel."""
    def __init__(self, session, transport):
        self.session, self.transport = session, transport
        self.buffer = bytearray()
        self.sequence = 0
        self.pending = None
        self.view = 0
        self.ready = False
        self.token = None
        self.opened = False
        self.preview_token = None
        self.preview_view = 0
        self.preview_seen = None

    def reply(self, value):
        if self.pending is None:
            return
        data = encode_frame(value)[4:]
        line = f"reply|{self.pending}|".encode() + data.hex().encode() + b"\n"
        self.transport.send_bytes(line)
        self.pending = None

    def terminal_error(self):
        text = "Editor backend unavailable; local draft retained. Start a new editor session to reconnect."
        if self.session.failure:
            text += " " + self.session.failure
        return text.replace("\0", "").encode("utf-8", "replace")[:2048].decode("utf-8", "ignore")

    def terminal_reply(self, view):
        self.reply(dict(op="failure", view=view, error=self.terminal_error()))

    def request(self, line):
        if len(line) > 131104:
            raise ValueError("oversized private UI line")
        parts = line.split(b"|")
        if len(parts) != 3 or parts[0] != b"command":
            raise ValueError("invalid private UI envelope")
        seq, encoded = parts[1:]
        if (not seq.isdigit() or seq.startswith(b"0") or len(seq) > 10
                or int(seq) != self.sequence + 1 or int(seq) > 2147483647
                or len(encoded) % 2 or any(c not in b"0123456789abcdef" for c in encoded)):
            raise ValueError("invalid private UI sequence or hex")
        raw = bytes.fromhex(encoded.decode("ascii"))
        decoder = FrameDecoder()
        message, = list(decoder.feed(len(raw).to_bytes(4, "big") + raw))
        decoder.finish()
        # These are trusted plugin controls, still closed-schema checked. All
        # numbers are lexical integers; the BookProtocol parser preserves floats.
        def integers(value):
            if isinstance(value, float):
                raise ValueError("private UI counters require integer spelling")
            if isinstance(value, dict):
                for item in value.values():
                    integers(item)
        integers(message)
        op = message.get("op")
        fields = {"hello": {"op", "protocol_version"}, "open": {"op", "view", "text"},
                  "action": {"op", "view", "surface_handle", "surface_generation", "action_id", "text"},
                  "close": {"op", "view"}, "decision": {"op", "view", "token", "accept"},
                  "preview-action": {"op", "view", "token", "surface_handle", "surface_generation", "action_id", "text"},
                  "preview-finish": {"op", "view", "token", "accept"}}
        if op not in fields or set(message) != fields[op]:
            raise ValueError("invalid private UI schema")
        self.sequence = int(seq)
        if op == "hello":
            if (type(message["protocol_version"]) is not int
                    or message["protocol_version"] != 1 or self.pending is not None):
                raise ValueError("unexpected private UI hello")
            self.ready = True
            self.pending = self.sequence
            self.reply(dict(op="ready", protocol_version=1, max_text_bytes=8192, max_actions=8))
            return
        view = message["view"]
        if not self.ready or type(view) is not int or not 1 <= view <= 2147483647:
            raise ValueError("invalid private UI view")
        if "text" in message:
            text = message["text"]
            if not isinstance(text, str) or "\0" in text or len(text.encode()) > 8192:
                raise ValueError("invalid private editor text")
        if op in ("preview-action", "preview-finish"):
            if (self.preview_token is None or message["token"] != self.preview_token
                    or view != self.preview_view):
                # A retired callback has no reply slot and must not terminate
                # the current candidate through the launcher's exception path.
                return
            if not self.session.authority_usable:
                if op == "preview-finish" and type(message["accept"]) is not bool:
                    raise ValueError("invalid preview decision")
                self.pending = self.sequence
                if op == "preview-finish":
                    self.preview_token = None
                    self.terminal_reply(self.view)
                else:
                    self.reply(dict(op="preview-failure", view=view, token=self.preview_token,
                                    error=self.terminal_error()))
                return
            candidate = self.session.preview
            if op == "preview-finish":
                if type(message["accept"]) is not bool:
                    raise ValueError("invalid preview decision")
                if message["accept"] and (self.pending is not None or
                        (candidate is not None and candidate.deadline is not None)):
                    raise ValueError("cannot accept busy or failed preview")
                # Cancel supersedes an in-flight candidate action. Its old reply
                # is retired; only the resumed author action uses this sequence.
                self.pending = self.sequence
                self.preview_token = None
                diagnostic = self.session.preview_failure or ("interactive preview accepted; child reaped"
                    if message["accept"] else "interactive preview cancelled")
                self.session.finish_preview(message["accept"], diagnostic)
            else:
                if self.pending is not None:
                    raise ValueError("preview is busy or failed")
                if self.session.preview_failure:
                    self.pending = self.sequence
                    self.reply(dict(op="preview-failure", view=view, token=self.preview_token,
                                    error=self.session.preview_failure[:2048]))
                    return
                if candidate is None:
                    raise ValueError("preview is busy or failed")
                form = candidate.form
                if (not form or message["surface_handle"] != form["surface_handle"]
                        or type(message["surface_generation"]) is not int
                        or message["surface_generation"] != form["surface_generation"]):
                    raise ValueError("action names a stale preview surface")
                self.pending = self.sequence
                candidate.action(message["action_id"], message["text"])
            return
        if op == "close":
            if self.opened and view != self.view:
                return
            self.view = view
            self.pending = self.token = None
            self.preview_token = None
            if self.session.authority_usable:
                self.session.stop_child()
                self.session.command("host-retire")
            self.opened = True
            return
        if op == "open":
            if view <= self.view:
                raise ValueError("open requires a fresh view")
            self.view = view
            self.pending = self.sequence
            self.token = None
            self.preview_token = None
            self.session.ui_events.clear()
            if not self.session.authority_usable:
                self.opened = True
                self.terminal_reply(view)
                return
            if self.opened:
                self.session.command("host-reopen", text=message["text"])
            else:
                self.opened = True
                if self.session.form:
                    self.reply(dict(op="present", view=view, form=self.session.form))
                elif self.session.failure:
                    self.reply(dict(op="failure", view=view, error=self.session.failure[:2048]))
            return
        if self.pending is not None or view != self.view:
            raise ValueError("private UI is busy or stale")
        if self.preview_token is not None:
            raise ValueError("author action blocked during preview")
        self.pending = self.sequence
        if not self.session.authority_usable:
            if op == "decision" and type(message["accept"]) is not bool:
                raise ValueError("invalid trusted proposal decision")
            self.token = None
            self.terminal_reply(view)
            return
        if op == "action":
            form = self.session.form
            if (not form or message["surface_handle"] != form["surface_handle"]
                    or type(message["surface_generation"]) is not int
                    or message["surface_generation"] != form["surface_generation"]):
                raise ValueError("action names a stale surface")
            self.session.action(message["action_id"], message["text"])
        elif op == "decision":
            if (self.token is None or message["token"] != self.token
                    or type(message["accept"]) is not bool):
                raise ValueError("invalid trusted proposal token")
            self.token = None
            if message["accept"]:
                self.session.confirm()
            else:
                self.session.cancel()

    def pump(self):
        activity = False
        if select.select([self.transport.sock], [], [], 0)[0]:
            data = self.transport.sock.recv(16384)
            if not data:
                raise EOFError("private UI closed")
            self.buffer.extend(data)
            activity = True
        if len(self.buffer) > 131104 + 16384:
            raise ValueError("private UI input bound exceeded")
        if b"\n" in self.buffer:
            line, _, remainder = self.buffer.partition(b"\n")
            self.buffer = bytearray(remainder)
            self.request(bytes(line))
        elif len(self.buffer) > 131104:
            raise ValueError("oversized private UI line")
        self.session.pump()
        if not self.session.authority_usable:
            # Preserve the UI transport and local widget draft after backend
            # retirement. Never publish queued forms/proposals from that domain
            # or attempt another RPC on its permanently closed connection.
            self.token = None
            if self.preview_token:
                self.reply(dict(op="preview-failure", view=self.preview_view,
                                token=self.preview_token, error=self.terminal_error()))
            else:
                self.terminal_reply(self.view)
            self.session.ui_events.clear()
            return activity
        candidate = self.session.preview
        if candidate is not None and candidate.form:
            if self.preview_token is None:
                self.preview_token = os.urandom(16).hex()
                self.preview_view = max(self.preview_view + 1, self.view + 1)
                self.preview_seen = candidate.form
                self.reply(dict(op="preview", view=self.view, token=self.preview_token,
                                preview_view=self.preview_view, form=candidate.form))
            elif candidate.form is not self.preview_seen:
                self.preview_seen = candidate.form
                self.reply(dict(op="preview", view=self.preview_view, token=self.preview_token,
                                preview_view=self.preview_view, form=candidate.form))
            candidate.ui_events.clear()
        if self.preview_token and self.session.preview_failure:
            self.reply(dict(op="preview-failure", view=self.preview_view, token=self.preview_token,
                            error=self.session.preview_failure[:2048]))
        elif self.session.preview_failure:
            self.session.finish_preview(False, self.session.preview_failure)
        for message in self.session.ui_events:
            if message["type"] == "editor-present":
                self.reply(dict(op="present", view=self.view, form=message))
            elif message["type"] == "editor-host-proposal":
                self.token = os.urandom(16).hex()
                self.reply(dict(op="confirmation", view=self.view, token=self.token,
                                kind="install", summary=message["text"]))
            elif message["type"] == "editor-host-status":
                self.reply(dict(op="failure", view=self.view, error=message["text"][:2048]))
        self.session.ui_events.clear()
        return activity


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, EOFError, ValueError, RuntimeError, TimeoutError) as error:
        print(f"native-editor: {error}", file=sys.stderr)
        sys.exit(1)
