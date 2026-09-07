#!/usr/bin/env python3
"""Fresh-process oracle for the native Book State vertical join.

Python only launches and checks trusted Guile authorities.  Guile remains the
sole production/storage authority, and both fixture books speak only Book
Protocol frames over their accepted socketpair endpoint.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import secrets
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from typing import Any


MAX_LOG_BYTES = 128 * 1024
LOST_NAMESPACE = "native-state-note/lost-ack/guile@1"


def authority_environment(run_root: Path) -> dict[str, str]:
    """Minimal trusted environment; no user Python/Guile injection survives."""
    required = (
        "PATH",
        "GUILE_LOAD_PATH",
        "GUILE_LOAD_COMPILED_PATH",
        "BOOK_FIXTURE_GUILE_LOAD_PATH",
        "BOOK_FIXTURE_GUILE_LOAD_COMPILED_PATH",
        "BOOK_FIXTURE_PYTHON_LAUNCHER",
        "BOOK_FIXTURE_PYTHON_CODEC",
        "BOOK_STATE_SNAPSHOT_ROOT",
    )
    values: dict[str, str] = {}
    for name in required:
        value = os.environ.get(name)
        if not value:
            raise RuntimeError(f"trusted test environment lacks {name}")
        values[name] = value
    values.update(
        {
            "HOME": "/nonexistent",
            "LANG": "C.UTF-8",
            "LC_ALL": "C.UTF-8",
            "GUILE_AUTO_COMPILE": "0",
            "PYTHONDONTWRITEBYTECODE": "1",
            "PYTHONUTF8": "1",
            "XDG_CACHE_HOME": str(run_root / "authority-cache"),
        }
    )
    Path(values["XDG_CACHE_HOME"]).mkdir(mode=0o700, exist_ok=True)
    return values


def process_start_time(pid: int) -> str:
    text = Path(f"/proc/{pid}/stat").read_text(encoding="utf-8")
    close = text.rfind(")")
    if close < 0:
        raise AssertionError(f"process {pid} has malformed /proc stat")
    fields = text[close + 2 :].split()
    if len(fields) < 20:
        raise AssertionError(f"process {pid} lacks Linux start time")
    return fields[19]


def run_authority(
    guile: str,
    authority: Path,
    state_root: Path,
    run_root: Path,
    mode: str,
    operation_ids: tuple[str, str],
    edits: tuple[str, str] | None = None,
) -> dict[str, Any]:
    phase_root = run_root / mode
    suffix = 1
    while phase_root.exists():
        suffix += 1
        phase_root = run_root / f"{mode}-{suffix}"
    phase_root.mkdir(mode=0o700)
    result_path = phase_root / "result.json"
    command = [
        guile,
        "--no-auto-compile",
        str(authority),
        str(state_root),
        str(phase_root),
        str(result_path),
        mode,
        *operation_ids,
    ]
    if edits is not None:
        command.extend(edits)

    # Later phases deliberately carry no expected state text in argv or env.
    if edits is None and any("state λ" in argument for argument in command):
        raise AssertionError("reopen authority command accidentally contains state text")

    process = subprocess.Popen(
        command,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        encoding="utf-8",
        env=authority_environment(run_root),
    )
    launched_start = process_start_time(process.pid)
    try:
        stdout, stderr = process.communicate(timeout=45)
    except subprocess.TimeoutExpired:
        process.kill()
        stdout, stderr = process.communicate()
        raise AssertionError(
            f"authority {mode} timed out\nstdout:\n{stdout}\nstderr:\n{stderr}"
        ) from None
    if process.returncode != 0:
        logs = []
        for path in sorted(phase_root.glob("*.log")):
            logs.append(f"--- {path.name} ---\n{path.read_text(errors='replace')}")
        raise AssertionError(
            f"authority {mode} exited {process.returncode}\n"
            f"stdout:\n{stdout}\nstderr:\n{stderr}\n" + "\n".join(logs)
        )
    if not result_path.exists():
        raise AssertionError(f"authority {mode} produced no result")
    result = json.loads(result_path.read_text(encoding="utf-8"))
    if result["authority_pid"] != process.pid:
        raise AssertionError("result does not identify the launched Guile authority")
    if result["authority_start_time"] != launched_start:
        raise AssertionError("result authority PID/start-time identity changed")
    if result["mode"] != mode or result["format"] != 1:
        raise AssertionError("authority result has the wrong mode or format")
    if list(phase_root.glob("*.pid")):
        raise AssertionError("authority left a live-child process record")
    for log in phase_root.glob("*.log"):
        if log.stat().st_size >= MAX_LOG_BYTES:
            raise AssertionError(f"child log reached its bound: {log}")
    codec = Path(os.environ["BOOK_FIXTURE_PYTHON_CODEC"]).resolve()
    codec_marker = (
        f"BOOK_PROTOCOL_PY_ORIGIN: {codec} "
        "sha256=4e2423e09291d29758a6441d460ee2abfb82f24ed589f477ad62021c95ebe735"
    )
    python_log = (phase_root / "python.log").read_text(encoding="utf-8")
    if python_log.splitlines().count(codec_marker) != 1:
        raise AssertionError("Python fixture did not load the exact snapshot codec once")
    result["_command"] = command
    result["_phase_root"] = str(phase_root)
    return result


def wait_for_path(path: Path, process: subprocess.Popen[str], seconds: float) -> None:
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        if path.exists():
            return
        if process.poll() is not None:
            stdout, stderr = process.communicate()
            raise AssertionError(
                f"authority exited before {path.name}\nstdout:\n{stdout}\nstderr:\n{stderr}"
            )
        time.sleep(0.01)
    process.kill()
    stdout, stderr = process.communicate()
    raise AssertionError(
        f"authority timed out before {path.name}\nstdout:\n{stdout}\nstderr:\n{stderr}"
    )


def validate_lost_ack_evidence(
    metadata: dict[str, Any], book_log: str
) -> None:
    """Reject a delivered/consumed receipt even if a fixture labels it lost."""
    if metadata.get("state_committed_consumed") is not False:
        raise AssertionError("claimed loss consumed state-committed")
    if metadata.get("outbound_frames") != 0:
        raise AssertionError("claimed loss retained or delivered an output frame")
    if book_log.count("LOST_ACK_BOOK: EOF-before-state-committed:ok\n") != 1:
        raise AssertionError("loss book did not record one exact EOF-before-receipt")
    if "LOST_ACK_BOOK: state-committed-consumed:yes" in book_log:
        raise AssertionError("loss book parsed state-committed before claiming EOF")
    if "pretended-loss" in book_log:
        raise AssertionError("acknowledged execution pretended to lose its receipt")


def lost_sqlite_rows(database: Path) -> tuple[tuple[Any, ...], list[tuple[Any, ...]]]:
    connection = sqlite3.connect(f"file:{database}?mode=ro", uri=True)
    try:
        instance = connection.execute(
            "SELECT state_version, has_value, text FROM book_instances "
            "WHERE book_revision = ?",
            (LOST_NAMESPACE,),
        ).fetchone()
        receipts = connection.execute(
            "SELECT c.operation_id, c.expected_state_version, "
            "c.resulting_state_version, c.text_bytes "
            "FROM commit_receipts c JOIN book_instances b USING (namespace_id) "
            "WHERE b.book_revision = ? ORDER BY c.operation_id",
            (LOST_NAMESPACE,),
        ).fetchall()
        if instance is None:
            raise AssertionError("lost-ack namespace is absent from SQLite")
        return instance, receipts
    finally:
        connection.close()


def run_lost_authority_sync(
    guile: str,
    authority: Path,
    state_root: Path,
    run_root: Path,
    mode: str,
    operation_id: str,
) -> tuple[dict[str, Any], str, list[str]]:
    phase_root = run_root / f"lost-{mode}"
    phase_root.mkdir(mode=0o700)
    result_path = phase_root / "result.json"
    command = [
        guile,
        "--no-auto-compile",
        str(authority),
        str(state_root),
        str(phase_root),
        str(result_path),
        mode,
        operation_id,
    ]
    process = subprocess.Popen(
        command,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        encoding="utf-8",
        env=authority_environment(run_root),
    )
    launched_start = process_start_time(process.pid)
    try:
        stdout, stderr = process.communicate(timeout=30)
    except subprocess.TimeoutExpired:
        process.kill()
        stdout, stderr = process.communicate()
        raise AssertionError(
            f"lost-ack authority {mode} timed out\nstdout:\n{stdout}\nstderr:\n{stderr}"
        ) from None
    if process.returncode != 0:
        raise AssertionError(
            f"lost-ack authority {mode} exited {process.returncode}\n"
            f"stdout:\n{stdout}\nstderr:\n{stderr}"
        )
    result = json.loads(result_path.read_text(encoding="utf-8"))
    if (
        result["authority_pid"] != process.pid
        or result["authority_start_time"] != launched_start
        or result["mode"] != mode
        or result["format"] != 2
        or result["child_exit_code"] != 0
    ):
        raise AssertionError("lost-ack authority result identity/status changed")
    log_path = phase_root / "lost-ack.log"
    book_log = log_path.read_text(encoding="utf-8")
    if log_path.stat().st_size >= MAX_LOG_BYTES:
        raise AssertionError("lost-ack book log reached its bound")
    if list(phase_root.glob("*.pid")):
        raise AssertionError("lost-ack authority left a child process record")
    return result, book_log, command


def run_lost_ack_scenario(
    guile: str,
    authority: Path,
    state_root: Path,
    run_root: Path,
    operation_id: str,
    text: str,
) -> list[dict[str, Any]]:
    phase_root = run_root / "lost-lose"
    phase_root.mkdir(mode=0o700)
    result_path = phase_root / "result.json"
    barrier_path = phase_root / "adapter-returned.json"
    release_path = phase_root / "release"
    command = [
        guile,
        "--no-auto-compile",
        str(authority),
        str(state_root),
        str(phase_root),
        str(result_path),
        "lose",
        operation_id,
        text,
    ]
    process = subprocess.Popen(
        command,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        encoding="utf-8",
        env=authority_environment(run_root),
    )
    launched_start = process_start_time(process.pid)
    wait_for_path(barrier_path, process, 20)
    barrier = json.loads(barrier_path.read_text(encoding="utf-8"))
    book_log = (phase_root / "lost-ack.log").read_text(encoding="utf-8")
    if (
        barrier["authority_pid"] != process.pid
        or barrier["authority_start_time"] != launched_start
        or barrier["operation_id"] != operation_id
        or barrier["adapter_returned"] is not True
        or barrier["endpoint_closed"] is not True
    ):
        raise AssertionError("post-adapter loss barrier identity/state changed")
    validate_lost_ack_evidence(barrier, book_log)

    database = state_root / "book-state-v1.sqlite"
    instance_before, receipts_before = lost_sqlite_rows(database)
    expected_receipt = (
        operation_id,
        0,
        1,
        len(text.encode("utf-8")),
    )
    if instance_before != (1, 1, text) or receipts_before != [expected_receipt]:
        raise AssertionError("SQLite did not independently observe lost commit/receipt")

    descriptor = os.open(release_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    os.write(descriptor, b"sqlite-oracle-complete\n")
    os.close(descriptor)
    try:
        stdout, stderr = process.communicate(timeout=20)
    except subprocess.TimeoutExpired:
        process.kill()
        stdout, stderr = process.communicate()
        raise AssertionError(
            f"lost authority did not reap paused callback\nstdout:\n{stdout}\n"
            f"stderr:\n{stderr}"
        ) from None
    if process.returncode != 0:
        raise AssertionError(
            f"lost authority exited {process.returncode}\nstdout:\n{stdout}\n"
            f"stderr:\n{stderr}"
        )
    lost = json.loads(result_path.read_text(encoding="utf-8"))
    validate_lost_ack_evidence(lost, book_log)
    if (
        lost["authority_pid"] != process.pid
        or lost["authority_start_time"] != launched_start
        or lost["child_exit_code"] != 0
        or lost["adapter_returned"] is not True
        or lost["endpoint_closed"] is not True
    ):
        raise AssertionError("completed lost authority result changed")

    retry, retry_log, retry_command = run_lost_authority_sync(
        guile, authority, state_root, run_root, "retry", operation_id
    )
    if text in "\0".join(retry_command):
        raise AssertionError("fresh retry authority received recovery text")
    expected_summary = receipt_text(operation_id, 1, len(text.encode("utf-8")), 1)
    if (
        retry["receipt_text"] != expected_summary
        or retry["state_committed_consumed"] is not True
        or retry_log.count(
            "LOST_ACK_BOOK: original-receipt-consumed-after-restart:ok\n"
        )
        != 1
    ):
        raise AssertionError("fresh retry did not consume the exact original receipt")
    instance_after, receipts_after = lost_sqlite_rows(database)
    if instance_after != instance_before or receipts_after != receipts_before:
        raise AssertionError("exact retry advanced state or inserted another receipt")

    # Execute the reviewer's semantic counterexample: a fresh real authority and
    # book consume state-committed, then attempt to label the run as a loss.  The
    # loss oracle must reject it even though storage and protocol behavior pass.
    pretended, pretend_log, _ = run_lost_authority_sync(
        guile, authority, state_root, run_root, "pretend-loss", operation_id
    )
    rejected = False
    try:
        validate_lost_ack_evidence(pretended, pretend_log)
    except AssertionError as error:
        if "consumed state-committed" not in str(error):
            raise
        rejected = True
    if not rejected:
        raise AssertionError("acknowledged replay was accepted as a lost acknowledgement")
    instance_final, receipts_final = lost_sqlite_rows(database)
    if instance_final != instance_before or receipts_final != receipts_before:
        raise AssertionError("semantic counterexample changed durable state")

    identities = {
        (lost["authority_pid"], lost["authority_start_time"]),
        (retry["authority_pid"], retry["authority_start_time"]),
        (pretended["authority_pid"], pretended["authority_start_time"]),
    }
    child_identities = {
        (lost["child_pid"], lost["child_start_time"]),
        (retry["child_pid"], retry["child_start_time"]),
        (pretended["child_pid"], pretended["child_start_time"]),
    }
    if len(identities) != 3 or len(child_identities) != 3:
        raise AssertionError("lost-ack scenario reused a process identity")
    print(
        "LOST-ACK: "
        f"operation={operation_id} text-bytes={len(text.encode('utf-8'))} "
        f"text-sha256={hashlib.sha256(text.encode('utf-8')).hexdigest()} "
        "adapter-returned=yes endpoint-closed=yes outbound-frames=0 "
        "book-eof-before-state-committed=yes"
    )
    print(
        "LOST-ACK-RETRY: fresh-authority=yes fresh-book=yes expected-version=0 "
        "receipt-version=1 current-version=1 receipt-count=1 state-unchanged=yes"
    )
    print("PASS: acknowledged-receipt counterexample rejected by loss oracle")
    return [lost, retry, pretended]


def peers(result: dict[str, Any]) -> dict[str, dict[str, Any]]:
    values = {peer["label"]: peer for peer in result["peers"]}
    if set(values) != {"guile", "python"}:
        raise AssertionError("authority did not supervise exactly two languages")
    for label, peer in values.items():
        if peer["exit_code"] != 0 or peer["process_group"] != peer["pid"]:
            raise AssertionError(f"{label} child was not reaped cleanly")
    return values


def receipt_text(
    operation_id: str, state_version: int, text_bytes: int, current_version: int
) -> str:
    return (
        f"receipt={operation_id}|state-version={state_version}|"
        f"text-bytes={text_bytes}|current-version={current_version}"
    )


def check_phase(
    result: dict[str, Any],
    expected_loads: dict[str, str],
    operation_ids: dict[str, str],
    receipt_versions: dict[str, int],
    current_versions: dict[str, int],
    text_bytes: dict[str, int],
    dispatch_count: int,
) -> None:
    for label, peer in peers(result).items():
        if peer["load_text"] != expected_loads[label]:
            raise AssertionError(f"{label} loaded the wrong trusted namespace value")
        expected_receipt = receipt_text(
            operation_ids[label],
            receipt_versions[label],
            text_bytes[label],
            current_versions[label],
        )
        if peer["receipt_text"] != expected_receipt:
            raise AssertionError(
                f"{label} did not present its durable receipt separately"
            )
        if peer["dispatch_statuses"] != ["queued"] * dispatch_count:
            raise AssertionError(f"{label} state scheduling results were not drained")


def assert_fresh_identities(results: list[dict[str, Any]]) -> None:
    authority_identities = {
        (result["authority_pid"], result["authority_start_time"])
        for result in results
    }
    if len(authority_identities) != len(results):
        raise AssertionError("authority phase reused a process identity")

    child_identities: set[tuple[int, str]] = set()
    session_ids: set[str] = set()
    surface_handles: set[str] = set()
    state_handles: set[str] = set()
    count = 0
    for result in results:
        for peer in peers(result).values():
            count += 1
            child_identities.add((peer["pid"], peer["start_time"]))
            session_ids.add(peer["session_id"])
            surface_handles.add(peer["surface_handle"])
            state_handles.add(peer["state_grant_handle"])
    for label, values in (
        ("child PID/start-time", child_identities),
        ("session ID", session_ids),
        ("surface handle", surface_handles),
        ("state grant handle", state_handles),
    ):
        if len(values) != count:
            raise AssertionError(f"fresh supervisor phases reused a {label}")


def assert_combined_fresh_identities(
    results: list[dict[str, Any]], lost_results: list[dict[str, Any]]
) -> None:
    authority_identities = {
        (result["authority_pid"], result["authority_start_time"])
        for result in [*results, *lost_results]
    }
    expected_authorities = len(results) + len(lost_results)
    if len(authority_identities) != expected_authorities:
        raise AssertionError("combined scenarios reused an authority identity")

    child_identities: set[tuple[int, str]] = set()
    session_ids: set[str] = set()
    surface_handles: set[str] = set()
    state_handles: set[str] = set()
    for result in results:
        for peer in peers(result).values():
            child_identities.add((peer["pid"], peer["start_time"]))
            session_ids.add(peer["session_id"])
            surface_handles.add(peer["surface_handle"])
            state_handles.add(peer["state_grant_handle"])
    for result in lost_results:
        child_identities.add((result["child_pid"], result["child_start_time"]))
        session_ids.add(result["session_id"])
        surface_handles.add(result["surface_handle"])
        state_handles.add(result["state_grant_handle"])
    expected_children = sum(len(peers(result)) for result in results) + len(
        lost_results
    )
    for label, values in (
        ("child PID/start-time", child_identities),
        ("session ID", session_ids),
        ("surface handle", surface_handles),
        ("state grant handle", state_handles),
    ):
        if len(values) != expected_children:
            raise AssertionError(f"combined scenarios reused a {label}")


def print_execution_identities(results: list[dict[str, Any]]) -> None:
    """Emit bounded, replay-independent process and endpoint evidence."""
    for phase, result in enumerate(results, 1):
        for label, peer in sorted(peers(result).items()):
            load = peer["load_text"].encode("utf-8")
            print(
                "IDENTITY: "
                f"phase={phase} mode={result['mode']} "
                f"authority={result['authority_pid']}/"
                f"{result['authority_start_time']} "
                f"book={label} child={peer['pid']}/{peer['start_time']} "
                f"session={peer['session_id']} "
                f"surface={peer['surface_handle']} "
                f"state-grant={peer['state_grant_handle']}/"
                f"{peer['state_grant_generation']} "
                f"load-bytes={len(load)} "
                f"load-sha256={hashlib.sha256(load).hexdigest()} "
                f"receipt={peer['receipt_text']}"
            )


def sqlite_rows(database: Path) -> tuple[list[tuple[Any, ...]], list[tuple[Any, ...]]]:
    connection = sqlite3.connect(f"file:{database}?mode=ro", uri=True)
    try:
        instances = connection.execute(
            "SELECT book_revision, instance_id, state_version, has_value, text "
            "FROM book_instances ORDER BY book_revision"
        ).fetchall()
        receipts = connection.execute(
            "SELECT b.book_revision, c.operation_id, c.expected_state_version, "
            "c.resulting_state_version, c.text_bytes "
            "FROM commit_receipts c JOIN book_instances b USING (namespace_id) "
            "ORDER BY b.book_revision, c.resulting_state_version"
        ).fetchall()
        return instances, receipts
    finally:
        connection.close()


def check_normal_sqlite(database: Path, expected: dict[str, str]) -> None:
    instances, receipts = sqlite_rows(database)
    normal = [row for row in instances if "/normal/" in row[0]]
    if len(normal) != 2:
        raise AssertionError("normal run did not retain two trusted namespaces")
    by_language = {"guile" if "/guile@" in row[0] else "python": row for row in normal}
    for label, row in by_language.items():
        if row[2:] != (2, 1, expected[label]):
            raise AssertionError(f"{label} SQLite row disagrees with reopened state")
    normal_receipts = [row for row in receipts if "/normal/" in row[0]]
    if len(normal_receipts) != 4:
        raise AssertionError("exact retries inserted or removed durable receipts")


def check_boundary_sqlite(database: Path) -> None:
    instances, receipts = sqlite_rows(database)
    boundary = [row for row in instances if "/boundary/" in row[0]]
    if len(boundary) != 2:
        raise AssertionError("boundary run did not retain two trusted namespaces")
    for row in boundary:
        if row[2:] != (2, 1, "\x00" * MAX_STATE_TEXT_BYTES):
            raise AssertionError("4,096-byte NUL state did not survive SQLite reopen")
    boundary_receipts = [row for row in receipts if "/boundary/" in row[0]]
    if len(boundary_receipts) != 4:
        raise AssertionError("boundary namespaces have the wrong receipt count")


MAX_STATE_TEXT_BYTES = 4096


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--normal-only",
        action="store_true",
        help="development-only run that does not constitute the full host gate",
    )
    arguments = parser.parse_args()
    tool_dir = Path(__file__).resolve().parent
    snapshot_root = Path(os.environ["BOOK_STATE_SNAPSHOT_ROOT"]).resolve()
    if tool_dir != snapshot_root / "integration":
        raise RuntimeError("restart oracle is not executing from the fixed snapshot")
    guile = shutil.which("guile")
    if guile is None:
        raise RuntimeError("pinned Guile is absent")

    run_root = Path(
        tempfile.mkdtemp(prefix="book-state-native-restart.", dir="/tmp/opencode")
    )
    os.chmod(run_root, 0o700)
    state_root = run_root / "state"
    state_root.mkdir(mode=0o700)
    authority = tool_dir / "native-authority.scm"
    state_nonce = secrets.token_urlsafe(18)
    operation_nonce = secrets.token_urlsafe(12)
    expected = {
        "guile": f"Guile state λ — 京東 — {state_nonce}",
        "python": f"Python state ÉLAN Λ — {state_nonce[::-1]}",
    }
    first_ops = {
        "guile": f"GuileSave_{operation_nonce}",
        "python": f"PythonSave_{operation_nonce}",
    }
    second_ops = {
        "guile": f"GuileSave2_{operation_nonce}",
        "python": f"PythonSave2_{operation_nonce}",
    }
    results: list[dict[str, Any]] = []
    try:
        saved = run_authority(
            guile,
            authority,
            state_root,
            run_root,
            "save",
            (first_ops["guile"], first_ops["python"]),
            (expected["guile"], expected["python"]),
        )
        results.append(saved)
        check_phase(
            saved,
            {"guile": "ABSENT", "python": "ABSENT"},
            first_ops,
            {"guile": 1, "python": 1},
            {"guile": 1, "python": 1},
            {label: len(text.encode("utf-8")) for label, text in expected.items()},
            2,
        )

        retry = run_authority(
            guile,
            authority,
            state_root,
            run_root,
            "replay",
            (first_ops["guile"], first_ops["python"]),
        )
        results.append(retry)
        # The exact operation ID is test-client state.  Neither expected text is
        # in this fresh authority's argv/environment; books recover it by read.
        if state_nonce in "\0".join(retry["_command"]):
            raise AssertionError("reopen authority received the state nonce")
        check_phase(
            retry,
            expected,
            first_ops,
            {"guile": 1, "python": 1},
            {"guile": 1, "python": 1},
            {label: len(text.encode("utf-8")) for label, text in expected.items()},
            3,
        )

        reopened = run_authority(
            guile,
            authority,
            state_root,
            run_root,
            "save-loaded",
            (second_ops["guile"], second_ops["python"]),
        )
        results.append(reopened)
        if state_nonce in "\0".join(reopened["_command"]):
            raise AssertionError("second commit authority received the state nonce")
        check_phase(
            reopened,
            expected,
            second_ops,
            {"guile": 2, "python": 2},
            {"guile": 2, "python": 2},
            {label: len(text.encode("utf-8")) for label, text in expected.items()},
            2,
        )

        late_retry = run_authority(
            guile,
            authority,
            state_root,
            run_root,
            "replay",
            (first_ops["guile"], first_ops["python"]),
        )
        results.append(late_retry)
        if state_nonce in "\0".join(late_retry["_command"]):
            raise AssertionError("late-retry authority received the state nonce")
        check_phase(
            late_retry,
            expected,
            first_ops,
            {"guile": 1, "python": 1},
            {"guile": 2, "python": 2},
            {label: len(text.encode("utf-8")) for label, text in expected.items()},
            3,
        )
        assert_fresh_identities(results)
        database = state_root / "book-state-v1.sqlite"
        check_normal_sqlite(database, expected)

        if arguments.normal_only:
            print_execution_identities(results)
            print("PASS: normal native restart/retry integration (boundary not run)")
            return 0

        lost_operation = f"LostAck_{operation_nonce}"
        lost_text = f"Lost acknowledgement λ — 東京 — {secrets.token_urlsafe(18)}"
        lost_results = run_lost_ack_scenario(
            guile,
            tool_dir / "lost-ack-authority.scm",
            state_root,
            run_root,
            lost_operation,
            lost_text,
        )

        boundary_first = {
            "guile": f"GuileNul_{operation_nonce}",
            "python": f"PythonNul_{operation_nonce}",
        }
        boundary_second = {
            "guile": f"GuileNul2_{operation_nonce}",
            "python": f"PythonNul2_{operation_nonce}",
        }
        boundary_saved = run_authority(
            guile,
            authority,
            state_root,
            run_root,
            "boundary-save",
            (boundary_first["guile"], boundary_first["python"]),
        )
        results.append(boundary_saved)
        check_phase(
            boundary_saved,
            {"guile": "ABSENT", "python": "ABSENT"},
            boundary_first,
            {"guile": 1, "python": 1},
            {"guile": 1, "python": 1},
            {"guile": MAX_STATE_TEXT_BYTES, "python": MAX_STATE_TEXT_BYTES},
            2,
        )
        boundary_reopened = run_authority(
            guile,
            authority,
            state_root,
            run_root,
            "boundary-reopen",
            (boundary_second["guile"], boundary_second["python"]),
        )
        results.append(boundary_reopened)
        check_phase(
            boundary_reopened,
            {"guile": "\x00" * MAX_STATE_TEXT_BYTES,
             "python": "\x00" * MAX_STATE_TEXT_BYTES},
            boundary_second,
            {"guile": 2, "python": 2},
            {"guile": 2, "python": 2},
            {"guile": MAX_STATE_TEXT_BYTES, "python": MAX_STATE_TEXT_BYTES},
            2,
        )
        assert_fresh_identities(results)
        assert_combined_fresh_identities(results, lost_results)
        check_boundary_sqlite(database)
        print_execution_identities(results)
        for result in lost_results:
            print(
                "LOST-IDENTITY: "
                f"mode={result['mode']} authority={result['authority_pid']}/"
                f"{result['authority_start_time']} child={result['child_pid']}/"
                f"{result['child_start_time']} session={result['session_id']} "
                f"surface={result['surface_handle']} state-grant="
                f"{result['state_grant_handle']}/"
                f"{result['state_grant_generation']}"
            )
        print("PASS: fresh Guile authorities reopened real SQLite state")
        print("PASS: native Guile/Python books used fresh PID/socket identities")
        print("PASS: combined native scenarios used fresh endpoint identities")
        print("PASS: acknowledged persisted receipts replayed before/after later CAS")
        print("PASS: actual dropped acknowledgement retried unchanged after restart")
        print("PASS: 4,096-byte NUL state crossed the real worker after reopen")
        return 0
    finally:
        shutil.rmtree(run_root)


if __name__ == "__main__":
    raise SystemExit(main())
