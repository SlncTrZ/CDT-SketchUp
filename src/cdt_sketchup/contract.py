"""Provider Contract — Stable identity, status, help, and capability truth.
Wing: code | Topic: sketchup_semantic_loop | Updated: 2026-09-11 19:55
"""

from __future__ import annotations

from typing import Any

from .capabilities import TOOL_NAMES, build_capability_payload

PROVIDER_ID = "cdt_sketchup"
PROVIDER_NAME = "CDT-SketchUp"
PROVIDER_VERSION = "0.1.0"
CONTRACT_VERSION = "0.22"
COMMON_CONTRACT_VERSION = "0.1"
SKETCHUP_EXTENSION_VERSION = "0.1"

_TOOL_NAMES = TOOL_NAMES


def build_help() -> dict[str, Any]:
    """Return static provider metadata without claiming a live SketchUp runtime."""
    return {
        "provider_id": PROVIDER_ID,
        "provider_name": PROVIDER_NAME,
        "provider_version": PROVIDER_VERSION,
        "contract_version": CONTRACT_VERSION,
        "common_contract_version": COMMON_CONTRACT_VERSION,
        "provider_extension_version": SKETCHUP_EXTENSION_VERSION,
        "transport": "streamable-http",
        "tools": list(_TOOL_NAMES),
        "safety": {
            "arbitrary_ruby_execution": False,
            "live_mutations_require_bridge": True,
            "bridge_scope": "loopback",
        },
    }


def build_status(
    *,
    bridge_connected: bool,
    live_model: bool,
    detail: str | None = None,
    runtime: dict[str, Any] | None = None,
) -> dict[str, Any]:
    """Build truthful runtime status from an observed bridge probe."""
    healthy = bridge_connected and live_model
    result: dict[str, Any] = {
        "provider_id": PROVIDER_ID,
        "status": "ready" if healthy else "degraded",
        "bridge": {"connected": bridge_connected},
        "runtime": {"live_model": live_model},
    }
    if runtime:
        result["runtime"].update(runtime)
    if detail:
        result["detail"] = detail
    return result



def build_capabilities(
    *,
    bridge_connected: bool,
    live_model: bool,
    runtime: dict[str, Any] | None = None,
) -> dict[str, Any]:
    """Return capability metadata v2 merged with fail-closed observed live state."""
    return build_capability_payload(
        provider_id=PROVIDER_ID,
        bridge_connected=bridge_connected,
        live_model=live_model,
        runtime=runtime,
    )
