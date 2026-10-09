"""Remote SketchUp runtime adapter — S2 provider-side port over transport.

Wing: code | Topic: sketchup_runtime_transport | Updated: 2026-10-07 18:35

No CAD semantics: forwards typed bridge commands over SketchUpRuntimeTransport.
Uncertain completion propagates (no blind replay); callers reconcile via
mutation_reconcile / operation_id, same as the local path.
"""

from __future__ import annotations

import asyncio
from pathlib import Path
from typing import Any

from .bridge import BridgeClient
from .runtime_transport import (
    MUTATION_OPS,
    RuntimeAuthError,
    RuntimeBridgeProtocolError,
    RuntimeGenerationMismatchError,
    RuntimeOpRefusedError,
    RuntimeUnavailableError,
    RuntimeUncertainError,
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
        state_file: Path | None = None,
    ) -> None:
        from .runtime_transport import SketchUpRuntimeTransport as _T

        if not isinstance(transport, _T):
            raise TypeError("RemoteSketchUpRuntimeAdapter requires a SketchUpRuntimeTransport")
        self._transport: SketchUpRuntimeTransport = transport
        self._expected_generation = expected_generation
        self._default_deadline_ms = check_deadline(default_deadline_ms)
        from .runtime_binding import RuntimeBinding
        self._binding = RuntimeBinding(state_file) if state_file else None
        self._writer_lock = asyncio.Lock()
        if self._binding:
            self._expected_generation = self._binding.generation

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
        if self._binding:
            raise ValueError("Durable binding requires the offline operator command")
        self._expected_generation = value

    async def call(self, command: str, params: dict[str, Any] | None = None) -> Any:
        body = dict(params or {})
        if self._binding is None or command not in MUTATION_OPS:
            return await self._transport.call(
                command, body, deadline_ms=self._default_deadline_ms,
                expected_generation=self._expected_generation,
            )
        async with self._writer_lock:
            if self._binding.pending is not None:
                raise RuntimeUncertainError("Previous operation requires reconciliation; writes fenced")
            pending = {"op": command, "mutation": body.get("mutation")}
            self._binding.save(self._expected_generation, pending)
            try:
                result = await self._transport.call(
                    command, body, deadline_ms=self._default_deadline_ms,
                    expected_generation=self._expected_generation,
                )
            except RuntimeBridgeProtocolError as exc:
                if str(exc).partition(":")[0] in {"unknown_commit", "mutation_unknown"}:
                    raise RuntimeUncertainError("Native operation remains uncertain") from exc
                self._complete()
                raise
            except (RuntimeAuthError, RuntimeGenerationMismatchError,
                    RuntimeOpRefusedError, RuntimeUnavailableError):
                self._complete()
                raise
            except BaseException:
                # Cancellation, process death and unknown failures retain the persisted fence.
                raise
            if (isinstance(result, dict) and result.get("ok") is False
                    and result.get("error", {}).get("kind") in {"unknown_commit", "mutation_unknown"}):
                raise RuntimeUncertainError("Native operation remains uncertain")
            self._complete()
            return result

    def _complete(self) -> None:
        try:
            self._binding.save(self._expected_generation, None)
        except OSError as exc:
            raise RuntimeUncertainError("Cannot persist completion; writes remain fenced") from exc

    async def close(self) -> None:
        try:
            await self._transport.close()
        finally:
            if self._binding:
                self._binding.close()

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
            "writes_fenced": bool(self._binding and self._binding.pending),
        }

    @property
    def _is_mutation(self) -> bool:
        return False  # per-call MUTATION_OPS check lives in transport tests

    def is_mutation_op(self, command: str) -> bool:
        return command in MUTATION_OPS
