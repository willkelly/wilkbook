"""Host-only reference contract for one Book Protocol action/presentation."""

from __future__ import annotations

import secrets
from collections import deque
from dataclasses import dataclass
from typing import Any

from book_protocol import MAX_SAFE_INTEGER

PROTOCOL_VERSION = 1
MAX_SESSIONS = 8
MAX_LIVE_HANDLES = 1
MAX_PENDING_REQUESTS = 4
MAX_TERMINAL_REQUESTS = 8
MAX_PEER_MESSAGE_MEMBERS = 8
MAX_FIELD_NAME_CHARACTERS = 24
MAX_OPAQUE_ID_BYTES = 96
MAX_ACTION_TEXT_BYTES = 2_048
MAX_PRESENT_TEXT_BYTES = 4_096
MAX_SURFACE_GENERATION = 1_000_000
MAX_SEQUENCE = 1_000_000
PRESENT_ITEM_COUNT = 1


class SessionError(ValueError):
    """The message or requested session transition is not permitted."""


class SchemaError(SessionError):
    """A peer message does not have the one exact supported schema."""


class StateError(SessionError):
    """A well-formed operation is invalid in the current session state."""


class AuthorityError(SessionError):
    """A well-formed message does not name authority on this connection."""


@dataclass(frozen=True, eq=False, slots=True)
class SupervisedConnectionBinding:
    """Trusted harness identity for one concrete supervised connection."""

    diagnostic_name: str


@dataclass(frozen=True, slots=True)
class SurfaceGrant:
    handle: str
    generation: int


@dataclass(frozen=True, slots=True)
class InitialGrantEnvelope:
    surfaces: tuple[SurfaceGrant, ...]

    def __post_init__(self) -> None:
        if len(self.surfaces) != MAX_LIVE_HANDLES:
            raise ValueError("the initial envelope must contain one surface")


@dataclass(frozen=True, slots=True)
class PresentedText:
    session_id: str
    request_id: str
    action_id: str
    surface_handle: str
    surface_generation: int
    sequence: int
    text: str


@dataclass(frozen=True, slots=True)
class SessionSnapshot:
    session_id: str
    state: str
    surface_generation: int
    pending_requests: int
    live_handles: int
    retained_terminal_requests: int


@dataclass(frozen=True, slots=True)
class _PendingRequest:
    request_id: str
    action_id: str
    surface_handle: str
    surface_generation: int
    sequence: int


def _exact_fields(message: Any, expected: tuple[str, ...]) -> None:
    if type(message) is not dict:
        raise SchemaError("a peer message must be a JSON object")
    if len(message) > MAX_PEER_MESSAGE_MEMBERS:
        raise SchemaError("peer message has too many members")
    if len(message) != len(expected):
        raise SchemaError("peer message fields do not match its exact schema")
    for key in message:
        if type(key) is not str or len(key) > MAX_FIELD_NAME_CHARACTERS:
            raise SchemaError("peer message field name is invalid")
        if key not in expected:
            raise SchemaError(f"unknown peer message field: {key!r}")
    if any(key not in message for key in expected):
        raise SchemaError("peer message is missing a required field")


def _bounded_string(name: str, value: Any, maximum_bytes: int) -> str:
    if type(value) is not str:
        raise SchemaError(f"{name} must be a string")
    if not value:
        raise SchemaError(f"{name} must not be empty")
    if len(value) > maximum_bytes:
        raise SchemaError(f"{name} exceeds its byte limit")
    try:
        encoded_length = len(value.encode("utf-8"))
    except UnicodeEncodeError as error:
        raise SchemaError(f"{name} must contain Unicode scalar values") from error
    if encoded_length > maximum_bytes:
        raise SchemaError(f"{name} exceeds its byte limit")
    return value


def _bounded_integer(name: str, value: Any, minimum: int, maximum: int) -> int:
    if type(value) is not int:
        raise SchemaError(f"{name} must be a lexical JSON integer")
    if not -MAX_SAFE_INTEGER <= value <= MAX_SAFE_INTEGER:
        raise SchemaError(f"{name} is outside the safe-integer range")
    if not minimum <= value <= maximum:
        raise SchemaError(f"{name} is outside its field-specific range")
    return value


def _validate_hello(message: Any) -> int:
    _exact_fields(message, ("type", "version"))
    if message["type"] != "hello":
        raise SchemaError("expected a hello message")
    return _bounded_integer("version", message["version"], 1, PROTOCOL_VERSION)


def _validate_present(message: Any) -> tuple[str, str, str, int, int, str]:
    fields = (
        "type",
        "request_id",
        "action_id",
        "surface_handle",
        "surface_generation",
        "sequence",
        "count",
        "text",
    )
    _exact_fields(message, fields)
    if message["type"] != "present":
        raise SchemaError("expected a present message")
    request_id = _bounded_string(
        "request_id", message["request_id"], MAX_OPAQUE_ID_BYTES
    )
    action_id = _bounded_string(
        "action_id", message["action_id"], MAX_OPAQUE_ID_BYTES
    )
    surface_handle = _bounded_string(
        "surface_handle", message["surface_handle"], MAX_OPAQUE_ID_BYTES
    )
    generation = _bounded_integer(
        "surface_generation",
        message["surface_generation"],
        1,
        MAX_SURFACE_GENERATION,
    )
    sequence = _bounded_integer("sequence", message["sequence"], 1, MAX_SEQUENCE)
    count = _bounded_integer("count", message["count"], 1, PRESENT_ITEM_COUNT)
    if count != PRESENT_ITEM_COUNT:
        raise SchemaError("this contract presents exactly one text item")
    text = _bounded_string("text", message["text"], MAX_PRESENT_TEXT_BYTES)
    return request_id, action_id, surface_handle, generation, sequence, text


def _new_opaque(prefix: str, forbidden: set[str]) -> str:
    for _ in range(8):
        value = f"{prefix}_{secrets.token_urlsafe(18)}"
        if len(value.encode("ascii")) > MAX_OPAQUE_ID_BYTES:
            raise AssertionError("host-generated opaque identifier exceeded its limit")
        if value not in forbidden:
            return value
    raise StateError("could not allocate a fresh opaque identifier")


class _Session:
    def __init__(self, forbidden_ids: set[str]) -> None:
        self.session_id = _new_opaque("session", forbidden_ids)
        forbidden_ids.add(self.session_id)
        self._surface_handle = _new_opaque("surface", forbidden_ids)
        self._generation = 1
        self._sequence = 0
        self._state = "awaiting-hello"
        self._pending: dict[str, _PendingRequest] = {}
        self._terminal: deque[tuple[str, str]] = deque(
            maxlen=MAX_TERMINAL_REQUESTS
        )
        self.initial_grants = InitialGrantEnvelope(
            (SurfaceGrant(self._surface_handle, self._generation),)
        )

    def snapshot(self) -> SessionSnapshot:
        return SessionSnapshot(
            session_id=self.session_id,
            state=self._state,
            surface_generation=self._generation,
            pending_requests=len(self._pending),
            live_handles=1 if self._state == "active" else 0,
            retained_terminal_requests=len(self._terminal),
        )

    def accept_hello(self, version: int) -> dict[str, Any]:
        if self._state != "awaiting-hello":
            raise StateError("hello is valid only once on a fresh session")
        if version != PROTOCOL_VERSION:
            raise SchemaError("unsupported protocol version")
        self._state = "active"
        grant = self.initial_grants.surfaces[0]
        return {
            "type": "initialize",
            "version": PROTOCOL_VERSION,
            "grant_count": len(self.initial_grants.surfaces),
            "surface_handle": grant.handle,
            "surface_generation": grant.generation,
            "max_pending_requests": MAX_PENDING_REQUESTS,
            "max_present_text_bytes": MAX_PRESENT_TEXT_BYTES,
        }

    def action(self, action_id: Any, text: Any) -> dict[str, Any]:
        self._require_active()
        action_id = _bounded_string("action_id", action_id, MAX_OPAQUE_ID_BYTES)
        text = _bounded_string("text", text, MAX_ACTION_TEXT_BYTES)
        if len(self._pending) >= MAX_PENDING_REQUESTS:
            raise StateError("pending request limit reached")
        if self._sequence >= MAX_SEQUENCE:
            raise StateError("session sequence limit reached")
        self._sequence += 1
        request_id = self._fresh_request_id()
        pending = _PendingRequest(
            request_id,
            action_id,
            self._surface_handle,
            self._generation,
            self._sequence,
        )
        self._pending[request_id] = pending
        return {
            "type": "action",
            "request_id": request_id,
            "action_id": action_id,
            "surface_handle": self._surface_handle,
            "surface_generation": self._generation,
            "sequence": self._sequence,
            "text": text,
        }

    def accept_present(
        self,
        request_id: str,
        action_id: str,
        surface_handle: str,
        generation: int,
        sequence: int,
        text: str,
    ) -> PresentedText:
        self._require_active()
        if surface_handle != self._surface_handle:
            raise AuthorityError("surface handle is not granted on this connection")
        if generation != self._generation:
            if generation < self._generation:
                raise StateError("presentation uses a stale surface generation")
            raise StateError("presentation uses an unknown future surface generation")
        pending = self._pending.get(request_id)
        if pending is None:
            reason = self._terminal_reason(request_id)
            if reason:
                raise StateError(f"request is no longer pending: {reason}")
            raise StateError("request is not pending on this connection")
        if (
            action_id != pending.action_id
            or surface_handle != pending.surface_handle
            or generation != pending.surface_generation
            or sequence != pending.sequence
        ):
            raise AuthorityError("presentation does not match its pending request")
        del self._pending[request_id]
        self._retire(request_id, "completed")
        return PresentedText(
            self.session_id,
            request_id,
            action_id,
            surface_handle,
            generation,
            sequence,
            text,
        )

    def cancel(self, request_id: Any) -> dict[str, Any]:
        self._require_active()
        request_id = _bounded_string(
            "request_id", request_id, MAX_OPAQUE_ID_BYTES
        )
        self._take_pending(request_id)
        self._retire(request_id, "cancelled")
        return {"type": "cancel", "request_id": request_id}

    def expire(self, request_id: Any) -> None:
        self._require_active()
        request_id = _bounded_string(
            "request_id", request_id, MAX_OPAQUE_ID_BYTES
        )
        self._take_pending(request_id)
        self._retire(request_id, "expired")

    def navigate(self) -> int:
        self._require_active()
        if self._generation >= MAX_SURFACE_GENERATION:
            raise StateError("surface generation limit reached")
        self._retire_all("navigation")
        self._generation += 1
        return self._generation

    def revoke(self) -> None:
        self._require_active()
        self._retire_all("revoked")
        self._state = "revoked"

    def close(self) -> None:
        if self._state == "closed":
            return
        self._retire_all("closed")
        self._state = "closed"

    def _require_active(self) -> None:
        if self._state != "active":
            raise StateError(f"session is not active: {self._state}")

    def _fresh_request_id(self) -> str:
        forbidden = set(self._pending)
        forbidden.update(request_id for request_id, _ in self._terminal)
        return _new_opaque("request", forbidden)

    def _take_pending(self, request_id: str) -> _PendingRequest:
        pending = self._pending.pop(request_id, None)
        if pending is None:
            raise StateError("request is not pending on this connection")
        return pending

    def _terminal_reason(self, request_id: str) -> str | None:
        for terminal_id, reason in self._terminal:
            if terminal_id == request_id:
                return reason
        return None

    def _retire(self, request_id: str, reason: str) -> None:
        self._terminal.append((request_id, reason))

    def _retire_all(self, reason: str) -> None:
        for request_id in tuple(self._pending):
            self._retire(request_id, reason)
        self._pending.clear()


class BookSessionHost:
    """Connection-owned host authority for the single-surface experiment."""

    def __init__(self) -> None:
        self._sessions: dict[SupervisedConnectionBinding, _Session] = {}

    def open_session(self, connection: SupervisedConnectionBinding) -> None:
        self._check_connection(connection)
        if connection in self._sessions:
            raise StateError("connection already has a session")
        if len(self._sessions) >= MAX_SESSIONS:
            raise StateError("live session limit reached")
        self._sessions[connection] = self._new_session()

    def dispatch_peer(
        self, connection: SupervisedConnectionBinding, message: Any
    ) -> dict[str, Any] | PresentedText:
        session = self._session(connection)
        if type(message) is not dict or len(message) > MAX_PEER_MESSAGE_MEMBERS:
            _exact_fields(message, ())
        message_type = _bounded_string("type", message.get("type"), 16)
        if message_type == "hello":
            return session.accept_hello(_validate_hello(message))
        if message_type == "present":
            return session.accept_present(*_validate_present(message))
        raise SchemaError(f"peer cannot send message type {message_type!r}")

    def host_action(
        self, connection: SupervisedConnectionBinding, action_id: Any, text: Any
    ) -> dict[str, Any]:
        return self._session(connection).action(action_id, text)

    def cancel_request(
        self, connection: SupervisedConnectionBinding, request_id: Any
    ) -> dict[str, Any]:
        return self._session(connection).cancel(request_id)

    def expire_request(
        self, connection: SupervisedConnectionBinding, request_id: Any
    ) -> None:
        self._session(connection).expire(request_id)

    def navigate(self, connection: SupervisedConnectionBinding) -> int:
        return self._session(connection).navigate()

    def revoke_surface(self, connection: SupervisedConnectionBinding) -> None:
        self._session(connection).revoke()

    def close_session(self, connection: SupervisedConnectionBinding) -> None:
        self._session(connection).close()

    def restart_session(self, connection: SupervisedConnectionBinding) -> None:
        old = self._session(connection)
        old.close()
        self._sessions[connection] = self._new_session()

    def release_connection(self, connection: SupervisedConnectionBinding) -> None:
        session = self._session(connection)
        session.close()
        del self._sessions[connection]

    def initial_grants(
        self, connection: SupervisedConnectionBinding
    ) -> InitialGrantEnvelope:
        return self._session(connection).initial_grants

    def snapshot(self, connection: SupervisedConnectionBinding) -> SessionSnapshot:
        return self._session(connection).snapshot()

    @staticmethod
    def _check_connection(connection: Any) -> None:
        if type(connection) is not SupervisedConnectionBinding:
            raise TypeError("a concrete SupervisedConnectionBinding is required")

    def _session(self, connection: SupervisedConnectionBinding) -> _Session:
        self._check_connection(connection)
        try:
            return self._sessions[connection]
        except KeyError as error:
            raise StateError("connection has no host session") from error

    def _new_session(self) -> _Session:
        forbidden = set()
        for session in self._sessions.values():
            forbidden.add(session.session_id)
            forbidden.add(session._surface_handle)
        return _Session(forbidden)
