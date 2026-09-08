import json
import socket
import struct
import unittest
from dataclasses import FrozenInstanceError

from book_protocol import FrameDecoder, ProtocolError, encode_frame
from book_session import (
    MAX_ACTION_TEXT_BYTES,
    MAX_OPAQUE_ID_BYTES,
    MAX_PENDING_REQUESTS,
    MAX_PEER_MESSAGE_MEMBERS,
    MAX_PRESENT_TEXT_BYTES,
    MAX_SAFE_INTEGER,
    MAX_SESSIONS,
    MAX_TERMINAL_REQUESTS,
    AuthorityError,
    BookSessionHost,
    PresentedText,
    SchemaError,
    StateError,
    SupervisedConnectionBinding,
)


def decode_literal(payload: str):
    encoded = payload.encode("utf-8")
    decoder = FrameDecoder()
    messages = list(decoder.feed(struct.pack(">I", len(encoded)) + encoded))
    decoder.finish()
    return messages[0]


def present_for(action, text="rendered text"):
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


def literal_present(action, field, token):
    numbers = {
        "surface_generation": str(action["surface_generation"]),
        "sequence": str(action["sequence"]),
        "count": "1",
    }
    numbers[field] = token
    return decode_literal(
        "{" + ",".join((
            '"type":"present"',
            f'"request_id":{json.dumps(action["request_id"])}',
            f'"action_id":{json.dumps(action["action_id"])}',
            f'"surface_handle":{json.dumps(action["surface_handle"])}',
            f'"surface_generation":{numbers["surface_generation"]}',
            f'"sequence":{numbers["sequence"]}',
            f'"count":{numbers["count"]}',
            '"text":"rendered text"',
        )) + "}"
    )


def receive_one(sock, decoder):
    while True:
        chunk = sock.recv(11)
        if not chunk:
            raise AssertionError("socket closed before a complete frame")
        messages = list(decoder.feed(chunk))
        if messages:
            if len(messages) != 1:
                raise AssertionError("test expected one frame")
            return messages[0]


class SessionContractTests(unittest.TestCase):
    def setUp(self):
        self.host = BookSessionHost()
        self.connection = SupervisedConnectionBinding("worker-a")
        self.host.open_session(self.connection)

    def initialize(self):
        return self.host.dispatch_peer(
            self.connection, {"type": "hello", "version": 1}
        )

    def test_hello_initializes_one_immutable_host_generated_surface(self):
        with self.assertRaises(StateError):
            self.host.host_action(self.connection, "submit", "before hello")

        initial_grants = self.host.initial_grants(self.connection)
        self.assertEqual(len(initial_grants.surfaces), 1)
        with self.assertRaises(FrozenInstanceError):
            initial_grants.surfaces[0].generation = 2

        initialize = self.initialize()
        self.assertEqual(
            set(initialize),
            {
                "type",
                "version",
                "grant_count",
                "surface_handle",
                "surface_generation",
                "max_pending_requests",
                "max_present_text_bytes",
            },
        )
        self.assertEqual(initialize["type"], "initialize")
        self.assertEqual(initialize["version"], 1)
        self.assertEqual(initialize["grant_count"], 1)
        self.assertEqual(initialize["surface_generation"], 1)
        self.assertEqual(initialize["max_pending_requests"], MAX_PENDING_REQUESTS)
        self.assertEqual(initialize["max_present_text_bytes"], MAX_PRESENT_TEXT_BYTES)
        for field in (
            "version",
            "grant_count",
            "surface_generation",
            "max_pending_requests",
            "max_present_text_bytes",
        ):
            self.assertIs(type(initialize[field]), int)
        self.assertIs(type(initialize["surface_handle"]), str)
        self.assertLessEqual(
            len(initialize["surface_handle"].encode("utf-8")),
            MAX_OPAQUE_ID_BYTES,
        )
        self.assertEqual(self.host.snapshot(self.connection).live_handles, 1)
        with self.assertRaises(StateError):
            self.initialize()

    def test_rejected_hello_is_atomic_and_retryable(self):
        bad_messages = (
            {"type": "hello"},
            {"type": "hello", "version": 1, "owner": "self-asserted"},
            {"type": "hello", "version": 2},
            {"type": "hello", "version": True},
            {"type": "hello", "version": 1.0},
        )
        for message in bad_messages:
            with self.subTest(message=message):
                with self.assertRaises(SchemaError):
                    self.host.dispatch_peer(self.connection, message)
                self.assertEqual(
                    self.host.snapshot(self.connection).state, "awaiting-hello"
                )
        self.initialize()

    def test_valid_action_present_and_duplicate_success(self):
        initialize = self.initialize()
        action = self.host.host_action(self.connection, "submit-value", "forty two")
        self.assertEqual(action["type"], "action")
        self.assertEqual(action["surface_handle"], initialize["surface_handle"])
        self.assertEqual(action["surface_generation"], 1)
        self.assertEqual(action["sequence"], 1)
        self.assertIs(type(action["surface_generation"]), int)
        self.assertIs(type(action["sequence"]), int)
        self.assertIs(type(action["request_id"]), str)

        result = self.host.dispatch_peer(self.connection, present_for(action, "42"))
        self.assertIsInstance(result, PresentedText)
        self.assertEqual(result.text, "42")
        self.assertEqual(self.host.snapshot(self.connection).pending_requests, 0)
        with self.assertRaisesRegex(StateError, "completed"):
            self.host.dispatch_peer(self.connection, present_for(action, "duplicate"))

    def test_schema_and_authority_failures_do_not_consume_pending_request(self):
        self.initialize()
        action = self.host.host_action(self.connection, "submit", "input")
        invalid = []

        extra = present_for(action)
        extra["owner"] = "claimed-component"
        invalid.append(extra)
        missing = present_for(action)
        del missing["text"]
        invalid.append(missing)
        wrong_type = present_for(action)
        wrong_type["text"] = ["not", "plain", "text"]
        invalid.append(wrong_type)
        too_long = present_for(action)
        too_long["text"] = "😀" * (MAX_PRESENT_TEXT_BYTES // 4 + 1)
        invalid.append(too_long)
        markup = present_for(action)
        markup["markup"] = "<b>not a supported field</b>"
        invalid.append(markup)
        path = present_for(action)
        path["path"] = "/etc/passwd"
        invalid.append(path)
        wrong_action = present_for(action)
        wrong_action["action_id"] = "another-action"
        invalid.append(wrong_action)
        wrong_sequence = present_for(action)
        wrong_sequence["sequence"] += 1
        invalid.append(wrong_sequence)

        for message in invalid:
            with self.subTest(message=message):
                with self.assertRaises((SchemaError, AuthorityError)):
                    self.host.dispatch_peer(self.connection, message)
                self.assertEqual(self.host.snapshot(self.connection).pending_requests, 1)

        result = self.host.dispatch_peer(
            self.connection,
            present_for(action, "<b>is literal text, not markup</b>"),
        )
        self.assertEqual(result.text, "<b>is literal text, not markup</b>")

    def test_raw_numeric_aliases_are_rejected_before_pending_lookup(self):
        self.initialize()
        action = self.host.host_action(self.connection, "submit", "input")
        aliases = ("true", "1.0", "1e0", "-0.0", "0.99999999999999999")
        for field in ("surface_generation", "sequence", "count"):
            for token in aliases:
                with self.subTest(field=field, token=token):
                    decoded = literal_present(action, field, token)
                    with self.assertRaises(SchemaError):
                        self.host.dispatch_peer(self.connection, decoded)
                    self.assertEqual(
                        self.host.snapshot(self.connection).pending_requests, 1
                    )

        for token in (str(MAX_SAFE_INTEGER), "1000001", "0", "-1"):
            with self.subTest(surface_generation=token):
                with self.assertRaises(SchemaError):
                    self.host.dispatch_peer(
                        self.connection,
                        literal_present(action, "surface_generation", token),
                    )
        for field, token in (("sequence", "1000001"), ("count", "0"), ("count", "2")):
            with self.subTest(field=field, token=token):
                with self.assertRaises(SchemaError):
                    self.host.dispatch_peer(
                        self.connection, literal_present(action, field, token)
                    )
        with self.assertRaises(ProtocolError):
            literal_present(action, "sequence", str(MAX_SAFE_INTEGER + 1))
        self.assertEqual(self.host.snapshot(self.connection).pending_requests, 1)
        self.host.dispatch_peer(self.connection, present_for(action))

    def test_raw_hello_numeric_aliases_do_not_activate(self):
        for token in ("true", "1.0", "1e0", "-0.0", "0.99999999999999999"):
            with self.subTest(token=token):
                hello = decode_literal(f'{{"type":"hello","version":{token}}}')
                with self.assertRaises(SchemaError):
                    self.host.dispatch_peer(self.connection, hello)
                self.assertEqual(
                    self.host.snapshot(self.connection).state, "awaiting-hello"
                )
        self.initialize()

    def test_bounded_opaque_fields_and_host_action_values(self):
        self.initialize()
        with self.assertRaises(SchemaError):
            self.host.host_action(self.connection, "a" * (MAX_OPAQUE_ID_BYTES + 1), "x")
        with self.assertRaises(SchemaError):
            self.host.host_action(
                self.connection, "submit", "x" * (MAX_ACTION_TEXT_BYTES + 1)
            )
        self.assertEqual(self.host.snapshot(self.connection).pending_requests, 0)

        action = self.host.host_action(self.connection, "submit", "input")
        for field in ("request_id", "action_id", "surface_handle"):
            message = present_for(action)
            message[field] = "x" * (MAX_OPAQUE_ID_BYTES + 1)
            with self.subTest(field=field):
                with self.assertRaises(SchemaError):
                    self.host.dispatch_peer(self.connection, message)
                self.assertEqual(self.host.snapshot(self.connection).pending_requests, 1)
        result = self.host.dispatch_peer(
            self.connection, present_for(action, "x" * MAX_PRESENT_TEXT_BYTES)
        )
        self.assertEqual(len(result.text), MAX_PRESENT_TEXT_BYTES)

    def test_pending_limit_cancel_expiry_and_late_results(self):
        self.initialize()
        actions = [
            self.host.host_action(self.connection, f"action-{index}", "input")
            for index in range(MAX_PENDING_REQUESTS)
        ]
        with self.assertRaisesRegex(StateError, "pending request limit"):
            self.host.host_action(self.connection, "one-too-many", "input")

        cancel = self.host.cancel_request(self.connection, actions[0]["request_id"])
        self.assertEqual(
            cancel, {"type": "cancel", "request_id": actions[0]["request_id"]}
        )
        with self.assertRaisesRegex(StateError, "cancelled"):
            self.host.dispatch_peer(self.connection, present_for(actions[0]))

        self.host.expire_request(self.connection, actions[1]["request_id"])
        with self.assertRaisesRegex(StateError, "expired"):
            self.host.dispatch_peer(self.connection, present_for(actions[1]))

        replacement = self.host.host_action(self.connection, "replacement", "input")
        self.host.dispatch_peer(self.connection, present_for(replacement))

    def test_navigation_invalidates_old_and_wrong_generation_results(self):
        self.initialize()
        old_action = self.host.host_action(self.connection, "submit", "old")
        self.assertEqual(self.host.navigate(self.connection), 2)
        self.assertEqual(self.host.snapshot(self.connection).pending_requests, 0)
        with self.assertRaisesRegex(StateError, "stale surface generation"):
            self.host.dispatch_peer(self.connection, present_for(old_action))

        current = self.host.host_action(self.connection, "submit", "current")
        stale = present_for(current)
        stale["surface_generation"] = 1
        with self.assertRaisesRegex(StateError, "stale surface generation"):
            self.host.dispatch_peer(self.connection, stale)
        future = present_for(current)
        future["surface_generation"] = 3
        with self.assertRaisesRegex(StateError, "future surface generation"):
            self.host.dispatch_peer(self.connection, future)
        self.assertEqual(self.host.snapshot(self.connection).pending_requests, 1)
        self.host.dispatch_peer(self.connection, present_for(current))

    def test_revoked_and_closed_sessions_reject_late_results(self):
        self.initialize()
        revoked_action = self.host.host_action(self.connection, "submit", "input")
        self.host.revoke_surface(self.connection)
        revoked = self.host.snapshot(self.connection)
        self.assertEqual(revoked.state, "revoked")
        self.assertEqual(revoked.live_handles, 0)
        self.assertEqual(revoked.pending_requests, 0)
        with self.assertRaisesRegex(StateError, "revoked"):
            self.host.dispatch_peer(self.connection, present_for(revoked_action))
        with self.assertRaisesRegex(StateError, "revoked"):
            self.host.host_action(self.connection, "submit", "later")

        self.host.restart_session(self.connection)
        self.initialize()
        closed_action = self.host.host_action(self.connection, "submit", "input")
        self.host.close_session(self.connection)
        self.host.close_session(self.connection)
        with self.assertRaisesRegex(StateError, "closed"):
            self.host.dispatch_peer(self.connection, present_for(closed_action))

    def test_cross_session_strings_do_not_confer_authority(self):
        self.initialize()
        other = SupervisedConnectionBinding("worker-a")
        self.host.open_session(other)
        self.host.dispatch_peer(other, {"type": "hello", "version": 1})
        first = self.host.host_action(self.connection, "submit", "first")
        second = self.host.host_action(other, "submit", "second")

        with self.assertRaises(AuthorityError):
            self.host.dispatch_peer(other, present_for(first))
        forged = present_for(first)
        forged["surface_handle"] = second["surface_handle"]
        with self.assertRaisesRegex(StateError, "not pending"):
            self.host.dispatch_peer(other, forged)
        self.assertEqual(self.host.snapshot(self.connection).pending_requests, 1)
        self.assertEqual(self.host.snapshot(other).pending_requests, 1)

        claimed = present_for(first)
        claimed["component"] = "worker-a"
        with self.assertRaises(SchemaError):
            self.host.dispatch_peer(self.connection, claimed)
        self.host.dispatch_peer(self.connection, present_for(first))
        self.host.dispatch_peer(other, present_for(second))

    def test_dispatch_requires_the_registered_concrete_binding_object(self):
        with self.assertRaises(TypeError):
            self.host.dispatch_peer("worker-a", {"type": "hello", "version": 1})
        lookalike = SupervisedConnectionBinding("worker-a")
        with self.assertRaisesRegex(StateError, "no host session"):
            self.host.dispatch_peer(lookalike, {"type": "hello", "version": 1})
        self.initialize()

    def test_restart_requires_hello_and_issues_fresh_identity_and_handle(self):
        original_initialize = self.initialize()
        original_snapshot = self.host.snapshot(self.connection)
        old_action = self.host.host_action(self.connection, "submit", "input")

        self.host.restart_session(self.connection)
        restarted = self.host.snapshot(self.connection)
        self.assertNotEqual(restarted.session_id, original_snapshot.session_id)
        self.assertEqual(restarted.state, "awaiting-hello")
        self.assertEqual(restarted.live_handles, 0)
        with self.assertRaisesRegex(StateError, "awaiting-hello"):
            self.host.host_action(self.connection, "submit", "not auto-active")
        with self.assertRaisesRegex(StateError, "awaiting-hello"):
            self.host.dispatch_peer(self.connection, present_for(old_action))

        new_initialize = self.initialize()
        self.assertNotEqual(
            new_initialize["surface_handle"], original_initialize["surface_handle"]
        )
        with self.assertRaises(AuthorityError):
            self.host.dispatch_peer(self.connection, present_for(old_action))
        new_action = self.host.host_action(self.connection, "submit", "new")
        self.host.dispatch_peer(self.connection, present_for(new_action))

    def test_terminal_history_and_connection_registry_are_bounded(self):
        self.initialize()
        old = None
        for index in range(MAX_TERMINAL_REQUESTS + 4):
            action = self.host.host_action(self.connection, f"action-{index}", "input")
            old = old or action
            self.host.dispatch_peer(self.connection, present_for(action))
        snapshot = self.host.snapshot(self.connection)
        self.assertEqual(snapshot.pending_requests, 0)
        self.assertEqual(snapshot.retained_terminal_requests, MAX_TERMINAL_REQUESTS)
        with self.assertRaises(StateError):
            self.host.dispatch_peer(self.connection, present_for(old))

        bounded_host = BookSessionHost()
        connections = [
            SupervisedConnectionBinding(f"connection-{index}")
            for index in range(MAX_SESSIONS + 1)
        ]
        for connection in connections[:MAX_SESSIONS]:
            bounded_host.open_session(connection)
        with self.assertRaisesRegex(StateError, "session limit"):
            bounded_host.open_session(connections[-1])
        bounded_host.release_connection(connections[0])
        bounded_host.open_session(connections[-1])

    def test_peer_cannot_invoke_host_authority_or_add_message_work(self):
        self.initialize()
        for message in (
            {"type": "action"},
            {"type": "cancel", "request_id": "request-known"},
            {f"field-{index}": index for index in range(MAX_PEER_MESSAGE_MEMBERS + 1)},
        ):
            with self.subTest(message=message):
                with self.assertRaises(SchemaError):
                    self.host.dispatch_peer(self.connection, message)
        self.assertEqual(self.host.snapshot(self.connection).pending_requests, 0)

    def test_real_socketpair_framing_carries_initial_action_present_trace(self):
        host_socket, peer_socket = socket.socketpair()
        host_socket.settimeout(2)
        peer_socket.settimeout(2)
        host_decoder = FrameDecoder()
        peer_decoder = FrameDecoder()
        try:
            peer_socket.sendall(encode_frame({"type": "hello", "version": 1}))
            hello = receive_one(host_socket, host_decoder)
            initialize = self.host.dispatch_peer(self.connection, hello)
            host_socket.sendall(encode_frame(initialize))
            peer_initialize = receive_one(peer_socket, peer_decoder)

            action = self.host.host_action(self.connection, "submit-name", "Ada")
            host_socket.sendall(encode_frame(action))
            peer_action = receive_one(peer_socket, peer_decoder)
            bad_present = present_for(peer_action, "must not consume request")
            bad_present["owner"] = "self-asserted"
            peer_socket.sendall(
                encode_frame(bad_present)
                + encode_frame(present_for(peer_action, "Hello, Ada"))
            )
            rejected = receive_one(host_socket, host_decoder)
            with self.assertRaises(SchemaError):
                self.host.dispatch_peer(self.connection, rejected)
            self.assertEqual(self.host.snapshot(self.connection).pending_requests, 1)
            present = receive_one(host_socket, host_decoder)
            result = self.host.dispatch_peer(self.connection, present)

            self.assertEqual(peer_initialize["type"], "initialize")
            self.assertEqual(peer_initialize["grant_count"], 1)
            self.assertEqual(peer_action["type"], "action")
            self.assertEqual(result.text, "Hello, Ada")
        finally:
            host_socket.close()
            peer_socket.close()


if __name__ == "__main__":
    unittest.main()
