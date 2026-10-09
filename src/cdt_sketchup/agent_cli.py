"""Attach-only workstation agent; never starts, closes or kills SketchUp."""
from __future__ import annotations

import argparse
import json
import os
import signal
import threading
from pathlib import Path

from .bridge import BridgeClient, read_bridge_token
from .local_runtime import LocalSketchUpRuntimeAdapter
from .workstation_agent import WorkstationAgentConfig, WorkstationSketchUpRuntimeAgent


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--token-file", type=Path, required=True)
    parser.add_argument("--stop-file", type=Path, required=True)
    parser.add_argument("--metadata-file", type=Path, required=True)
    args = parser.parse_args()
    if args.stop_file.exists():
        parser.error("Stop marker exists; remove it explicitly before starting")
    token = read_bridge_token(args.token_file)
    agent = WorkstationSketchUpRuntimeAgent(
        LocalSketchUpRuntimeAdapter(BridgeClient(timeout=60)),
        WorkstationAgentConfig(port=args.port, auth_token=token),
    )
    stop = threading.Event()
    for sig in (signal.SIGINT, signal.SIGTERM):
        signal.signal(sig, lambda *_: stop.set())
    agent.start()
    try:
        metadata = {"agent_pid": os.getpid(), "generation": agent.generation, "port": args.port}
        args.metadata_file.parent.mkdir(parents=True, exist_ok=True)
        temp = args.metadata_file.with_suffix(".tmp")
        temp.write_text(json.dumps(metadata) + "\n", encoding="utf-8")
        temp.replace(args.metadata_file)
        print(json.dumps(metadata), flush=True)
        while not stop.wait(.2):
            if args.stop_file.exists():
                break
    finally:
        agent.stop()


if __name__ == "__main__":
    main()
