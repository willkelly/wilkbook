#!/usr/bin/env python3
"""Offline oracle for the Guile authority + book + KOReader + SQLite join.

Python does not broker either connected channel.  It launches fresh Guile
authorities, supplies ordinary scripted operator edits through private plan
files, then checks terminal evidence and the retained SQLite database.
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import signal
import sqlite3
import stat
import subprocess
import sys
import time
from pathlib import Path
from typing import Any


GUILE_TEXT_A = "Mémoire persistante A — 東京 λ\nligne deux"
GUILE_TEXT_B = "Mémoire persistante B — Αθήνα — café"
GUILE_TEXT_C = "Mémoire persistante C — 서울 — نهاية"
PYTHON_TEXT_A = "Примечание Python A — مرحبا — café"
PYTHON_TEXT_B = "Примечание Python B — 東京 — λ"
PYTHON_TEXT_C = "Примечание Python C — Αθήνα — نهاية"
EMPTY_SEED_TEXT = "Cette note sera effacée — 東京"
READ_ONLY_SEED_TEXT = "Valeur durable en lecture seule — 東京"
MAX_TEXT = "x" * 4096
RETRY_TEXT = "Nouvelle intention, même opération lors de la reprise"
DELAYED_SUBMISSION = "Version durable avant nouvelle frappe"
DELAYED_NEW_DRAFT = "Nouveau brouillon — 東京"
FORGED_PRESENT_TEXT = "Présentation précoce — pas un reçu"
MISMATCH_SUBMISSION = "Brouillon attendu — identité exacte"
MISMATCH_DURABLE = MISMATCH_SUBMISSION + " [book-mismatch]"
KOREADER_REVISION = "v2026.03"
MAX_LOG_BYTES = 128 * 1024
ACTIVE_PROCESS: subprocess.Popen[bytes] | None = None
ACTIVE_PHASE: Path | None = None


def fail(message: str) -> None:
    raise RuntimeError(message)


def exact_dir(path_text: str) -> Path:
    path = Path(path_text)
    if not path.is_absolute() or path.resolve() != path:
        fail(f"directory is not absolute and canonical: {path}")
    info = path.stat(follow_symlinks=False)
    if not stat.S_ISDIR(info.st_mode):
        fail(f"not a directory: {path}")
    return path


def make_private_dir(path: Path) -> None:
    path.mkdir(mode=0o700)
    path.chmod(0o700)


def prepare_phase(
    root: Path,
    name: str,
    ui_fixture: Path,
    pending_edit_fixture: Path,
    install_pending_edit: bool,
) -> tuple[Path, Path]:
    phase = root / name
    make_private_dir(phase)
    for path in (
        phase / "home",
        phase / "home" / ".config",
        phase / "home" / ".cache",
        phase / "home" / ".local",
        phase / "home" / ".local" / "share",
        phase / "ko",
        phase / "ko" / "plugins",
        phase / "tmp",
    ):
        path.mkdir(mode=0o700, exist_ok=True)
        path.chmod(0o700)
    shutil.copytree(
        ui_fixture,
        phase / "ko" / "plugins" / "bookstatereader.koplugin",
        copy_function=shutil.copyfile,
    )
    if install_pending_edit:
        shutil.copytree(
            pending_edit_fixture,
            phase / "ko" / "plugins" / "pendingedit.koplugin",
            copy_function=shutil.copyfile,
        )
    document = phase / "persistent-note.txt"
    document.write_text(
        "Persistent note reader join\n\n"
        "The connected Guile authority owns all durable state.\n",
        encoding="utf-8",
    )
    document.chmod(0o600)
    return phase, document


def authority_environment() -> dict[str, str]:
    required = (
        "PATH",
        "GUILE_LOAD_PATH",
        "GUILE_LOAD_COMPILED_PATH",
        "BOOK_JOIN_PYTHON_CODEC",
        "BOOK_JOIN_BOOK_GUILE_LOAD_PATH",
        "BOOK_JOIN_BOOK_GUILE_COMPILED_PATH",
    )
    environment: dict[str, str] = {}
    for name in required:
        value = os.environ.get(name)
        if not value:
            fail(f"trusted runner did not set {name}")
        environment[name] = value
    environment.update(
        {
            "HOME": "/nonexistent",
            "LANG": "C.UTF-8",
            "LC_ALL": "C.UTF-8",
            "GUILE_AUTO_COMPILE": "0",
            "PYTHONDONTWRITEBYTECODE": "1",
            "PYTHONUTF8": "1",
        }
    )
    return environment


def read_start_time(pid: int) -> str | None:
    try:
        text = Path(f"/proc/{pid}/stat").read_text(encoding="ascii")
    except (FileNotFoundError, ProcessLookupError):
        return None
    close = text.rfind(")")
    if close < 0:
        return None
    fields = text[close + 2 :].split()
    return fields[19] if len(fields) >= 20 else None


def clean_recorded_child(record: Path) -> None:
    if not record.exists():
        return
    fields = record.read_text(encoding="ascii").split()
    if len(fields) != 2:
        fail(f"malformed process record left behind: {record}")
    pid = int(fields[0], 10)
    start = fields[1]
    if read_start_time(pid) == start:
        try:
            os.kill(pid, 15)
        except ProcessLookupError:
            pass
        for _ in range(20):
            if read_start_time(pid) != start:
                break
            time.sleep(0.05)
        if read_start_time(pid) == start:
            try:
                os.kill(pid, 9)
            except ProcessLookupError:
                pass
    record.unlink(missing_ok=True)


def write_process_record(path: Path, pid: int) -> tuple[int, str]:
    for _ in range(100):
        start = read_start_time(pid)
        if start is not None:
            temporary = path.with_suffix(path.suffix + ".new")
            temporary.write_text(f"{pid} {start}\n", encoding="ascii")
            temporary.chmod(0o600)
            temporary.replace(path)
            return pid, start
        time.sleep(0.001)
    fail(f"could not identify process {pid}")


def deadline_signal(signum: int, _frame: object) -> None:
    raise RuntimeError(f"suite received deadline signal {signum}")


def load_json(path: Path) -> dict[str, Any]:
    value = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(value, dict) or value.get("format") != 2:
        fail(f"invalid authority result: {path}")
    return value


def run_phase(
    args: argparse.Namespace,
    state_root: Path,
    suite_root: Path,
    name: str,
    profile: str,
    plan: str,
    text: str | None,
) -> tuple[dict[str, Any], Path]:
    global ACTIVE_PHASE, ACTIVE_PROCESS
    phase, document = prepare_phase(
        suite_root,
        name,
        args.ui_fixture,
        args.pending_edit_fixture,
        plan == "delayed-edit",
    )
    result = phase / "result.json"
    log = phase / "authority.log"
    input_arg = "-"
    if text is not None:
        input_path = phase / "operator-edit.txt"
        input_path.write_text(text, encoding="utf-8")
        input_path.chmod(0o600)
        input_arg = str(input_path)
    command = [
        str(args.guile),
        "--no-auto-compile",
    ]
    for source in args.load_path:
        command.extend(("-L", str(source)))
    command.extend(
        (
            str(args.authority),
            str(state_root),
            str(phase),
            str(result),
            profile,
            plan,
            input_arg,
            str(args.koreader_dir),
            str(document),
        )
    )
    process: subprocess.Popen[bytes] | None = None
    authority_identity: tuple[int, str] | None = None
    ACTIVE_PHASE = phase
    try:
        with log.open("wb") as output:
            log.chmod(0o600)
            process = subprocess.Popen(
                command,
                cwd=args.join_dir,
                env=authority_environment(),
                stdin=subprocess.DEVNULL,
                stdout=output,
                stderr=subprocess.STDOUT,
            )
            ACTIVE_PROCESS = process
            authority_identity = write_process_record(
                phase / "authority.pid", process.pid
            )
            try:
                return_code = process.wait(timeout=35)
            except subprocess.TimeoutExpired:
                process.terminate()
                try:
                    process.wait(timeout=2)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=2)
                return_code = 124
    finally:
        if process is not None and process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=2)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=2)
        for record in (
            phase / "book.pid", phase / "reader.pid", phase / "authority.pid"
        ):
            clean_recorded_child(record)
        ACTIVE_PROCESS = None
        ACTIVE_PHASE = None
    log_bytes = log.read_bytes()
    if len(log_bytes) >= MAX_LOG_BYTES:
        fail(f"{name} authority log reached its bound")
    if return_code != 0:
        sys.stderr.buffer.write(log_bytes)
        fail(f"{name} authority exited {return_code}")
    if not result.exists():
        fail(f"{name} produced no terminal result")
    value = load_json(result)
    if authority_identity is None or (
        value["authority"]["pid"], value["authority"]["start_time"]
    ) != authority_identity:
        fail(f"{name} authority identity differs from the external owner record")
    if value.get("profile") != profile or value.get("plan") != plan:
        fail(f"{name} result changed trusted profile/plan")
    if value.get("cleanup") != "endpoint-revoked-before-ui-finish":
        fail(f"{name} did not close its endpoint before UI finish")
    return value, phase


def exact_line_count(text: str, line: str) -> int:
    return sum(candidate == line for candidate in text.splitlines())


def check_reader_log(phase: Path, expected_load: str, plan: str, text: str | None) -> None:
    log_path = phase / "reader.log"
    data = log_path.read_bytes()
    if len(data) >= MAX_LOG_BYTES:
        fail(f"{phase.name} KOReader log reached its bound")
    log = data.decode("utf-8", errors="strict")
    forbidden = ("BOOK_STATE_READER: FAIL:", "Saving failed.")
    if any(token in log for token in forbidden):
        fail(f"{phase.name} KOReader reported a UI failure")
    required_once = (
        "BOOK_STATE_READER_JOIN_SPAWN: koreader:fd-hygiene:only-stdio-and-donated",
        f" [*] Version: {KOREADER_REVISION}",
        "BOOK_STATE_READER: plugin-init:trusted-automated-fixture",
        "BOOK_STATE_READER: private-source-registered",
        "BOOK_STATE_READER: selection-action:registered",
        "BOOK_STATE_READER: dialog-ready:generation=1",
        f"BOOK_STATE_READER: status-painted:generation=1:state={expected_load}",
        "BOOK_STATE_READER: cleanup-audit:all-generations-clean",
        "BOOK_STATE_READER_UI_AUDIT: cleanup:dialogs-source-fd-action-callback:clean",
    )
    for line in required_once:
        if exact_line_count(log, line) != 1:
            fail(f"{phase.name} expected exactly one log line: {line!r}")
    submit_count = sum(
        line.startswith("BOOK_STATE_READER: submit:generation=1:")
        for line in log.splitlines()
    )
    if plan in {"save", "retry-same-operation"}:
        if submit_count != 1:
            fail(f"{phase.name} did not invoke exactly one real Save callback")
        saved = "BOOK_STATE_READER: status-painted:generation=1:state=saved"
        if exact_line_count(log, saved) != 1:
            fail(f"{phase.name} did not paint exactly one Saved state")
        assert text is not None
        paint = (
            "BOOK_STATE_READER_UI_AUDIT: paintTo-state:generation=1:state=saved:"
            f"text-bytes={len(text.encode('utf-8'))}"
        )
        if exact_line_count(log, paint) != 1:
            fail(f"{phase.name} Saved paint did not retain exact submitted bytes")
    elif plan == "read-only-failure":
        if submit_count != 2:
            fail(f"{phase.name} did not resubmit the retained failed draft")
        if ":state=saved" in log:
            fail(f"{phase.name} displayed Saved for a failed backend commit")
        failed = "BOOK_STATE_READER: status-painted:generation=1:state=failed"
        if exact_line_count(log, failed) != 2:
            fail(f"{phase.name} did not paint two actual failure receipts")
        assert text is not None
        failed_paint = (
            "BOOK_STATE_READER_UI_AUDIT: paintTo-state:generation=1:state=failed:"
            f"text-bytes={len(text.encode('utf-8'))}"
        )
        if exact_line_count(log, failed_paint) != 2:
            fail(f"{phase.name} did not retain exact failed draft bytes")
    elif plan == "delayed-edit":
        if submit_count != 1 or ":state=saved" in log:
            fail(f"{phase.name} mislabeled a newer draft Saved")
        marker = (
            "BOOK_STATE_READER_JOIN_PENDING_EDIT: actual-widget-edited:"
            f"text-bytes={len(DELAYED_NEW_DRAFT.encode('utf-8'))}"
        )
        if exact_line_count(log, marker) != 1:
            fail(f"{phase.name} did not perform the actual pending widget edit")
        dirty_paint = (
            "BOOK_STATE_READER_UI_AUDIT: paintTo-state:generation=1:state=dirty:"
            f"text-bytes={len(DELAYED_NEW_DRAFT.encode('utf-8'))}"
        )
        if exact_line_count(log, dirty_paint) != 1:
            fail(f"{phase.name} did not paint the newer draft Dirty after receipt")
    elif plan in {"forged-present", "mismatched-commit"}:
        if submit_count != 1 or ":state=saved" in log:
            fail(f"{phase.name} promoted untrusted evidence to Saved")
    elif submit_count != 0 or ":state=saved" in log:
        fail(f"{phase.name} non-editing UI displayed a save fact")


def require_load(
    result: dict[str, Any], *, present: bool, version: int, text: str
) -> None:
    load = result.get("load")
    if load != {
        "present": present,
        "state_version": version,
        "text": text,
        "ui_applied_text": text,
    }:
        fail(f"typed load/UI paint mismatch: {load!r}")


def require_success(result: dict[str, Any], text: str, version: int) -> None:
    decision = result.get("save_decision")
    if not (
        isinstance(decision, list)
        and len(decision) == 4
        and decision[0] == "committed"
        and decision[2] == version
        and decision[3] == text
        and result.get("ui_saved") is True
        and result.get("ui_saved_text") == text
    ):
        fail(f"save did not map exact typed receipt to Saved: {decision!r}")
    completion = result.get("save_completion")
    if not (
        isinstance(completion, dict)
        and completion.get("operation_kind") == "commit"
        and completion.get("response_type") == "state-committed"
        and completion.get("expected_state_version") == version - 1
        and completion.get("text") == text
        and completion.get("operation_id") == decision[1]
        and completion.get("resulting_state_version") == version
        and completion.get("result_text_bytes") == len(text.encode("utf-8"))
    ):
        fail("save completion lost operation/text/version identity")
    if not isinstance(result.get("presentation_action"), dict):
        fail("successful save lacked separate post-receipt book presentation")


def require_operation_id(result: dict[str, Any]) -> str:
    action = result.get("save_action")
    completion = result.get("save_completion")
    if not isinstance(action, dict) or not isinstance(completion, dict):
        fail("saved lifecycle omitted action/completion identity")
    value = completion.get("operation_id")
    expected = (
        f"note_{action['surface_handle']}_s{action['surface_generation']}"
        f"_q{action['sequence']}"
    )
    allowed = set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")
    if (
        not isinstance(value, str)
        or value != expected
        or not 1 <= len(value.encode("ascii")) <= 128
        or not set(value) <= allowed
    ):
        fail(f"book operation ID is not the fresh action-derived ID: {value!r}")
    return value


def require_same_operation_retry(result: dict[str, Any]) -> None:
    original = result.get("save_completion")
    retry = result.get("retry_completion")
    if not isinstance(original, dict) or not isinstance(retry, dict):
        fail("same-operation retry omitted either typed completion")
    fields = (
        "session_id", "surface_generation", "grant_generation",
        "operation_kind", "operation_id", "expected_state_version", "text",
        "response_type", "resulting_state_version", "result_text_bytes",
    )
    if any(original.get(field) != retry.get(field) for field in fields):
        fail("same-operation retry did not return the original exact receipt")


def require_fresh(left: dict[str, Any], right: dict[str, Any], label: str) -> None:
    for role in ("authority", "book", "reader"):
        left_identity = (left[role]["pid"], left[role]["start_time"])
        right_identity = (right[role]["pid"], right[role]["start_time"])
        if left_identity == right_identity:
            fail(f"{label} reused the old {role} process identity")
    for field in ("session_id", "surface_handle", "grant_handle"):
        if left[field] == right[field]:
            fail(f"{label} reused old endpoint identity field {field}")


def database_rows(database: Path) -> dict[tuple[str, str], tuple[int, int, str]]:
    connection = sqlite3.connect(f"file:{database}?mode=ro", uri=True)
    try:
        rows = connection.execute(
            "SELECT book_revision, instance_id, state_version, has_value, text "
            "FROM book_instances ORDER BY book_revision, instance_id"
        ).fetchall()
    finally:
        connection.close()
    return {
        (row[0], row[1]):
        (int(row[2]), int(row[3]), "" if row[4] is None else str(row[4]))
        for row in rows
    }


def database_receipts(
    database: Path,
) -> list[tuple[str, str, str, int, int, int, str]]:
    connection = sqlite3.connect(f"file:{database}?mode=ro", uri=True)
    try:
        rows = connection.execute(
            "SELECT b.book_revision, b.instance_id, r.operation_id, "
            "r.expected_state_version, r.resulting_state_version, r.text_bytes, "
            "r.text FROM commit_receipts AS r "
            "JOIN book_instances AS b ON b.namespace_id = r.namespace_id "
            "ORDER BY b.book_revision, b.instance_id, r.resulting_state_version"
        ).fetchall()
    finally:
        connection.close()
    return [
        (
            str(row[0]), str(row[1]), str(row[2]), int(row[3]), int(row[4]),
            int(row[5]), str(row[6]),
        )
        for row in rows
    ]


def database_audit(database: Path) -> tuple[str, list[tuple[Any, ...]]]:
    connection = sqlite3.connect(f"file:{database}?mode=ro", uri=True)
    try:
        integrity = str(connection.execute("PRAGMA integrity_check").fetchone()[0])
        foreign_keys = connection.execute("PRAGMA foreign_key_check").fetchall()
    finally:
        connection.close()
    return integrity, foreign_keys


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--run-root", type=exact_dir, required=True)
    parser.add_argument("--join-dir", type=exact_dir, required=True)
    parser.add_argument("--ui-fixture", type=exact_dir, required=True)
    parser.add_argument("--pending-edit-fixture", type=exact_dir, required=True)
    parser.add_argument("--koreader-dir", type=exact_dir, required=True)
    parser.add_argument("--guile", type=Path, required=True)
    parser.add_argument("--authority", type=Path, required=True)
    parser.add_argument("--load-path", type=exact_dir, action="append", required=True)
    return parser.parse_args()


def main() -> int:
    args = parse_arguments()
    state_root = args.run_root / "state"
    suite_root = args.run_root / "lives"
    make_private_dir(state_root)
    make_private_dir(suite_root)

    def phase(
        number: int, label: str, profile: str, plan: str, text: str | None
    ) -> tuple[dict[str, Any], Path]:
        return run_phase(
            args, state_root, suite_root, f"{number:02d}-{label}", profile, plan, text
        )

    guile_a, guile_a_dir = phase(1, "guile-save-a", "guile-note", "save", GUILE_TEXT_A)
    guile_b, guile_b_dir = phase(2, "guile-save-b", "guile-note", "save", GUILE_TEXT_B)
    guile_c, guile_c_dir = phase(3, "guile-save-c", "guile-note", "save", GUILE_TEXT_C)
    guile_load, guile_load_dir = phase(4, "guile-load-c", "guile-note", "load", None)

    python_a, python_a_dir = phase(5, "python-save-a", "python-note", "save", PYTHON_TEXT_A)
    python_b, python_b_dir = phase(6, "python-save-b", "python-note", "save", PYTHON_TEXT_B)
    python_c, python_c_dir = phase(7, "python-save-c", "python-note", "save", PYTHON_TEXT_C)
    python_load, python_load_dir = phase(8, "python-load-c", "python-note", "load", None)

    empty_seed, empty_seed_dir = phase(
        9, "empty-save-nonempty", "guile-empty", "save", EMPTY_SEED_TEXT
    )
    empty_clear, empty_clear_dir = phase(
        10, "empty-clear-save", "guile-empty", "save", ""
    )
    empty_load, empty_load_dir = phase(
        11, "empty-load", "guile-empty", "load", None
    )

    readonly_seed, readonly_seed_dir = phase(
        12, "read-only-seed", "guile-read-only-seed", "save", READ_ONLY_SEED_TEXT
    )
    readonly, readonly_dir = phase(
        13, "read-only-empty-failure", "guile-read-only",
        "read-only-failure", ""
    )

    delayed_save, delayed_save_dir = phase(
        14, "delayed-edit-save", "guile-delayed-edit", "delayed-edit",
        DELAYED_SUBMISSION
    )
    delayed_load, delayed_load_dir = phase(
        15, "delayed-edit-reopen", "guile-delayed-edit", "load", None
    )
    forged, forged_dir = phase(
        16, "forged-present", "guile-forged-present", "forged-present",
        FORGED_PRESENT_TEXT
    )
    mismatch, mismatch_dir = phase(
        17, "mismatched-commit", "guile-mismatched-commit",
        "mismatched-commit", MISMATCH_SUBMISSION
    )
    mismatch_load, mismatch_load_dir = phase(
        18, "mismatched-reopen", "guile-mismatched-recover", "load", None
    )

    max_save, max_save_dir = phase(
        19, "max-text-save", "guile-max-text", "save", MAX_TEXT
    )
    max_load, max_load_dir = phase(
        20, "max-text-load", "guile-max-text", "load", None
    )
    retry_save, retry_save_dir = phase(
        21, "same-operation-retry", "guile-retry", "retry-same-operation",
        RETRY_TEXT
    )
    retry_load, retry_load_dir = phase(
        22, "same-operation-reopen", "guile-retry", "load", None
    )

    phases = (
        (guile_a, guile_a_dir, "loaded-absent", "save", GUILE_TEXT_A),
        (guile_b, guile_b_dir, "loaded-value", "save", GUILE_TEXT_B),
        (guile_c, guile_c_dir, "loaded-value", "save", GUILE_TEXT_C),
        (guile_load, guile_load_dir, "loaded-value", "load", None),
        (python_a, python_a_dir, "loaded-absent", "save", PYTHON_TEXT_A),
        (python_b, python_b_dir, "loaded-value", "save", PYTHON_TEXT_B),
        (python_c, python_c_dir, "loaded-value", "save", PYTHON_TEXT_C),
        (python_load, python_load_dir, "loaded-value", "load", None),
        (empty_seed, empty_seed_dir, "loaded-absent", "save", EMPTY_SEED_TEXT),
        (empty_clear, empty_clear_dir, "loaded-value", "save", ""),
        (empty_load, empty_load_dir, "loaded-value", "load", None),
        (
            readonly_seed, readonly_seed_dir, "loaded-absent", "save",
            READ_ONLY_SEED_TEXT,
        ),
        (readonly, readonly_dir, "loaded-value", "read-only-failure", ""),
        (
            delayed_save, delayed_save_dir, "loaded-absent", "delayed-edit",
            DELAYED_SUBMISSION,
        ),
        (delayed_load, delayed_load_dir, "loaded-value", "load", None),
        (
            forged, forged_dir, "loaded-absent", "forged-present",
            FORGED_PRESENT_TEXT,
        ),
        (
            mismatch, mismatch_dir, "loaded-absent", "mismatched-commit",
            MISMATCH_SUBMISSION,
        ),
        (mismatch_load, mismatch_load_dir, "loaded-value", "load", None),
        (max_save, max_save_dir, "loaded-absent", "save", MAX_TEXT),
        (max_load, max_load_dir, "loaded-value", "load", None),
        (
            retry_save, retry_save_dir, "loaded-absent", "retry-same-operation",
            RETRY_TEXT,
        ),
        (retry_load, retry_load_dir, "loaded-value", "load", None),
    )
    seen: dict[str, set[tuple[int, str]]] = {
        "authority": set(), "book": set(), "reader": set()
    }
    for result, phase, expected_load, plan, text in phases:
        check_reader_log(phase, expected_load, plan, text)
        for role in seen:
            process = result.get(role)
            identity = (process["pid"], process["start_time"])
            if identity in seen[role]:
                fail(f"fresh lifecycle reused {role} PID/start-time {identity!r}")
            if role != "authority" and process.get("exit_code") != 0:
                fail(f"{phase.name} {role} did not exit cleanly")
            if read_start_time(identity[0]) == identity[1]:
                fail(f"{phase.name} left exact {role} process identity present")
            seen[role].add(identity)

    require_load(guile_a, present=False, version=0, text="")
    require_success(guile_a, GUILE_TEXT_A, 1)
    require_load(guile_b, present=True, version=1, text=GUILE_TEXT_A)
    require_success(guile_b, GUILE_TEXT_B, 2)
    require_load(guile_c, present=True, version=2, text=GUILE_TEXT_B)
    require_success(guile_c, GUILE_TEXT_C, 3)
    require_load(guile_load, present=True, version=3, text=GUILE_TEXT_C)
    require_fresh(guile_a, guile_b, "Guile save A to B")
    require_fresh(guile_b, guile_c, "Guile save B to C")
    require_fresh(guile_c, guile_load, "Guile final reopen")

    require_load(python_a, present=False, version=0, text="")
    require_success(python_a, PYTHON_TEXT_A, 1)
    require_load(python_b, present=True, version=1, text=PYTHON_TEXT_A)
    require_success(python_b, PYTHON_TEXT_B, 2)
    require_load(python_c, present=True, version=2, text=PYTHON_TEXT_B)
    require_success(python_c, PYTHON_TEXT_C, 3)
    require_load(python_load, present=True, version=3, text=PYTHON_TEXT_C)
    require_fresh(python_a, python_b, "Python save A to B")
    require_fresh(python_b, python_c, "Python save B to C")
    require_fresh(python_c, python_load, "Python final reopen")

    for label, results in (
        ("Guile", (guile_a, guile_b, guile_c)),
        ("Python", (python_a, python_b, python_c)),
    ):
        operation_ids = [require_operation_id(result) for result in results]
        if len(set(operation_ids)) != 3:
            fail(f"{label} fresh save intents reused an operation ID")

    require_load(empty_seed, present=False, version=0, text="")
    require_success(empty_seed, EMPTY_SEED_TEXT, 1)
    require_load(empty_clear, present=True, version=1, text=EMPTY_SEED_TEXT)
    require_success(empty_clear, "", 2)
    require_load(empty_load, present=True, version=2, text="")
    require_fresh(empty_seed, empty_clear, "empty-note clear")
    require_fresh(empty_clear, empty_load, "present-empty reopen")

    require_load(readonly_seed, present=False, version=0, text="")
    require_success(readonly_seed, READ_ONLY_SEED_TEXT, 1)
    require_load(
        readonly, present=True, version=1, text=READ_ONLY_SEED_TEXT
    )
    decision = readonly.get("save_decision")
    completion = readonly.get("save_completion")
    retry_action = readonly.get("retry_action")
    retry_completion = readonly.get("retry_completion")
    if not (
        decision[0] == "failed"
        and decision[2] == "read-only"
        and decision[3] == ""
        and completion["response_type"] == "state-commit-failed"
        and completion["text"] == ""
        and isinstance(retry_action, dict)
        and retry_completion["response_type"] == "state-commit-failed"
        and retry_completion["text"] == ""
        and retry_completion["operation_id"] != completion["operation_id"]
        and readonly.get("ui_saved") is False
    ):
        fail("real read-only failure did not retain the exact empty UI draft")

    require_load(delayed_save, present=False, version=0, text="")
    require_success_fields = delayed_save.get("save_decision")
    if not (
        require_success_fields[0] == "committed"
        and require_success_fields[2:] == [1, DELAYED_SUBMISSION]
        and delayed_save.get("ui_saved") is False
    ):
        fail("delayed receipt did not retain the newer widget draft as Dirty")
    require_load(
        delayed_load, present=True, version=1, text=DELAYED_SUBMISSION
    )
    require_fresh(delayed_save, delayed_load, "delayed-edit reopen")

    require_load(forged, present=False, version=0, text="")
    if not (
        forged.get("save_decision")
        == ["rejected-forged-present", False, False, FORGED_PRESENT_TEXT]
        and forged.get("save_completion") is False
        and forged.get("ui_saved") is False
    ):
        fail("forged early presentation crossed into storage/UI success")

    require_load(mismatch, present=False, version=0, text="")
    if not (
        mismatch.get("save_decision")[0] == "rejected-mismatched-completion"
        and mismatch["save_decision"][2:] == [1, MISMATCH_DURABLE]
        and mismatch["save_completion"]["text"] == MISMATCH_DURABLE
        and mismatch.get("ui_saved") is False
    ):
        fail("mismatched book commit marked the unrelated UI draft Saved")
    require_load(mismatch_load, present=True, version=1, text=MISMATCH_DURABLE)
    require_fresh(mismatch, mismatch_load, "mismatched-commit reopen")

    require_load(max_save, present=False, version=0, text="")
    require_success(max_save, MAX_TEXT, 1)
    require_load(max_load, present=True, version=1, text=MAX_TEXT)
    require_fresh(max_save, max_load, "exact 4 KiB reopen")

    require_load(retry_save, present=False, version=0, text="")
    require_success(retry_save, RETRY_TEXT, 1)
    require_same_operation_retry(retry_save)
    require_load(retry_load, present=True, version=1, text=RETRY_TEXT)
    require_fresh(retry_save, retry_load, "same-operation retry reopen")

    database = state_root / "book-state-v1.sqlite"
    rows = database_rows(database)
    expected_rows = {
        ("reader-note/guile@1", "persistent-note-guile"): (3, 1, GUILE_TEXT_C),
        ("reader-note/python@1", "persistent-note-python"): (3, 1, PYTHON_TEXT_C),
        ("reader-note/empty@1", "persistent-note-empty"): (2, 1, ""),
        ("reader-note/read-only-test@1", "persistent-note-read-only"):
        (1, 1, READ_ONLY_SEED_TEXT),
        ("reader-note/delayed-edit@1", "persistent-note-delayed-edit"):
        (1, 1, DELAYED_SUBMISSION),
        ("reader-note/forged-present@1", "persistent-note-forged-present"):
        (0, 0, ""),
        ("reader-note/mismatched-commit@1", "persistent-note-mismatched-commit"):
        (1, 1, MISMATCH_DURABLE),
        ("reader-note/max-text@1", "persistent-note-max-text"):
        (1, 1, MAX_TEXT),
        ("reader-note/retry@1", "persistent-note-retry"):
        (1, 1, RETRY_TEXT),
    }
    if rows != expected_rows:
        fail(f"retained SQLite state differs from joined evidence: {rows!r}")

    committed = (
        (guile_a, "reader-note/guile@1", "persistent-note-guile", GUILE_TEXT_A, 0, 1),
        (guile_b, "reader-note/guile@1", "persistent-note-guile", GUILE_TEXT_B, 1, 2),
        (guile_c, "reader-note/guile@1", "persistent-note-guile", GUILE_TEXT_C, 2, 3),
        (python_a, "reader-note/python@1", "persistent-note-python", PYTHON_TEXT_A, 0, 1),
        (python_b, "reader-note/python@1", "persistent-note-python", PYTHON_TEXT_B, 1, 2),
        (python_c, "reader-note/python@1", "persistent-note-python", PYTHON_TEXT_C, 2, 3),
        (empty_seed, "reader-note/empty@1", "persistent-note-empty", EMPTY_SEED_TEXT, 0, 1),
        (empty_clear, "reader-note/empty@1", "persistent-note-empty", "", 1, 2),
        (
            readonly_seed, "reader-note/read-only-test@1", "persistent-note-read-only",
            READ_ONLY_SEED_TEXT, 0, 1,
        ),
        (
            delayed_save, "reader-note/delayed-edit@1", "persistent-note-delayed-edit",
            DELAYED_SUBMISSION, 0, 1,
        ),
        (
            mismatch, "reader-note/mismatched-commit@1",
            "persistent-note-mismatched-commit", MISMATCH_DURABLE, 0, 1,
        ),
        (max_save, "reader-note/max-text@1", "persistent-note-max-text", MAX_TEXT, 0, 1),
        (retry_save, "reader-note/retry@1", "persistent-note-retry", RETRY_TEXT, 0, 1),
    )
    expected_receipts = sorted(
        [
            (
                revision,
                instance,
                str(result["save_completion"]["operation_id"]),
                expected,
                resulting,
                len(text.encode("utf-8")),
                text,
            )
            for result, revision, instance, text, expected, resulting in committed
        ],
        key=lambda row: (row[0], row[1], row[4]),
    )
    receipts = database_receipts(database)
    if receipts != expected_receipts:
        fail("SQLite receipts differ from exact book-issued commit evidence")
    new_intent_ids = [row[2] for row in receipts]
    if len(set(new_intent_ids)) != len(new_intent_ids):
        fail("distinct committed intents reused an operation ID")
    retry_id = retry_save["save_completion"]["operation_id"]
    retry_rows = [row for row in receipts if row[2] == retry_id]
    if len(retry_rows) != 1:
        fail("same-operation retry created more than one durable receipt")

    integrity, foreign_keys = database_audit(database)
    if integrity != "ok" or foreign_keys:
        fail(f"SQLite integrity failed: {integrity!r}, foreign keys={foreign_keys!r}")
    for suffix in ("-journal", "-wal", "-shm"):
        if Path(f"{database}{suffix}").exists():
            fail(f"SQLite did not quiesce: {database}{suffix}")

    evidence = {
        "format": 2,
        "guile": {
            "displayed_texts": [GUILE_TEXT_A, GUILE_TEXT_B, GUILE_TEXT_C],
            "versions": [1, 2, 3],
            "operation_ids": [
                result["save_completion"]["operation_id"]
                for result in (guile_a, guile_b, guile_c)
            ],
            "final_reopen": guile_load["load"],
        },
        "python": {
            "displayed_texts": [PYTHON_TEXT_A, PYTHON_TEXT_B, PYTHON_TEXT_C],
            "versions": [1, 2, 3],
            "operation_ids": [
                result["save_completion"]["operation_id"]
                for result in (python_a, python_b, python_c)
            ],
            "final_reopen": python_load["load"],
        },
        "present_empty": {
            "clear_save": empty_clear["save_completion"],
            "fresh_load": empty_load["load"],
        },
        "read_only_empty_failure": {
            "durable_before": READ_ONLY_SEED_TEXT,
            "first": readonly["save_completion"],
            "second": readonly["retry_completion"],
            "database_after": list(rows[(
                "reader-note/read-only-test@1", "persistent-note-read-only"
            )]),
        },
        "delayed_edit": {
            "submitted": DELAYED_SUBMISSION,
            "newer_widget_draft": DELAYED_NEW_DRAFT,
            "ui_saved": delayed_save["ui_saved"],
            "reopened_durable_text": delayed_load["load"]["text"],
        },
        "forged_present": forged["save_decision"],
        "mismatched_commit": {
            "submitted": MISMATCH_SUBMISSION,
            "durable": mismatch_load["load"]["text"],
            "ui_saved": mismatch["ui_saved"],
        },
        "exact_4096_bytes": max_load["load"],
        "same_operation_retry": {
            "first": retry_save["save_completion"],
            "retry": retry_save["retry_completion"],
            "durable_receipt_count": len(retry_rows),
        },
        "sqlite_rows": [
            [revision, instance, *values]
            for (revision, instance), values in sorted(rows.items())
        ],
        "sqlite_receipt_count": len(receipts),
        "sqlite_integrity_check": integrity,
        "sqlite_foreign_key_violations": len(foreign_keys),
        "fresh_lifecycles": len(phases),
        "unique_process_identities": {
            role: len(identities) for role, identities in seen.items()
        },
    }
    evidence_path = args.run_root / "joined-evidence.json"
    evidence_path.write_text(
        json.dumps(evidence, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )
    evidence_path.chmod(0o600)
    print(
        f"JOIN_EVIDENCE guile version=3 painted={GUILE_TEXT_C!r} "
        f"fresh={guile_load['authority']['pid']}/{guile_load['book']['pid']}/"
        f"{guile_load['reader']['pid']}"
    )
    print(
        f"JOIN_EVIDENCE python version=3 painted={PYTHON_TEXT_C!r} "
        f"fresh={python_load['authority']['pid']}/{python_load['book']['pid']}/"
        f"{python_load['reader']['pid']}"
    )
    print(
        "JOIN_EVIDENCE UI-empty-save=version2; read-only-empty-retained; "
        "exact-4096=ok; retry-one-receipt=ok"
    )
    print(
        f"JOIN_EVIDENCE sqlite namespaces={len(rows)} receipts={len(receipts)} "
        f"integrity={integrity}; fresh-lifecycles={len(phases)}"
    )
    return 0


if __name__ == "__main__":
    signal.signal(signal.SIGTERM, deadline_signal)
    signal.signal(signal.SIGINT, deadline_signal)
    try:
        raise SystemExit(main())
    except Exception as error:
        print(f"BOOK_STATE_READER_JOIN_TEST: FAIL: {error}", file=sys.stderr)
        raise
