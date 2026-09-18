"""B0 native spatial matrix — fresh SketchUp acceptance for the R01 coincident-solid fix.

Wing: code | Topic: sketchup_spatial | Updated: 2026-09-18

Runs the B0 fixture matrix against a live SketchUp model through the bounded
loopback bridge (public commands only: execute_geometry / query_overlap /
get_entity_state). Expected relations come from analytic fixture construction,
never from query_overlap itself.

Usage:
    python scripts/native_spatial_matrix_b0.py --probe
    python scripts/native_spatial_matrix_b0.py --run [--report path.json]

Exit codes: 0 all pass | 1 relation mismatch / fixture drift | 2 bridge unavailable.
"""

from __future__ import annotations

import argparse
import asyncio
import json
import math
import subprocess
import sys
import time
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO / "src"))

from cdt_sketchup.bridge import BridgeClient  # noqa: E402

UNIT = "in"
BOX = [1.0, 1.0, 1.0]
# Classifier surface epsilon, native inches (spatial.rb SPATIAL_EPSILON).
EPS = 1e-7
SUB_EPS = 0.5 * EPS
SUPER_EPS = 32.0 * EPS


def rot_z_about(center: list[float], degrees: float) -> list[float]:
    """Row-major 4x4 absolute matrix: 30d rotation about Z through center."""
    cx, cy = center[0], center[1]
    radians = math.radians(degrees)
    cos, sin = math.cos(radians), math.sin(radians)
    tx = cx - (cx * cos - cy * sin)
    ty = cy - (cx * sin + cy * cos)
    return [
        cos, -sin, 0.0, 0.0,
        sin, cos, 0.0, 0.0,
        0.0, 0.0, 1.0, 0.0,
        tx, ty, 0.0, 1.0,
    ]


CASES: list[dict] = [
    {
        "id": "identical",
        "kind": "boxes",
        "first": {"origin": [0.0, 0.0, 0.0], "dimensions": BOX},
        "second": {"origin": [0.0, 0.0, 0.0], "dimensions": BOX},
        "analytic": "coincident 1in^3 shared volume, distinct PIDs",
        "expected": "penetrating",
    },
    {
        "id": "copied_instance",
        "kind": "copy",
        "first": {"origin": [0.0, 0.0, 0.0], "dimensions": BOX},
        "analytic": "copy_entity keeps the same transform",
        "expected": "penetrating",
    },
    {
        "id": "coplanar_partial",
        "kind": "boxes",
        "first": {"origin": [0.0, 0.0, 0.0], "dimensions": BOX},
        "second": {"origin": [0.5, 0.0, 0.0], "dimensions": BOX},
        "analytic": "0.5x1x1 overlap, coplanar face pairs",
        "expected": "penetrating",
    },
    {
        "id": "face_touch",
        "kind": "boxes",
        "first": {"origin": [0.0, 0.0, 0.0], "dimensions": BOX},
        "second": {"origin": [1.0, 0.0, 0.0], "dimensions": BOX},
        "analytic": "shared 1x1 face, zero volume",
        "expected": "touching",
    },
    {
        "id": "edge_touch",
        "kind": "boxes",
        "first": {"origin": [0.0, 0.0, 0.0], "dimensions": BOX},
        "second": {"origin": [1.0, 1.0, 0.0], "dimensions": BOX},
        "analytic": "shared edge, zero volume",
        "expected": "touching",
    },
    {
        "id": "point_touch",
        "kind": "boxes",
        "first": {"origin": [0.0, 0.0, 0.0], "dimensions": BOX},
        "second": {"origin": [1.0, 1.0, 1.0], "dimensions": BOX},
        "analytic": "shared corner point, zero volume",
        "expected": "touching",
    },
    {
        "id": "containment",
        "kind": "boxes",
        "first": {"origin": [0.0, 0.0, 0.0], "dimensions": [2.0, 2.0, 2.0]},
        "second": {"origin": [0.5, 0.5, 0.5], "dimensions": [0.5, 0.5, 0.5]},
        "analytic": "strict containment, no surface contact",
        "expected": "penetrating",
    },
    {
        "id": "disjoint",
        "kind": "boxes",
        "first": {"origin": [0.0, 0.0, 0.0], "dimensions": BOX},
        "second": {"origin": [2.0, 0.0, 0.0], "dimensions": BOX},
        "analytic": "1.0in clear gap",
        "expected": "disjoint",
    },
    {
        "id": "rotated_overlap",
        "kind": "rotated",
        "first": {"origin": [0.0, 0.0, 0.0], "dimensions": BOX},
        "second": {"origin": [0.0, 0.0, 0.0], "dimensions": BOX},
        "rotation": {"center": [0.5, 0.5, 0.0], "degrees": 30.0},
        "analytic": "same cube rotated 30d about its vertical axis",
        "expected": "penetrating",
    },
    {
        "id": "near_gap_sub",
        "kind": "boxes",
        "first": {"origin": [0.0, 0.0, 0.0], "dimensions": BOX},
        "second": {"origin": [1.0 + SUB_EPS, 0.0, 0.0], "dimensions": BOX},
        "analytic": f"analytic disjoint, {SUB_EPS}in gap below surface epsilon",
        "expected": "touching",
    },
    {
        "id": "near_gap_super",
        "kind": "boxes",
        "first": {"origin": [0.0, 0.0, 0.0], "dimensions": BOX},
        "second": {"origin": [1.0 + SUPER_EPS, 0.0, 0.0], "dimensions": BOX},
        "analytic": f"analytic disjoint, {SUPER_EPS}in gap above surface epsilon",
        "expected": "disjoint",
    },
    {
        "id": "near_overlap_sub",
        "kind": "boxes",
        "first": {"origin": [0.0, 0.0, 0.0], "dimensions": BOX},
        "second": {"origin": [1.0 - SUB_EPS, 0.0, 0.0], "dimensions": BOX},
        "analytic": f"analytic {SUB_EPS}x1x1 shared volume below surface epsilon",
        "expected": "penetrating",
    },
]


def find_persistent_id(node, path="root"):
    """Defensively extract the created entity PID from an operation receipt."""
    if isinstance(node, dict):
        if isinstance(node.get("persistent_id"), int):
            return node["persistent_id"], path + ".persistent_id"
        for key in ("state", "entity", "result", "data"):
            if key in node:
                found = find_persistent_id(node[key], path + "." + key)
                if found[0] is not None:
                    return found
        for key, value in node.items():
            found = find_persistent_id(value, path + "." + str(key))
            if found[0] is not None:
                return found
    elif isinstance(node, list):
        for index, value in enumerate(node):
            found = find_persistent_id(value, f"{path}[{index}]")
            if found[0] is not None:
                return found
    return None, path


def find_key(node, wanted):
    if isinstance(node, dict):
        if wanted in node:
            return node[wanted]
        for value in node.values():
            hit = find_key(value, wanted)
            if hit is not None:
                return hit
    elif isinstance(node, list):
        for value in node:
            hit = find_key(value, wanted)
            if hit is not None:
                return hit
    return None


class Matrix:
    def __init__(self, client: BridgeClient, run_id: str):
        self.client = client
        self.run_id = run_id
        self.counter = 0
        self.created: list[int] = []

    def _name(self, case_id: str, side: str) -> str:
        self.counter += 1
        return f"B0_{self.run_id}_{case_id}_{side}_{self.counter}"

    async def create_box(self, case_id: str, side: str, origin, dimensions) -> int:
        receipt = await self.client.call(
            "execute_geometry",
            {
                "action": "create_box",
                "params": {
                    "name": self._name(case_id, side),
                    "origin": list(origin),
                    "dimensions": list(dimensions),
                },
                "expect": {"active_entity_delta": 1, "type": "ComponentInstance"},
                "unit": UNIT,
            },
        )
        pid, at = find_persistent_id(receipt)
        if pid is None:
            raise RuntimeError(f"create_box receipt has no persistent_id: {receipt}")
        self.created.append(pid)
        return pid

    async def copy(self, pid: int) -> int:
        receipt = await self.client.call(
            "execute_geometry",
            {
                "action": "copy_entity",
                "params": {"persistent_id": pid},
                "expect": {"active_entity_delta": 1, "type": "ComponentInstance"},
                "unit": UNIT,
            },
        )
        new_pid, _ = find_persistent_id(receipt)
        if new_pid is None:
            raise RuntimeError(f"copy_entity receipt has no persistent_id: {receipt}")
        self.created.append(new_pid)
        return new_pid

    async def transform(self, pid: int, matrix: list[float]) -> None:
        await self.client.call(
            "execute_geometry",
            {
                "action": "transform_entity",
                "params": {"persistent_id": pid, "matrix": list(matrix)},
                "expect": {"active_entity_delta": 0, "transformation": list(matrix)},
                "unit": UNIT,
            },
        )

    async def cleanup(self, pid: int) -> bool:
        try:
            await self.client.call(
                "execute_geometry",
                {
                    "action": "delete_entity",
                    "params": {"persistent_id": pid},
                    "expect": {"active_entity_delta": -1, "deleted": True},
                    "unit": UNIT,
                },
            )
            return True
        except Exception:
            return False

    async def bounds_min(self, pid: int):
        try:
            state = await self.client.call(
                "get_entity_state",
                {"persistent_id": pid, "unit": UNIT, "coordinate_space": "active_context"},
            )
            bounds = find_key(state, "bounds")
            if isinstance(bounds, dict) and isinstance(bounds.get("min"), list):
                return bounds["min"]
        except Exception:
            pass
        return None

    async def overlap(self, first: int, second: int) -> dict:
        return await self.client.call(
            "query_overlap",
            {"first_pid": first, "second_pid": second, "unit": UNIT},
        )

    async def run_case(self, case: dict) -> dict:
        first = await self.create_box(
            case["id"], "A", case["first"]["origin"], case["first"]["dimensions"]
        )
        if case["kind"] == "copy":
            second = await self.copy(first)
        else:
            second = await self.create_box(
                case["id"], "B", case["second"]["origin"], case["second"]["dimensions"]
            )
            if case["kind"] == "rotated":
                await self.transform(second, rot_z_about(**case["rotation"]))
        placed_b = await self.bounds_min(second)
        result = await self.overlap(first, second)
        relationship = find_key(result, "relationship")
        outcome = {
            "case": case["id"],
            "analytic": case["analytic"],
            "expected": case["expected"],
            "actual": relationship,
            "exact": find_key(result, "exact"),
            "surface_clearance": find_key(result, "surface_clearance"),
            "bounds_overlap": find_key(result, "bounds_overlap"),
            "first_triangle_count": find_key(result, "first_triangle_count"),
            "second_triangle_count": find_key(result, "second_triangle_count"),
            "first_pid": first,
            "second_pid": second,
            "measured_b_min": placed_b,
            "pass": relationship == case["expected"],
        }
        cleaned_a = await self.cleanup(first)
        cleaned_b = await self.cleanup(second)
        outcome["cleanup"] = bool(cleaned_a and cleaned_b)
        return outcome


async def probe_only() -> dict:
    client = BridgeClient()
    probe = await client.probe()
    print(json.dumps(probe, indent=2))
    return probe


async def run_matrix(report_path: str | None) -> dict:
    try:
        head = subprocess.run(
            ["git", "rev-parse", "HEAD"],
            cwd=REPO,
            capture_output=True,
            text=True,
            check=False,
        ).stdout.strip()
    except Exception:
        head = "unknown"
    import hashlib

    spatial = REPO / "extension" / "cdt_sketchup" / "queries" / "spatial.rb"
    spatial_sha = hashlib.sha256(spatial.read_bytes()).hexdigest()
    client = BridgeClient()
    started = time.time()
    ping = await client.call("ping")
    if not isinstance(ping, dict) or not ping.get("live_model"):
        return {"bridge_available": False, "ping": ping}
    matrix = Matrix(client, f"{int(started)}")
    cases = []
    try:
        for case in CASES:
            try:
                cases.append(await matrix.run_case(case))
            except Exception as exc:
                cases.append(
                    {
                        "case": case["id"],
                        "analytic": case["analytic"],
                        "expected": case["expected"],
                        "actual": None,
                        "error": f"{type(exc).__name__}: {exc}",
                        "pass": False,
                    }
                )
    finally:
        for pid in list(matrix.created):
            try:
                await matrix.cleanup(pid)
            except Exception:
                pass
    report = {
        "revision": head,
        "spatial_sha256": spatial_sha,
        "sketchup_version": ping.get("sketchup_version"),
        "ruby_version": ping.get("ruby_version"),
        "bridge_protocol": ping.get("bridge_protocol"),
        "unit": UNIT,
        "surface_epsilon_in": EPS,
        "elapsed_s": round(time.time() - started, 2),
        "cases": cases,
        "passed": sum(1 for c in cases if c.get("pass")),
        "total": len(cases),
    }
    text = json.dumps(report, indent=2)
    print(text)
    if report_path:
        Path(report_path).write_text(text, encoding="utf-8")
    return report


def main() -> int:
    parser = argparse.ArgumentParser(description="B0 native spatial matrix")
    parser.add_argument("--probe", action="store_true")
    parser.add_argument("--run", action="store_true")
    parser.add_argument("--report", default=None)
    args = parser.parse_args()
    if args.probe:
        probe = asyncio.run(probe_only())
        ok = bool(probe.get("bridge_connected") and probe.get("live_model"))
        return 0 if ok else 2
    if args.run:
        report = asyncio.run(run_matrix(args.report))
        if not report.get("cases"):
            return 2
        return 0 if report["passed"] == report["total"] else 1
    parser.print_help()
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
