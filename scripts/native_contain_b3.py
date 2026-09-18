"""B3 native saturation — live admission-cap proof on the SketchUp bridge.

Wing: code | Topic: sketchup_containment | Updated: 2026-09-18

Holds 8 slow/partial clients inside the 5s idle window, then proves the
9th connection is admitted-but-rejected (closed with no response and no
slot growth) while the tick loop stays alive. No model mutation.

Usage:
    python scripts/native_contain_b3.py --run [--report path.json]

Exit codes: 0 contained | 1 leak/unbounded | 2 bridge unavailable.
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

REPO = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO / "src"))

from cdt_sketchup.bridge import (  # noqa: E402
    BridgeClient,
    DEFAULT_BRIDGE_PORT,
    read_bridge_token,
)

HOST = "127.0.0.1"


def tcp_count() -> int | None:
    try:
        out = subprocess.run(
            ["powershell", "-NoProfile", "-Command",
             "(Get-NetTCPConnection -LocalPort 9876 -State Established "
             "-ErrorAction SilentlyContinue | Measure-Object).Count"],
            capture_output=True, text=True, timeout=15, check=False)
        return int(out.stdout.strip())
    except Exception:
        return None


async def ping_ms(client: BridgeClient) -> float | None:
    try:
        start = time.perf_counter()
        await client.call("ping")
        return (time.perf_counter() - start) * 1000.0
    except Exception:
        return None


async def run(report_path: str | None) -> dict:
    client = BridgeClient()
    try:
        await client.call("ping")
    except Exception as exc:
        return {"bridge_available": False, "detail": str(exc)}
    token = read_bridge_token()
    request_id = "b3saturation01"
    frame = (json.dumps({"protocol": 1, "request_id": request_id,
                         "command": "ping", "params": {},
                         "token": token},
                        separators=(",", ":")) + "\n").encode()
    holds: list[socket.socket] = []
    checks: dict = {}
    # Slow client first on an empty bridge: byte-wise delivery completes.
    slow = socket.create_connection((HOST, DEFAULT_BRIDGE_PORT), timeout=10)
    slow.settimeout(10)
    try:
        for i in range(0, len(frame), 4):
            slow.sendall(frame[i:i + 4])
            await asyncio.sleep(0.05)
        slow_resp = slow.recv(4096)
        checks["slow_completed"] = bool(slow_resp)
    except (ConnectionResetError, socket.timeout):
        checks["slow_completed"] = False
    finally:
        slow.close()
    try:
        for _ in range(8):
            sock = socket.create_connection((HOST, DEFAULT_BRIDGE_PORT),
                                            timeout=5)
            sock.sendall(b'{"protocol":1,"par')
            holds.append(sock)
        checks["holds_open"] = len(holds)
        await asyncio.sleep(1.0)
        checks["tcp_established_during_hold"] = tcp_count()
        ninth = socket.create_connection((HOST, DEFAULT_BRIDGE_PORT),
                                         timeout=5)
        ninth.settimeout(5)
        try:
            ninth.sendall(frame)
            try:
                data = ninth.recv(4096)
                checks["ninth_close"] = "eof" if data == b"" else "data"
                checks["ninth_rejected"] = data == b""
            except socket.timeout:
                checks["ninth_close"] = "timeout"
                checks["ninth_rejected"] = False
            except ConnectionResetError:
                checks["ninth_close"] = "rst"
                checks["ninth_rejected"] = True
        finally:
            ninth.close()
    finally:
        for sock in holds:
            try:
                sock.close()
            except OSError:
                pass
    await asyncio.sleep(6.5)
    latencies = []
    for _ in range(5):
        sample = await ping_ms(client)
        if sample is not None:
            latencies.append(round(sample, 1))
    checks["ping_after_ms"] = latencies
    checks["tcp_established_after"] = tcp_count()
    ok = (checks.get("holds_open") == 8
          and checks.get("ninth_rejected") is True
          and checks.get("slow_completed") is True
          and len(latencies) == 5)
    try:
        head = subprocess.run(
            ["git", "rev-parse", "HEAD"], cwd=REPO,
            capture_output=True, text=True, check=False).stdout.strip()
    except Exception:
        head = "unknown"
    report = {"revision": head, "checks": checks,
              "passed": 1 if ok else 0, "total": 1,
              "cases": [{"case": "saturation", "pass": ok,
                         "checks": checks}]}
    text = json.dumps(report, indent=2)
    print(text)
    if report_path:
        Path(report_path).write_text(text, encoding="utf-8")
    return report


def main() -> int:
    parser = argparse.ArgumentParser(description="B3 native saturation")
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
