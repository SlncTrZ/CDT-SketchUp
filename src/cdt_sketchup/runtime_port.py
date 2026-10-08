"""SketchUp Runtime Port — provider/execution seam (S1).

Wing: code | Topic: sketchup_runtime_port | Updated: 2026-10-07 18:30

Structural seam between the MCP provider layer (server.py) and SketchUp
execution. The default implementation delegates 1:1 to the existing
loopback BridgeClient, so PID/fingerprint/recovery/timeout semantics are
untouched. Remote execution reuses the same port behind RuntimeTransport.
"""

from __future__ import annotations

from typing import Any, Protocol, runtime_checkable

from .bridge import BridgeClient


@runtime_checkable
class SketchUpRuntimePort(Protocol):
    """Provider-facing SketchUp execution seam (read + typed dispatch)."""

    @property
    def backend(self) -> BridgeClient:
        """Return the wrapped local bridge (controlled escape hatch)."""
        ...

    async def call(self, command: str, params: dict[str, Any] | None = None) -> Any:
        """Dispatch one typed bridge command (same semantics as BridgeClient)."""
        ...

    async def probe(self) -> dict[str, Any]:
        """Non-throwing observed runtime probe (same semantics as BridgeClient)."""
        ...

    def health(self) -> dict[str, Any]:
        """Read-only adapter liveness without CAD mutation."""
        ...
