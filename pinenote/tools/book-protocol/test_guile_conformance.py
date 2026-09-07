import json
import math
import os
from pathlib import Path
import socket
import subprocess
import unittest

from book_protocol import (
    MAX_FRAME_SIZE,
    FrameDecoder,
    ProtocolError,
    encode_frame,
)


HERE = Path(__file__).resolve().parent
DIAGNOSTIC = b"Guile conformance fixture diagnostic on stdout\n"
NUMERIC_VECTORS = json.loads(
    (HERE / "numeric-wire-vectors.json").read_text(encoding="utf-8")
)
MALFORMED_OBJECT_VECTORS = json.loads(
    (HERE / "malformed-object-vectors.json").read_text(encoding="utf-8")
)


def run_guile_peer(input_bytes: bytes, *, originate_fixtures: bool = False):
    parent_socket, child_socket = socket.socketpair()
    environment = os.environ.copy()
    environment["BOOK_PROTOCOL_FD"] = str(child_socket.fileno())
    if originate_fixtures:
        environment["BOOK_PROTOCOL_ORIGINATE_FIXTURES"] = "1"
    process = subprocess.Popen(
        ["guile", "--no-auto-compile", "-L", str(HERE),
         str(HERE / "guile-conformance-peer.scm")],
        pass_fds=(child_socket.fileno(),),
        env=environment,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    child_socket.close()
    parent_socket.settimeout(10)

    try:
        parent_socket.sendall(input_bytes)
        parent_socket.shutdown(socket.SHUT_WR)
        response_parts = []
        while True:
            part = parent_socket.recv(4096)
            if not part:
                break
            response_parts.append(part)
    except Exception:
        process.kill()
        process.communicate()
        raise
    finally:
        parent_socket.close()

    try:
        stdout, stderr = process.communicate(timeout=10)
    except subprocess.TimeoutExpired:
        process.kill()
        stdout, stderr = process.communicate()
        raise AssertionError(
            f"Guile conformance peer timed out; stdout={stdout!r}, stderr={stderr!r}"
        )
    return process.returncode, b"".join(response_parts), stdout, stderr


class GuileConformanceTests(unittest.TestCase):
    def test_python_frames_are_decoded_and_reencoded_by_guile(self):
        messages = [
            {
                "type": "open",
                "title": "Café 📖",
                "page": 17,
                "ratio": 0.125,
                "flags": [True, False, None],
            },
            {"type": "status", "nested": {"ready": True}},
        ]
        returncode, response, stdout, stderr = run_guile_peer(
            b"".join(encode_frame(message) for message in messages)
        )

        decoder = FrameDecoder()
        decoded = list(decoder.feed(response))
        decoder.finish()
        self.assertEqual(
            decoded,
            [{"from": "guile", "message": message} for message in messages],
        )
        self.assertEqual(returncode, 0, stderr.decode("utf-8", "replace"))
        self.assertEqual(stdout, DIAGNOSTIC)
        self.assertEqual(stderr, b"")
        self.assertNotIn(response, stdout)
        self.assertIs(type(decoded[0]["message"]["page"]), int)
        self.assertIs(type(decoded[0]["message"]["ratio"]), float)

    def test_guile_rejects_duplicate_keys_in_a_python_framed_payload(self):
        payload = b'{"same":1,"same":2}'
        frame = len(payload).to_bytes(4, "big") + payload
        returncode, response, stdout, stderr = run_guile_peer(frame)

        self.assertEqual(returncode, 2)
        self.assertEqual(response, b"")
        self.assertEqual(stdout, DIAGNOSTIC)
        self.assertIn(b"Book Protocol error", stderr)

    def test_malformed_object_separator_corpus_fails_locally_and_on_socket(self):
        for vector in MALFORMED_OBJECT_VECTORS:
            with self.subTest(vector=vector["name"]):
                payload = vector["payload"].encode("utf-8")
                frame = len(payload).to_bytes(4, "big") + payload

                with self.assertRaises(ProtocolError):
                    list(FrameDecoder().feed(frame))

                returncode, response, stdout, stderr = run_guile_peer(frame)
                self.assertEqual(returncode, 2)
                self.assertEqual(response, b"")
                self.assertEqual(stdout, DIAGNOSTIC)
                self.assertIn(b"Book Protocol error", stderr)

    def test_python_controls_in_keys_and_values_round_trip_through_guile(self):
        controls = "".join(chr(codepoint) for codepoint in range(32))
        control_object = {
            chr(codepoint): chr(codepoint) for codepoint in range(32)
        }
        message = {"controls": controls, "control-object": control_object}
        returncode, response, stdout, stderr = run_guile_peer(
            encode_frame(message)
        )

        payload_length = int.from_bytes(response[:4], "big")
        response_payload = response[4 : 4 + payload_length]
        self.assertFalse(any(byte < 0x20 for byte in response_payload))
        self.assertEqual(
            list(FrameDecoder().feed(response)),
            [{"from": "guile", "message": message}],
        )
        self.assertEqual(returncode, 0, stderr.decode("utf-8", "replace"))
        self.assertEqual(stdout, DIAGNOSTIC)
        self.assertEqual(stderr, b"")

    def test_guile_originates_controls_supplementary_and_exact_maximum(self):
        returncode, response, stdout, stderr = run_guile_peer(
            b"", originate_fixtures=True
        )

        first_length = int.from_bytes(response[:4], "big")
        first_payload = response[4 : 4 + first_length]
        second_offset = 4 + first_length
        second_length = int.from_bytes(
            response[second_offset : second_offset + 4], "big"
        )
        self.assertFalse(any(byte < 0x20 for byte in first_payload))
        self.assertIn(b"\\ud83d\\ude00", first_payload)
        self.assertEqual(second_length, MAX_FRAME_SIZE)

        decoded = list(FrameDecoder().feed(response))
        controls = "".join(chr(codepoint) for codepoint in range(32))
        expected_control_object = {
            chr(codepoint): chr(codepoint) for codepoint in range(32)
        }
        self.assertEqual(decoded[0]["controls"], controls)
        self.assertEqual(decoded[0]["control-object"], expected_control_object)
        self.assertEqual(decoded[0]["supplementary"], "😀")
        negative_zero = decoded[0]["negative-zero"]
        self.assertIs(type(negative_zero), float)
        self.assertEqual(math.copysign(1.0, negative_zero), -1.0)
        self.assertEqual(len(decoded[1]["s"]), 10_923)
        self.assertEqual(returncode, 0, stderr.decode("utf-8", "replace"))
        self.assertEqual(stdout, DIAGNOSTIC)
        self.assertEqual(stderr, b"")

    def test_literal_numeric_vectors_expose_guile_type_changes(self):
        frames = []
        for vector in NUMERIC_VECTORS:
            payload = ("{\"number\":" + vector["token"] + "}").encode("ascii")
            frames.append(len(payload).to_bytes(4, "big") + payload)

        returncode, response, stdout, stderr = run_guile_peer(b"".join(frames))
        decoded = list(FrameDecoder().feed(response))

        self.assertEqual(returncode, 0, stderr.decode("utf-8", "replace"))
        self.assertEqual(stdout, DIAGNOSTIC)
        self.assertEqual(stderr, b"")
        self.assertEqual(len(decoded), len(NUMERIC_VECTORS))
        for vector, reply in zip(NUMERIC_VECTORS, decoded, strict=True):
            with self.subTest(vector=vector["name"]):
                value = reply["message"]["number"]
                self.assertEqual(
                    type(value).__name__, vector["python_type_after_guile"]
                )
                self.assertEqual(repr(value), vector["python_repr_after_guile"])
                expected_sign = vector.get("zero_sign_after_guile")
                if expected_sign is not None:
                    self.assertEqual(math.copysign(1.0, value), expected_sign)


if __name__ == "__main__":
    unittest.main()
