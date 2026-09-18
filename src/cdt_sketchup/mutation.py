"""Stable mutation identity — retry-safe envelopes for strict bridge mutations.
Wing: code | Topic: sketchup_recovery | Updated: 2026-09-18
"""

from __future__ import annotations

import hashlib
import json
import re
import secrets
from typing import Any, Mapping

_MUTATION_ID_RE = re.compile(r"\A[0-9a-f]{32}\Z")


def new_mutation_id() -> str:
    """Generate one stable logical-mutation identity (hex32)."""
    return secrets.token_hex(16)


def valid_mutation_id(value: object) -> bool:
    """Check the mutation identity shape without raising."""
    return isinstance(value, str) and _MUTATION_ID_RE.match(value) is not None


def canonical_json(node: Any) -> str:
    """Encode canonical JSON: recursive key sort, compact separators, raw UTF-8.

    Key order is the only normalization; numeric formatting follows the
    platform shortest-roundtrip repr on both Python and Ruby sides, and all
    envelope keys are ASCII so ordering agrees across runtimes.
    """
    return json.dumps(node, sort_keys=True, separators=(",", ":"),
                      ensure_ascii=False, allow_nan=False)


def _canonical_request(action: str, body: Mapping[str, Any]) -> dict[str, Any]:
    """Project the mutation-bound subset of an execute_geometry payload.

    target_context and if_context are dispatch-time routing/caller guards
    consumed before the inner execution sees them, so both runtimes exclude
    them to keep the outer claim and the inner execution on one hash.
    """
    request: dict[str, Any] = {"action": action}
    for key in ("params", "expect", "unit", "coordinate_space", "if_match"):
        if key in body:
            request[key] = body[key]
    return request


def request_hash(action: str, body: Mapping[str, Any]) -> str:
    """Bind one logical mutation to its canonical public request bytes."""
    digest = hashlib.sha256(canonical_json(
        _canonical_request(action, body)).encode("utf-8"))
    return digest.hexdigest()


def mutation_envelope(mutation_id: str, body: Mapping[str, Any]) -> dict[str, Any]:
    """Build the mutation envelope for an execute_geometry payload body."""
    action = body.get("action")
    if not valid_mutation_id(mutation_id):
        raise ValueError("mutation_id must be lowercase hex32")
    if not isinstance(action, str) or not action:
        raise ValueError("body action must be a non-empty string")
    return {"id": mutation_id,
            "request_hash": request_hash(action, body)}
