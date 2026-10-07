"""RuntimeTransport parity — S3 read + S4 mutation/fault over local vs remote.

Wing: code | Topic: sketchup_runtime_parity | Updated: 2026-10-07 18:45

Local path: fake SketchUpRuntimePort (no SketchUp needed).
Remote path: same fake port behind WorkstationSketchUpRuntimeAgent
(loopback HTTP) + RemoteSketchUpTransport + RemoteSketchUpRuntimeAdapter.
Parity = identical results; faults = typed uncertain, no blind replay.
"""

from __future__ import annotations

import asyncio
import sys
import unittest
from pathlib import Path
from unittest.mock import AsyncMock

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))

from cdt_sketchup.bridge import BridgeClient
from cdt_sketchup.local_runtime import LocalSketchUpRuntimeAdapter
from cdt_sketchup.remote_runtime import RemoteSketchUpRuntimeAdapter
from cdt_sketchup.runtime_transport import (
    LocalSketchUpTransport,
    RemoteSketchUpTransport,
    RuntimeAuthError,
    RuntimeGenerationMismatchError,
    RuntimeOpRefusedError,
    RuntimeUnavailableError,
    RuntimeUncertainError,
)
from cdt_sketchup.workstation_agent import (
    WorkstationAgentConfig,
    WorkstationSketchUpRuntimeAgent,
)


class FakePort:
    """Minimal SketchUpRuntimePort double with scripted command results."""

    def __init__(self, routes: dict | None = None, delay_s: float = 0.0) -> None:
        from cdt_sketchup.runtime_port import SketchUpRuntimePort

        assert isinstance(self, object)
        self._routes = dict(routes or {})
        self._delay = delay_s
        self.calls: list[tuple[str, dict]] = []
        self._bridge = BridgeClient.__new__(BridgeClient)
        self._port_check = SketchUpRuntimePort  # reference only; structural check below

    @property
    def backend(self):  # escape hatch shape (not a live bridge)
        return self._bridge

    async def call(self, command: str, params: dict | None = None):
        self.calls.append((command, dict(params or {})))
        if self._delay:
            await asyncio.sleep(self._delay)
        if command in self._routes:
            result = self._routes[command]
            if isinstance(result, BaseException):
                raise result
            return result() if callable(result) else result
        raise AssertionError(f"unexpected command: {command!r}")

    async def probe(self):
        return {"bridge_connected": True, "live_model": True}

    def health(self):
        return {"adapter": "fake", "available": True}


def _make_remote(fake: FakePort, token: str = "t" * 32):
    agent = WorkstationSketchUpRuntimeAgent(
        fake, WorkstationAgentConfig(host="127.0.0.1", port=0, auth_token=token)
    )
    base_url = agent.start()
    transport = RemoteSketchUpTransport(base_url, token)
    adapter = RemoteSketchUpRuntimeAdapter(transport)
    return agent, transport, adapter


class S1SeamTests(unittest.TestCase):
    def test_local_adapter_delegates_1_to_1(self) -> None:
        bridge = AsyncMock(spec=BridgeClient)
        bridge.call = AsyncMock(return_value={"ok": True})
        bridge.probe = AsyncMock(return_value={"bridge_connected": True, "live_model": True})
        adapter = LocalSketchUpRuntimeAdapter(bridge)
        asyncio.run(adapter.call("document_info", {"a": 1}))
        bridge.call.assert_awaited_once_with("document_info", {"a": 1})
        asyncio.run(adapter.probe())
        bridge.probe.assert_awaited_once()
        self.assertIs(adapter.backend, bridge)
        self.assertEqual(adapter.health()["adapter"], "local")

    def test_local_adapter_rejects_non_bridge(self) -> None:
        with self.assertRaises(TypeError):
            LocalSketchUpRuntimeAdapter(object())  # type: ignore[arg-type]

    def test_server_uses_seam_with_loopback_default(self) -> None:
        from cdt_sketchup import server

        self.assertIs(server._bridge, server.get_runtime())
        self.assertIsInstance(server.get_runtime(), LocalSketchUpRuntimeAdapter)
        self.assertIsInstance(server.get_runtime().backend, BridgeClient)
        with self.assertRaises(TypeError):
            server.set_runtime(object())  # type: ignore[arg-type]


class S3ReadParityTests(unittest.IsolatedAsyncioTestCase):
    from typing import ClassVar

    READ_ROUTES: ClassVar[dict] = {
        "ping": {"live_model": True, "sketchup_version": "24.0.594", "ruby_version": "3.2.2"},
        "document_info": {"title": "M", "context": {"id": "a" * 64, "revision": "b" * 64}},
        "object_list": {"entities": [{"persistent_id": 1}]},
        "object_get": {"persistent_id": 1, "type": "Group"},
        "get_entity_state": {
            "context": {"id": "a" * 64, "revision": "b" * 64},
            "entity_fingerprint": "c" * 64,
            "result": {"persistent_id": 1, "type": "Group"},
        },
        "material_info": {"material": "Brick"},
        "definition_info": {"guid": "g" * 32},
        "query_topology": {"persistent_id": 1, "connected": []},
        "measure_distance": {"center_distance": 1.0},
        "integrity_report": {"issues": []},
        "mutation_reconcile": {"mutation_id": "ab" * 16, "status": "committed"},
    }

    async def test_read_parity_local_vs_remote(self) -> None:
        for command, expected in self.READ_ROUTES.items():
            with self.subTest(command=command):
                local_fake = FakePort({command: expected})
                local = LocalSketchUpTransport(local_fake)
                local_result = await local.call(command, {"x": 1} if command != "ping" else None)

                remote_fake = FakePort({command: expected})
                agent, transport, adapter = _make_remote(remote_fake)
                try:
                    adapter_result = await adapter.call(
                        command, {"x": 1} if command != "ping" else None
                    )
                finally:
                    agent.stop()
                    await transport.close()
                    await local.close()
                self.assertEqual(local_result, expected)
                self.assertEqual(adapter_result, expected)

    async def test_probe_parity_remote(self) -> None:
        remote_fake = FakePort({"ping": {"live_model": True, "sketchup_version": "24.0.594"}})
        agent, transport, adapter = _make_remote(remote_fake)
        try:
            probe = await adapter.probe()
        finally:
            agent.stop()
            await transport.close()
        self.assertTrue(probe["bridge_connected"])
        self.assertTrue(probe["live_model"])

    async def test_server_status_works_through_remote_adapter(self) -> None:
        from cdt_sketchup import server

        previous = server.get_runtime()
        remote_fake = FakePort({"ping": {"live_model": True}})
        agent, transport, adapter = _make_remote(remote_fake)
        server.set_runtime(adapter)
        try:
            status = await server.system_status()
        finally:
            server.set_runtime(previous)
            agent.stop()
            await transport.close()
        self.assertEqual(status["status"], "ready")


class S4MutationFaultTests(unittest.IsolatedAsyncioTestCase):
    async def test_mutation_receipt_parity_and_guards_pass_through(self) -> None:
        receipt = {"committed": True, "persistent_id": 77}
        ctx = {"id": "a" * 64, "revision": "b" * 64}
        fp = "c" * 64
        payload = {
            "action": "transform_entity",
            "params": {"persistent_id": 77},
            "expect": {},
            "unit": "mm",
            "coordinate_space": "active_context",
            "if_context": ctx,
            "if_match": fp,
            "mutation": {"id": "ab" * 16, "request_hash": "cd" * 64},
        }
        local_fake = FakePort({"execute_geometry": receipt})
        local = LocalSketchUpTransport(local_fake)
        self.assertEqual(await local.call("execute_geometry", payload), receipt)
        self.assertEqual(local_fake.calls[0][1]["if_match"], fp)
        await local.close()

        remote_fake = FakePort({"execute_geometry": receipt})
        agent, transport, adapter = _make_remote(remote_fake)
        try:
            self.assertEqual(await adapter.call("execute_geometry", payload), receipt)
        finally:
            agent.stop()
            await transport.close()
        self.assertEqual(remote_fake.calls[0][1]["if_match"], fp)

    async def test_stale_context_refusal_propagates_on_both_paths(self) -> None:
        refusal = {"ok": False, "error": {"kind": "context_mismatch", "message": "stale"}}
        local_fake = FakePort({"execute_geometry": refusal})
        local = LocalSketchUpTransport(local_fake)
        self.assertEqual(
            (await local.call("execute_geometry", {"action": "x"}))["error"]["kind"],
            "context_mismatch",
        )
        await local.close()

        remote_fake = FakePort({"execute_geometry": refusal})
        agent, transport, adapter = _make_remote(remote_fake)
        try:
            result = await adapter.call("execute_geometry", {"action": "x"})
        finally:
            agent.stop()
            await transport.close()
        self.assertEqual(result["error"]["kind"], "context_mismatch")

    async def test_unknown_op_refused_before_dispatch_no_cad_effect(self) -> None:
        fake = FakePort({})
        local = LocalSketchUpTransport(fake)
        with self.assertRaises(RuntimeOpRefusedError):
            await local.call("drop_table", {})
        self.assertEqual(fake.calls, [])
        await local.close()

        fake2 = FakePort({})
        agent, transport, adapter = _make_remote(fake2)
        try:
            with self.assertRaises(RuntimeOpRefusedError):
                await adapter.call("drop_table", {})
        finally:
            agent.stop()
            await transport.close()
        self.assertEqual(fake2.calls, [])

    async def test_bad_token_is_auth_error(self) -> None:
        fake = FakePort({"ping": {"live_model": True}})
        agent = WorkstationSketchUpRuntimeAgent(
            fake, WorkstationAgentConfig(host="127.0.0.1", port=0, auth_token="good" + "g" * 28)
        )
        base_url = agent.start()
        bad = RemoteSketchUpTransport(base_url, "wrong" + "w" * 27)
        try:
            with self.assertRaises(RuntimeAuthError):
                await bad.call("ping")
        finally:
            agent.stop()
            await bad.close()

    async def test_generation_mismatch_discards_result(self) -> None:
        fake = FakePort({"ping": {"live_model": True}})
        agent, transport, adapter = _make_remote(fake)
        adapter.pin_generation("stale-gen")
        try:
            with self.assertRaises(RuntimeGenerationMismatchError):
                await adapter.call("ping")
            # pin to the real generation -> works again
            adapter.pin_generation(agent.generation)
            self.assertEqual(await adapter.call("ping"), {"live_model": True})
        finally:
            agent.stop()
            await transport.close()

    async def test_local_timeout_is_uncertain_and_single_dispatch(self) -> None:
        fake = FakePort({"execute_geometry": {"committed": True}}, delay_s=5.0)
        local = LocalSketchUpTransport(fake)
        try:
            with self.assertRaises(RuntimeUncertainError):
                await local.call("execute_geometry", {"action": "x"}, deadline_ms=200)
        finally:
            await local.close()
        self.assertEqual(len(fake.calls), 1)  # no blind replay

    async def test_remote_timeout_is_uncertain_no_replay(self) -> None:
        fake = FakePort({"execute_geometry": {"committed": True}}, delay_s=5.0)
        agent, transport, adapter = _make_remote(fake)
        transport._default_deadline_ms = 300
        adapter._default_deadline_ms = 300
        try:
            with self.assertRaises(RuntimeUncertainError):
                await adapter.call("execute_geometry", {"action": "x"})
        finally:
            agent.stop()
            await transport.close()
        self.assertEqual(len(fake.calls), 1)

    async def test_disconnect_is_unavailable_before_dispatch_or_uncertain_after(self) -> None:
        # Nothing listening -> clean unavailable (no dispatch possible).
        dead = RemoteSketchUpTransport("http://127.0.0.1:9", "t" * 32)
        try:
            with self.assertRaises(RuntimeUnavailableError):
                await dead.call("document_info")
        finally:
            await dead.close()

    async def test_non_loopback_refused(self) -> None:
        with self.assertRaises(RuntimeOpRefusedError):
            RemoteSketchUpTransport("http://192.168.1.50:9999", "t" * 32)
        with self.assertRaises(ValueError):
            WorkstationAgentConfig(host="0.0.0.0", port=9999, auth_token="t" * 32)

    async def test_oversized_request_refused_before_dispatch(self) -> None:
        fake = FakePort({"execute_geometry": {}})
        local = LocalSketchUpTransport(fake)
        big = {"action": "x", "blob": "y" * (300 * 1024)}
        with self.assertRaises(RuntimeOpRefusedError):
            await local.call("execute_geometry", big)
        self.assertEqual(fake.calls, [])
        await local.close()

    async def test_agent_restart_creates_new_generation(self) -> None:
        fake = FakePort({"ping": {}})
        a1 = WorkstationSketchUpRuntimeAgent(
            fake, WorkstationAgentConfig(host="127.0.0.1", port=0, auth_token="t" * 32)
        )
        a1.start()
        g1 = a1.generation
        a1.stop()
        a2 = WorkstationSketchUpRuntimeAgent(
            fake, WorkstationAgentConfig(host="127.0.0.1", port=0, auth_token="t" * 32)
        )
        a2.start()
        try:
            self.assertNotEqual(g1, a2.generation)
        finally:
            a2.stop()


if __name__ == "__main__":
    unittest.main()
