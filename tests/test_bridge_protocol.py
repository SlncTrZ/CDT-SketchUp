"""Bridge Protocol Tests — bounded authenticated local bridge envelopes.
Wing: code | Topic: sketchup_bridge | Updated: 2026-09-09 18:56
"""

from __future__ import annotations

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))

from cdt_sketchup.bridge import (  # noqa: E402
    MAX_FRAME_BYTES,
    BridgeProtocolError,
    build_request,
    decode_response,
    encode_frame,
)


class BridgeProtocolTests(unittest.TestCase):
    def test_request_contains_only_typed_command_envelope(self) -> None:
        payload = build_request(
            request_id="abc",
            command="document_info",
            params={},
            token="secret",
        )
        self.assertEqual(
            payload,
            {
                "protocol": 1,
                "request_id": "abc",
                "command": "document_info",
                "params": {},
                "token": "secret",
            },
        )
        self.assertNotIn("code", payload)

    def test_frame_is_newline_delimited_utf8_json(self) -> None:
        frame = encode_frame({"protocol": 1, "request_id": "abc"})
        self.assertTrue(frame.endswith(b"\n"))
        self.assertLessEqual(len(frame), MAX_FRAME_BYTES)

    def test_oversized_frame_is_refused(self) -> None:
        with self.assertRaises(BridgeProtocolError):
            encode_frame({"payload": "x" * MAX_FRAME_BYTES})

    def test_success_response_decodes(self) -> None:
        payload = decode_response(
            b'{"protocol":1,"request_id":"abc","ok":true,"result":{"title":"Demo"}}\n',
            expected_request_id="abc",
        )
        self.assertEqual(payload, {"title": "Demo"})

    def test_remote_error_is_typed(self) -> None:
        with self.assertRaisesRegex(BridgeProtocolError, "live_model_unavailable"):
            decode_response(
                b'{"protocol":1,"request_id":"abc","ok":false,"error":{"kind":"live_model_unavailable","message":"No active model"}}\n',
                expected_request_id="abc",
            )

    def test_response_id_mismatch_is_refused(self) -> None:
        with self.assertRaisesRegex(BridgeProtocolError, "request_id"):
            decode_response(
                b'{"protocol":1,"request_id":"other","ok":true,"result":{}}\n',
                expected_request_id="abc",
            )


if __name__ == "__main__":
    unittest.main()
