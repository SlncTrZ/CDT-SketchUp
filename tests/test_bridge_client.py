"""Bridge Client Tests — Loopback I/O and authentication envelope behavior.
Wing: code | Topic: sketchup_bridge | Updated: 2026-09-09 19:00
"""

from __future__ import annotations

import asyncio
import json
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))

from cdt_sketchup.bridge import BridgeClient  # noqa: E402


class BridgeClientTests(unittest.IsolatedAsyncioTestCase):
    async def test_call_sends_token_and_decodes_result(self) -> None:
        received: dict[str, object] = {}

        async def handle(reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
            request = json.loads((await reader.readline()).decode("utf-8"))
            received.update(request)
            response = {
                "protocol": 1,
                "request_id": request["request_id"],
                "ok": True,
                "result": {"live_model": True},
            }
            writer.write(json.dumps(response).encode("utf-8") + b"\n")
            await writer.drain()
            writer.close()
            await writer.wait_closed()

        server = await asyncio.start_server(handle, "127.0.0.1", 0)
        port = server.sockets[0].getsockname()[1]
        with tempfile.TemporaryDirectory() as temp_dir:
            token_path = Path(temp_dir) / "bridge.token"
            token_path.write_text("a" * 64, encoding="utf-8")
            client = BridgeClient(port=port, token_path=token_path)
            try:
                result = await client.call("ping")
            finally:
                server.close()
                await server.wait_closed()

        self.assertEqual(result, {"live_model": True})
        self.assertEqual(received["command"], "ping")
        self.assertEqual(received["token"], "a" * 64)
        self.assertNotIn("code", received)

    async def test_probe_is_degraded_when_bridge_is_absent(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            token_path = Path(temp_dir) / "bridge.token"
            token_path.write_text("b" * 64, encoding="utf-8")
            client = BridgeClient(port=9, timeout=0.05, token_path=token_path)
            status = await client.probe()
        self.assertFalse(status["bridge_connected"])
        self.assertFalse(status["live_model"])


if __name__ == "__main__":
    unittest.main()
