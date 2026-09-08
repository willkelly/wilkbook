"""Experimental host-side reference codec for the Book Protocol framing.

The wire format is a four-byte unsigned big-endian payload length followed by
one UTF-8 JSON object.  This module deliberately contains no socket, event-loop,
or subprocess policy.
"""

from __future__ import annotations

import json
import math
import struct
from collections.abc import Iterator
from decimal import Decimal, InvalidOperation
from typing import Any


MAX_FRAME_SIZE = 64 * 1024
MAX_NESTING = 16
MAX_SAFE_INTEGER = (1 << 53) - 1
MAX_DECIMAL_EXPONENT = 1000
_MAX_SAFE_INTEGER_DIGITS = str(MAX_SAFE_INTEGER)
_MAX_DECIMAL_EXPONENT_DIGITS = str(MAX_DECIMAL_EXPONENT)


class ProtocolError(ValueError):
    """The local value or peer byte stream violates the framing protocol."""


def _spend_budget(remaining: int, amount: int) -> int:
    if amount > remaining:
        raise ProtocolError(
            f"JSON object exceeds the conservative {MAX_FRAME_SIZE}-byte "
            "encoding budget limit"
        )
    return remaining - amount


def _measure_string(value: str, remaining: int) -> int:
    """Account for compact ensure_ascii=False JSON without building a copy."""

    remaining = _spend_budget(remaining, 2)  # Opening and closing quotes.
    if len(value) > remaining:
        # Every Unicode scalar costs at least one output byte.
        return _spend_budget(remaining, len(value))

    for character in value:
        code_point = ord(character)
        if 0xD800 <= code_point <= 0xDFFF:
            raise ProtocolError("JSON strings must not contain surrogates")
        if character in {'"', "\\", "\b", "\f", "\n", "\r", "\t"}:
            size = 2
        elif code_point < 0x20:
            size = 6
        elif code_point < 0x80:
            size = 1
        elif code_point < 0x800:
            size = 2
        elif code_point < 0x10000:
            size = 3
        else:
            size = 4
        remaining = _spend_budget(remaining, size)
    return remaining


def _validate_and_budget(value: Any, parent_depth: int, remaining: int) -> int:
    """Validate and bound serialization with O(MAX_NESTING) local stack use."""

    if isinstance(value, dict):
        depth = parent_depth + 1
        if depth > MAX_NESTING:
            raise ProtocolError(f"JSON nesting exceeds the limit of {MAX_NESTING}")
        count = len(value)
        minimum_size = 2 if count == 0 else 5 * count + 1
        if minimum_size > remaining:
            return _spend_budget(remaining, minimum_size)
        remaining = _spend_budget(remaining, 2)
        for index, (key, child) in enumerate(value.items()):
            if index:
                remaining = _spend_budget(remaining, 1)
            if not isinstance(key, str):
                raise ProtocolError("JSON object keys must be strings")
            remaining = _measure_string(key, remaining)
            remaining = _spend_budget(remaining, 1)  # Colon.
            remaining = _validate_and_budget(child, depth, remaining)
        return remaining

    if isinstance(value, list):
        depth = parent_depth + 1
        if depth > MAX_NESTING:
            raise ProtocolError(f"JSON nesting exceeds the limit of {MAX_NESTING}")
        count = len(value)
        minimum_size = 2 if count == 0 else 2 * count + 1
        if minimum_size > remaining:
            return _spend_budget(remaining, minimum_size)
        remaining = _spend_budget(remaining, 2)
        for index, child in enumerate(value):
            if index:
                remaining = _spend_budget(remaining, 1)
            remaining = _validate_and_budget(child, depth, remaining)
        return remaining

    if value is None:
        return _spend_budget(remaining, 4)
    if isinstance(value, bool):
        return _spend_budget(remaining, 4 if value else 5)
    if isinstance(value, str):
        return _measure_string(value, remaining)
    if isinstance(value, int):
        if not -MAX_SAFE_INTEGER <= value <= MAX_SAFE_INTEGER:
            raise ProtocolError(
                f"JSON integers must be between {-MAX_SAFE_INTEGER} and "
                f"{MAX_SAFE_INTEGER}"
            )
        return _spend_budget(remaining, len(str(value)))
    if isinstance(value, float):
        if not math.isfinite(value):
            raise ProtocolError("JSON numbers must be finite")
        if value.is_integer() and abs(value) > MAX_SAFE_INTEGER:
            raise ProtocolError(
                "integral JSON numbers must be within the safe-integer range"
            )
        return _spend_budget(remaining, len(float.__repr__(value)))
    raise ProtocolError(
        "values must use JSON object, array, string, number, boolean, or null types"
    )


def _validate_value(value: Any) -> None:
    _validate_and_budget(value, 0, MAX_FRAME_SIZE)


def encode_frame(message: dict[str, Any]) -> bytes:
    """Encode one JSON object, including its four-byte length prefix."""

    if not isinstance(message, dict):
        raise ProtocolError("the top-level JSON value must be an object")
    _validate_value(message)

    try:
        text = json.dumps(
            message,
            ensure_ascii=False,
            allow_nan=False,
            separators=(",", ":"),
        )
        payload = text.encode("utf-8", errors="strict")
    except (TypeError, ValueError, UnicodeEncodeError, RecursionError) as error:
        raise ProtocolError(f"cannot encode JSON object: {error}") from error

    if not payload:
        raise ProtocolError("a frame payload must not be empty")
    if len(payload) > MAX_FRAME_SIZE:
        raise ProtocolError(
            f"frame payload is {len(payload)} bytes; limit is {MAX_FRAME_SIZE}"
        )

    return struct.pack(">I", len(payload)) + payload


def _reject_duplicate_keys(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise ProtocolError(f"duplicate JSON object key: {key!r}")
        result[key] = value
    return result


def _parse_integer(token: str) -> int:
    negative = token.startswith("-")
    digits = token[1:] if negative else token
    significant = digits.lstrip("0") or "0"
    if (
        len(significant) > len(_MAX_SAFE_INTEGER_DIGITS)
        or len(significant) == len(_MAX_SAFE_INTEGER_DIGITS)
        and significant > _MAX_SAFE_INTEGER_DIGITS
    ):
        raise ProtocolError(
            f"JSON integers must be between {-MAX_SAFE_INTEGER} and "
            f"{MAX_SAFE_INTEGER}"
        )
    # Conversion is now limited to at most 16 digits, independent of CPython's
    # optional process-global integer-string guard.
    magnitude = int(significant)
    return -magnitude if negative else magnitude


def _normalize_bounded_exponent(token: str) -> str:
    marker = max(token.find("e"), token.find("E"))
    if marker < 0:
        return token

    exponent_text = token[marker + 1 :]
    sign = ""
    if exponent_text.startswith(("+", "-")):
        sign, exponent_text = exponent_text[0], exponent_text[1:]
    significant = exponent_text.lstrip("0") or "0"
    if (
        len(significant) > len(_MAX_DECIMAL_EXPONENT_DIGITS)
        or len(significant) == len(_MAX_DECIMAL_EXPONENT_DIGITS)
        and significant > _MAX_DECIMAL_EXPONENT_DIGITS
    ):
        raise ProtocolError(
            f"JSON decimal exponent exceeds the limit of {MAX_DECIMAL_EXPONENT}"
        )
    # Long leading-zero exponents are valid JSON and remain accepted, but the
    # numeric libraries only receive the bounded normalized spelling.
    return token[: marker + 1] + sign + significant


def _parse_float(token: str) -> float:
    try:
        normalized_token = _normalize_bounded_exponent(token)
        decimal_value = Decimal(normalized_token)
        value = float(normalized_token)
    except ProtocolError:
        raise
    except (InvalidOperation, OverflowError, ValueError) as error:
        raise ProtocolError("invalid JSON number") from error
    if not math.isfinite(value):
        raise ProtocolError("JSON numbers must be finite binary64 values")
    if value == 0.0 and not decimal_value.is_zero():
        raise ProtocolError("JSON number underflows binary64")
    if decimal_value == decimal_value.to_integral_value() and (
        abs(decimal_value) > MAX_SAFE_INTEGER
    ):
        raise ProtocolError(
            "integral JSON numbers must be within the safe-integer range"
        )
    return value


def _reject_nonstandard_number(token: str) -> Any:
    raise ProtocolError(f"non-standard JSON number is forbidden: {token}")


def _check_nesting_before_parse(text: str) -> None:
    """Lexically bound container nesting before the JSON parser can recurse."""

    containers: list[str] = []
    in_string = False
    escaped = False

    for character in text:
        if in_string:
            if escaped:
                escaped = False
            elif character == "\\":
                escaped = True
            elif character == '"':
                in_string = False
            continue

        if character == '"':
            in_string = True
        elif character in "[{":
            containers.append(character)
            if len(containers) > MAX_NESTING:
                raise ProtocolError(
                    f"JSON nesting exceeds the limit of {MAX_NESTING}"
                )
        elif character in "]}":
            expected = "[" if character == "]" else "{"
            if not containers or containers[-1] != expected:
                raise ProtocolError("mismatched JSON container delimiter")
            containers.pop()

    if in_string:
        raise ProtocolError("unterminated JSON string")
    if containers:
        raise ProtocolError("unterminated JSON container")


def _decode_payload(payload: bytes) -> dict[str, Any]:
    try:
        text = payload.decode("utf-8", errors="strict")
    except UnicodeDecodeError as error:
        raise ProtocolError("frame payload is not well-formed UTF-8") from error

    _check_nesting_before_parse(text)

    try:
        value = json.loads(
            text,
            object_pairs_hook=_reject_duplicate_keys,
            parse_int=_parse_integer,
            parse_float=_parse_float,
            parse_constant=_reject_nonstandard_number,
        )
    except ProtocolError:
        raise
    except (json.JSONDecodeError, OverflowError, RecursionError, ValueError) as error:
        raise ProtocolError(f"malformed JSON payload: {error}") from error

    if not isinstance(value, dict):
        raise ProtocolError("the top-level JSON value must be an object")
    _validate_value(value)
    return value


class _FeedIterator(Iterator[dict[str, Any]]):
    """One decoder-owned feed operation, reserved before iteration starts."""

    def __init__(self, decoder: FrameDecoder, data: bytes) -> None:
        self._decoder = decoder
        self._data = data
        self._offset = 0
        self._done = False
        self._running = False

    def __iter__(self) -> _FeedIterator:
        return self

    def __copy__(self):
        raise TypeError("feed iterators own stream state and cannot be copied")

    def __deepcopy__(self, memo):
        raise TypeError("feed iterators own stream state and cannot be copied")

    def __reduce_ex__(self, protocol):
        raise TypeError("feed iterators cannot be serialized")

    def _release(self) -> None:
        if not self._done:
            self._done = True
            self._decoder._feeding = False

    def close(self) -> None:
        if self._done:
            return
        if self._running:
            raise RuntimeError("cannot close a feed iterator while it is executing")
        if self._offset < len(self._data):
            self._decoder._poison()
        self._release()

    def __del__(self) -> None:
        try:
            self.close()
        except BaseException:
            # Destructors cannot report local misuse; explicit close is the
            # deterministic API. The decoder remains reserved in that case.
            pass

    def __next__(self) -> dict[str, Any]:
        if self._done:
            raise StopIteration
        if self._running:
            raise RuntimeError("feed iterator is already executing")

        self._running = True
        decoder = self._decoder
        try:
            decoder._ensure_usable()
            while self._offset < len(self._data):
                if decoder._expected_length is None:
                    needed = 4 - len(decoder._header)
                    take = min(needed, len(self._data) - self._offset)
                    decoder._header.extend(
                        self._data[self._offset : self._offset + take]
                    )
                    self._offset += take
                    if len(decoder._header) < 4:
                        continue

                    length = struct.unpack(">I", decoder._header)[0]
                    decoder._header.clear()
                    if length == 0:
                        decoder._fail("zero-length frames are forbidden")
                    if length > MAX_FRAME_SIZE:
                        decoder._fail(
                            f"frame length {length} exceeds the "
                            f"{MAX_FRAME_SIZE}-byte limit"
                        )
                    decoder._expected_length = length

                assert decoder._expected_length is not None
                needed = decoder._expected_length - len(decoder._payload)
                take = min(needed, len(self._data) - self._offset)
                decoder._payload.extend(
                    self._data[self._offset : self._offset + take]
                )
                self._offset += take

                if len(decoder._payload) < decoder._expected_length:
                    continue

                payload = bytes(decoder._payload)
                decoder._payload = bytearray()
                decoder._expected_length = None
                return _decode_payload(payload)
        except ProtocolError:
            decoder._poison()
            self._release()
            raise
        except BaseException:
            # An unexpected local exception must not leave a stream reusable
            # after some caller-owned bytes may have been consumed.
            decoder._poison()
            self._release()
            raise
        finally:
            self._running = False

        self._release()
        raise StopIteration


class FrameDecoder:
    """Incrementally decode framed objects without an internal output queue.

    ``feed`` returns an explicit iterator and reserves the decoder immediately,
    before the first ``next``.  Exhaust or close that iterator before calling
    ``feed`` or ``finish`` again.  At most one frame payload and a partial
    four-byte header are retained; coalesced trailing bytes remain in the
    caller-owned input while each yielded frame is handled.
    """

    def __init__(self) -> None:
        self._header = bytearray()
        self._payload = bytearray()
        self._expected_length: int | None = None
        self._poisoned = False
        self._closed = False
        self._feeding = False

    def __copy__(self):
        raise TypeError("decoders own stream state and cannot be copied")

    def __deepcopy__(self, memo):
        raise TypeError("decoders own stream state and cannot be copied")

    def __reduce_ex__(self, protocol):
        raise TypeError("decoders cannot be serialized")

    @property
    def poisoned(self) -> bool:
        return self._poisoned

    @property
    def buffered_bytes(self) -> int:
        """Bytes retained toward the current header or frame payload."""

        return len(self._header) + len(self._payload)

    def _ensure_usable(self) -> None:
        if self._poisoned:
            raise ProtocolError("decoder is poisoned after a protocol error")
        if self._closed:
            raise ProtocolError("decoder is closed after EOF")

    def _poison(self) -> None:
        self._poisoned = True
        self._header.clear()
        self._payload.clear()
        self._expected_length = None

    def _fail(self, message: str) -> None:
        self._poison()
        raise ProtocolError(message)

    def feed(self, data: bytes) -> Iterator[dict[str, Any]]:
        """Consume available bytes and lazily yield each complete object.

        The iterator stops normally when more bytes are needed.  This method
        does no blocking I/O and accepts immutable ``bytes`` only, so a caller
        cannot mutate input while iteration is suspended.
        """

        self._ensure_usable()
        if self._feeding:
            raise RuntimeError("exhaust or close the previous feed iterator first")
        if not isinstance(data, bytes):
            raise TypeError("feed data must be bytes")
        self._feeding = True
        try:
            return _FeedIterator(self, data)
        except BaseException:
            self._feeding = False
            raise

    def finish(self) -> None:
        """Declare EOF, rejecting an incomplete header or payload."""

        self._ensure_usable()
        if self._feeding:
            raise RuntimeError("exhaust or close the active feed iterator before EOF")
        if self._header:
            self._fail(
                f"EOF truncated the frame header after {len(self._header)} of 4 bytes"
            )
        if self._expected_length is not None:
            self._fail(
                "EOF truncated the frame payload after "
                f"{len(self._payload)} of {self._expected_length} bytes"
            )
        self._closed = True
