#!/usr/bin/env python3
"""Fixed Python persistent-note book; state arrives only over donated FD 3."""

from __future__ import annotations

import fcntl
import os
import signal
import socket
import stat
import sys
from collections.abc import Iterator
from typing import Any

from book_protocol import FrameDecoder, encode_frame


INITIALIZE_FIELDS = {
    "type", "version", "grant_count", "surface_handle", "surface_generation",
    "max_pending_requests", "max_present_text_bytes",
}
READY_FIELDS = {
    "type", "protocol_version", "grant_handle", "grant_generation", "access",
}
VALUE_FIELDS = {"type", "protocol_version", "present", "state_version", "text"}
ACTION_FIELDS = {
    "type", "request_id", "action_id", "surface_handle", "surface_generation",
    "sequence", "text",
}
COMMITTED_FIELDS = {
    "type", "protocol_version", "operation_id", "state_version", "text_bytes",
}
CONFLICT_FIELDS = {
    "type", "protocol_version", "operation_id", "current_state_version",
}
FAILED_FIELDS = {"type", "protocol_version", "operation_id", "code"}
OPERATION_ID_CHARACTERS = frozenset(
    "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-"
)


def marker(text: str) -> None:
    print(f"BOOK_STATE_READER_JOIN_BOOK: {text}", flush=True)


def exact_integer(value: object) -> bool:
    return type(value) is int


def require_initialize(message: dict[str, Any]) -> None:
    if not (
        set(message) == INITIALIZE_FIELDS
        and message["type"] == "initialize"
        and message["version"] == 1
        and message["grant_count"] == 1
        and isinstance(message["surface_handle"], str)
        and message["surface_handle"]
        and len(message["surface_handle"]) <= 96
        and set(message["surface_handle"]) <= OPERATION_ID_CHARACTERS
        and message["surface_generation"] == 1
        and message["max_pending_requests"] == 4
        and message["max_present_text_bytes"] == 4096
    ):
        raise RuntimeError("initialize does not match the fixed book")


def require_ready(message: dict[str, Any]) -> None:
    if not (
        set(message) == READY_FIELDS
        and message["type"] == "state-ready"
        and message["protocol_version"] == 1
        and isinstance(message["grant_handle"], str)
        and message["grant_handle"]
        and exact_integer(message["grant_generation"])
        and message["grant_generation"] > 0
        and message["access"] == "read-write"
    ):
        raise RuntimeError("state-ready does not match the fixed book")


def require_value(message: dict[str, Any]) -> dict[str, Any]:
    present = message.get("present")
    version = message.get("state_version")
    text = message.get("text")
    if not (
        set(message) == VALUE_FIELDS
        and message["type"] == "state-value"
        and message["protocol_version"] == 1
        and type(present) is bool
        and exact_integer(version)
        and version >= 0
        and isinstance(text, str)
        and len(text.encode("utf-8")) <= 4096
        and (version > 0 if present else version == 0 and text == "")
    ):
        raise RuntimeError("state-value does not match the fixed book")
    return message


def require_action(message: dict[str, Any], action_id: str) -> dict[str, Any]:
    if not (
        set(message) == ACTION_FIELDS
        and message["type"] == "action"
        and message["action_id"] == action_id
        and isinstance(message["request_id"], str)
        and message["request_id"]
        and isinstance(message["surface_handle"], str)
        and message["surface_handle"]
        and exact_integer(message["surface_generation"])
        and exact_integer(message["sequence"])
        and isinstance(message["text"], str)
        and len(message["text"].encode("utf-8")) <= 4096
    ):
        raise RuntimeError(f"action does not match fixed operation {action_id!r}")
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


def operation_id(action: dict[str, Any]) -> str:
    value = (
        f"note_{action['surface_handle']}_s{action['surface_generation']}"
        f"_q{action['sequence']}"
    )
    if not 1 <= len(value) <= 128 or not set(value) <= OPERATION_ID_CHARACTERS:
        raise RuntimeError("derived operation ID is outside the accepted wire grammar")
    return value


def state_read(ready: dict[str, Any]) -> dict[str, Any]:
    return {
        "type": "state-read", "protocol_version": 1,
        "grant_handle": ready["grant_handle"],
        "grant_generation": ready["grant_generation"],
    }


def state_commit(
    ready: dict[str, Any], action: dict[str, Any], op_id: str, version: int,
    text: str,
) -> dict[str, Any]:
    return {
        "type": "state-commit", "protocol_version": 1,
        "grant_handle": ready["grant_handle"],
        "grant_generation": ready["grant_generation"],
        "operation_id": op_id, "expected_state_version": version,
        "text": text,
    }


def presentation(action: dict[str, Any], text: str) -> dict[str, Any]:
    return {
        "type": "present", "request_id": action["request_id"],
        "action_id": action["action_id"],
        "surface_handle": action["surface_handle"],
        "surface_generation": action["surface_generation"],
        "sequence": action["sequence"], "count": 1, "text": text,
    }


def require_operation_result(
    message: dict[str, Any], op_id: str, expected: int, text: str
) -> tuple[str, int]:
    kind = message.get("type")
    if kind == "state-committed":
        if not (
            set(message) == COMMITTED_FIELDS
            and message["operation_id"] == op_id
            and message["state_version"] == expected + 1
            and message["text_bytes"] == len(text.encode("utf-8"))
        ):
            raise RuntimeError("committed response differs from exact operation")
        return "committed", message["state_version"]
    if kind == "state-conflict":
        if set(message) != CONFLICT_FIELDS or message["operation_id"] != op_id:
            raise RuntimeError("conflict response differs from exact operation")
        return "conflict", expected
    if kind == "state-commit-failed":
        if not (
            set(message) == FAILED_FIELDS
            and message["operation_id"] == op_id
            and message["code"]
            in {"receipt-quota-exhausted", "read-only", "storage-failure"}
        ):
            raise RuntimeError("failed response differs from exact operation")
        return "failed", expected
    raise RuntimeError(f"unexpected commit response {kind!r}")


def run(connection: socket.socket) -> None:
    stream = messages(connection)
    send(connection, {"type": "hello", "version": 1})
    initialize = next(stream)
    ready = next(stream)
    require_initialize(initialize)
    require_ready(ready)
    send(connection, state_read(ready))
    snapshot = require_value(next(stream))
    version = snapshot["state_version"]
    present = snapshot["present"]
    current_text = snapshot["text"]
    marker(f"loaded:present={present}:version={version}")

    for message in stream:
        action_id = message.get("action_id")
        if action_id in {"save-note", "retry-save-note"}:
            action = require_action(message, action_id)
            op_id = operation_id(action)
            text = action["text"]
            send(connection, state_commit(ready, action, op_id, version, text))
            outcome, result_version = require_operation_result(
                next(stream), op_id, version, text
            )
            marker(f"commit-result:{outcome}:operation={op_id}")
            if action_id == "retry-save-note" and outcome == "committed":
                send(connection, state_commit(ready, action, op_id, version, text))
                retry_outcome, retry_version = require_operation_result(
                    next(stream), op_id, version, text
                )
                if retry_outcome != "committed" or retry_version != result_version:
                    raise RuntimeError("same-operation retry changed its receipt")
                marker(f"retry-result:same-receipt:operation={op_id}")
            if outcome == "committed":
                version, present, current_text = result_version, True, text
        elif action_id == "present-saved":
            action = require_action(message, "present-saved")
            if not present or action["text"] != current_text:
                raise RuntimeError("presentation differs from committed state")
            send(connection, presentation(action, current_text))
            marker("presented-after-receipt")
        else:
            raise RuntimeError(f"unknown fixed book action {action_id!r}")


def protocol_socket() -> socket.socket:
    if os.environ.get("BOOK_SESSION_FD") != "3":
        raise RuntimeError("BOOK_SESSION_FD must name donated FD 3")
    donated = os.fstat(3)
    if not stat.S_ISSOCK(donated.st_mode):
        raise RuntimeError("donated FD 3 is not a socket")
    if fcntl.fcntl(3, fcntl.F_GETFD) & fcntl.FD_CLOEXEC:
        raise RuntimeError("donated FD 3 remained close-on-exec")
    connection = socket.socket(fileno=3)
    if connection.family != socket.AF_UNIX or connection.type & socket.SOCK_STREAM == 0:
        raise RuntimeError("donated FD 3 is not a connected Unix stream socket")
    connection.getpeername()
    for name in os.listdir("/proc/self/fd"):
        try:
            fd = int(name)
        except ValueError:
            continue
        if fd <= 3:
            continue
        try:
            flags = fcntl.fcntl(fd, fcntl.F_GETFD)
            info = os.fstat(fd)
        except OSError:
            continue
        if info.st_dev == donated.st_dev and info.st_ino == donated.st_ino:
            raise RuntimeError(f"book retained duplicate donated socket FD {fd}")
        if not flags & fcntl.FD_CLOEXEC:
            raise RuntimeError(f"book inherited unrelated non-CLOEXEC FD {fd}")
    return connection


def main() -> int:
    if len(sys.argv) != 1:
        raise RuntimeError("fixed book accepts no arguments")
    signal.signal(signal.SIGPIPE, signal.SIG_IGN)
    connection = protocol_socket()
    try:
        run(connection)
    finally:
        connection.close()
    marker("result:ok")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
