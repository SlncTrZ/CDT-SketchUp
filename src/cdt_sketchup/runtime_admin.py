"""Offline-owned operator binding and read-only native journal reconciliation."""
from __future__ import annotations

import argparse
import asyncio
import json
from pathlib import Path

from .bridge import read_bridge_token
from .runtime_binding import RuntimeBinding
from .runtime_transport import RemoteSketchUpTransport, RuntimeTransportError


async def administer(args) -> dict:
    binding = RuntimeBinding(Path(args.state_file), allow_missing=args.action == "bind")
    transport = None
    try:
        if args.action == "inspect":
            return {"generation": binding.generation, "pending": binding.pending}
        transport = RemoteSketchUpTransport(
            args.endpoint, read_bridge_token(Path(args.token_file))
        )
        health = await transport.health()
        if health.get("generation") != args.generation:
            raise RuntimeTransportError("Observed generation differs from explicit operator selection")
        ping = await transport.call("ping", expected_generation=args.generation)
        if not isinstance(ping, dict) or ping.get("live_model") is not True:
            raise RuntimeTransportError("Native model is not ready")
        if args.action == "bind":
            if binding.pending is not None:
                raise RuntimeTransportError("Pending completion must be reconciled before rebind")
            document = await transport.call("document_info", expected_generation=args.generation)
            if not isinstance(document, dict) or document.get("ok") is False:
                raise RuntimeTransportError("Native document readback failed")
            binding.save(args.generation, None)
            return {"generation": args.generation, "pending": None, "native_readback": True}
        pending = binding.pending
        mutation = pending.get("mutation") if isinstance(pending, dict) else None
        if not isinstance(mutation, dict) or pending.get("op") != "execute_geometry":
            raise RuntimeTransportError("No journal-bound operation; external effects need manual review")
        proof = await transport.call(
            "mutation_reconcile", {"mutation_id": mutation["id"]},
            expected_generation=args.generation,
        )
        receipt = proof.get("receipt") if isinstance(proof, dict) else None
        identity = receipt.get("mutation") if isinstance(receipt, dict) else None
        terminal = (
            proof.get("status") == proof.get("journal") == "committed"
            or (proof.get("status") == proof.get("journal") == "rolled_back"
                and isinstance(receipt, dict) and receipt.get("rollback_verified") is True)
        ) if isinstance(proof, dict) else False
        if not terminal or identity != {**mutation, "replayed": False}:
            raise RuntimeTransportError("Native journal cannot prove this exact pending request")
        binding.save(args.generation, None)
        return {"generation": args.generation, "pending": None, "reconciliation": proof}
    finally:
        if transport is not None:
            await transport.close()
        binding.close()


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="action", required=True)
    for name in ("inspect", "bind", "recover"):
        cmd = sub.add_parser(name)
        cmd.add_argument("--state-file", required=True)
        if name != "inspect":
            cmd.add_argument("--endpoint", required=True)
            cmd.add_argument("--token-file", required=True)
            cmd.add_argument("--generation", required=True)
    print(json.dumps(asyncio.run(administer(parser.parse_args()))))


if __name__ == "__main__":
    main()
