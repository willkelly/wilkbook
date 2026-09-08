#!/usr/bin/env python3
"""Fixed untrusted Python book for the first real runsc protocol gate."""

from __future__ import annotations

import fcntl
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
EXPECTED_ACTIONS = (
    ("python-transform-1", "Grace"),
    ("python-transform-2", "東京"),
)


def open_descriptors() -> list[int]:
    # listdir has released its own descriptor before each candidate is probed.
    descriptors: list[int] = []
    for name in os.listdir("/proc/self/fd"):
        try:
            descriptor = int(name)
            fcntl.fcntl(descriptor, fcntl.F_GETFD)
        except (ValueError, OSError):
            continue
        descriptors.append(descriptor)
    return sorted(descriptors)


def require_donated_socket() -> None:
    if os.environ.get("BOOK_SESSION_FD") != "3":
        raise RuntimeError("BOOK_SESSION_FD must name donated FD 3")
    descriptors = open_descriptors()
    if descriptors[:4] != [0, 1, 2, 3]:
        raise RuntimeError("fixed Python book lacks the donated stdio/FD3 shape")
    if fcntl.fcntl(3, fcntl.F_GETFD) & fcntl.FD_CLOEXEC:
        raise RuntimeError("donated FD 3 is unexpectedly close-on-exec")
    donated = os.fstat(3)
    for descriptor in descriptors[4:]:
        info = os.fstat(descriptor)
        if (info.st_dev, info.st_ino) == (donated.st_dev, donated.st_ino):
            raise RuntimeError("fixed Python book retained a duplicate donated socket")
        if not fcntl.fcntl(descriptor, fcntl.F_GETFD) & fcntl.FD_CLOEXEC:
            raise RuntimeError("fixed Python book inherited an unrelated non-CLOEXEC FD")
    probe = socket.socket(fileno=os.dup(3))
    try:
        if probe.family != socket.AF_UNIX or probe.type != socket.SOCK_STREAM:
            raise RuntimeError("donated FD 3 is not a Unix stream socket")
        probe.getpeername()
    finally:
        probe.close()


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


def require_initialize(message: dict[str, Any]) -> None:
    if (
        set(message) != INITIALIZE_FIELDS
        or message["type"] != "initialize"
        or type(message["version"]) is not int
        or message["version"] != 1
        or type(message["grant_count"]) is not int
        or message["grant_count"] != 1
        or type(message["surface_handle"]) is not str
        or not message["surface_handle"]
        or type(message["surface_generation"]) is not int
        or message["surface_generation"] != 1
        or type(message["max_pending_requests"]) is not int
        or message["max_pending_requests"] != 4
        or type(message["max_present_text_bytes"]) is not int
        or message["max_present_text_bytes"] != 4096
    ):
        raise RuntimeError("initialize did not match the fixed Python fixture")


def require_action(
    message: dict[str, Any], expected: tuple[str, str], sequence: int
) -> None:
    if (
        set(message) != ACTION_FIELDS
        or message["type"] != "action"
        or type(message["request_id"]) is not str
        or not message["request_id"]
        or message["action_id"] != expected[0]
        or type(message["surface_handle"]) is not str
        or not message["surface_handle"]
        or type(message["surface_generation"]) is not int
        or message["surface_generation"] != 1
        or type(message["sequence"]) is not int
        or message["sequence"] != sequence
        or type(message["text"]) is not str
        or not message["text"].startswith(expected[1] + "|nonce=p-")
        or len(message["text"]) != len(expected[1] + "|nonce=p-") + 16
        or not all(
            character.isascii() and (character.isalnum() or character in "-_")
            for character in message["text"][-16:]
        )
    ):
        raise RuntimeError(f"action {sequence} did not match the fixed Python fixture")


def computed_text(value: str) -> str:
    return f"PYTHON[{len(value)}]:{value[::-1]}"


def run(connection: socket.socket) -> None:
    stream = messages(connection)
    send(connection, {"type": "hello", "version": 1})
    require_initialize(next(stream))
    for sequence, expected in enumerate(EXPECTED_ACTIONS, 1):
        action = next(stream)
        require_action(action, expected, sequence)
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
                "text": computed_text(action["text"]),
            },
        )


def main() -> int:
    require_donated_socket()
    connection = socket.socket(fileno=3)
    try:
        run(connection)
    finally:
        connection.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
