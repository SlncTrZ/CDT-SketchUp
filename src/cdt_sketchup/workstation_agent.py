"""Workstation SketchUp runtime agent — S2 loopback-only executor.

Wing: code | Topic: sketchup_runtime_agent | Updated: 2026-10-07 18:35

Authenticated persistent listener owning the native side of the
RuntimeTransport boundary. Minimal by design:

- bearer-authenticated HTTP listener (127.0.0.1 only, no LAN bind);
- runtime generation minted at start (restart creates a new one);
- process/session discovery (pid, best-effort);
- bounded adapter dispatch by op name from the shared allowlist.

Explicitly NOT in this agent: MCP server, engineering semantics, and no
Ruby bridge changes (the adapter still calls the existing loopback
BridgeClient; the Ruby extension itself never binds LAN).
"""

from __future__ import annotations

import asyncio
import json
import os
import threading
import time
from dataclasses import dataclass
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any
from urllib.parse import urlparse
from uuid import uuid4

from .runtime_transport import (
    ALLOWED_OPS,
    MAX_REQUEST_BYTES,
    MAX_RESPONSE_BYTES,
    bearer_matches,
    check_deadline,
)

_LOOPBACK_HOSTS = {"127.0.0.1", "localhost", "::1"}


def _to_jsonable(value: Any) -> Any:
    if value is None or isinstance(value, (bool, int, float, str)):
        return value
    if isinstance(value, bytes):
        import base64

        return {"__bytes_b64": base64.b64encode(value).decode("ascii")}
    to_dict = getattr(value, "to_dict", None)
    if callable(to_dict):
        return _to_jsonable(to_dict())
    if isinstance(value, (tuple, list)):
        return [_to_jsonable(item) for item in value]
    if isinstance(value, dict):
        return {str(key): _to_jsonable(item) for key, item in value.items()}
    return str(value)


@dataclass
class WorkstationAgentConfig:
    host: str = "127.0.0.1"
    port: int = 0
    auth_token: str = ""
    allow_remote_bind: bool = False
    max_request_bytes: int = MAX_REQUEST_BYTES

    def __post_init__(self) -> None:
        if not str(self.auth_token or "").strip():
            raise ValueError("WorkstationSketchUpRuntimeAgent requires a non-empty auth_token")
        if self.host.lower() not in _LOOPBACK_HOSTS and not self.allow_remote_bind:
            raise ValueError(f"refusing non-loopback agent bind {self.host!r} without allow_remote_bind")
        if not 0 <= self.port <= 65535:
            raise ValueError("port must be within [0, 65535]")
        if self.max_request_bytes <= 0:
            raise ValueError("max_request_bytes must be > 0")


class WorkstationSketchUpRuntimeAgent:
    """Owns one S1 adapter + one runtime generation behind an authed listener."""

    def __init__(self, adapter: Any, config: WorkstationAgentConfig) -> None:
        from .runtime_port import SketchUpRuntimePort

        if not isinstance(adapter, SketchUpRuntimePort):
            raise TypeError("WorkstationSketchUpRuntimeAgent requires a SketchUpRuntimePort adapter")
        self._adapter = adapter
        self._config = config
        self._generation = f"gen-{uuid4().hex}"
        self._started_at = time.time()
        self._dispatch_lock = threading.Lock()
        self._server: ThreadingHTTPServer | None = None
        self._thread: threading.Thread | None = None
        self._session = {"pid": os.getpid()}

    @property
    def generation(self) -> str:
        return self._generation

    @property
    def adapter(self) -> Any:
        return self._adapter

    @property
    def base_url(self) -> str:
        if self._server is None:
            raise RuntimeError("agent is not started")
        host, port = self._server.server_address[:2]
        return f"http://{host}:{port}"

    def heartbeat(self) -> dict[str, Any]:
        return {
            "generation": self._generation,
            "uptime_s": round(time.time() - self._started_at, 3),
            "session": dict(self._session),
            "adapter": self._adapter.health() if hasattr(self._adapter, "health") else {},
        }

    def dispatch(
        self,
        op: str,
        params: dict[str, Any] | None = None,
        *,
        expected_generation: str | None = None,
        deadline_ms: int | None = None,
    ) -> dict[str, Any]:
        name = str(op or "").strip()
        if name not in ALLOWED_OPS:
            return self._envelope(False, None, "unknown_op", f"op refused: {name!r}", False)
        if expected_generation is not None and expected_generation != self._generation:
            return self._envelope(
                False, None, "generation_mismatch",
                f"stale runtime generation: expected {expected_generation!r}, agent is {self._generation!r}",
                False,
            )
        try:
            bound_ms = check_deadline(deadline_ms)
        except ValueError as exc:
            return self._envelope(False, None, "bad_request", str(exc), False)
        target = getattr(self._adapter, "call", None)
        if not callable(target):
            return self._envelope(False, None, "unknown_op", "adapter has no call()", False)
        with self._dispatch_lock:
            try:
                result = self._run_bounded(target, (name, dict(params or {})), {}, bound_ms)
            except TimeoutError as exc:
                return self._envelope(False, None, "dispatch_timeout_uncertain", str(exc), True)
            except Exception as exc:
                uncertain = bool(getattr(exc, "completion_unknown", False))
                code = "uncertain" if uncertain else "backend_error"
                return self._envelope(False, None, code, str(exc), uncertain)
        try:
            return self._envelope(True, _to_jsonable(result), "ok", "", False)
        except Exception as exc:
            return self._envelope(False, None, "backend_error", f"result not serializable: {exc}", False)

    def _envelope(self, ok: bool, result: Any, code: str, message: str, unknown: bool) -> dict[str, Any]:
        return {
            "ok": ok,
            "result": result,
            "error_code": code,
            "error_message": message,
            "generation": self._generation,
            "completion_unknown": unknown,
        }

    @staticmethod
    def _run_bounded(target: Any, args: tuple[Any, ...], kwargs: dict[str, Any], bound_ms: int) -> Any:
        outcome: dict[str, Any] = {}

        def _invoke() -> None:
            try:
                res = target(*args, **kwargs)
                if asyncio.iscoroutine(res):
                    res = asyncio.run(res)
                outcome["result"] = res
            except BaseException as exc:
                outcome["error"] = exc

        worker = threading.Thread(target=_invoke, daemon=True)
        worker.start()
        worker.join(timeout=bound_ms / 1000.0)
        if worker.is_alive():
            raise TimeoutError(
                f"adapter op exceeded {bound_ms}ms after dispatch; completion unknown, no replay"
            )
        if "error" in outcome:
            raise outcome["error"]
        return outcome.get("result")

    def start(self) -> str:
        if self._server is not None:
            raise RuntimeError("agent is already started")
        agent = self

        class _Handler(BaseHTTPRequestHandler):
            server_version = "CDT-SketchUp-Agent/0.1"

            def _authed(self) -> bool:
                presented = self.headers.get("Authorization", "")
                scheme, _, token = presented.partition(" ")
                if scheme.lower() != "bearer":
                    return False
                return bearer_matches(token.strip(), agent._config.auth_token)

            def _send(self, status: int, payload: dict[str, Any]) -> None:
                raw = json.dumps(payload, separators=(",", ":")).encode("utf-8")
                if len(raw) > MAX_RESPONSE_BYTES:
                    raw = json.dumps(
                        agent._envelope(False, None, "oversized", "response oversized", False),
                        separators=(",", ":"),
                    ).encode("utf-8")
                    status = 500
                self.send_response(status)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(raw)))
                self.end_headers()
                try:
                    self.wfile.write(raw)
                except OSError:
                    pass

            def _refuse_auth(self) -> None:
                self._send(401, agent._envelope(False, None, "unauthorized", "invalid bearer token", False))

            def do_GET(self) -> None:
                if not self._authed():
                    self._refuse_auth()
                    return
                path = urlparse(self.path).path.rstrip("/") or "/"
                if path in ("/health", "/heartbeat"):
                    self._send(200, agent._envelope(True, agent.heartbeat(), "ok", "", False))
                else:
                    self._send(404, agent._envelope(False, None, "not_found", f"no route: {path}", False))

            def do_POST(self) -> None:
                if not self._authed():
                    self._refuse_auth()
                    return
                path = urlparse(self.path).path.rstrip("/") or "/"
                if path != "/dispatch":
                    self._send(404, agent._envelope(False, None, "not_found", f"no route: {path}", False))
                    return
                try:
                    length = int(self.headers.get("Content-Length", "0"))
                except ValueError:
                    length = 0
                if length <= 0 or length > agent._config.max_request_bytes:
                    self._send(400, agent._envelope(False, None, "oversized", "body missing/oversized", False))
                    return
                try:
                    body = json.loads(self.rfile.read(length).decode("utf-8") or "{}")
                except (ValueError, UnicodeDecodeError):
                    self._send(400, agent._envelope(False, None, "bad_request", "malformed JSON", False))
                    return
                if not isinstance(body, dict):
                    self._send(400, agent._envelope(False, None, "bad_request", "body must be object", False))
                    return
                envelope = agent.dispatch(
                    body.get("op", ""),
                    body.get("params"),
                    expected_generation=body.get("expected_generation"),
                    deadline_ms=body.get("deadline_ms"),
                )
                self._send(400 if envelope.get("error_code") == "unknown_op" else 200, envelope)

            def log_message(self, *args: Any) -> None:
                pass

        server = ThreadingHTTPServer((self._config.host, self._config.port), _Handler)
        server.daemon_threads = True
        self._server = server
        thread = threading.Thread(target=server.serve_forever, kwargs={"poll_interval": 0.05})
        thread.daemon = True
        thread.start()
        self._thread = thread
        return self.base_url

    def stop(self) -> None:
        server, thread = self._server, self._thread
        self._server = None
        self._thread = None
        if server is not None:
            server.shutdown()
            server.server_close()
        if thread is not None:
            thread.join(timeout=5.0)
