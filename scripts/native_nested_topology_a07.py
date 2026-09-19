"""A07 nested semantic topology acceptance on live SketchUp.

Wing: code | Topic: sketchup_topology | Updated: 2026-09-19

Creates one strict box ComponentInstance, wraps it in two nested Groups, then
queries topology from the outer wrapper. The semantic topology layer must
descend the single-container wrapper chain and report the leaf solid topology
without fabricating multi-solid semantics.

Usage:
    python scripts/native_nested_topology_a07.py --run [--report path.json]

Exit codes: 0 all pass | 1 mismatch | 2 bridge unavailable.
"""

from __future__ import annotations

import argparse
import asyncio
import json
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from typing import Any

REPO = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO / "src"))

from cdt_sketchup.bridge import BridgeClient  # noqa: E402

UNIT = "mm"


def find_key(node: Any, key: str) -> Any:
    if isinstance(node, dict):
        if key in node:
            return node[key]
        for value in node.values():
            found = find_key(value, key)
            if found is not None:
                return found
    elif isinstance(node, list):
        for value in node:
            found = find_key(value, key)
            if found is not None:
                return found
    return None


def find_persistent_id(node: Any) -> int | None:
    if isinstance(node, dict):
        state = node.get("state")
        if isinstance(state, dict) and isinstance(state.get("persistent_id"), int):
            return state["persistent_id"]
    value = find_key(node, "persistent_id")
    return value if isinstance(value, int) else None


def git_revision() -> str:
    completed = subprocess.run(
        ["git", "rev-parse", "HEAD"],
        cwd=REPO,
        capture_output=True,
        text=True,
        check=False,
    )
    return completed.stdout.strip() or "unknown"


async def active_count(client: BridgeClient) -> int | None:
    result = await client.call("object_list", {"limit": 500})
    for key in ("total_in_active_context", "returned", "count"):
        value = find_key(result, key)
        if isinstance(value, int):
            return value
    return None


async def execute(
    client: BridgeClient,
    action: str,
    params: dict[str, Any],
    expect: dict[str, Any],
) -> dict[str, Any]:
    return await client.call(
        "execute_geometry",
        {
            "action": action,
            "params": params,
            "expect": expect,
            "unit": UNIT,
        },
    )


async def run(report_path: str | None) -> dict[str, Any]:
    client = BridgeClient()
    try:
        ping = await client.call("ping")
    except Exception as exc:
        return {
            "bridge_available": False,
            "detail": f"{type(exc).__name__}: {exc}",
            "revision": git_revision(),
        }
    if not isinstance(ping, dict) or not ping.get("live_model"):
        return {
            "bridge_available": False,
            "ping": ping,
            "revision": git_revision(),
        }

    started = time.time()
    run_id = str(int(started))
    cases: list[dict[str, Any]] = []
    outer_pid: int | None = None

    def record(name: str, passed: bool, detail: str) -> None:
        cases.append({"case": name, "pass": passed, "detail": detail})
        print(f"{name}: {'PASS' if passed else 'FAIL'} {detail}")

    before = await active_count(client)

    try:
        box = await execute(
            client,
            "create_box",
            {
                "name": f"A07_{run_id}_box",
                "origin": [0.0, 0.0, 0.0],
                "dimensions": [10.0, 20.0, 30.0],
            },
            {"active_entity_delta": 1, "type": "ComponentInstance"},
        )
        box_pid = find_persistent_id(box)
        if box_pid is None:
            raise RuntimeError("box receipt has no persistent_id")

        first = await execute(
            client,
            "group_entities",
            {
                "persistent_ids": [box_pid],
                "name": f"A07_{run_id}_wrapper1",
            },
            {
                "active_entity_delta": 0,
                "type": "Group",
                "child_persistent_ids": [box_pid],
            },
        )
        first_pid = find_persistent_id(first)
        if first_pid is None:
            raise RuntimeError("first wrapper receipt has no persistent_id")

        second = await execute(
            client,
            "group_entities",
            {
                "persistent_ids": [first_pid],
                "name": f"A07_{run_id}_wrapper2",
            },
            {
                "active_entity_delta": 0,
                "type": "Group",
                "child_persistent_ids": [first_pid],
            },
        )
        outer_pid = find_persistent_id(second)
        if outer_pid is None:
            raise RuntimeError("second wrapper receipt has no persistent_id")

        topology = await client.call(
            "query_topology",
            {"persistent_id": outer_pid, "unit": UNIT},
        )
        vertex_count = find_key(topology, "vertex_count")
        edge_count = find_key(topology, "edge_count")
        face_count = find_key(topology, "face_count")
        manifold = find_key(topology, "manifold")
        record(
            "nested_wrapper_topology_counts",
            vertex_count == 8 and edge_count == 12 and face_count == 6,
            f"v/e/f={vertex_count}/{edge_count}/{face_count}",
        )
        record(
            "nested_wrapper_manifold",
            manifold is True,
            f"manifold={manifold}",
        )

        state = await client.call(
            "get_entity_state",
            {
                "persistent_id": outer_pid,
                "unit": UNIT,
                "coordinate_space": "active_context",
            },
        )
        state_counts_ok = (
            find_key(state, "vertex_count") == 8
            and find_key(state, "edge_count") == 12
            and find_key(state, "face_count") == 6
            and find_key(state, "manifold") is True
        )
        record(
            "nested_wrapper_state_consistent",
            state_counts_ok,
            "state topology/manifold matches query_topology",
        )
    finally:
        cleanup_ok = False
        if outer_pid is not None:
            try:
                cleanup = await execute(
                    client,
                    "delete_entity",
                    {"persistent_id": outer_pid},
                    {"active_entity_delta": -1, "deleted": True},
                )
                cleanup_ok = find_key(cleanup, "committed") is True
            except Exception:
                cleanup_ok = False
        after = await active_count(client)
        record(
            "cleanup_restores_active_count",
            cleanup_ok and before is not None and after == before,
            f"count {before}->{after}",
        )

    report = {
        "tool": "native_nested_topology_a07",
        "revision": git_revision(),
        "sketchup_version": ping.get("sketchup_version"),
        "ruby_version": ping.get("ruby_version"),
        "unit": UNIT,
        "elapsed_s": round(time.time() - started, 2),
        "cases": cases,
        "passed": sum(1 for case in cases if case["pass"]),
        "total": len(cases),
    }
    rendered = json.dumps(report, indent=2)
    print(rendered)
    if report_path:
        Path(report_path).write_text(rendered + "\n", encoding="utf-8")
    return report


def main() -> int:
    parser = argparse.ArgumentParser(description="A07 nested semantic topology acceptance")
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
