"""R5 restart, ownership and recovery over real HTTP; no CAD required."""
import asyncio
import json
import subprocess
import sys
from argparse import Namespace
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))
from test_runtime_transport import FakePort

from cdt_sketchup.remote_runtime import RemoteSketchUpRuntimeAdapter
from cdt_sketchup.runtime_admin import administer
from cdt_sketchup.runtime_binding import RuntimeBinding
from cdt_sketchup.runtime_config import configured_runtime
from cdt_sketchup.runtime_transport import (
    RemoteSketchUpTransport,
    RuntimeGenerationMismatchError,
    RuntimeTransportError,
    RuntimeUncertainError,
)
from cdt_sketchup.workstation_agent import WorkstationAgentConfig, WorkstationSketchUpRuntimeAgent

TOKEN = "test-only-" + "x" * 32
MID = "a" * 32
MUTATION = {"id": MID, "request_hash": "b" * 64}


@pytest.fixture
def pilot(tmp_path):
    port = FakePort({
        "ping": {"live_model": True},
        "document_info": {"context": {"id": "native-doc", "revision": "one"}},
        "execute_geometry": {"ok": True, "mutation": {**MUTATION, "replayed": False}},
        "mutation_reconcile": {
            "mutation_id": MID, "status": "committed", "journal": "committed",
            "receipt": {"mutation": {**MUTATION, "replayed": False}},
        },
        "model_save": {"ok": True},
    })
    agent = WorkstationSketchUpRuntimeAgent(port, WorkstationAgentConfig(auth_token=TOKEN))
    agent.start()
    path = tmp_path / "binding.json"
    binding = RuntimeBinding(path, allow_missing=True)
    binding.save(agent.generation, None)
    binding.close()
    token = tmp_path / "token"
    token.write_text(TOKEN)
    yield port, agent, path, token
    agent.stop()


def runtime(agent, path, deadline=60000):
    return RemoteSketchUpRuntimeAdapter(
        RemoteSketchUpTransport(agent.base_url, TOKEN),
        state_file=path, default_deadline_ms=deadline,
    )


def test_unknown_completion_is_fenced_across_restart(pilot):
    async def run():
        port, agent, path, _ = pilot
        port._delay = .3
        first = runtime(agent, path, 100)
        with pytest.raises(RuntimeUncertainError):
            await first.call("execute_geometry", {"mutation": MUTATION})
        await first.close()
        second = runtime(agent, path)
        try:
            before = len(port.calls)
            with pytest.raises(RuntimeUncertainError):
                await second.call("model_save")
            assert len(port.calls) == before
            port._delay = 0
            assert await second.call("document_info")
        finally:
            await second.close()
    asyncio.run(run())


def test_cancelled_dispatch_and_concurrent_write_stay_fenced(pilot):
    async def run():
        port, agent, path, _ = pilot
        port._delay = .3
        r = runtime(agent, path)
        task = asyncio.create_task(r.call("execute_geometry", {"mutation": MUTATION}))
        for _ in range(100):
            if port.calls:
                break
            await asyncio.sleep(.005)
        assert port.calls
        task.cancel()
        with pytest.raises(asyncio.CancelledError):
            await task
        with pytest.raises(RuntimeUncertainError):
            await r.call("model_save")
        assert len(port.calls) == 1
        await r.close()
    asyncio.run(run())


def test_agent_restart_never_adopts_new_generation(pilot):
    async def run():
        port, agent, path, _ = pilot
        address = agent._server.server_port
        agent.stop()
        next_agent = WorkstationSketchUpRuntimeAgent(
            port, WorkstationAgentConfig(port=address, auth_token=TOKEN))
        next_agent.start()
        r = runtime(next_agent, path)
        try:
            with pytest.raises(RuntimeGenerationMismatchError):
                await r.call("execute_geometry", {"mutation": MUTATION})
            assert port.calls == []
            assert json.loads(path.read_text())["pending"] is None
        finally:
            await r.close()
            next_agent.stop()
    asyncio.run(run())


def test_completion_persistence_failure_fences_same_process(pilot, monkeypatch):
    async def run():
        port, agent, path, _ = pilot
        r = runtime(agent, path)
        save = r._binding.save
        def fail_complete(generation, pending):
            if pending is None:
                raise OSError("injected write failure")
            save(generation, pending)
        monkeypatch.setattr(r._binding, "save", fail_complete)
        with pytest.raises(RuntimeUncertainError):
            await r.call("execute_geometry", {"mutation": MUTATION})
        with pytest.raises(RuntimeUncertainError):
            await r.call("model_save")
        assert len(port.calls) == 1
        await r.close()
    asyncio.run(run())


def test_second_process_cannot_own_binding(pilot):
    _, agent, path, _ = pilot
    first = runtime(agent, path)
    code = ("from cdt_sketchup.runtime_binding import RuntimeBinding;"
            "RuntimeBinding(__import__('pathlib').Path(__import__('sys').argv[1]))")
    import os
    env = {**os.environ, "PYTHONPATH": str(Path(__file__).resolve().parents[1] / "src")}
    result = subprocess.run([sys.executable, "-c", code, str(path)],
                            env=env, capture_output=True, text=True, timeout=15)
    assert result.returncode != 0
    assert "already owned" in result.stderr
    asyncio.run(first.close())


def admin_args(agent, path, token, action):
    return Namespace(action=action, state_file=str(path), token_file=str(token),
                     endpoint=agent.base_url, generation=agent.generation)


def test_explicit_bind_and_exact_native_journal_recovery(pilot):
    async def run():
        _, agent, path, token = pilot
        binding = RuntimeBinding(path)
        binding.save(agent.generation, {"op": "execute_geometry", "mutation": MUTATION})
        binding.close()
        with pytest.raises(RuntimeTransportError):
            await administer(admin_args(agent, path, token, "bind"))
        result = await administer(admin_args(agent, path, token, "recover"))
        assert result["pending"] is None
        assert json.loads(path.read_text())["pending"] is None
    asyncio.run(run())


@pytest.mark.parametrize("proof", [
    {"mutation_id": MID, "status": "diverged_unknown", "journal": "miss"},
    {"mutation_id": MID, "status": "committed", "journal": "committed",
     "receipt": {"mutation": {**MUTATION, "request_hash": "c" * 64, "replayed": False}}},
    {"mutation_id": MID, "status": "rolled_back", "journal": "rolled_back",
     "receipt": {"mutation": {**MUTATION, "replayed": False}, "rollback_verified": False}},
])
def test_non_authoritative_recovery_keeps_fence(pilot, proof):
    async def run():
        port, agent, path, token = pilot
        port._routes["mutation_reconcile"] = proof
        binding = RuntimeBinding(path)
        binding.save(agent.generation, {"op": "execute_geometry", "mutation": MUTATION})
        binding.close()
        with pytest.raises(RuntimeTransportError):
            await administer(admin_args(agent, path, token, "recover"))
        assert json.loads(path.read_text())["pending"]
    asyncio.run(run())


def test_configuration_is_explicit_and_fails_closed(pilot, monkeypatch):
    _, agent, path, token = pilot
    for key in ("ENDPOINT", "TOKEN_FILE", "STATE_FILE"):
        monkeypatch.delenv("CDT_SKETCHUP_RUNTIME_" + key, raising=False)
    assert configured_runtime() is None
    monkeypatch.setenv("CDT_SKETCHUP_RUNTIME_ENDPOINT", agent.base_url)
    with pytest.raises(ValueError):
        configured_runtime()
    monkeypatch.setenv("CDT_SKETCHUP_RUNTIME_TOKEN_FILE", str(token))
    monkeypatch.setenv("CDT_SKETCHUP_RUNTIME_STATE_FILE", str(path))
    r = configured_runtime()
    assert r.expected_generation == agent.generation
    with pytest.raises(ValueError):
        r.pin_generation("silent-rebind")
    asyncio.run(r.close())


@pytest.mark.parametrize("value", ["[]", '{"schema_version":1,"generation":"","pending":null}'])
def test_invalid_binding_cannot_enable_writes(tmp_path, value):
    path = tmp_path / "binding.json"
    path.write_text(value)
    with pytest.raises(RuntimeTransportError):
        RuntimeBinding(path)

@pytest.mark.parametrize("kind", ["unknown_commit", "mutation_unknown"])
def test_native_unknown_rejection_retains_fence(pilot, kind):
    from cdt_sketchup.bridge import BridgeProtocolError
    async def run():
        port, agent, path, _ = pilot
        port._routes["execute_geometry"] = BridgeProtocolError(kind + ": unresolved")
        r = runtime(agent, path)
        try:
            with pytest.raises(RuntimeUncertainError):
                await r.call("execute_geometry", {"mutation": MUTATION})
            with pytest.raises(RuntimeUncertainError):
                await r.call("model_save")
            assert len(port.calls) == 1
        finally:
            await r.close()
    asyncio.run(run())
