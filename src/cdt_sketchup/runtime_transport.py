"""SketchUp RuntimeTransport — provider/workstation boundary (S2).

Wing: code | Topic: sketchup_runtime_transport | Updated: 2026-10-07 22:21

Typed bounded request/response between the MCP provider process and the
workstation-side SketchUp runtime agent. Two implementations, one contract:

- LocalSketchUpTransport — in-process delegate over a SketchUpRuntimePort
  (S1 adapter). Default single-host path; behavior unchanged.
- RemoteSketchUpTransport — loopback HTTP client to a
  WorkstationSketchUpRuntimeAgent. Proves the split-process path on one
  host; split-host deploy is out of scope (non-loopback refused).

No CAD semantics here: the only vocabulary is the ALLOWED_OPS allowlist of
bridge command names. Payloads are opaque JSON primitives. Context /
fingerprint / journal / reconcile semantics stay inside the reused Ruby
bridge + provider guards.

Timeout rule: any timeout/disconnect once dispatch may have started is
completion-unknown (RuntimeUncertainError). Only pre-dispatch failures
(unresolvable host, refused connection, refused op/deadline/size) are
clean errors. Blind replay stays forbidden — callers reconcile.
"""

from __future__ import annotations

import asyncio
import hmac
import json
import socket
import threading
import urllib.error
import urllib.request
from abc import ABC, abstractmethod
from dataclasses import dataclass, field
from typing import Any
from uuid import uuid4

_LOOPBACK_HOSTS = {"127.0.0.1", "localhost", "::1"}

ALLOWED_OPS: frozenset[str] = frozenset(
    {
        "ping",
        "document_info",
        "object_list",
        "object_get",
        "get_entity_state",
        "execute_geometry",
        "mutation_reconcile",
        "measure_distance",
        "query_topology",
        "query_overlap",
        "asset_list",
        "texture_list",
        "material_info",
        "camera_get",
        "definition_info",
        "create_edge",
        "create_face",
        "selection_by_ids",
        "selection_clear",
        "object_delete",
        "push_pull_face",
        "component_create_box",
        "tag_create",
        "material_create",
        "model_save",
        "model_save_as",
        "model_open",
        "model_export",
        "model_list",
        "artifact_seal",
        "artifact_verify",
        "integrity_report",
    }
)

#: Ops that may mutate model/document state and are therefore uncertain
#: after dispatch loss. Reads stay clean-retryable at the transport layer.
MUTATION_OPS: frozenset[str] = frozenset(
    {
        "execute_geometry",
        "create_edge",
        "create_face",
        "object_delete",
        "push_pull_face",
        "component_create_box",
        "tag_create",
        "material_create",
        "selection_by_ids",
        "selection_clear",
        "model_save",
        "model_save_as",
        "model_open",
        "model_export",
    }
)

MAX_REQUEST_BYTES = 256 * 1024
MAX_RESPONSE_BYTES = 4 * 1024 * 1024
DEFAULT_DEADLINE_MS = 60_000
MAX_DEADLINE_MS = 120_000
MIN_DEADLINE_MS = 100


class RuntimeTransportError(RuntimeError):
    """Base class for typed runtime-boundary failures."""


class RuntimeBridgeProtocolError(RuntimeTransportError):
    """A complete native bridge rejection; preserves its public error kind."""


class RuntimeUnavailableError(RuntimeTransportError):
    """Endpoint unreachable before dispatch — safe to report, never success."""


class RuntimeAuthError(RuntimeTransportError):
    """Missing/rejected credential. Not retryable without operator action."""


class RuntimeGenerationMismatchError(RuntimeTransportError):
    """Stale runtime generation — result discarded before trust."""


class RuntimeUncertainError(RuntimeTransportError):
    """Timeout/disconnect after dispatch — completion unknown, no replay."""


class RuntimeOpRefusedError(ValueError):
    """Unknown/refused op rejected before dispatch — no effect."""


def check_op(op: str) -> str:
    name = str(op or "").strip()
    if name not in ALLOWED_OPS:
        raise RuntimeOpRefusedError(f"runtime op refused (not in allowlist): {name!r}")
    return name


def check_deadline(deadline_ms: int | None) -> int:
    value = DEFAULT_DEADLINE_MS if deadline_ms is None else int(deadline_ms)
    if not MIN_DEADLINE_MS <= value <= MAX_DEADLINE_MS:
        raise ValueError(
            f"deadline_ms must be within [{MIN_DEADLINE_MS}, {MAX_DEADLINE_MS}], got {value}"
        )
    return value


def check_request_size(payload: dict[str, Any]) -> dict[str, Any]:
    raw = json.dumps(payload, separators=(",", ":")).encode("utf-8")
    if len(raw) > MAX_REQUEST_BYTES:
        raise RuntimeOpRefusedError(
            f"runtime request oversized: {len(raw)} bytes > {MAX_REQUEST_BYTES}"
        )
    return payload


@dataclass(frozen=True)
class RuntimeRequest:
    op: str
    params: dict[str, Any] | None = None
    deadline_ms: int = DEFAULT_DEADLINE_MS
    expected_generation: str | None = None
    request_id: str = field(default_factory=lambda: uuid4().hex)

    def to_wire(self) -> dict[str, Any]:
        return check_request_size(
            {
                "request_id": self.request_id,
                "op": check_op(self.op),
                "params": dict(self.params or {}),
                "deadline_ms": check_deadline(self.deadline_ms),
                "expected_generation": self.expected_generation,
            }
        )


@dataclass(frozen=True)
class RuntimeResponse:
    ok: bool
    result: Any = None
    error_code: str = "ok"
    error_message: str = ""
    generation: str = "unbound"
    completion_unknown: bool = False

    @classmethod
    def from_wire(cls, payload: dict[str, Any]) -> RuntimeResponse:
        if not isinstance(payload, dict):
            raise RuntimeTransportError("malformed runtime response (not an object)")
        return cls(
            ok=bool(payload.get("ok", False)),
            result=payload.get("result"),
            error_code=str(payload.get("error_code") or ("ok" if payload.get("ok") else "error")),
            error_message=str(payload.get("error_message") or ""),
            generation=str(payload.get("generation") or "unbound"),
            completion_unknown=bool(payload.get("completion_unknown", False)),
        )


def raise_for_response(op: str, response: RuntimeResponse) -> Any:
    if response.ok:
        return response.result
    code = response.error_code
    message = response.error_message or f"runtime op {op!r} failed: {code}"
    if code in {"unauthorized", "forbidden"}:
        raise RuntimeAuthError(message)
    if code in {"generation_mismatch", "stale_generation"}:
        raise RuntimeGenerationMismatchError(message)
    if code in {"unknown_op", "op_refused", "oversized", "bad_request"}:
        raise RuntimeOpRefusedError(message)
    if code == "bridge_protocol_error":
        raise RuntimeBridgeProtocolError(message)
    if code in {"dispatch_timeout_uncertain", "uncertain"} or response.completion_unknown:
        raise RuntimeUncertainError(message)
    if code in {"dispatch_timeout_clean", "timeout_clean"}:
        raise TimeoutError(message)
    if code == "unavailable":
        raise RuntimeUnavailableError(message)
    raise RuntimeTransportError(f"{message} [{code}]")


class SketchUpRuntimeTransport(ABC):
    """Typed provider -> runtime boundary. One op call, one verified response."""

    @abstractmethod
    async def call(
        self,
        op: str,
        params: dict[str, Any] | None = None,
        *,
        deadline_ms: int | None = None,
        expected_generation: str | None = None,
    ) -> Any: ...

    @abstractmethod
    async def health(self) -> dict[str, Any]: ...

    @abstractmethod
    async def close(self) -> None: ...


class LocalSketchUpTransport(SketchUpRuntimeTransport):
    """In-process delegate over an S1 SketchUpRuntimePort (default path)."""

    def __init__(self, runtime: Any, *, generation: str = "local") -> None:
        from .runtime_port import SketchUpRuntimePort

        if not isinstance(runtime, SketchUpRuntimePort):
            raise TypeError("LocalSketchUpTransport requires a SketchUpRuntimePort")
        self._runtime = runtime
        self._generation = str(generation or "local")
        self._closed = False

    @property
    def generation(self) -> str:
        return self._generation

    async def call(
        self,
        op: str,
        params: dict[str, Any] | None = None,
        *,
        deadline_ms: int | None = None,
        expected_generation: str | None = None,
    ) -> Any:
        if self._closed:
            raise RuntimeUnavailableError("local runtime transport is closed")
        name = check_op(op)
        bound = check_deadline(deadline_ms)
        RuntimeRequest(op=name, params=dict(params or {}), deadline_ms=bound,
                       expected_generation=expected_generation).to_wire()
        if expected_generation is not None and expected_generation != self._generation:
            raise RuntimeGenerationMismatchError(
                f"runtime generation mismatch: expected {expected_generation!r}, "
                f"local generation is {self._generation!r}; result discarded"
            )
        try:
            invoked = self._runtime.call(name, params)
            result = await asyncio.wait_for(invoked, timeout=bound / 1000.0)
        except TimeoutError as exc:
            raise RuntimeUncertainError(
                f"local runtime op {name!r} exceeded {bound}ms after dispatch; "
                "completion is unknown, blind retry is forbidden"
            ) from exc
        return result

    async def health(self) -> dict[str, Any]:
        if self._closed:
            raise RuntimeUnavailableError("local runtime transport is closed")
        return {
            "transport": "local",
            "reachable": True,
            "generation": self._generation,
            "runtime": self._runtime.health(),
        }

    async def close(self) -> None:
        self._closed = True


def _require_loopback(url: str, *, allow_remote: bool = False) -> str:
    from urllib.parse import urlparse

    host = (urlparse(url).hostname or "").lower()
    if host not in _LOOPBACK_HOSTS and not allow_remote:
        raise RuntimeOpRefusedError(
            f"refusing non-loopback runtime endpoint {host!r}; split-host out of scope"
        )
    return url.rstrip("/")


def _no_proxy_opener() -> urllib.request.OpenerDirector:
    return urllib.request.build_opener(urllib.request.ProxyHandler({}))


def _preflight_connect(host: str, port: int, timeout_s: float) -> str:
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    sock.settimeout(max(0.2, min(2.0, timeout_s)))
    try:
        sock.connect((host, port))
        return "open"
    except ConnectionRefusedError:
        return "refused"
    except OSError:
        return "filtered"
    finally:
        try:
            sock.close()
        except OSError:
            pass


def _endpoint_host_port(base_url: str) -> tuple[str, int]:
    from urllib.parse import urlparse

    parts = urlparse(base_url)
    return (parts.hostname or "127.0.0.1", int(parts.port or 80))


def _post_json(url: str, payload: dict[str, Any], *, token: str, timeout_s: float) -> tuple[int, bytes]:
    raw = json.dumps(payload, separators=(",", ":")).encode("utf-8")
    request = urllib.request.Request(
        url,
        data=raw,
        method="POST",
        headers={
            "Content-Type": "application/json",
            "Content-Length": str(len(raw)),
            "Authorization": f"Bearer {token}",
        },
    )
    try:
        with _no_proxy_opener().open(request, timeout=timeout_s) as response:
            return int(response.status or 200), response.read(MAX_RESPONSE_BYTES + 1)
    except urllib.error.HTTPError as exc:
        return int(exc.code or 500), exc.read(MAX_RESPONSE_BYTES + 1)


def _get_json(url: str, *, token: str, timeout_s: float) -> tuple[int, bytes]:
    request = urllib.request.Request(url, method="GET", headers={"Authorization": f"Bearer {token}"})
    try:
        with _no_proxy_opener().open(request, timeout=timeout_s) as response:
            return int(response.status or 200), response.read(MAX_RESPONSE_BYTES + 1)
    except urllib.error.HTTPError as exc:
        return int(exc.code or 500), exc.read(MAX_RESPONSE_BYTES + 1)


def _decode_response(status: int, raw: bytes, *, op: str) -> RuntimeResponse:
    if len(raw) > MAX_RESPONSE_BYTES:
        raise RuntimeTransportError("runtime response oversized; discarded without trust")
    if status in (401, 403):
        raise RuntimeAuthError(f"runtime endpoint rejected credentials for op {op!r} (http {status})")
    if status == 404:
        raise RuntimeUnavailableError(f"runtime endpoint has no route for op {op!r}")
    if status >= 500:
        raise RuntimeUncertainError(
            f"runtime endpoint error {status} for op {op!r} after dispatch; "
            "completion is unknown, blind retry is forbidden"
        )
    if status >= 400:
        raise RuntimeTransportError(f"runtime endpoint http {status} for op {op!r}")
    try:
        payload = json.loads(raw.decode("utf-8") or "{}")
    except (ValueError, UnicodeDecodeError) as exc:
        raise RuntimeTransportError(f"malformed runtime response for op {op!r}") from exc
    return RuntimeResponse.from_wire(payload)


class RemoteSketchUpTransport(SketchUpRuntimeTransport):
    """Loopback HTTP client to a WorkstationSketchUpRuntimeAgent."""

    def __init__(
        self,
        base_url: str,
        auth_token: str,
        *,
        allow_remote: bool = False,
        default_deadline_ms: int = DEFAULT_DEADLINE_MS,
    ) -> None:
        if not str(auth_token or "").strip():
            raise ValueError("RemoteSketchUpTransport requires a non-empty auth_token")
        self._base_url = _require_loopback(base_url, allow_remote=allow_remote)
        self._auth_token = str(auth_token)
        self._default_deadline_ms = check_deadline(default_deadline_ms)
        self._closed = False
        self._lock = threading.Lock()

    def __repr__(self) -> str:
        return f"RemoteSketchUpTransport(base_url={self._base_url!r}, auth=<redacted>)"

    async def call(
        self,
        op: str,
        params: dict[str, Any] | None = None,
        *,
        deadline_ms: int | None = None,
        expected_generation: str | None = None,
    ) -> Any:
        if self._closed:
            raise RuntimeUnavailableError("remote runtime transport is closed")
        request = RuntimeRequest(
            op=check_op(op),
            params=dict(params or {}),
            deadline_ms=self._default_deadline_ms if deadline_ms is None else deadline_ms,
            expected_generation=expected_generation,
        )
        wire = request.to_wire()
        timeout_s = request.deadline_ms / 1000.0
        host, port = _endpoint_host_port(self._base_url)
        preflight = await asyncio.to_thread(_preflight_connect, host, port, timeout_s)
        if preflight == "refused":
            raise RuntimeUnavailableError(
                f"remote runtime refused connection before dispatch for op {request.op!r}"
            )
        url = f"{self._base_url}/dispatch"
        try:
            status, raw = await asyncio.to_thread(
                _post_json, url, wire, token=self._auth_token, timeout_s=timeout_s
            )
        except (urllib.error.URLError, TimeoutError, OSError) as exc:
            reason = getattr(exc, "reason", None) or exc
            if isinstance(reason, ConnectionRefusedError) or isinstance(exc, ConnectionRefusedError):
                raise RuntimeUnavailableError(
                    f"remote runtime refused connection before dispatch for op {request.op!r}: {exc}"
                ) from exc
            if isinstance(reason, OSError) and "getaddrinfo" in str(reason).lower():
                raise RuntimeUnavailableError(
                    f"remote runtime host unresolvable before dispatch for op {request.op!r}: {exc}"
                ) from exc
            raise RuntimeUncertainError(
                f"remote runtime op {request.op!r} lost response after dispatch "
                f"({exc}); completion is unknown, blind retry is forbidden"
            ) from exc
        response = await asyncio.to_thread(_decode_response, status, raw, op=request.op)
        if request.expected_generation is not None and response.generation != request.expected_generation:
            raise RuntimeGenerationMismatchError(
                f"runtime generation mismatch: expected {request.expected_generation!r}, "
                f"got {response.generation!r}; result for op {request.op!r} discarded"
            )
        return raise_for_response(request.op, response)

    async def health(self) -> dict[str, Any]:
        if self._closed:
            raise RuntimeUnavailableError("remote runtime transport is closed")
        host, port = _endpoint_host_port(self._base_url)
        preflight = await asyncio.to_thread(_preflight_connect, host, port, 5.0)
        if preflight == "refused":
            raise RuntimeUnavailableError("remote runtime refused connection; agent is down")
        try:
            status, raw = await asyncio.to_thread(
                _get_json, f"{self._base_url}/health", token=self._auth_token, timeout_s=5.0
            )
        except (urllib.error.URLError, TimeoutError, OSError) as exc:
            raise RuntimeUnavailableError(f"remote runtime health unreachable: {exc}") from exc
        response = await asyncio.to_thread(_decode_response, status, raw, op="health")
        if not response.ok:
            raise RuntimeUnavailableError(
                f"remote runtime unhealthy: {response.error_message or response.error_code}"
            )
        result = response.result
        return result if isinstance(result, dict) else {"ok": True, "detail": result}

    async def close(self) -> None:
        self._closed = True


def bearer_matches(presented: str, expected: str) -> bool:
    if not str(expected or ""):
        return False
    return hmac.compare_digest(str(presented or ""), str(expected))
