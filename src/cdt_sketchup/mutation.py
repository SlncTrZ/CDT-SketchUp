"""Stable mutation identity — retry-safe envelopes for strict bridge mutations.
Wing: code | Topic: sketchup_recovery | Updated: 2026-09-19
"""

from __future__ import annotations

import hashlib
import json
import math
import re
import secrets
import struct
from typing import Any, Mapping

_MUTATION_ID_RE = re.compile(r"\A[0-9a-f]{32}\Z")


def new_mutation_id() -> str:
    """Generate one stable logical-mutation identity (hex32)."""
    return secrets.token_hex(16)


def valid_mutation_id(value: object) -> bool:
    """Check the mutation identity shape without raising."""
    return isinstance(value, str) and _MUTATION_ID_RE.match(value) is not None


def _utf8_hex(value: str) -> str:
    """Encode text as lowercase UTF-8 hex for cross-runtime byte parity."""
    return value.encode("utf-8").hex()


def _canonical_node(node: Any) -> list[Any]:
    """Return an unambiguous typed tree containing ASCII-only scalar data.

    Float values are bound by their IEEE-754 binary64 bits, avoiding any
    dependency on Python/Ruby JSON number formatting. Signed zero is normalized
    because +0.0 and -0.0 are the same logical CAD numeric value.
    """
    if node is None:
        return ["n"]
    if isinstance(node, bool):
        return ["b", "1" if node else "0"]
    if isinstance(node, int):
        return ["i", str(node)]
    if isinstance(node, float):
        if not math.isfinite(node):
            raise ValueError("canonical mutation values must be finite")
        value = 0.0 if node == 0.0 else node
        return ["f", struct.pack(">d", value).hex()]
    if isinstance(node, str):
        return ["s", _utf8_hex(node)]
    if isinstance(node, list):
        return ["a", [_canonical_node(item) for item in node]]
    if isinstance(node, Mapping):
        entries: list[list[Any]] = []
        for key, value in node.items():
            if not isinstance(key, str):
                raise TypeError("canonical mutation object keys must be strings")
            entries.append([_utf8_hex(key), _canonical_node(value)])
        entries.sort(key=lambda item: item[0])
        return ["o", entries]
    raise TypeError(f"unsupported canonical mutation value: {type(node).__name__}")


def canonical_json(node: Any) -> str:
    """Encode deterministic typed canonical bytes for mutation hashing.

    The output is valid JSON but deliberately does not preserve the original
    JSON surface form. Every value carries an explicit type tag, strings/keys
    are represented by UTF-8 bytes, and floats use IEEE-754 binary64 hex. This
    makes the hash independent of runtime-specific JSON formatting.
    """
    return json.dumps(
        _canonical_node(node),
        separators=(",", ":"),
        ensure_ascii=True,
        allow_nan=False,
    )


def _canonical_request(action: str, body: Mapping[str, Any]) -> dict[str, Any]:
    """Project every logical execute_geometry field except mutation metadata.

    Routing and stale-state guards are operation semantics: target_context,
    if_context and if_match therefore participate in the same identity as the
    action payload. Future execute_geometry fields are bound automatically
    unless they are explicitly transport-only mutation metadata.
    """
    request: dict[str, Any] = {"action": action}
    for key, value in body.items():
        if key in {"action", "mutation"}:
            continue
        request[key] = value
    return request


def request_hash(action: str, body: Mapping[str, Any]) -> str:
    """Bind one logical mutation to its canonical public request bytes."""
    digest = hashlib.sha256(
        canonical_json(_canonical_request(action, body)).encode("ascii")
    )
    return digest.hexdigest()


def mutation_envelope(mutation_id: str, body: Mapping[str, Any]) -> dict[str, Any]:
    """Build the mutation envelope for an execute_geometry payload body."""
    action = body.get("action")
    if not valid_mutation_id(mutation_id):
        raise ValueError("mutation_id must be lowercase hex32")
    if not isinstance(action, str) or not action:
        raise ValueError("body action must be a non-empty string")
    return {
        "id": mutation_id,
        "request_hash": request_hash(action, body),
    }
