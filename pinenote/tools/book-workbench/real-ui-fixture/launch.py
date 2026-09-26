#!/usr/bin/env python3
"""Private real-widget owner: production KOReader plugin plus one donated FD.

BOOK_WORKBENCH_GUILE selects the actual trusted-native authority with the same
module environment as run-tests.sh. No authored source executes in this Python
process or in KOReader. Without that explicit environment a deterministic peer
tests the widgets only; its result is labeled accordingly.
"""
import hashlib
import json
import os
from pathlib import Path
import shutil
import signal
import socket
import subprocess
import tempfile
import threading
import time

TOOL = Path(__file__).resolve().parents[1]
SEED = '(define (workbench text) (string-append "seed: " text))\n'
SUCCESSOR = '(define (workbench text) (string-append "revised: " (string-upcase text)))\n'
MAX_LINE = 2 * 65536 + 32


def deterministic_peer(peer, errors):
    """An independent test peer, not a substitute storage/preview authority."""
    source, version, activation = SEED, 0, 0
    active, previous = "seed-r1", False
    sequence, incoming = 1, b""
    try:
        peer.settimeout(30)
        while True:
            while b"\n" not in incoming:
                part = peer.recv(16384)
                if not part:
                    raise AssertionError("UI disconnected without its close request")
                incoming += part
                if len(incoming) > MAX_LINE:
                    raise AssertionError("oversized UI command")
            line, incoming = incoming.split(b"\n", 1)
            kind, seq, payload = line.split(b"|")
            assert kind == b"command" and seq == str(sequence).encode()
            request = json.loads(bytes.fromhex(payload.decode()))
            op = request["op"]
            reply = {"ok": True, "op": op}
            if op == "save":
                assert request["expected_version"] == version
                source, version = request["source"], version + 1
            elif op in ("preview", "run"):
                selected = source if op == "preview" else (SEED if active == "seed-r1" else SUCCESSOR)
                if selected == SEED:
                    reply.update(text="seed: " + request["text"], diagnostic="")
                elif selected == SUCCESSOR:
                    reply.update(text="revised: " + request["text"].upper(), diagnostic="")
                else:
                    reply = {"ok": False, "op": op, "error": "preview-failed",
                             "diagnostic": "Deterministic fixture: broken test source."}
            elif op == "activate":
                assert request["expected_version"] == version
                assert request["expected_activation"] == activation
                previous, active, activation = active, "successor-r2", activation + 1
            elif op == "rollback":
                assert request["expected_activation"] == activation
                active, previous, activation = previous or "seed-r1", active, activation + 1
            elif op == "export":
                reply["artifact"] = json.dumps({"source": SEED if active == "seed-r1" else SUCCESSOR})
            else:
                assert op in ("open", "close"), op
            if reply["ok"]:
                metadata = {"workspace_version": version,
                            "source_digest": hashlib.sha256(source.encode()).hexdigest(),
                            "activation_generation": activation}
                if op in ("preview", "run", "export"):
                    reply.update(metadata)
                else:
                    reply["snapshot"] = dict(metadata, source=source, active_revision=active,
                                             previous_revision=previous)
            encoded = json.dumps(reply, ensure_ascii=False, separators=(",", ":")).encode()
            peer.sendall(b"reply|" + seq + b"|" + encoded.hex().encode() + b"\n")
            if op == "close":
                return
            sequence += 1
    except Exception as error:
        errors.append(error)
    finally:
        peer.close()


def stop(process):
    if process is None or process.poll() is not None:
        return
    # Each still-owned Popen leader is its own session/process-group leader.
    os.killpg(process.pid, signal.SIGTERM)
    try:
        process.wait(timeout=2)
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGKILL)
        process.wait(timeout=3)


def main():
    os.umask(0o077)
    bundle = Path(os.environ["KOREADER_NATIVE_BUNDLE"])
    kor = bundle / "lib/koreader"
    assert (kor / "git-rev").read_text().strip() == "v2026.03", "wrong KOReader version"
    guile = os.environ.get("BOOK_WORKBENCH_GUILE")
    native = bool(guile)
    root = Path(tempfile.mkdtemp(prefix="book-workbench-real-ui-", dir="/tmp/opencode"))
    reader = authority = None
    client = peer = None
    thread = None
    files = []
    passed = False
    def interrupted(signum, _frame):
        raise InterruptedError(f"fixture interrupted by signal {signum}")
    for signum in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
        signal.signal(signum, interrupted)
    try:
        for child in ("home", "ko/plugins", "tmp", "cache", "config", "data", "workspace"):
            (root / child).mkdir(parents=True, exist_ok=True)
        shutil.copytree(TOOL / "plugin/bookworkbench.koplugin", root / "ko/plugins/bookworkbench.koplugin")
        shutil.copytree(TOOL / "real-ui-fixture/bookworkbenchrealui.koplugin",
                        root / "ko/plugins/bookworkbenchrealui.koplugin")
        (root / "book.txt").write_text("Workbench native UI fixture\n\nAn inert ReaderUI document.\n")
        (root / "seed.scm").write_text(SEED)
        client, peer = socket.socketpair()
        errors = []
        if native:
            assert os.environ.get("GUILE_LOAD_PATH"), "native fixture requires explicit Guile module paths"
            log = open(root / "authority.log", "wb"); files.append(log)
            environment = dict(os.environ, HOME=str(root / "home"), XDG_CACHE_HOME=str(root / "cache"))
            authority = subprocess.Popen(
                [guile, "--no-auto-compile", str(TOOL / "native-authority.scm"),
                 "--trusted-native-fixture", str(peer.fileno()), str(root / "workspace"),
                 str(root / "seed.scm"), guile, str(TOOL / "workbench-runner.scm"),
                 str(TOOL.parent / "book-protocol")], env=environment,
                pass_fds=(peer.fileno(),), stdin=subprocess.DEVNULL,
                stdout=log, stderr=log, start_new_session=True)
            peer.close(); peer = None
        else:
            thread = threading.Thread(target=deterministic_peer, args=(peer, errors), daemon=True)
            thread.start()
        environment = {"PATH": os.environ["PATH"], "LC_ALL": "C", "HOME": str(root / "home"),
                       "KO_HOME": str(root / "ko"), "XDG_CACHE_HOME": str(root / "cache"),
                       "XDG_CONFIG_HOME": str(root / "config"), "XDG_DATA_HOME": str(root / "data"),
                       "TMPDIR": str(root / "tmp"), "SDL_VIDEODRIVER": "offscreen",
                       "SDL_AUDIODRIVER": "dummy", "BOOK_WORKBENCH_UI_FD": str(client.fileno()),
                       "BOOK_WORKBENCH_REAL_UI_ROOT": str(root)}
        log = open(root / "koreader.log", "wb"); files.append(log)
        reader = subprocess.Popen([str(kor / "luajit"), "reader.lua", str(root / "book.txt")],
                                  cwd=kor, env=environment, pass_fds=(client.fileno(),),
                                  stdin=subprocess.DEVNULL, stdout=log, stderr=log, start_new_session=True)
        client.close(); client = None
        deadline = time.monotonic() + 20
        while reader.poll() is None:
            assert time.monotonic() < deadline, "real UI exceeded 20-second process deadline"
            for path in root.glob("*.log"):
                assert path.stat().st_size <= 4 * 1024 * 1024, "fixture log exceeded 4 MiB"
            time.sleep(0.02)
        assert reader.returncode == 0, f"KOReader exited {reader.returncode}"
        text = (root / "koreader.log").read_text(errors="replace")
        assert text.count("BOOK_WORKBENCH_REAL_UI: result:ok\n") == 1, "missing/duplicate UI success"
        assert text.count("BOOK_WORKBENCH_REAL_UI: regression-cases:6\n") == 1, "missing real-widget regression cases"
        assert "BOOK_WORKBENCH_REAL_UI: FAIL:" not in text, "UI reported failure"
        assert "Tearing down UIManager with exit code: 0" in text, "unclean KOReader teardown"
        assert " [*] Version: v2026.03" in text, "official version marker missing"
        if native:
            assert authority.wait(timeout=5) == 0, "authority did not close cleanly"
        else:
            thread.join(timeout=5)
            assert not thread.is_alive() and not errors, f"deterministic peer failed: {errors}"
        mode = "actual trusted-native authority/SQLite/preview child" if native else "deterministic peer (widget-only evidence)"
        print(f"mode: full native KOReader + production Workbench plugin + {mode}")
        for line in text.splitlines():
            if line.startswith("BOOK_WORKBENCH_REAL_UI:"):
                print(line)
        print("PASS: real Workbench InputDialog save/preview/installed-run/activate/diagnostics/rollback/export/same-FD-reopen/teardown")
        passed = True
    finally:
        stop(reader); stop(authority)
        if client is not None:
            client.close()
        if peer is not None:
            try:
                peer.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
            if thread:
                thread.join(timeout=2)
            peer.close()
        for handle in files:
            handle.close()
        if not passed:
            for name in ("koreader.log", "authority.log"):
                path = root / name
                if path.exists():
                    print(f"{name}:\n{path.read_text(errors='replace')[-40000:]}")
        if not passed or os.environ.get("KEEP_ARTIFACTS") == "1":
            print(f"artifacts: {root}")
        else:
            shutil.rmtree(root)


if __name__ == "__main__":
    main()
