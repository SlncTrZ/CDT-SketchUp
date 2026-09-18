"""B2 recovery seams — live transport-loss/retry integrity proof.

Wing: code | Topic: sketchup_recovery | Updated: 2026-09-18

Drives the Ruby mutation journal through the public bridge with
caller-crafted stable envelopes (same code path as server.py wiring):
dedup replay, reuse rejection, hash binding, reconcile classification,
and journal bound eviction. No mocks, no discarded receipts.

Usage:
    python scripts/native_recovery_b2.py --run [--report path.json]

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

REPO = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO / "src"))

from cdt_sketchup.bridge import BridgeClient, BridgeProtocolError  # noqa: E402
from cdt_sketchup.mutation import (  # noqa: E402
    mutation_envelope,
    new_mutation_id,
)

UNIT = "mm"
FILL_COUNT = 129


def box_body(name, origin):
    return {
        "action": "create_box",
        "params": {"name": name, "origin": list(origin),
                   "dimensions": [10.0, 10.0, 10.0]},
        "expect": {"active_entity_delta": 1, "type": "ComponentInstance"},
        "unit": UNIT,
    }


class Seams:
    def __init__(self, client: BridgeClient, run_id: str):
        self.client = client
        self.run_id = run_id
        self.counter = 0
        self.created: list[int] = []
        self.results: list[dict] = []

    def record(self, seam: str, ok: bool, detail: str = "") -> None:
        self.results.append({"seam": seam, "pass": ok, "detail": detail})
        print(f"{seam}: {'PASS' if ok else 'FAIL'} {detail}")

    async def geom(self, body: dict, mutation: dict | None = None) -> dict:
        payload = dict(body)
        if mutation is not None:
            payload["mutation"] = mutation
        return await self.client.call("execute_geometry", payload)

    async def count(self) -> int | None:
        try:
            info = await self.client.call("object_list", {})
            return info.get("total_in_active_context", info.get("returned"))
        except Exception:
            return None

    async def cleanup(self, pid: int) -> None:
        try:
            await self.client.call(
                "execute_geometry",
                {"action": "delete_entity",
                 "params": {"persistent_id": pid},
                 "expect": {"active_entity_delta": -1, "deleted": True},
                 "unit": UNIT})
        except Exception:
            pass

    async def seam_dedup_replay(self) -> dict:
        mid = new_mutation_id()
        body = box_body(f"B2_{self.run_id}_replay", [0, 0, 0])
        before = await self.count()
        first = await self.geom(body, mutation_envelope(mid, body))
        second = await self.geom(body, mutation_envelope(mid, body))
        after = await self.count()
        pid = (first.get("entity_states") or [{}])[0].get("persistent_id")
        if isinstance(pid, int):
            self.created.append(pid)
        same_receipt = (first.get("receipt_id") == second.get("receipt_id")
                        and first.get("receipt_id") is not None)
        ok = (same_receipt
              and second.get("mutation", {}).get("replayed") is True
              and first.get("idempotent") is True
              and after == before + 1)
        self.record("dedup_replay", ok,
                    f"same_receipt={same_receipt} count {before}->{after}")
        return {"mid": mid, "receipt": first, "pid": pid}

    async def seam_reuse_reject(self, mid: str) -> None:
        bodies = box_body(f"B2_{self.run_id}_reuse", [500, 0, 0])
        before = await self.count()
        try:
            await self.geom(bodies, mutation_envelope(mid, bodies))
            self.record("reuse_reject", False, "same id+new payload accepted")
        except BridgeProtocolError as exc:
            after = await self.count()
            ok = "mutation_id_reuse" in str(exc) and after == before
            self.record("reuse_reject", ok,
                        f"{str(exc)[:60]} count {before}->{after}")

    async def seam_hash_mismatch(self) -> None:
        mid = new_mutation_id()
        body = box_body(f"B2_{self.run_id}_hash", [0, 0, 0])
        env = mutation_envelope(mid, body)
        env["request_hash"] = "0" * 64
        try:
            await self.geom(body, env)
            self.record("hash_mismatch", False, "bad hash accepted")
        except BridgeProtocolError as exc:
            self.record("hash_mismatch", "mutation_hash_mismatch" in str(exc),
                        str(exc)[:80])

    async def reconcile(self, **params) -> dict:
        return await self.client.call("mutation_reconcile", params)

    async def seam_reconcile_committed(self, mid: str, receipt: dict) -> None:
        out = await self.reconcile(mutation_id=mid)
        ok = (out.get("status") == "committed"
              and out.get("journal") == "committed"
              and (out.get("receipt") or {}).get("receipt_id")
              == receipt.get("receipt_id"))
        self.record("reconcile_committed", ok, out.get("status", ""))

    async def seam_reconcile_rolled_back(self) -> None:
        mid = new_mutation_id()
        body = box_body(f"B2_{self.run_id}_rb", [0, 0, 0])
        body["expect"] = {"active_entity_delta": 99, "type": "ComponentInstance"}
        failed = await self.geom(body, mutation_envelope(mid, body))
        out = await self.reconcile(mutation_id=mid)
        ok = (failed.get("rolled_back") is True
              and out.get("status") == "rolled_back")
        self.record("reconcile_rolled_back", ok, out.get("status", ""))

    async def seam_reconcile_not_started(self, receipt: dict) -> None:
        before = {
            "model_fingerprint":
                (receipt.get("model") or {}).get("after", {}).get(
                    "model_fingerprint"),
            "context": {"revision":
                        (receipt.get("context") or {}).get("revision")},
        }
        out = await self.reconcile(
            mutation_id=new_mutation_id(), before=before)
        self.record("reconcile_not_started",
                    out.get("status") == "not_started"
                    and out.get("journal") == "miss",
                    out.get("status", ""))

    async def seam_reconcile_diverged(self) -> None:
        out = await self.reconcile(
            mutation_id=new_mutation_id(),
            before={"model_fingerprint": "0" * 64,
                    "context": {"revision": "0" * 64}})
        self.record("reconcile_diverged",
                    out.get("status") == "diverged_unknown",
                    out.get("status", ""))

    async def seam_eviction(self) -> None:
        # Fill the 128-entry journal with ROLLED_BACK ops so the model
        # fingerprint never drifts: failing validations journal without
        # mutating, which keeps the evicted entry's proof checkable.
        # (Committed filler ops would leave unused definitions behind and
        # legitimately break fingerprint proof — fail-closed, not a bug.)
        first_mid = new_mutation_id()
        first_body = box_body(f"B2_{self.run_id}_ev0", [900, 0, 0])
        first = await self.geom(first_body,
                                mutation_envelope(first_mid, first_body))
        first_pid = (first.get("entity_states") or [{}])[0].get("persistent_id")
        if isinstance(first_pid, int):
            self.created.append(first_pid)
        first_after = ((first.get("model") or {}).get("after") or {}).get(
            "model_fingerprint")
        first_fp = None
        for state in first.get("entity_states") or []:
            if state.get("persistent_id") == first_pid:
                first_fp = state.get("semantic_fingerprint")
        for i in range(1, FILL_COUNT):
            mid = new_mutation_id()
            bad = box_body(f"B2_{self.run_id}_ev{i}", [900, 0, 0])
            bad["expect"] = {"active_entity_delta": 99,
                             "type": "ComponentInstance"}
            await self.geom(bad, mutation_envelope(mid, bad))
        direct = await self.reconcile(mutation_id=first_mid)
        self.record("eviction_still_present"
                    if direct.get("journal") != "miss" else "eviction_miss",
                    direct.get("journal") == "miss",
                    f"journal={direct.get('journal')}")
        if isinstance(first_pid, int) and first_after and first_fp:
            late = await self.reconcile(
                mutation_id=first_mid,
                expect_post={"model_fingerprint": first_after,
                             "entity_fingerprints": {str(first_pid): first_fp}})
            self.record("evicted_receipt_lost_proof",
                        late.get("status") == "committed_but_receipt_lost",
                        late.get("status", ""))
        for pid in list(self.created):
            await self.cleanup(pid)
            self.created.remove(pid)


async def run(report_path: str | None) -> dict:
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
    seams = Seams(client, f"{int(started)}")
    try:
        first = await seams.seam_dedup_replay()
        await seams.seam_reuse_reject(first["mid"])
        await seams.seam_hash_mismatch()
        await seams.seam_reconcile_committed(first["mid"], first["receipt"])
        await seams.seam_reconcile_rolled_back()
        await seams.seam_reconcile_not_started(first["receipt"])
        await seams.seam_reconcile_diverged()
        await seams.seam_eviction()
    finally:
        for pid in list(seams.created):
            await seams.cleanup(pid)
    report = {
        "revision": head,
        "sketchup_version": ping.get("sketchup_version"),
        "ruby_version": ping.get("ruby_version"),
        "unit": UNIT,
        "elapsed_s": round(time.time() - started, 2),
        "cases": seams.results,
        "passed": sum(1 for c in seams.results if c.get("pass")),
        "total": len(seams.results),
    }
    text = json.dumps(report, indent=2)
    print(text)
    if report_path:
        Path(report_path).write_text(text, encoding="utf-8")
    return report


def main() -> int:
    parser = argparse.ArgumentParser(description="B2 recovery seams")
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
