"""A04 target-context mutation identity — exact native acceptance.

Wing: code | Topic: sketchup_recovery | Updated: 2026-09-19

Proves that caller-stable mutation identity binds target_context on the live
SketchUp bridge. One stable ID executes once in target A, replays in target A,
and is rejected as mutation_id_reuse if retargeted to B.

Usage:
    python scripts/native_target_context_a04.py --run [--report path.json]

Exit codes: 0 all pass | 1 mismatch | 2 bridge unavailable.
"""

from __future__ import annotations

import argparse
import asyncio
import json
import subprocess
import sys
import time
from pathlib import Path
from typing import Any

REPO = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO / "src"))

from cdt_sketchup.bridge import BridgeClient, BridgeProtocolError  # noqa: E402
from cdt_sketchup.mutation import mutation_envelope, new_mutation_id  # noqa: E402

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


def box_body(name: str, origin: list[float]) -> dict[str, Any]:
    return {
        "action": "create_box",
        "params": {
            "name": name,
            "origin": origin,
            "dimensions": [10.0, 10.0, 10.0],
        },
        "expect": {
            "active_entity_delta": 1,
            "type": "ComponentInstance",
        },
        "unit": UNIT,
    }


async def active_count(client: BridgeClient) -> int | None:
    result = await client.call("object_list", {"limit": 500})
    for key in ("total_in_active_context", "returned", "count"):
        value = find_key(result, key)
        if isinstance(value, int):
            return value
    return None


async def entity_fingerprint(client: BridgeClient, pid: int) -> str | None:
    result = await client.call(
        "get_entity_state",
        {
            "persistent_id": pid,
            "unit": UNIT,
            "coordinate_space": "active_context",
        },
    )
    value = find_key(result, "semantic_fingerprint")
    return value if isinstance(value, str) else None


async def execute(
    client: BridgeClient,
    body: dict[str, Any],
    *,
    mutation: dict[str, Any] | None = None,
) -> dict[str, Any]:
    payload = dict(body)
    if mutation is not None:
        payload["mutation"] = mutation
    return await client.call("execute_geometry", payload)


async def delete_entity(client: BridgeClient, pid: int) -> None:
    await execute(
        client,
        {
            "action": "delete_entity",
            "params": {"persistent_id": pid},
            "expect": {"active_entity_delta": -1, "deleted": True},
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
    created: list[int] = []
    baseline = await active_count(client)

    def record(name: str, passed: bool, detail: str) -> None:
        cases.append({"case": name, "pass": passed, "detail": detail})
        print(f"{name}: {'PASS' if passed else 'FAIL'} {detail}")

    try:
        a = await execute(client, box_body(f"A04_{run_id}_A", [0.0, 0.0, 0.0]))
        b = await execute(client, box_body(f"A04_{run_id}_B", [50.0, 0.0, 0.0]))
        a_pid = find_persistent_id(a)
        b_pid = find_persistent_id(b)
        if not isinstance(a_pid, int) or not isinstance(b_pid, int):
            raise RuntimeError("target fixture receipts have no persistent_id")
        created.extend([a_pid, b_pid])

        a_before = await entity_fingerprint(client, a_pid)
        b_before = await entity_fingerprint(client, b_pid)

        mid = new_mutation_id()
        body_a = box_body(f"A04_{run_id}_nested", [0.0, 0.0, 0.0])
        body_a["target_context"] = {"instance_path": [a_pid]}
        first = await execute(
            client,
            body_a,
            mutation=mutation_envelope(mid, body_a),
        )
        a_after_first = await entity_fingerprint(client, a_pid)
        b_after_first = await entity_fingerprint(client, b_pid)
        restoration = find_key(first, "restoration")
        record(
            "target_a_commits_once",
            a_before is not None
            and a_after_first is not None
            and a_after_first != a_before
            and b_after_first == b_before
            and isinstance(restoration, dict)
            and restoration.get("verified") is True,
            f"A changed={a_after_first != a_before}; B stable={b_after_first == b_before}",
        )

        replay = await execute(
            client,
            body_a,
            mutation=mutation_envelope(mid, body_a),
        )
        a_after_replay = await entity_fingerprint(client, a_pid)
        replayed = find_key(replay, "replayed")
        record(
            "same_target_same_id_replays",
            replayed is True and a_after_replay == a_after_first,
            f"replayed={replayed}; A stable={a_after_replay == a_after_first}",
        )

        body_b = box_body(f"A04_{run_id}_nested", [0.0, 0.0, 0.0])
        body_b["target_context"] = {"instance_path": [b_pid]}
        retarget_rejected = False
        detail = "retarget unexpectedly accepted"
        try:
            await execute(
                client,
                body_b,
                mutation=mutation_envelope(mid, body_b),
            )
        except BridgeProtocolError as exc:
            detail = str(exc)
            retarget_rejected = "mutation_id_reuse" in detail

        b_after_retarget = await entity_fingerprint(client, b_pid)
        record(
            "same_id_different_target_rejected",
            retarget_rejected and b_after_retarget == b_before,
            f"reject={retarget_rejected}; B stable={b_after_retarget == b_before}; {detail[:80]}",
        )

        count_after = await active_count(client)
        record(
            "caller_context_restored",
            baseline is not None and count_after == baseline + 2,
            f"top-level count {baseline}->{count_after}",
        )
    except Exception as exc:
        record("a04_execution", False, f"{type(exc).__name__}: {exc}")
    finally:
        for pid in reversed(created):
            try:
                await delete_entity(client, pid)
            except Exception:
                pass
        final_count = await active_count(client)
        record(
            "cleanup_restores_active_count",
            baseline is not None and final_count == baseline,
            f"count {baseline}->{final_count}",
        )

    report = {
        "tool": "native_target_context_a04",
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
    parser = argparse.ArgumentParser(description="A04 target-context mutation identity")
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
