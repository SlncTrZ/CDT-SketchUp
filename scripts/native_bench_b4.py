"""B4 native performance benchmark — latency/throughput evidence via bounded bridge.

Wing: code | Topic: sketchup_performance | Updated: 2026-09-18

Measures p50/p95 latency + throughput for representative workloads through the
bounded loopback bridge (public commands only: execute_geometry /
get_entity_state / query_overlap). No SLA is claimed; this harness only
records measured native behavior for SKP-R06 evidence.

Usage:
    python scripts/native_bench_b4.py --probe [--host H] [--port P] [--timeout S]
    python scripts/native_bench_b4.py --run [--iterations N] [--warmup W]
        [--host H] [--port P] [--timeout S] [--report path.json]

Default report path is outside the repo (system Temp directory).

Exit codes: 0 completed (report written, even with per-iteration errors
recorded) | 2 bridge unavailable. No live workload is executed on probe
failure; fixtures always self-cleanup (0 residual entities expected).
"""

from __future__ import annotations

import argparse
import asyncio
import json
import math
import os
import platform
import subprocess
import sys
import tempfile
import time
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO / "src"))

from cdt_sketchup.bridge import (  # noqa: E402
    BridgeClient,
    BridgeProtocolError,
    BridgeUnavailableError,
)

UNIT = "in"
# Observed bridge config (source, not measured): server.rb POLL_SECONDS=0.05,
# BridgeClient DEFAULT_TIMEOUT_SECONDS=5.0. Recorded in report for context only.
BRIDGE_POLL_SECONDS = 0.05

# Budgets mirrored from extension/cdt_sketchup/kernel/limits.rb (fail-closed
# reference only; the probe below verifies fail-closed behavior natively).
MAX_MESH_VERTICES = 2048
MAX_MESH_FACES = 4096

# Representative bounded mesh fixture: unit cube shell (8 verts, 6 quad faces).
MESH_POINTS = [
    [0.0, 0.0, 0.0],
    [1.0, 0.0, 0.0],
    [1.0, 1.0, 0.0],
    [0.0, 1.0, 0.0],
    [0.0, 0.0, 1.0],
    [1.0, 0.0, 1.0],
    [1.0, 1.0, 1.0],
    [0.0, 1.0, 1.0],
]
MESH_FACES = [[0, 1, 2, 3], [4, 5, 6, 7], [0, 1, 5, 4],
              [2, 3, 7, 6], [0, 3, 7, 4], [1, 2, 6, 5]]

IDENTITY_4X4 = [1.0, 0.0, 0.0, 0.0,
                0.0, 1.0, 0.0, 0.0,
                0.0, 0.0, 1.0, 0.0,
                0.0, 0.0, 0.0, 1.0]
SHIFT_4X4 = [1.0, 0.0, 0.0, 0.0,
             0.0, 1.0, 0.0, 0.0,
             0.0, 0.0, 1.0, 0.0,
             0.25, 0.0, 0.0, 1.0]


def find_persistent_id(node, path="root"):
    """Defensively extract the created entity PID from an operation receipt."""
    if isinstance(node, dict):
        if isinstance(node.get("persistent_id"), int):
            return node["persistent_id"]
        for key in ("state", "entity", "result", "data"):
            if key in node:
                found = find_persistent_id(node[key], path + "." + key)
                if found is not None:
                    return found
        for key, value in node.items():
            found = find_persistent_id(value, path + "." + str(key))
            if found is not None:
                return found
    elif isinstance(node, list):
        for index, value in enumerate(node):
            found = find_persistent_id(value, f"{path}[{index}]")
            if found is not None:
                return found
    return None


def percentile(sorted_ms: list[float], q: float) -> float | None:
    """Nearest-rank percentile over an already-sorted sample list."""
    if not sorted_ms:
        return None
    if len(sorted_ms) == 1:
        return sorted_ms[0]
    rank = math.ceil(q / 100.0 * len(sorted_ms)) - 1
    rank = max(0, min(rank, len(sorted_ms) - 1))
    return sorted_ms[rank]


def summarize(samples_ms: list[float]) -> dict:
    """Summarize latency samples; throughput derived by the caller."""
    ordered = sorted(samples_ms)
    total_s = sum(samples_ms) / 1000.0
    return {
        "samples": len(samples_ms),
        "min_ms": min(samples_ms) if samples_ms else None,
        "max_ms": max(samples_ms) if samples_ms else None,
        "mean_ms": (sum(samples_ms) / len(samples_ms)) if samples_ms else None,
        "p50_ms": percentile(ordered, 50),
        "p95_ms": percentile(ordered, 95),
        "total_s": round(total_s, 4),
        "throughput_ops": round(len(samples_ms) / total_s, 3) if total_s > 0 else None,
    }


def rss_kb() -> int | None:
    """Best-effort client RSS in KiB (stdlib only; None when unmeasurable)."""
    try:
        import resource  # POSIX only; absent on Windows
        return int(resource.getrusage(resource.RUSAGE_SELF).ru_maxrss)
    except Exception:
        pass
    try:
        import ctypes
        wintypes_process = ctypes.windll.psapi
        counters = (ctypes.c_ulonglong * 12)()
        counters[0] = ctypes.sizeof(counters)
        handle = ctypes.windll.kernel32.GetCurrentProcess()
        if wintypes_process.GetProcessMemoryInfo(handle, counters, counters[0]):
            return int(counters[1] // 1024)
    except Exception:
        pass
    return None


def hardware_metadata() -> dict:
    return {
        "os": f"{platform.system()} {platform.release()} ({platform.version()})",
        "machine": platform.machine(),
        "processor": platform.processor() or platform.machine(),
        "cpu_count": os.cpu_count(),
        "python": platform.python_version(),
    }


def git_revision() -> str:
    try:
        out = subprocess.run(
            ["git", "rev-parse", "HEAD"], cwd=REPO,
            capture_output=True, text=True, check=False,
        ).stdout.strip()
        return out or "unknown"
    except Exception:
        return "unknown"


async def model_size(client: BridgeClient) -> dict:
    """Best-effort live model size (entity count); never throws."""
    for command, params in (
        ("object_list", {}),
        ("document_info", {}),
    ):
        try:
            result = await client.call(command, params)
        except Exception:
            continue
        if isinstance(result, dict):
            for key in ("active_entity_count", "entity_count", "count"):
                if isinstance(result.get(key), int):
                    return {"source": command, "entity_count": result[key]}
            for key in ("entities", "objects"):
                value = result.get(key)
                if isinstance(value, list):
                    return {"source": command, "entity_count": len(value)}
            return {"source": command, "entity_count": "unknown"}
    return {"source": "unavailable", "entity_count": "unknown"}


class Bench:
    def __init__(self, client: BridgeClient, run_id: str):
        self.client = client
        self.run_id = run_id
        self.counter = 0
        self.created = 0
        self.deleted = 0
        self._live: list[int] = []

    def _name(self, workload: str) -> str:
        self.counter += 1
        return f"B4_{self.run_id}_{workload}_{self.counter}"

    async def create_box(self, workload: str, origin=(0.0, 0.0, 0.0)) -> int:
        receipt = await self.client.call(
            "execute_geometry",
            {
                "action": "create_box",
                "params": {
                    "name": self._name(workload),
                    "origin": list(origin),
                    "dimensions": [1.0, 1.0, 1.0],
                },
                "expect": {"active_entity_delta": 1, "type": "ComponentInstance"},
                "unit": UNIT,
            },
        )
        pid = find_persistent_id(receipt)
        if pid is None:
            raise RuntimeError(f"create_box receipt has no persistent_id: {receipt}")
        self.created += 1
        self._live.append(pid)
        return pid

    async def create_mesh(self, workload: str) -> int:
        receipt = await self.client.call(
            "execute_geometry",
            {
                "action": "create_mesh",
                "params": {
                    "name": self._name(workload),
                    "points": [list(p) for p in MESH_POINTS],
                    "faces": [list(f) for f in MESH_FACES],
                },
                "expect": {"active_entity_delta": 1, "type": "Group",
                           "vertex_count": 8, "face_count": 6},
                "unit": UNIT,
            },
        )
        pid = find_persistent_id(receipt)
        if pid is None:
            raise RuntimeError(f"create_mesh receipt has no persistent_id: {receipt}")
        self.created += 1
        self._live.append(pid)
        return pid

    async def delete(self, pid: int) -> None:
        await self.client.call(
            "execute_geometry",
            {
                "action": "delete_entity",
                "params": {"persistent_id": pid},
                "expect": {"active_entity_delta": -1, "deleted": True},
                "unit": UNIT,
            },
        )
        self.deleted += 1
        if pid in self._live:
            self._live.remove(pid)

    async def cleanup_all(self) -> int:
        """Delete every fixture PID; return residual count (expected 0)."""
        for pid in list(self._live):
            try:
                await self.delete(pid)
            except Exception:
                pass
        return len(self._live)

    async def timed(self, coro_factory) -> float:
        start = time.perf_counter()
        await coro_factory()
        return (time.perf_counter() - start) * 1000.0


async def run_workload(name: str, iterations: int, warmup: int, body) -> dict:
    """Run warm-up (untimed) then N timed iterations of an async body."""
    for _ in range(warmup):
        await body()
    samples: list[float] = []
    errors = 0
    last_error: str | None = None
    for _ in range(iterations):
        try:
            samples.append(await body())
        except Exception as exc:  # record, never abort the matrix
            errors += 1
            last_error = f"{type(exc).__name__}: {exc}"
    summary = summarize(samples)
    summary.update({"workload": name, "errors": errors, "last_error": last_error})
    return summary


async def probe_only(host: str, port: int, timeout: float) -> dict:
    client = BridgeClient(host=host, port=port, timeout=timeout)
    probe = await client.probe()
    print(json.dumps(probe, indent=2))
    return probe


async def run_bench(host: str, port: int, timeout: float,
                    iterations: int, warmup: int,
                    report_path: str | None) -> dict:
    started = time.time()
    run_id = str(int(started))
    client = BridgeClient(host=host, port=port, timeout=timeout)

    try:
        ping = await client.call("ping")
    except (BridgeUnavailableError, BridgeProtocolError, Exception) as exc:
        return {"bridge_available": False, "detail": str(exc)}
    if not isinstance(ping, dict) or not ping.get("live_model"):
        return {"bridge_available": False, "ping": ping}

    bench = Bench(client, run_id)
    rss_before = rss_kb()
    size_before = await model_size(client)
    workloads: dict[str, dict] = {}
    try:
        # W1: get_entity_state on a stable fixture (read path).
        fixture = await bench.create_box("state")
        workloads["get_entity_state"] = await run_workload(
            "get_entity_state", iterations, warmup,
            lambda: bench.timed(lambda: client.call(
                "get_entity_state",
                {"persistent_id": fixture, "unit": UNIT,
                 "coordinate_space": "active_context"})),
        )
        await bench.delete(fixture)

        # W2: strict create (create_box timed; immediate delete unmeasured cleanup).
        async def strict_create() -> float:
            # Time create only: re-run split to isolate create latency.
            start = time.perf_counter()
            pid = await bench.create_box("create")
            elapsed = (time.perf_counter() - start) * 1000.0
            await bench.delete(pid)
            return elapsed
        workloads["strict_create"] = await run_workload(
            "strict_create", iterations, warmup, strict_create)

        # W3: transform on a stable fixture (alternating absolute matrices).
        t_fixture = await bench.create_box("transform")
        toggle = {"even": True}

        async def transform_op() -> float:
            matrix = IDENTITY_4X4 if toggle["even"] else SHIFT_4X4
            toggle["even"] = not toggle["even"]

            async def op():
                await client.call(
                    "execute_geometry",
                    {
                        "action": "transform_entity",
                        "params": {"persistent_id": t_fixture,
                                   "matrix": list(matrix)},
                        "expect": {"active_entity_delta": 0,
                                   "transformation": list(matrix)},
                        "unit": UNIT,
                    },
                )
            return await bench.timed(op)
        workloads["transform"] = await run_workload(
            "transform", iterations, warmup, transform_op)
        await bench.delete(t_fixture)

        # W4: representative bounded mesh (create_mesh + delete).
        async def mesh_op() -> float:
            start = time.perf_counter()
            pid = await bench.create_mesh("mesh")
            elapsed = (time.perf_counter() - start) * 1000.0
            await bench.delete(pid)
            return elapsed
        workloads["create_mesh_bounded"] = await run_workload(
            "create_mesh_bounded", iterations, warmup, mesh_op)

        # W5: spatial query on a stable pair (query_overlap).
        q_a = await bench.create_box("query", origin=(0.0, 0.0, 0.0))
        q_b = await bench.create_box("query", origin=(5.0, 0.0, 0.0))
        workloads["query_overlap"] = await run_workload(
            "query_overlap", iterations, warmup,
            lambda: bench.timed(lambda: client.call(
                "query_overlap",
                {"first_pid": q_a, "second_pid": q_b, "unit": UNIT})),
        )
        await bench.delete(q_a)
        await bench.delete(q_b)

        # W6: multi-step composition (create A/B, transform, overlap, state).
        async def composition_op() -> float:
            start = time.perf_counter()
            a = await bench.create_box("compose", origin=(0.0, 0.0, 0.0))
            b = await bench.create_box("compose", origin=(10.0, 0.0, 0.0))
            await client.call(
                "execute_geometry",
                {
                    "action": "transform_entity",
                    "params": {"persistent_id": b, "matrix": list(SHIFT_4X4)},
                    "expect": {"active_entity_delta": 0,
                               "transformation": list(SHIFT_4X4)},
                    "unit": UNIT,
                },
            )
            await client.call(
                "query_overlap",
                {"first_pid": a, "second_pid": b, "unit": UNIT})
            await client.call(
                "get_entity_state",
                {"persistent_id": a, "unit": UNIT,
                 "coordinate_space": "active_context"})
            await bench.delete(a)
            await bench.delete(b)
            return (time.perf_counter() - start) * 1000.0
        workloads["composition"] = await run_workload(
            "composition", iterations, warmup, composition_op)

        # Over-budget probe: exceed MAX_MESH_VERTICES -> deterministic
        # fail-closed (rejection), never a crash, never a created entity.
        over_budget: dict = {
            "budget_vertices": MAX_MESH_VERTICES,
            "budget_faces": MAX_MESH_FACES,
            "sent_vertices": MAX_MESH_VERTICES + 1,
            "sent_faces": 1,
        }
        created_before = bench.created
        try:
            oversized = [[float(i) * 0.01, 0.0, 0.0]
                         for i in range(MAX_MESH_VERTICES + 1)]
            receipt = await client.call(
                "execute_geometry",
                {
                    "action": "create_mesh",
                    "params": {"name": bench._name("overbudget"),
                               "points": oversized, "faces": [[0, 1, 2]]},
                "expect": {"active_entity_delta": 1, "type": "Group",
                           "vertex_count": MAX_MESH_VERTICES + 1,
                           "face_count": 1},
                    "unit": UNIT,
                },
            )
            leaked_pid = find_persistent_id(receipt)
            if leaked_pid is not None:
                bench.created += 1
                bench._live.append(leaked_pid)
            else:
                bench.created += 1
            over_budget.update({
                "fail_closed": False,
                "crashed": False,
                "detail": "over-budget mesh was unexpectedly accepted",
            })
            # Best-effort count; cleanup_all() below deletes any live fixture.
            bench.created += 1
        except Exception as exc:
            over_budget.update({
                "fail_closed": bench.created == created_before,
                "crashed": False,
                "error": f"{type(exc).__name__}: {exc}",
            })
    finally:
        residual = await bench.cleanup_all()

    rss_after = rss_kb()
    size_after = await model_size(client)
    report = {
        "tool": "native_bench_b4",
        "goal": "SKP-R06 performance evidence (measured only, no SLA claimed)",
        "revision": git_revision(),
        "hardware": hardware_metadata(),
        "sketchup_version": ping.get("sketchup_version"),
        "ruby_version": ping.get("ruby_version"),
        "bridge_protocol": ping.get("bridge_protocol"),
        "bridge": {"host": host, "port": port,
                   "client_timeout_s": timeout,
                   "bridge_poll_seconds": BRIDGE_POLL_SECONDS},
        "unit": UNIT,
        "mode": "warm" if warmup > 0 else "cold",
        "iterations": iterations,
        "warmup": warmup,
        "model_size_before": size_before,
        "model_size_after": size_after,
        "workloads": workloads,
        "memory_client_rss_kb": {
            "before": rss_before, "after": rss_after,
            "growth": (rss_after - rss_before)
            if (rss_before is not None and rss_after is not None) else None,
        },
        "over_budget": over_budget,
        "cleanup": {"created": bench.created, "deleted": bench.deleted,
                    "residual": residual},
        "elapsed_s": round(time.time() - started, 2),
    }
    if report_path is None:
        report_path = str(Path(tempfile.gettempdir())
                           / f"cdt-bench-b4-{run_id}.json")
    Path(report_path).write_text(json.dumps(report, indent=2), encoding="utf-8")

    lines = [f"B4 bench complete: revision={report['revision']} "
             f"mode={report['mode']} iter={iterations} warmup={warmup} "
             f"residual={residual} report={report_path}"]
    for name, summary in workloads.items():
        lines.append(
            f"  {name}: n={summary['samples']} "
            f"p50={summary['p50_ms']}ms p95={summary['p95_ms']}ms "
            f"throughput={summary['throughput_ops']}ops/s "
            f"errors={summary['errors']}")
    mem = report["memory_client_rss_kb"]
    lines.append(f"  client rss growth: {mem['growth']} KiB "
                 f"(before={mem['before']} after={mem['after']})")
    lines.append(f"  over-budget mesh: fail_closed={over_budget.get('fail_closed')} "
                 f"crashed={over_budget.get('crashed')}")
    print("\n".join(lines))
    return {"bridge_available": True, "report": report, "path": report_path}


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="B4 native performance benchmark (measured only, no SLA)")
    parser.add_argument("--probe", action="store_true",
                        help="ping the bridge and exit")
    parser.add_argument("--run", action="store_true",
                        help="run the benchmark matrix")
    parser.add_argument("--iterations", type=int, default=20,
                        help="timed iterations per workload (default 20)")
    parser.add_argument("--warmup", type=int, default=3,
                        help="untimed warm-up iterations per workload (default 3)")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=9876)
    parser.add_argument("--timeout", type=float, default=5.0)
    parser.add_argument("--report", default=None,
                        help="report JSON path (default: system Temp dir)")
    return parser


def main(argv=None) -> int:
    args = build_parser().parse_args(argv)
    if args.iterations < 1 or args.warmup < 0:
        print("iterations must be >=1 and warmup >=0", file=sys.stderr)
        return 2
    if args.probe:
        probe = asyncio.run(probe_only(args.host, args.port, args.timeout))
        ok = bool(probe.get("bridge_connected") and probe.get("live_model"))
        return 0 if ok else 2
    if args.run:
        outcome = asyncio.run(run_bench(
            args.host, args.port, args.timeout,
            args.iterations, args.warmup, args.report))
        return 0 if outcome.get("bridge_available") else 2
    build_parser().print_help()
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
