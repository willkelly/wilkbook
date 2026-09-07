#!/usr/bin/env python3
"""Native Python fixture book for the trusted Book State integration proof."""

from __future__ import annotations

import fcntl
import os
import signal
import socket
import sys
from collections.abc import Iterator
from typing import Any

from book_protocol import FrameDecoder, encode_frame


INITIALIZE_FIELDS = {
    "type",
    "version",
    "grant_count",
    "surface_handle",
    "surface_generation",
    "max_pending_requests",
    "max_present_text_bytes",
}
STATE_READY_FIELDS = {
    "type",
    "protocol_version",
    "grant_handle",
    "grant_generation",
    "access",
}
STATE_VALUE_FIELDS = {
    "type",
    "protocol_version",
    "present",
    "state_version",
    "text",
}
COMMITTED_FIELDS = {
    "type",
    "protocol_version",
    "operation_id",
    "state_version",
    "text_bytes",
}
ACTION_FIELDS = {
    "type",
    "request_id",
    "action_id",
    "surface_handle",
    "surface_generation",
    "sequence",
    "text",
}
MAX_STATE_TEXT_BYTES = 4096


def require_integer(value: object) -> bool:
    return type(value) is int


def require_initialize(message: dict[str, Any]) -> None:
    if not (
        set(message) == INITIALIZE_FIELDS
        and message["type"] == "initialize"
        and message["version"] == 1
        and message["grant_count"] == 1
        and type(message["surface_handle"]) is str
        and message["surface_handle"]
        and message["surface_generation"] == 1
        and message["max_pending_requests"] == 4
        and message["max_present_text_bytes"] == 4096
    ):
        raise RuntimeError("initialize did not match the fixed native fixture")


def require_state_ready(message: dict[str, Any]) -> None:
    if not (
        set(message) == STATE_READY_FIELDS
        and message["type"] == "state-ready"
        and message["protocol_version"] == 1
        and type(message["grant_handle"]) is str
        and message["grant_handle"]
        and require_integer(message["grant_generation"])
        and message["grant_generation"] > 0
        and message["access"] == "read-write"
    ):
        raise RuntimeError("state-ready did not match the fixed native fixture")


def require_state_value(message: dict[str, Any]) -> dict[str, Any]:
    present = message.get("present")
    version = message.get("state_version")
    text = message.get("text")
    if not (
        set(message) == STATE_VALUE_FIELDS
        and message["type"] == "state-value"
        and message["protocol_version"] == 1
        and type(present) is bool
        and require_integer(version)
        and version >= 0
        and type(text) is str
        and len(text.encode("utf-8")) <= MAX_STATE_TEXT_BYTES
        and (version > 0 if present else version == 0 and text == "")
    ):
        raise RuntimeError("state-value did not match the fixed native fixture")
    return message


def require_action(message: dict[str, Any], action_id: str) -> dict[str, Any]:
    if not (
        set(message) == ACTION_FIELDS
        and message["type"] == "action"
        and message["action_id"] == action_id
        and type(message["request_id"]) is str
        and message["request_id"]
        and type(message["surface_handle"]) is str
        and message["surface_handle"]
        and require_integer(message["surface_generation"])
        and require_integer(message["sequence"])
        and type(message["text"]) is str
    ):
        raise RuntimeError(f"action {action_id!r} did not match the fixture")
    return message


def require_committed(
    message: dict[str, Any], operation_id: str, expected: int, text: str
) -> dict[str, Any]:
    if not (
        set(message) == COMMITTED_FIELDS
        and message["type"] == "state-committed"
        and message["protocol_version"] == 1
        and message["operation_id"] == operation_id
        and message["state_version"] == expected + 1
        and message["text_bytes"] == len(text.encode("utf-8"))
    ):
        raise RuntimeError("state-committed did not match the exact request")
    return message


def messages(connection: socket.socket) -> Iterator[dict[str, Any]]:
    decoder = FrameDecoder()
    while True:
        data = connection.recv(4096)
        if not data:
            decoder.finish()
            return
        yield from decoder.feed(data)


def send(connection: socket.socket, message: dict[str, Any]) -> None:
    connection.sendall(encode_frame(message))


def read_type(stream: Iterator[dict[str, Any]], expected: str) -> dict[str, Any]:
    message = next(stream)
    if message.get("type") != expected:
        raise RuntimeError(
            f"authority sent {message.get('type')!r}, expected {expected!r}"
        )
    return message


def state_read(ready: dict[str, Any]) -> dict[str, Any]:
    return {
        "type": "state-read",
        "protocol_version": 1,
        "grant_handle": ready["grant_handle"],
        "grant_generation": ready["grant_generation"],
    }


def state_commit(
    ready: dict[str, Any], operation_id: str, expected: int, text: str
) -> dict[str, Any]:
    return {
        "type": "state-commit",
        "protocol_version": 1,
        "grant_handle": ready["grant_handle"],
        "grant_generation": ready["grant_generation"],
        "operation_id": operation_id,
        "expected_state_version": expected,
        "text": text,
    }


def presentation(action: dict[str, Any], text: str) -> dict[str, Any]:
    return {
        "type": "present",
        "request_id": action["request_id"],
        "action_id": action["action_id"],
        "surface_handle": action["surface_handle"],
        "surface_generation": action["surface_generation"],
        "sequence": action["sequence"],
        "count": 1,
        "text": text,
    }


def receive_load_state_and_action(
    connection: socket.socket,
    stream: Iterator[dict[str, Any]],
    ready: dict[str, Any],
) -> tuple[dict[str, Any], dict[str, Any]]:
    send(connection, state_read(ready))
    snapshot: dict[str, Any] | None = None
    action: dict[str, Any] | None = None
    while snapshot is None or action is None:
        message = next(stream)
        if message.get("type") == "state-value":
            if snapshot is not None:
                raise RuntimeError("duplicate state-value")
            snapshot = require_state_value(message)
        elif message.get("type") == "action":
            if action is not None:
                raise RuntimeError("duplicate load-display action")
            action = require_action(message, "load-display")
        else:
            raise RuntimeError("unexpected message before load presentation")
    return snapshot, action


def commit_text(mode: str, snapshot: dict[str, Any], action: dict[str, Any]) -> str:
    if mode == "save":
        return action["text"]
    if mode in {"save-loaded", "replay"}:
        marker = "REPLAY-LOADED" if mode == "replay" else "SAVE-LOADED"
        if action["text"] != marker or not snapshot["present"]:
            raise RuntimeError("loaded-state action marker is invalid")
        return snapshot["text"]
    if mode == "boundary-save":
        if action["text"] != "SAVE-NUL-4096":
            raise RuntimeError("boundary action marker is invalid")
        return "\x00" * MAX_STATE_TEXT_BYTES
    raise RuntimeError(f"unknown fixture mode: {mode}")


def run(
    connection: socket.socket, mode: str, operation_id: str, replay_expected: int
) -> None:
    stream = messages(connection)
    send(connection, {"type": "hello", "version": 1})
    initialize = read_type(stream, "initialize")
    ready = read_type(stream, "state-ready")
    require_initialize(initialize)
    require_state_ready(ready)

    snapshot, load_action = receive_load_state_and_action(connection, stream, ready)
    display = snapshot["text"] if snapshot["present"] else "ABSENT"
    send(connection, presentation(load_action, display))

    edit_action = require_action(read_type(stream, "action"), "edit-save")
    text = commit_text(mode, snapshot, edit_action)
    expected = replay_expected if mode == "replay" else snapshot["state_version"]
    send(connection, state_commit(ready, operation_id, expected, text))
    committed = require_committed(
        read_type(stream, "state-committed"), operation_id, expected, text
    )

    if mode == "replay":
        send(connection, state_read(ready))
        current = require_state_value(read_type(stream, "state-value"))[
            "state_version"
        ]
    else:
        current = committed["state_version"]
    receipt = (
        f"receipt={operation_id}|state-version={committed['state_version']}|"
        f"text-bytes={committed['text_bytes']}|current-version={current}"
    )
    send(connection, presentation(edit_action, receipt))


def require_protocol_fd() -> socket.socket:
    if os.environ.get("BOOK_SESSION_FD") != "0":
        raise RuntimeError("BOOK_SESSION_FD must name donated FD 0")
    donated = os.fstat(0)
    if not stat_is_socket(donated.st_mode):
        raise RuntimeError("donated FD 0 is not a socket")
    if fcntl.fcntl(0, fcntl.F_GETFD) & fcntl.FD_CLOEXEC:
        raise RuntimeError("donated FD 0 remained close-on-exec")
    connection = socket.socket(fileno=0)
    if connection.type & socket.SOCK_STREAM != socket.SOCK_STREAM:
        raise RuntimeError("donated FD 0 is not a stream socket")
    if connection.family != socket.AF_UNIX or not connection.getpeername() == "":
        # Linux unnamed socketpairs report empty local and peer addresses.
        raise RuntimeError("donated FD 0 is not a connected Unix socketpair")
    for name in os.listdir("/proc/self/fd"):
        try:
            fd = int(name)
        except ValueError:
            continue
        if fd <= 2:
            continue
        try:
            flags = fcntl.fcntl(fd, fcntl.F_GETFD)
            info = os.fstat(fd)
        except OSError:
            continue
        if info.st_dev == donated.st_dev and info.st_ino == donated.st_ino:
            raise RuntimeError(f"fixture retained duplicate donated socket FD {fd}")
        if not flags & fcntl.FD_CLOEXEC:
            raise RuntimeError(f"fixture inherited unrelated non-CLOEXEC FD {fd}")
    return connection


def stat_is_socket(mode: int) -> bool:
    import stat

    return stat.S_ISSOCK(mode)


def main() -> int:
    if len(sys.argv) != 4:
        raise RuntimeError(
            "usage: fixture_book.py MODE OPERATION-ID REPLAY-EXPECTED"
        )
    mode, operation_id, replay_text = sys.argv[1:]
    replay_expected = int(replay_text, 10)
    os.setpgid(0, 0)
    os.kill(os.getpid(), signal.SIGSTOP)
    connection = require_protocol_fd()
    try:
        run(connection, mode, operation_id, replay_expected)
    finally:
        connection.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
