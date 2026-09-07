#!/usr/bin/env python3
"""Fixed Python book for the first runsc FD-donation fixture."""

from __future__ import annotations

import os
import socket
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


def messages(connection: socket.socket) -> Iterator[dict[str, Any]]:
    decoder = FrameDecoder()
    while True:
        data = connection.recv(4096)
        if not data:
            decoder.finish()
            return
        operation = decoder.feed(data)
        yield from operation


def send(connection: socket.socket, message: dict[str, Any]) -> None:
    connection.sendall(encode_frame(message))


def run(connection: socket.socket) -> None:
    stream = messages(connection)
    send(connection, {"type": "hello", "version": 1})
    initialize = next(stream)
    if (
        set(initialize) != INITIALIZE_FIELDS
        or initialize["type"] != "initialize"
        or initialize["version"] != 1
        or initialize["grant_count"] != 1
        or type(initialize["surface_handle"]) is not str
        or initialize["surface_generation"] != 1
        or initialize["max_pending_requests"] != 4
        or initialize["max_present_text_bytes"] != 4096
    ):
        raise RuntimeError("initialize did not match the fixed fixture")

    action = next(stream)
    if (
        set(action) != ACTION_FIELDS
        or action["type"] != "action"
        or action["action_id"] != "python-action"
        or action["text"] != "élan λ"
    ):
        raise RuntimeError("action did not match the fixed Python fixture")

    send(
        connection,
        {
            "type": "present",
            "request_id": action["request_id"],
            "action_id": action["action_id"],
            "surface_handle": action["surface_handle"],
            "surface_generation": action["surface_generation"],
            "sequence": action["sequence"],
            "count": 1,
            "text": "Python book: ÉLAN Λ",
        },
    )


def main() -> int:
    if os.environ.get("BOOK_SESSION_FD") != "3":
        raise RuntimeError("BOOK_SESSION_FD must name donated FD 3")
    connection = socket.socket(fileno=3)
    try:
        run(connection)
    finally:
        connection.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
