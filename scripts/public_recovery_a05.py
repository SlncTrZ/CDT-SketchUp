"""A05 public recovery acceptance — lose response after native commit.

Wing: code | Topic: sketchup_recovery | Updated: 2026-09-19

Runs a real Streamable HTTP MCP endpoint in-process. A temporary loopback
proxy forwards one execute_geometry request to the live SketchUp Ruby bridge,
waits until the native bridge returns its committed receipt, then deliberately
drops that response before the Python provider can receive it.

The public caller must observe unknown_commit, reconcile the stable operation
ID, and may then repeat the same request without producing a duplicate.

Usage:
    python scripts/public_recovery_a05.py --run [--report path.json]

Exit codes: 0 all pass | 1 mismatch | 2 live bridge unavailable.
"""

from __future__ import annotations

import argparse
import asyncio
import json
import socket
import subprocess
import sys
import time
from pathlib import Path
from typing import Any

import uvicorn
from mcp import Client

REPO = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO / "src"))

from cdt_sketchup import server as provider  # noqa: E402
from cdt_sketchup.bridge import (  # noqa: E402
    BridgeClient,
    DEFAULT_BRIDGE_HOST,
    DEFAULT_BRIDGE_PORT,
    MAX_FRAME_BYTES,
)
from cdt_sketchup.contract import CONTRACT_VERSION  # noqa: E402
from cdt_sketchup.mutation import new_mutation_id  # noqa: E402


UNIT = "mm"
TIMEOUT_SECONDS = 10.0


def _payload(result: Any) -> dict[str, Any]:
    payload = getattr(result, "structured_content", None)
    return payload if isinstance(payload, dict) else {}


def _count(payload: dict[str, Any]) -> int | None:
    value = payload.get("total_in_active_context", payload.get("returned"))
    return value if isinstance(value, int) else None


def _box_args(run_id: str, operation_id: str) -> dict[str, Any]:
    return {
        "action": "create_box",
        "params": {
            "name": f"A05_{run_id}",
            "origin": [0.0, 0.0, 0.0],
            "dimensions": [10.0, 20.0, 30.0],
        },
        "expect": {
            "active_entity_delta": 1,
            "type": "ComponentInstance",
        },
        "unit": UNIT,
        "operation_id": operation_id,
    }


class DropNativeResponseProxy:
    """Forward one bridge request, observe its response, then drop downstream."""

    def __init__(
        self,
        *,
        upstream_host: str = DEFAULT_BRIDGE_HOST,
        upstream_port: int = DEFAULT_BRIDGE_PORT,
    ) -> None:
        self.upstream_host = upstream_host
        self.upstream_port = upstream_port
        self.server: asyncio.AbstractServer | None = None
        self.native_response: dict[str, Any] | None = None
        self.response_received = asyncio.Event()

    @property
    def port(self) -> int:
        if self.server is None or not self.server.sockets:
            raise RuntimeError("drop-response proxy is not running")
        return int(self.server.sockets[0].getsockname()[1])

    async def start(self) -> None:
        self.server = await asyncio.start_server(
            self._handle,
            "127.0.0.1",
            0,
            limit=MAX_FRAME_BYTES + 1,
        )

    async def close(self) -> None:
        if self.server is None:
            return
        self.server.close()
        await self.server.wait_closed()
        self.server = None

    async def _handle(
        self,
        downstream_reader: asyncio.StreamReader,
        downstream_writer: asyncio.StreamWriter,
    ) -> None:
        upstream_writer: asyncio.StreamWriter | None = None
        try:
            upstream_reader, upstream_writer = await asyncio.open_connection(
                self.upstream_host,
                self.upstream_port,
                limit=MAX_FRAME_BYTES + 1,
            )
            request = await asyncio.wait_for(
                downstream_reader.readuntil(b"\n"),
                timeout=TIMEOUT_SECONDS,
            )
            upstream_writer.write(request)
            await asyncio.wait_for(upstream_writer.drain(), timeout=TIMEOUT_SECONDS)
            response = await asyncio.wait_for(
                upstream_reader.readuntil(b"\n"),
                timeout=TIMEOUT_SECONDS,
            )
            if len(response) > MAX_FRAME_BYTES:
                raise RuntimeError("native bridge response exceeded frame bound")
            decoded = json.loads(response.decode("utf-8"))
            if isinstance(decoded, dict):
                self.native_response = decoded
            self.response_received.set()
            # Deliberately do not forward the response: caller sees EOF after
            # the native bridge has already produced its authoritative result.
        finally:
            if upstream_writer is not None:
                upstream_writer.close()
                try:
                    await upstream_writer.wait_closed()
                except OSError:
                    pass
            downstream_writer.close()
            try:
                await downstream_writer.wait_closed()
            except OSError:
                pass


class PublicMCPServer:
    """Ephemeral loopback Streamable HTTP server using the real provider app."""

    def __init__(self) -> None:
        self.socket: socket.socket | None = None
        self.server: uvicorn.Server | None = None
        self.task: asyncio.Task[None] | None = None
        self.port: int | None = None

    async def start(self) -> None:
        sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        sock.bind(("127.0.0.1", 0))
        sock.listen(128)
        sock.setblocking(False)
        self.socket = sock
        self.port = int(sock.getsockname()[1])

        config = uvicorn.Config(
            provider.create_app(),
            host="127.0.0.1",
            port=self.port,
            log_level="warning",
            access_log=False,
        )
        self.server = uvicorn.Server(config)
        self.task = asyncio.create_task(self.server.serve(sockets=[sock]))
        deadline = time.monotonic() + TIMEOUT_SECONDS
        while not self.server.started:
            if self.task.done():
                await self.task
                raise RuntimeError("public MCP server exited before startup")
            if time.monotonic() >= deadline:
                raise RuntimeError("public MCP server startup timed out")
            await asyncio.sleep(0.02)

    async def close(self) -> None:
        if self.server is not None:
            self.server.should_exit = True
        if self.task is not None:
            try:
                await asyncio.wait_for(self.task, timeout=TIMEOUT_SECONDS)
            except asyncio.TimeoutError:
                self.task.cancel()
        if self.socket is not None:
            try:
                self.socket.close()
            except OSError:
                pass
        self.task = None
        self.server = None
        self.socket = None

    @property
    def url(self) -> str:
        if self.port is None:
            raise RuntimeError("public MCP server is not running")
        return f"http://127.0.0.1:{self.port}/mcp"


async def run(report_path: str | None) -> dict[str, Any]:
    try:
        revision = subprocess.run(
            ["git", "rev-parse", "HEAD"],
            cwd=REPO,
            capture_output=True,
            text=True,
            check=False,
        ).stdout.strip()
    except Exception:
        revision = "unknown"

    real_bridge = provider._bridge
    try:
        ping = await real_bridge.call("ping")
    except Exception as exc:
        return {
            "bridge_available": False,
            "detail": type(exc).__name__,
            "revision": revision,
        }
    if not isinstance(ping, dict) or not ping.get("live_model"):
        return {
            "bridge_available": False,
            "ping": ping,
            "revision": revision,
        }

    public_server = PublicMCPServer()
    proxy = DropNativeResponseProxy()
    cases: list[dict[str, Any]] = []
    created_pid: int | None = None
    started = time.time()

    def record(name: str, passed: bool, detail: str = "") -> None:
        cases.append({"case": name, "pass": passed, "detail": detail})
        print(f"{name}: {'PASS' if passed else 'FAIL'} {detail}")

    try:
        await public_server.start()
        async with Client(
            public_server.url,
            raise_exceptions=True,
            read_timeout_seconds=TIMEOUT_SECONDS,
        ) as client:
            before_result = await client.call_tool("object_list", {"limit": 500})
            before_count = _count(_payload(before_result))

            operation_id = new_mutation_id()
            args = _box_args(str(int(started)), operation_id)

            await proxy.start()
            provider._bridge = BridgeClient(
                host="127.0.0.1",
                port=proxy.port,
                timeout=TIMEOUT_SECONDS,
            )
            try:
                lost_result = await client.call_tool("execute_geometry", args)
            finally:
                provider._bridge = real_bridge

            await asyncio.wait_for(
                proxy.response_received.wait(),
                timeout=TIMEOUT_SECONDS,
            )
            lost = _payload(lost_result)
            native_frame = proxy.native_response or {}
            native_receipt = native_frame.get("result")
            native_receipt = native_receipt if isinstance(native_receipt, dict) else {}

            loss_ok = (
                lost.get("ok") is False
                and isinstance(lost.get("error"), dict)
                and lost["error"].get("kind") == "unknown_commit"
                and lost["error"].get("retryable") is False
                and native_frame.get("ok") is True
                and native_receipt.get("committed") is True
                and native_receipt.get("mutation", {}).get("id") == operation_id
            )
            record(
                "lost_after_native_commit",
                loss_ok,
                f"public={lost.get('error', {}).get('kind')} "
                f"native_committed={native_receipt.get('committed')}",
            )

            reconciled_result = await client.call_tool(
                "reconcile_operation",
                {"operation_id": operation_id},
            )
            reconciled = _payload(reconciled_result)
            reconciled_receipt = reconciled.get("receipt")
            reconciled_receipt = (
                reconciled_receipt if isinstance(reconciled_receipt, dict) else {}
            )
            reconcile_ok = (
                reconciled.get("status") == "committed"
                and reconciled.get("journal") == "committed"
                and reconciled_receipt.get("receipt_id")
                == native_receipt.get("receipt_id")
            )
            record(
                "public_reconcile_committed",
                reconcile_ok,
                f"status={reconciled.get('status')} "
                f"journal={reconciled.get('journal')}",
            )

            after_reconcile_result = await client.call_tool(
                "object_list",
                {"limit": 500},
            )
            after_reconcile = _count(_payload(after_reconcile_result))
            exactly_once_after_loss = (
                before_count is not None
                and after_reconcile == before_count + 1
            )
            record(
                "exactly_once_after_loss",
                exactly_once_after_loss,
                f"count {before_count}->{after_reconcile}",
            )

            replay_result = await client.call_tool("execute_geometry", args)
            replay = _payload(replay_result)
            after_replay_result = await client.call_tool("object_list", {"limit": 500})
            after_replay = _count(_payload(after_replay_result))
            replay_ok = (
                replay.get("mutation", {}).get("replayed") is True
                and replay.get("receipt_id") == native_receipt.get("receipt_id")
                and after_replay == after_reconcile
            )
            record(
                "same_id_retry_no_duplicate",
                replay_ok,
                f"replayed={replay.get('mutation', {}).get('replayed')} "
                f"count {after_reconcile}->{after_replay}",
            )

            entity_states = reconciled_receipt.get("entity_states")
            if isinstance(entity_states, list) and entity_states:
                pid = entity_states[0].get("persistent_id")
                if isinstance(pid, int):
                    created_pid = pid

            cleanup_ok = False
            if created_pid is not None:
                cleanup_result = await client.call_tool(
                    "delete_entity",
                    {"persistent_id": created_pid, "unit": UNIT},
                )
                cleanup = _payload(cleanup_result)
                final_result = await client.call_tool("object_list", {"limit": 500})
                final_count = _count(_payload(final_result))
                cleanup_ok = (
                    cleanup.get("committed") is True
                    and final_count == before_count
                )
                record(
                    "cleanup_restores_active_count",
                    cleanup_ok,
                    f"pid={created_pid} final={final_count}",
                )
            else:
                record("cleanup_restores_active_count", False, "missing created PID")
    finally:
        provider._bridge = real_bridge
        await proxy.close()
        await public_server.close()

    report = {
        "revision": revision,
        "source_contract": CONTRACT_VERSION,
        "sketchup_version": ping.get("sketchup_version"),
        "ruby_version": ping.get("ruby_version"),
        "unit": UNIT,
        "elapsed_s": round(time.time() - started, 2),
        "cases": cases,
        "passed": sum(1 for case in cases if case.get("pass")),
        "total": len(cases),
    }
    rendered = json.dumps(report, indent=2)
    print(rendered)
    if report_path:
        Path(report_path).write_text(rendered, encoding="utf-8")
    return report


def main() -> int:
    parser = argparse.ArgumentParser(description="A05 public recovery acceptance")
    parser.add_argument("--run", action="store_true")
    parser.add_argument("--report", default=None)
    args = parser.parse_args()
    if not args.run:
        parser.print_help()
        return 2

    report = asyncio.run(run(args.report))
    if "cases" not in report:
        print(json.dumps(report, indent=2))
        return 2
    return 0 if report["passed"] == report["total"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
