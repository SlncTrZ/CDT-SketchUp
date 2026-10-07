"""Local SketchUp runtime adapter — S1 single-host seam over BridgeClient.

Wing: code | Topic: sketchup_runtime_port | Updated: 2026-10-07 18:30

1:1 delegation: no new validation, no retries, no semantic change. The Ruby
loopback bridge (127.0.0.1 + per-user token) stays the only native path.
"""

from __future__ import annotations

from typing import Any

from .bridge import BridgeClient
from .runtime_port import SketchUpRuntimePort


class LocalSketchUpRuntimeAdapter(SketchUpRuntimePort):
    """Single-host adapter wrapping exactly one BridgeClient."""

    def __init__(self, bridge: BridgeClient) -> None:
        if not isinstance(bridge, BridgeClient):
            raise TypeError("LocalSketchUpRuntimeAdapter requires a BridgeClient")
        self._bridge = bridge

    @property
    def backend(self) -> BridgeClient:
        return self._bridge

    async def call(self, command: str, params: dict[str, Any] | None = None) -> Any:
        return await self._bridge.call(command, params)

    async def probe(self) -> dict[str, Any]:
        return await self._bridge.probe()

    def health(self) -> dict[str, Any]:
        return {"adapter": "local", "bridge": "loopback", "available": True}
