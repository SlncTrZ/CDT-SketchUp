"""Remote SketchUp runtime adapter — S2 provider-side port over transport.

Wing: code | Topic: sketchup_runtime_transport | Updated: 2026-10-07 18:35

No CAD semantics: forwards typed bridge commands over SketchUpRuntimeTransport.
Uncertain completion propagates (no blind replay); callers reconcile via
mutation_reconcile / operation_id, same as the local path.
"""

from __future__ import annotations

from typing import Any

from .bridge import BridgeClient
from .runtime_transport import (
    MUTATION_OPS,
    SketchUpRuntimeTransport,
    check_deadline,
)


class RemoteSketchUpRuntimeAdapter:
    """Provider-side SketchUpRuntimePort implemented over a transport."""

    def __init__(
        self,
        transport: SketchUpRuntimeTransport,
        *,
        expected_generation: str | None = None,
        default_deadline_ms: int = 60_000,
    ) -> None:
        from .runtime_transport import SketchUpRuntimeTransport as _T

        if not isinstance(transport, _T):
            raise TypeError("RemoteSketchUpRuntimeAdapter requires a SketchUpRuntimeTransport")
        self._transport: SketchUpRuntimeTransport = transport
        self._expected_generation = expected_generation
        self._default_deadline_ms = check_deadline(default_deadline_ms)

    @property
    def backend(self) -> BridgeClient:
        raise RuntimeError(
            "remote adapter has no in-process bridge; native execution lives in the agent process"
        )

    @property
    def expected_generation(self) -> str | None:
        return self._expected_generation

    def pin_generation(self, generation: str) -> None:
        value = str(generation or "").strip()
        if not value:
            raise ValueError("generation pin must be non-empty")
        self._expected_generation = value

    async def call(self, command: str, params: dict[str, Any] | None = None) -> Any:
        # Uncertainty propagates unchanged: reads may re-query, mutations
        # must reconcile via mutation_reconcile, never blind-replay.
        return await self._transport.call(
            command,
            dict(params or {}),
            deadline_ms=self._default_deadline_ms,
            expected_generation=self._expected_generation,
        )

    async def probe(self) -> dict[str, Any]:
        try:
            result = await self.call("ping")
        except Exception as exc:
            return {"bridge_connected": False, "live_model": False, "detail": str(exc)}
        if not isinstance(result, dict):
            return {"bridge_connected": True, "live_model": False, "detail": "invalid ping result"}
        return {
            "bridge_connected": True,
            "live_model": bool(result.get("live_model")),
            "detail": result.get("detail"),
            "runtime": {
                key: result[key] for key in ("sketchup_version", "ruby_version") if key in result
            },
        }

    def health(self) -> dict[str, Any]:
        return {
            "adapter": "remote",
            "bridge": "loopback-via-agent",
            "available": True,
            "expected_generation": self._expected_generation,
        }

    @property
    def _is_mutation(self) -> bool:
        return False  # per-call MUTATION_OPS check lives in transport tests

    def is_mutation_op(self, command: str) -> bool:
        return command in MUTATION_OPS
