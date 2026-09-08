import copy
import json
import pickle
import math
from pathlib import Path
import struct
import unittest
from unittest import mock

import book_protocol
from book_protocol import (
    MAX_FRAME_SIZE,
    MAX_NESTING,
    MAX_SAFE_INTEGER,
    FrameDecoder,
    ProtocolError,
    encode_frame,
)


NUMERIC_VECTORS = json.loads(
    (Path(__file__).resolve().parent / "numeric-wire-vectors.json").read_text(
        encoding="utf-8"
    )
)


def raw_frame(payload: bytes) -> bytes:
    return struct.pack(">I", len(payload)) + payload


def nested_object(depth: int):
    value = 0
    for _ in range(depth):
        value = {"child": value}
    return value


class FramingTests(unittest.TestCase):
    def test_round_trip_and_big_endian_length(self):
        message = {"type": "open", "title": "Café 📖", "pages": [1, 2, 3]}
        frame = encode_frame(message)

        self.assertEqual(frame[:4], len(frame[4:]).to_bytes(4, "big"))
        self.assertEqual(list(FrameDecoder().feed(frame)), [message])

    def test_smallest_json_object_has_a_two_byte_payload(self):
        frame = encode_frame({})

        self.assertEqual(frame[:4], b"\x00\x00\x00\x02")
        self.assertEqual(frame[4:], b"{}")
        self.assertEqual(list(FrameDecoder().feed(frame)), [{}])

    def test_fragmented_one_byte_at_a_time(self):
        message = {"type": "page", "number": 17, "ready": True}
        decoder = FrameDecoder()
        decoded = []

        for byte in encode_frame(message):
            decoded.extend(decoder.feed(bytes([byte])))

        self.assertEqual(decoded, [message])
        self.assertEqual(decoder.buffered_bytes, 0)

    def test_coalesced_frames_are_yielded_without_an_output_list(self):
        messages = [{"sequence": number} for number in range(5)]
        decoder = FrameDecoder()
        iterator = decoder.feed(b"".join(map(encode_frame, messages)))

        self.assertIs(iter(iterator), iterator)
        self.assertEqual(next(iterator), messages[0])
        self.assertEqual(list(iterator), messages[1:])

    def test_fragment_ends_mid_header_and_mid_payload(self):
        first = encode_frame({"first": "message"})
        second = encode_frame({"second": "message"})
        stream = first + second
        cuts = [1, 4, len(first) + 2, len(stream) - 1, len(stream)]
        decoder = FrameDecoder()
        decoded = []
        start = 0

        for end in cuts:
            decoded.extend(decoder.feed(stream[start:end]))
            start = end

        self.assertEqual(decoded, [{"first": "message"}, {"second": "message"}])

    def test_exact_maximum_payload_is_accepted_and_one_more_is_rejected(self):
        empty_size = len(encode_frame({"s": ""})) - 4
        maximum = {"s": "x" * (MAX_FRAME_SIZE - empty_size)}
        frame = encode_frame(maximum)

        self.assertEqual(int.from_bytes(frame[:4], "big"), MAX_FRAME_SIZE)
        self.assertEqual(list(FrameDecoder().feed(frame)), [maximum])
        with self.assertRaisesRegex(ProtocolError, "limit"):
            encode_frame({"s": maximum["s"] + "x"})

    def test_partial_maximum_frame_never_buffers_more_than_one_payload(self):
        empty_size = len(encode_frame({"s": ""})) - 4
        message = {"s": "x" * (MAX_FRAME_SIZE - empty_size)}
        frame = encode_frame(message)
        decoder = FrameDecoder()

        self.assertEqual(list(decoder.feed(frame[:-1])), [])
        self.assertEqual(decoder.buffered_bytes, MAX_FRAME_SIZE - 1)
        self.assertEqual(list(decoder.feed(frame[-1:])), [message])
        self.assertLessEqual(decoder.buffered_bytes, MAX_FRAME_SIZE)

    def test_zero_and_oversize_lengths_poison_immediately_after_header(self):
        for length in (0, MAX_FRAME_SIZE + 1, 0xFFFFFFFF):
            with self.subTest(length=length):
                decoder = FrameDecoder()
                with self.assertRaises(ProtocolError):
                    list(decoder.feed(struct.pack(">I", length)))
                self.assertTrue(decoder.poisoned)


class JsonPolicyTests(unittest.TestCase):
    def assert_payload_rejected(self, payload: bytes):
        decoder = FrameDecoder()
        with self.assertRaises(ProtocolError):
            list(decoder.feed(raw_frame(payload)))
        self.assertTrue(decoder.poisoned)

    def test_duplicate_keys_are_rejected_at_any_level_and_after_unescaping(self):
        duplicates = [
            b'{"same":1,"same":2}',
            b'{"outer":{"same":1,"same":2}}',
            b'{"a":1,"\\u0061":2}',
        ]
        for payload in duplicates:
            with self.subTest(payload=payload):
                self.assert_payload_rejected(payload)

    def test_nonstandard_and_nonfinite_numbers_are_rejected(self):
        payloads = [
            b'{"n":NaN}',
            b'{"n":Infinity}',
            b'{"n":-Infinity}',
            b'{"n":1e400}',
            b'{"n":1e-4000}',
        ]
        for payload in payloads:
            with self.subTest(payload=payload):
                self.assert_payload_rejected(payload)

        for value in (float("nan"), float("inf"), float("-inf")):
            with self.subTest(value=value):
                with self.assertRaises(ProtocolError):
                    encode_frame({"n": value})

    def test_safe_integer_boundaries_and_exponent_bypass(self):
        for value in (-MAX_SAFE_INTEGER, MAX_SAFE_INTEGER):
            with self.subTest(value=value):
                self.assertEqual(
                    list(FrameDecoder().feed(encode_frame({"n": value}))),
                    [{"n": value}],
                )

        for value in (-MAX_SAFE_INTEGER - 1, MAX_SAFE_INTEGER + 1):
            with self.subTest(value=value):
                with self.assertRaises(ProtocolError):
                    encode_frame({"n": value})
                self.assert_payload_rejected(
                    json.dumps({"n": value}, separators=(",", ":")).encode("ascii")
                )

        self.assert_payload_rejected(b'{"n":9.007199254740992e15}')

    def test_finite_fractional_binary64_numbers_are_accepted(self):
        message = {"ratio": 0.125, "negative_zero": -0.0}
        decoded = list(FrameDecoder().feed(encode_frame(message)))[0]

        self.assertEqual(decoded["ratio"], 0.125)
        self.assertEqual(decoded["negative_zero"], -0.0)

    def test_decimal_exponent_limit_matches_guile_json(self):
        self.assertEqual(
            list(FrameDecoder().feed(raw_frame(b'{"zero":0e1000}'))),
            [{"zero": 0.0}],
        )
        self.assert_payload_rejected(b'{"zero":0e1001}')
        self.assert_payload_rejected(b'{"zero":0e-1001}')

    def test_integer_magnitude_is_rejected_before_int_conversion(self):
        payload = b'{"n":' + b"9" * 65_000 + b"}"
        with mock.patch.object(book_protocol, "int", wraps=int, create=True) as convert:
            self.assert_payload_rejected(payload)
        convert.assert_not_called()

    def test_exponent_magnitude_is_rejected_before_numeric_conversion(self):
        token = "1e" + "0" * 60_000 + "1001"
        payload = ("{\"n\":" + token + "}").encode("ascii")
        with (
            mock.patch.object(
                book_protocol, "Decimal", side_effect=AssertionError("Decimal called")
            ) as decimal,
            mock.patch.object(
                book_protocol,
                "float",
                side_effect=AssertionError("float called"),
                create=True,
            ) as convert,
        ):
            self.assert_payload_rejected(payload)
        decimal.assert_not_called()
        convert.assert_not_called()

    def test_long_leading_zero_exponents_are_normalized_then_accepted(self):
        zeros = "0" * 60_000
        cases = [
            ("1e+" + zeros + "3", 1000.0),
            ("1e-" + zeros + "3", 0.001),
            ("0e" + zeros + "1000", 0.0),
        ]
        for token, expected in cases:
            with self.subTest(token_suffix=token[-12:]):
                payload = ("{\"n\":" + token + "}").encode("ascii")
                value = list(FrameDecoder().feed(raw_frame(payload)))[0]["n"]
                self.assertIs(type(value), float)
                self.assertEqual(value, expected)

    def test_literal_numeric_vectors_expose_types_and_equality_aliases(self):
        decoded = {}
        for vector in NUMERIC_VECTORS:
            with self.subTest(vector=vector["name"]):
                payload = ("{\"number\":" + vector["token"] + "}").encode(
                    "ascii"
                )
                value = list(FrameDecoder().feed(raw_frame(payload)))[0]["number"]
                self.assertEqual(type(value).__name__, vector["python_type"])
                decoded[vector["name"]] = value

        aliases = {}
        for vector in NUMERIC_VECTORS:
            alias = vector.get("alias_group")
            if alias:
                aliases.setdefault(alias, []).append(decoded[vector["name"]])
        for alias, values in aliases.items():
            with self.subTest(alias=alias):
                self.assertTrue(all(value == values[0] for value in values))
                self.assertTrue(all(hash(value) == hash(values[0]) for value in values))

        self.assertEqual(math.copysign(1.0, decoded["negative-float-zero"]), -1.0)

    def test_malformed_utf8_is_rejected(self):
        self.assert_payload_rejected(b'{"text":"\xff"}')

    def test_surrogate_code_points_are_rejected_in_values_and_keys(self):
        for payload in (
            b'{"text":"\\ud800"}',
            b'{"text":"\\ude00\\ud83d"}',
            b'{"\\udfff":true}',
        ):
            with self.subTest(payload=payload):
                self.assert_payload_rejected(payload)

        for message in ({"text": "\ud800"}, {"\udfff": True}):
            with self.subTest(message=list(message.keys())):
                with self.assertRaises(ProtocolError):
                    encode_frame(message)

        escaped_text = {"text": r"literal characters: \ud800"}
        self.assertEqual(
            list(FrameDecoder().feed(encode_frame(escaped_text))), [escaped_text]
        )

    def test_standard_ascii_json_surrogate_pairs_are_accepted(self):
        message = {"📖": "Café 😀"}
        payload = json.dumps(message, ensure_ascii=True).encode("ascii")
        self.assertEqual(list(FrameDecoder().feed(raw_frame(payload))), [message])

        # Duplicate detection operates on decoded Unicode, not wire spelling.
        self.assert_payload_rejected(
            '{"😀":1,"\\ud83d\\ude00":2}'.encode("utf-8")
        )

    def test_malformed_json_syntax_is_rejected(self):
        for payload in (
            b'{"trailing":true,}',
            b'{"missing":}',
            b'{"first":true}{"second":true}',
            b'{"mismatch":[}',
        ):
            with self.subTest(payload=payload):
                self.assert_payload_rejected(payload)

    def test_nonobject_top_levels_are_rejected(self):
        for payload in (b"[]", b'"string"', b"17", b"true", b"null"):
            with self.subTest(payload=payload):
                self.assert_payload_rejected(payload)

        for value in ([], "string", 17, True, None):
            with self.subTest(value=value):
                with self.assertRaises(ProtocolError):
                    encode_frame(value)  # type: ignore[arg-type]

    def test_only_json_data_model_types_and_string_keys_are_encoded(self):
        for message in ({1: "integer key"}, {"tuple": (1, 2)}, {"bytes": b"no"}):
            with self.subTest(message=message):
                with self.assertRaises(ProtocolError):
                    encode_frame(message)  # type: ignore[arg-type]

    def test_brackets_and_escaped_quotes_inside_strings_do_not_add_depth(self):
        text = '[{ nested-looking text \\" still in the string: } ]'
        message = {"text": text}

        self.assertEqual(list(FrameDecoder().feed(encode_frame(message))), [message])

        raw = b'{"text":"[ { escaped quote: \\" and close marks: } ]"}'
        self.assertEqual(list(FrameDecoder().feed(raw_frame(raw))), [
            {"text": '[ { escaped quote: " and close marks: } ]'}
        ])

    def test_maximum_nesting_is_accepted(self):
        message = nested_object(MAX_NESTING)
        self.assertEqual(list(FrameDecoder().feed(encode_frame(message))), [message])

    def test_excess_nesting_is_rejected_before_json_loads_recurses(self):
        text = json.dumps(nested_object(MAX_NESTING + 1), separators=(",", ":"))
        decoder = FrameDecoder()

        with mock.patch.object(book_protocol.json, "loads") as loads:
            with self.assertRaisesRegex(ProtocolError, "nesting"):
                list(decoder.feed(raw_frame(text.encode("ascii"))))
            loads.assert_not_called()
        self.assertTrue(decoder.poisoned)

        with mock.patch.object(book_protocol.json, "dumps") as dumps:
            with self.assertRaisesRegex(ProtocolError, "nesting"):
                encode_frame(nested_object(MAX_NESTING + 1))
            dumps.assert_not_called()


class EncodingBudgetTests(unittest.TestCase):
    def test_oversized_string_is_rejected_before_json_serialization(self):
        message = {"s": "x" * (1024 * 1024)}
        with mock.patch.object(book_protocol.json, "dumps") as dumps:
            with self.assertRaisesRegex(ProtocolError, "encoding budget limit"):
                encode_frame(message)
            dumps.assert_not_called()

    def test_impossibly_wide_list_is_rejected_before_iterating_its_children(self):
        class IterationForbiddenList(list):
            def __iter__(self):
                raise AssertionError("wide list children were visited")

        message = {"items": IterationForbiddenList([None] * 40_000)}
        with mock.patch.object(book_protocol.json, "dumps") as dumps:
            with self.assertRaisesRegex(ProtocolError, "encoding budget limit"):
                encode_frame(message)
            dumps.assert_not_called()


class EofAndFailureTests(unittest.TestCase):
    def test_stream_owners_cannot_be_copied_or_pickled(self):
        for clone in (copy.copy, copy.deepcopy, pickle.dumps):
            for started in (False, True):
                with self.subTest(clone=clone.__name__, started=started):
                    decoder = FrameDecoder()
                    frames = decoder.feed(encode_frame({"seq": 1}) +
                                          encode_frame({"seq": 2}))
                    if started:
                        self.assertEqual(next(frames), {"seq": 1})
                    for owner in (decoder, frames):
                        with self.assertRaises(TypeError):
                            clone(owner)
                    # Failed copying must not release or poison ownership.
                    with self.assertRaises(RuntimeError):
                        decoder.feed(encode_frame({"seq": 3}))
                    self.assertFalse(decoder.poisoned)
                    self.assertEqual(list(frames),
                                     [{"seq": 2}] if started else
                                     [{"seq": 1}, {"seq": 2}])
                    self.assertEqual(list(decoder.feed(encode_frame({"seq": 3}))),
                                     [{"seq": 3}])
                    decoder.finish()

    def test_clean_eof_closes_decoder(self):
        decoder = FrameDecoder()
        self.assertEqual(list(decoder.feed(encode_frame({"done": True}))), [{"done": True}])
        decoder.finish()

        with self.assertRaisesRegex(ProtocolError, "closed"):
            decoder.feed(b"")

    def test_eof_rejects_partial_header_and_poisons(self):
        decoder = FrameDecoder()
        self.assertEqual(list(decoder.feed(b"\x00\x00")), [])

        with self.assertRaisesRegex(ProtocolError, "header"):
            decoder.finish()
        self.assertTrue(decoder.poisoned)

    def test_eof_rejects_partial_payload_and_poisons(self):
        frame = encode_frame({"incomplete": True})
        decoder = FrameDecoder()
        self.assertEqual(list(decoder.feed(frame[:-2])), [])

        with self.assertRaisesRegex(ProtocolError, "payload"):
            decoder.finish()
        self.assertTrue(decoder.poisoned)

    def test_protocol_error_fails_closed_for_all_later_input(self):
        decoder = FrameDecoder()

        with self.assertRaises(ProtocolError):
            list(decoder.feed(raw_frame(b"[]")))
        self.assertTrue(decoder.poisoned)
        self.assertEqual(decoder.buffered_bytes, 0)

        with self.assertRaisesRegex(ProtocolError, "poisoned"):
            decoder.feed(encode_frame({"would": "otherwise be valid"}))
        with self.assertRaisesRegex(ProtocolError, "poisoned"):
            decoder.finish()

    def test_valid_frame_before_bad_coalesced_frame_is_emitted_then_stream_poisoned(self):
        decoder = FrameDecoder()
        iterator = decoder.feed(encode_frame({"first": True}) + struct.pack(">I", 0))

        self.assertEqual(next(iterator), {"first": True})
        with self.assertRaises(ProtocolError):
            next(iterator)
        self.assertTrue(decoder.poisoned)

    def test_active_iterator_must_be_finished_before_another_feed_or_eof(self):
        decoder = FrameDecoder()
        iterator = decoder.feed(encode_frame({"first": True}) + encode_frame({"second": True}))
        self.assertEqual(next(iterator), {"first": True})

        with self.assertRaises(RuntimeError):
            decoder.feed(b"")
        with self.assertRaises(RuntimeError):
            decoder.finish()

        self.assertEqual(list(iterator), [{"second": True}])
        self.assertEqual(
            list(decoder.feed(encode_frame({"later": True}))), [{"later": True}]
        )

    def test_unstarted_feed_reserves_decoder_and_prevents_reverse_order(self):
        decoder = FrameDecoder()
        first = decoder.feed(encode_frame({"sequence": 1}))

        with self.assertRaisesRegex(RuntimeError, "previous feed"):
            decoder.feed(encode_frame({"sequence": 2}))

        self.assertEqual(list(first), [{"sequence": 1}])
        self.assertEqual(
            list(decoder.feed(encode_frame({"sequence": 2}))),
            [{"sequence": 2}],
        )

    def test_unstarted_feed_prevents_clean_eof_until_consumed(self):
        decoder = FrameDecoder()
        pending = decoder.feed(encode_frame({"sequence": 1}))

        with self.assertRaisesRegex(RuntimeError, "active feed"):
            decoder.finish()

        self.assertEqual(list(pending), [{"sequence": 1}])
        decoder.finish()
        self.assertFalse(decoder.poisoned)

    def test_close_before_first_next_poisons_handed_off_input(self):
        decoder = FrameDecoder()
        pending = decoder.feed(
            encode_frame({"sequence": 1}) + encode_frame({"sequence": 2})
        )

        pending.close()

        self.assertTrue(decoder.poisoned)
        with self.assertRaisesRegex(ProtocolError, "poisoned"):
            decoder.feed(encode_frame({"sequence": 3}))

    def test_same_iterator_cannot_reenter_while_decoding(self):
        decoder = FrameDecoder()
        original_decode = book_protocol._decode_payload
        holder = {}

        def decode_with_reentry_check(payload):
            with self.assertRaisesRegex(RuntimeError, "already executing"):
                next(holder["iterator"])
            return original_decode(payload)

        with mock.patch.object(
            book_protocol, "_decode_payload", side_effect=decode_with_reentry_check
        ):
            iterator = decoder.feed(encode_frame({"sequence": 1}))
            holder["iterator"] = iterator
            self.assertEqual(next(iterator), {"sequence": 1})
            iterator.close()

        self.assertFalse(decoder.poisoned)

    def test_abandoning_coalesced_input_poisons_instead_of_dropping_bytes(self):
        decoder = FrameDecoder()
        iterator = decoder.feed(
            encode_frame({"first": True}) + encode_frame({"second": True})
        )
        self.assertEqual(next(iterator), {"first": True})

        iterator.close()

        self.assertTrue(decoder.poisoned)
        with self.assertRaisesRegex(ProtocolError, "poisoned"):
            decoder.feed(b"")


if __name__ == "__main__":
    unittest.main()
