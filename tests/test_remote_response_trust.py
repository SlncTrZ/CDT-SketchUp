"""Remote response trust: real HTTP boundary, one dispatch and honest uncertainty."""

from __future__ import annotations

import json
import secrets
import sys
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))

from cdt_sketchup.runtime_transport import (
    MAX_RESPONSE_BYTES,
    RemoteSketchUpTransport,
    RuntimeGenerationMismatchError,
    RuntimeUncertainError,
)


class RemoteResponseTrustTests(unittest.IsolatedAsyncioTestCase):
    def setUp(self) -> None:
        self.dispatches = 0
        self.status = 200
        self.body = b""
        case = self

        class Handler(BaseHTTPRequestHandler):
            def do_POST(self) -> None:
                self.rfile.read(int(self.headers["Content-Length"]))
                case.dispatches += 1
                self.send_response(case.status)
                self.send_header("Content-Length", str(len(case.body)))
                self.end_headers()
                self.wfile.write(case.body)

            def log_message(self, *args) -> None:
                pass

        self.listener = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.thread = threading.Thread(target=self.listener.serve_forever, daemon=True)
        self.thread.start()
        self.transport = RemoteSketchUpTransport(
            f"http://127.0.0.1:{self.listener.server_port}", secrets.token_urlsafe(32)
        )

    async def asyncTearDown(self) -> None:
        await self.transport.close()
        self.listener.shutdown()
        self.listener.server_close()
        self.thread.join(timeout=2)

    def response(self, **changes) -> dict:
        payload = {
            "ok": True,
            "result": {"committed": True},
            "error_code": "ok",
            "error_message": "",
            "generation": "proof-gen",
            "completion_unknown": False,
        }
        payload.update(changes)
        return payload

    async def mutation(self):
        return await self.transport.call(
            "execute_geometry", {"action": "transform_entity"}, expected_generation="proof-gen"
        )

    async def test_malformed_or_contradictory_mutation_response_is_uncertain(self) -> None:
        cases = [
            self.response(ok="false"),
            self.response(ok=1),
            self.response(completion_unknown=True),
            self.response(completion_unknown="false"),
            self.response(error_code="backend_error"),
            self.response(generation=17),
            self.response(generation=""),
            {"ok": True, "result": {"committed": True}, "generation": "proof-gen"},
            [],
        ]
        for payload in cases:
            with self.subTest(payload=payload):
                self.body = json.dumps(payload).encode()
                before = self.dispatches
                with self.assertRaises(RuntimeUncertainError):
                    await self.mutation()
                self.assertEqual(self.dispatches, before + 1)

    async def test_unreadable_or_oversized_reply_is_uncertain(self) -> None:
        for body in [b"not-json", b"\xff", b"", b"x" * (MAX_RESPONSE_BYTES + 1)]:
            with self.subTest(bytes=len(body)):
                self.body = body
                before = self.dispatches
                with self.assertRaises(RuntimeUncertainError):
                    await self.mutation()
                self.assertEqual(self.dispatches, before + 1)

    async def test_wrong_or_missing_success_generation_is_uncertain(self) -> None:
        for generation in ["other-gen", "unbound", None]:
            with self.subTest(generation=generation):
                self.body = json.dumps(self.response(generation=generation)).encode()
                before = self.dispatches
                with self.assertRaises(RuntimeUncertainError):
                    await self.mutation()
                self.assertEqual(self.dispatches, before + 1)

    async def test_success_on_unverified_http_status_is_uncertain(self) -> None:
        self.status = 302
        self.body = json.dumps(self.response()).encode()
        with self.assertRaises(RuntimeUncertainError):
            await self.mutation()
        self.assertEqual(self.dispatches, 1)

    async def test_native_stale_generation_refusal_remains_clean(self) -> None:
        self.body = json.dumps(
            self.response(ok=False, result=None, generation="current-gen",
                          error_code="generation_mismatch", error_message="stale")
        ).encode()
        with self.assertRaises(RuntimeGenerationMismatchError):
            await self.mutation()
        self.assertEqual(self.dispatches, 1)

    async def test_valid_success_keeps_result_unchanged(self) -> None:
        self.body = json.dumps(self.response()).encode()
        self.assertEqual(await self.mutation(), {"committed": True})
        self.assertEqual(self.dispatches, 1)
