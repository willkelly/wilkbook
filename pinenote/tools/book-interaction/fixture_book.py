#!/usr/bin/env python3
"""Trusted Python fixture book; never a production host or broker."""

from __future__ import annotations

import os
import signal
import socket
import sys
import time
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
ACTION_FIELDS = {
    "type",
    "request_id",
    "action_id",
    "surface_handle",
    "surface_generation",
    "sequence",
    "text",
}


def marker(text: str) -> None:
    print(f"BOOK_INTERACTION_PEER: {text}", flush=True)


def fail(message: str) -> None:
    raise RuntimeError(message)


def messages(connection: socket.socket) -> Iterator[dict[str, Any]]:
    decoder = FrameDecoder()
    while True:
        data = connection.recv(4096)
        if not data:
            decoder.finish()
            return
        operation = decoder.feed(data)
        while True:
            try:
                yield next(operation)
            except StopIteration:
                break


def require_initialize(message: dict[str, Any]) -> None:
    if (
        set(message) != INITIALIZE_FIELDS
        or message["type"] != "initialize"
        or type(message["version"]) is not int
        or message["version"] != 1
        or message["grant_count"] != 1
        or type(message["surface_handle"]) is not str
        or message["surface_generation"] != 1
        or message["max_pending_requests"] != 4
        or message["max_present_text_bytes"] != 4096
    ):
        fail("initialize did not match the fixture contract")


def require_action(
    stream: Iterator[dict[str, Any]], expected_action_id: str
) -> dict[str, Any]:
    message = next(stream)
    if (
        set(message) != ACTION_FIELDS
        or message["type"] != "action"
        or message["action_id"] != expected_action_id
        or type(message["request_id"]) is not str
        or type(message["surface_handle"]) is not str
        or type(message["surface_generation"]) is not int
        or type(message["sequence"]) is not int
        or type(message["text"]) is not str
    ):
        fail(f"action did not match phase {expected_action_id}")
    return message


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


def send(connection: socket.socket, message: dict[str, Any]) -> None:
    connection.sendall(encode_frame(message))


def run(connection: socket.socket) -> None:
    stream = messages(connection)
    send(connection, {"type": "hello", "version": 1})
    require_initialize(next(stream))
    marker("initialize:accepted")

    action = require_action(stream, "update")
    send(connection, presentation(action, f"Book result: {action['text'].upper()}"))
    marker("update:presented")

    action = require_action(stream, "navigate-stale")
    time.sleep(0.35)
    send(connection, presentation(action, "late navigation result"))
    marker("navigation:late-present-attempted")

    action = require_action(stream, "close-stale")
    time.sleep(0.35)
    try:
        send(connection, presentation(action, "late close result"))
    except (BrokenPipeError, ConnectionResetError):
        marker("close:late-present-rejected")
    else:
        fail("close-stale presentation unexpectedly crossed shutdown")
    marker("result:ok")


def main() -> int:
    signal.signal(signal.SIGPIPE, signal.SIG_IGN)
    if os.environ.get("BOOK_SESSION_FD") != "3":
        fail("session donation environment did not name FD 3")
    connection = socket.socket(fileno=3)
    try:
        run(connection)
    finally:
        connection.close()
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as error:
        print(f"BOOK_INTERACTION_PEER: FAIL:{error!r}", file=sys.stderr, flush=True)
        raise
