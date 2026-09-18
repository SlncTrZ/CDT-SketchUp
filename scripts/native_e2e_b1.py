"""B1 Engineer->native end-to-end — provider-neutral recipe realization proof.

Wing: code | Topic: sketchup_e2e | Updated: 2026-09-18

Realizes CDT_Engineer planner fixtures (scripts/export_planner_fixtures.py,
never hand-written coordinates) through PUBLIC provider bridge commands and
checks them against planner-side oracle values from the fixture JSON.
The provider never sees domain logic; the oracle never reads provider output
to build expectations.

Usage:
    python scripts/native_e2e_b1.py --run [--fixtures DIR] [--report path.json]

Exit codes: 0 all pass | 1 mismatch/reject-failure | 2 bridge unavailable.
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

UNIT = "mm"
DEFAULT_FIXTURES = Path("H:/Develop/CDT_Engineer/domains/building-architecture/e2e-fixtures")
VALID_CASES = [
    "straight-rect-sweep",
    "tapered-quad-loft",
    "four-section-loft",
    "concave-c-sweep",
    "curved-rect-sweep",
]
BOUNDS_TOL_MM = 1e-3


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


def find_pid(node):
    if isinstance(node, dict):
        if isinstance(node.get("persistent_id"), int):
            return node["persistent_id"]
        for key in ("state", "entity", "result", "data"):
            if key in node:
                hit = find_pid(node[key])
                if hit is not None:
                    return hit
        for value in node.values():
            hit = find_pid(value)
            if hit is not None:
                return hit
    elif isinstance(node, list):
        for value in node:
            hit = find_pid(value)
            if hit is not None:
                return hit
    return None


def find_all_pids(node, acc=None):
    if acc is None:
        acc = []
    if isinstance(node, dict):
        if isinstance(node.get("persistent_id"), int):
            acc.append(node["persistent_id"])
        for value in node.values():
            find_all_pids(value, acc)
    elif isinstance(node, list):
        for value in node:
            find_all_pids(value, acc)
    return acc


def close(a, b, tol):
    return abs(a - b) <= tol


class Runner:
    def __init__(self, client: BridgeClient, run_id: str):
        self.client = client
        self.run_id = run_id
        self.counter = 0
        self.created: list[int] = []

    def _name(self, base: str) -> str:
        self.counter += 1
        return f"B1_{self.run_id}_{base}_{self.counter}"[:120]

    async def active_count(self) -> int | None:
        try:
            info = await self.client.call("object_list", {})
            return info.get("total_in_active_context", info.get("returned"))
        except Exception:
            return None

    async def create_mesh(self, name, points, faces, extra_expect=None):
        expect = {"active_entity_delta": 1, "type": "Group",
                  "vertex_count": len(points), "face_count": len(faces)}
        if extra_expect:
            expect.update(extra_expect)
        receipt = await self.client.call(
            "execute_geometry",
            {"action": "create_mesh",
             "params": {"name": name, "points": points, "faces": faces},
             "expect": expect, "unit": UNIT},
        )
        pid = find_pid(receipt)
        if pid is None:
            raise RuntimeError(f"create_mesh receipt has no PID: {str(receipt)[:200]}")
        self.created.append(pid)
        return pid, receipt

    async def cleanup(self, pid: int) -> bool:
        try:
            await self.client.call(
                "execute_geometry",
                {"action": "delete_entity",
                 "params": {"persistent_id": pid},
                 "expect": {"active_entity_delta": -1, "deleted": True},
                 "unit": UNIT},
            )
            return True
        except Exception:
            return False

    async def mesh_case(self, fixture: dict) -> dict:
        case_id = fixture["case_id"]
        exp = fixture["expected"]
        recipe = fixture["recipe"]
        pid, _ = await self.create_mesh(
            self._name(case_id), recipe["points"], recipe["faces"])
        state = await self.client.call(
            "get_entity_state",
            {"persistent_id": pid, "unit": UNIT,
             "coordinate_space": "active_context"})
        topo = await self.client.call(
            "query_topology", {"persistent_id": pid, "unit": UNIT})
        checks: dict = {}
        state_bounds = (find_key(state, "bounds") or {})
        for corner in ("min", "max"):
            got = state_bounds.get(corner) if isinstance(state_bounds, dict) else None
            want = (exp["bounds"]["min"] if corner == "min"
                    else exp["bounds"]["max"])
            checks[f"bounds_{corner}"] = (
                isinstance(got, list) and len(got) == 3
                and all(close(g, w, BOUNDS_TOL_MM) for g, w in zip(got, want)))
        checks["vertex_count"] = find_key(state, "vertex_count") == exp["vertex_count"]
        checks["face_count"] = find_key(state, "face_count") == exp["face_count"]
        topo_v = find_key(topo, "vertex_count")
        topo_e = find_key(topo, "edge_count")
        topo_f = find_key(topo, "face_count")
        checks["topology_counts"] = (
            topo_v == exp["vertex_count"] and topo_f == exp["face_count"]
            and isinstance(topo_e, int) and topo_e > 0)
        checks["euler"] = (
            checks["topology_counts"]
            and topo_v - topo_e + topo_f == 2)
        checks["manifold"] = find_key(topo, "manifold") is True
        want_vol = exp["expected_volume"]
        diagnostics: dict = {}
        if want_vol is None:
            checks["volume"] = "reduced_scope_unknown_by_design"
        else:
            got_vol = find_key(state, "volume")
            tol = exp.get("volume_tolerance", 1e-6) * abs(want_vol)
            checks["volume"] = (
                isinstance(got_vol, (int, float))
                and close(float(got_vol), want_vol, tol))
            diagnostics["volume_got"] = got_vol
            diagnostics["volume_tol_abs"] = tol
        ok = all(v is True or v == "reduced_scope_unknown_by_design"
                 for v in checks.values())
        cleaned = await self.cleanup(pid)
        return {"case": case_id, "planner": fixture["planner"],
                "expected_volume": want_vol,
                "volume_tolerance": exp.get("volume_tolerance"),
                "checks": checks, "diagnostics": diagnostics,
                "pass": bool(ok), "cleanup": cleaned}

    async def composition_case(self, fixture: dict) -> dict:
        # NOTE (B1 residual, 18.09.2026): create_component keeps its input
        # as a nested child, and instance semantic counts/manifold do not
        # descend nesting (v/e/f=0, manifold=false), so composed instances
        # cannot enter spatial queries even though triangulation could
        # descend. Family 3 therefore arrays the mesh Group directly:
        # copies carry raw faces and stay manifold. The nesting limitation
        # is recorded in the SOT, not worked around here.
        recipe = fixture["recipe"]
        base, _ = await self.create_mesh(
            self._name("comp"), recipe["points"], recipe["faces"])
        vector = [200.0, 0.0, 0.0]
        arr = await self.client.call(
            "execute_geometry",
            {"action": "linear_array",
             "params": {"persistent_id": base, "vector": vector, "count": 3},
             "expect": {"active_entity_delta": 3, "count": 3,
                        "type": "Group"},
             "unit": UNIT})
        copies = [p for p in (arr.get("affected", {}) or {}).get("created", [])
                  if isinstance(p, int) and p != base]
        for p in copies:
            self.created.append(p)
        checks: dict = {}
        checks["three_copies"] = len(copies) == 3
        states = [await self.client.call(
            "get_entity_state",
            {"persistent_id": p, "unit": UNIT,
             "coordinate_space": "active_context"}) for p in copies]
        checks["copies_are_manifold_groups"] = all(
            find_key(s, "type") == "Group"
            and find_key(s, "manifold") is True
            and find_key(s, "vertex_count") == recipe["vertex_count"]
            and find_key(s, "face_count") == recipe["face_count"]
            for s in states)
        mins = [find_key(s, "bounds").get("min") for s in states]
        checks["spacing_200mm"] = all(
            isinstance(m, list) and close(m[0], 200.0 * (i + 1), 1e-3)
            for i, m in enumerate(mins))
        dist = await self.client.call(
            "measure_distance",
            {"first_pid": base, "second_pid": copies[0], "unit": UNIT})
        clr = find_key(dist, "surface_clearance")
        checks["gap_100mm"] = isinstance(clr, (int, float)) and close(
            float(clr), 100.0, 1e-3)
        ok = all(checks.values())
        cleaned = all([await self.cleanup(p)
                       for p in [base, *copies]])
        return {"case": "generic-composition-linear-array",
                "checks": checks, "pass": bool(ok), "cleanup": cleaned}

    async def invalid_cases(self) -> list[dict]:
        out = []
        before = await self.active_count()
        try:
            await self.create_mesh(
                self._name("badidx"),
                [[0, 0, 0], [1, 0, 0], [0, 1, 0]], [[0, 1, 5]])
            out.append({"case": "invalid_bad_index", "pass": False,
                        "detail": "malformed mesh was NOT rejected"})
        except Exception as exc:
            out.append({"case": "invalid_bad_index", "pass": True,
                        "detail": f"rejected: {type(exc).__name__}"})
        ring = [[math.cos(2 * math.pi * i / 17), math.sin(2 * math.pi * i / 17), 0]
                for i in range(17)]
        try:
            await self.create_mesh(
                self._name("bigface"), ring, [list(range(17))])
            out.append({"case": "invalid_17gon_face", "pass": False,
                        "detail": "over-budget face was NOT rejected"})
        except Exception as exc:
            out.append({"case": "invalid_17gon_face", "pass": True,
                        "detail": f"rejected: {type(exc).__name__}"})
        return out

    async def stale_context_case(self) -> dict:
        baseline = await self.active_count()
        pid_a, receipt_a = await self.create_mesh(
            self._name("ctxa"),
            [[0, 0, 0], [1, 0, 0], [1, 1, 0], [0, 1, 0],
             [0, 0, 1], [1, 0, 1], [1, 1, 1], [0, 1, 1]],
            [[0, 1, 2, 3], [4, 5, 6, 7], [0, 1, 5, 4],
             [1, 2, 6, 5], [2, 3, 7, 6], [3, 0, 4, 7]])
        stale_full = find_key(receipt_a, "context") or {}
        stale_ctx = {"id": stale_full.get("id"),
                     "revision": stale_full.get("revision")}
        pid_b, _ = await self.create_mesh(
            self._name("ctxb"),
            [[10, 0, 0], [11, 0, 0], [11, 1, 0], [10, 1, 0],
             [10, 0, 1], [11, 0, 1], [11, 1, 1], [10, 1, 1]],
            [[0, 1, 2, 3], [4, 5, 6, 7], [0, 1, 5, 4],
             [1, 2, 6, 5], [2, 3, 7, 6], [3, 0, 4, 7]])
        try:
            await self.client.call(
                "execute_geometry",
                {"action": "create_box",
                 "params": {"name": self._name("stale"),
                            "origin": [50, 0, 0], "dimensions": [1, 1, 1]},
                 "expect": {"active_entity_delta": 1,
                            "type": "ComponentInstance"},
                 "unit": UNIT, "if_context": stale_ctx})
            result = {"case": "invalid_stale_if_context", "pass": False,
                      "detail": "stale context was NOT rejected"}
        except Exception as exc:
            after = await self.active_count()
            result = {"case": "invalid_stale_if_context",
                      "pass": ("context_mismatch" in str(exc)
                               and after == baseline + 2),
                      "detail": f"rejected: {str(exc)[:120]}, "
                                f"count {baseline}->{after} (A,B alive)"}
        cleaned = all([await self.cleanup(pid_a), await self.cleanup(pid_b)])
        final = await self.active_count()
        result["cleanup"] = cleaned and final == baseline
        return result


async def run_matrix(fixtures_dir: Path, report_path: str | None) -> dict:
    try:
        eng_head = subprocess.run(
            ["git", "rev-parse", "HEAD"], cwd=fixtures_dir.parents[2],
            capture_output=True, text=True, check=False).stdout.strip()
    except Exception:
        eng_head = "unknown"
    try:
        head = subprocess.run(
            ["git", "rev-parse", "HEAD"], cwd=REPO,
            capture_output=True, text=True, check=False).stdout.strip()
    except Exception:
        head = "unknown"
    client = BridgeClient()
    started = time.time()
    try:
        ping = await client.call("ping")
    except Exception as exc:
        return {"bridge_available": False, "detail": str(exc)}
    if not isinstance(ping, dict) or not ping.get("live_model"):
        return {"bridge_available": False, "ping": ping}
    runner = Runner(client, f"{int(started)}")
    cases = []
    try:
        loaded = {}
        for case_id in VALID_CASES:
            path = fixtures_dir / f"{case_id}.json"
            loaded[case_id] = json.loads(path.read_text(encoding="utf-8"))
        for case_id in VALID_CASES:
            try:
                cases.append(await runner.mesh_case(loaded[case_id]))
            except Exception as exc:
                cases.append({"case": case_id, "pass": False,
                              "error": f"{type(exc).__name__}: {exc}"})
        try:
            cases.append(await runner.composition_case(
                loaded["straight-rect-sweep"]))
        except Exception as exc:
            cases.append({"case": "generic-composition-linear-array",
                          "pass": False,
                          "error": f"{type(exc).__name__}: {exc}"})
        try:
            cases.extend(await runner.invalid_cases())
        except Exception as exc:
            cases.append({"case": "invalid_group",
                          "pass": False,
                          "error": f"{type(exc).__name__}: {exc}"})
        try:
            cases.append(await runner.stale_context_case())
        except Exception as exc:
            cases.append({"case": "invalid_stale_if_context", "pass": False,
                          "error": f"{type(exc).__name__}: {exc}"})
    finally:
        for pid in list(runner.created):
            try:
                await runner.cleanup(pid)
            except Exception:
                pass
    report = {
        "revision": head, "engineer_revision": eng_head,
        "engineer_fixtures": str(fixtures_dir),
        "sketchup_version": ping.get("sketchup_version"),
        "ruby_version": ping.get("ruby_version"),
        "unit": UNIT, "elapsed_s": round(time.time() - started, 2),
        "cases": cases,
        "passed": sum(1 for c in cases if c.get("pass") is True),
        "total": len(cases),
    }
    text = json.dumps(report, indent=2)
    print(text)
    if report_path:
        Path(report_path).write_text(text, encoding="utf-8")
    return report


def main() -> int:
    parser = argparse.ArgumentParser(description="B1 Engineer->native E2E")
    parser.add_argument("--run", action="store_true")
    parser.add_argument("--fixtures", default=str(DEFAULT_FIXTURES))
    parser.add_argument("--report", default=None)
    args = parser.parse_args()
    if not args.run:
        parser.print_help()
        return 2
    report = asyncio.run(run_matrix(Path(args.fixtures), args.report))
    if not report.get("cases"):
        print(json.dumps(report, indent=2))
        return 2
    return 0 if report["passed"] == report["total"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
