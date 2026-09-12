"""Bridge Protocol — Bounded authenticated loopback protocol for SketchUp.
Wing: code | Topic: sketchup_bridge | Updated: 2026-09-09 18:58
"""

from __future__ import annotations

import asyncio
import json
import os
import secrets
from pathlib import Path
from typing import Any, Mapping

BRIDGE_PROTOCOL_VERSION = 1
DEFAULT_BRIDGE_HOST = "127.0.0.1"
DEFAULT_BRIDGE_PORT = 9876
MAX_FRAME_BYTES = 256 * 1024
DEFAULT_TIMEOUT_SECONDS = 5.0


class BridgeProtocolError(RuntimeError):
    """Raised for malformed, rejected, or mismatched bridge messages."""


class BridgeUnavailableError(ConnectionError):
    """Raised when the local SketchUp bridge cannot be reached."""


def build_request(
    *,
    request_id: str,
    command: str,
    params: Mapping[str, Any],
    token: str,
) -> dict[str, Any]:
    """Build a typed bridge request; arbitrary code payloads are never synthesized."""
    if not request_id:
        raise BridgeProtocolError("request_id is required")
    if not command or not command.replace("_", "").isalnum():
        raise BridgeProtocolError("command must be a simple identifier")
    if not token:
        raise BridgeProtocolError("bridge token is required")
    return {
        "protocol": BRIDGE_PROTOCOL_VERSION,
        "request_id": request_id,
        "command": command,
        "params": dict(params),
        "token": token,
    }


def encode_frame(payload: Mapping[str, Any]) -> bytes:
    """Encode one bounded newline-delimited UTF-8 JSON frame."""
    try:
        frame = json.dumps(
            payload,
            ensure_ascii=False,
            separators=(",", ":"),
            allow_nan=False,
        ).encode("utf-8") + b"\n"
    except (TypeError, ValueError) as exc:
        raise BridgeProtocolError(f"invalid JSON payload: {exc}") from exc
    if len(frame) > MAX_FRAME_BYTES:
        raise BridgeProtocolError("bridge frame exceeds maximum size")
    return frame


def decode_response(frame: bytes, *, expected_request_id: str) -> Any:
    """Validate and decode one bridge response frame."""
    if not frame or len(frame) > MAX_FRAME_BYTES:
        raise BridgeProtocolError("invalid bridge response size")
    try:
        payload = json.loads(frame.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise BridgeProtocolError("invalid bridge response JSON") from exc
    if not isinstance(payload, dict):
        raise BridgeProtocolError("bridge response must be an object")
    if payload.get("protocol") != BRIDGE_PROTOCOL_VERSION:
        raise BridgeProtocolError("bridge protocol version mismatch")
    if payload.get("request_id") != expected_request_id:
        raise BridgeProtocolError("bridge response request_id mismatch")
    if payload.get("ok") is not True:
        error = payload.get("error") or {}
        kind = error.get("kind", "bridge_error") if isinstance(error, dict) else "bridge_error"
        message = error.get("message", "SketchUp bridge rejected request") if isinstance(error, dict) else str(error)
        raise BridgeProtocolError(f"{kind}: {message}")
    return payload.get("result")


def default_token_path() -> Path:
    """Return the per-user bridge token path shared with the SketchUp extension."""
    configured = os.environ.get("CDT_SKETCHUP_BRIDGE_TOKEN_FILE")
    if configured:
        return Path(configured).expanduser()
    local_app_data = os.environ.get("LOCALAPPDATA")
    if local_app_data:
        return Path(local_app_data) / "CDT-SketchUp" / "bridge.token"
    return Path.home() / ".cdt-sketchup" / "bridge.token"


def read_bridge_token(path: Path | None = None) -> str:
    """Read the existing bridge token without creating or logging it."""
    token_path = path or default_token_path()
    try:
        token = token_path.read_text(encoding="utf-8").strip()
    except OSError as exc:
        raise BridgeUnavailableError("bridge credential unavailable") from exc
    if len(token) < 32:
        raise BridgeUnavailableError("bridge token is invalid")
    return token


class BridgeClient:
    """One-request-per-connection client for the local SketchUp extension."""

    def __init__(
        self,
        *,
        host: str = DEFAULT_BRIDGE_HOST,
        port: int = DEFAULT_BRIDGE_PORT,
        timeout: float = DEFAULT_TIMEOUT_SECONDS,
        token_path: Path | None = None,
    ) -> None:
        if host not in {"127.0.0.1", "::1", "localhost"}:
            raise ValueError("SketchUp bridge must use loopback")
        if not (1 <= port <= 65535):
            raise ValueError("bridge port must be 1..65535")
        if timeout <= 0:
            raise ValueError("timeout must be positive")
        self._host = host
        self._port = port
        self._timeout = timeout
        self._token_path = token_path

    async def call(self, command: str, params: Mapping[str, Any] | None = None) -> Any:
        """Call one allowlisted command through the bounded loopback bridge."""
        request_id = secrets.token_hex(16)
        token = read_bridge_token(self._token_path)
        request = build_request(
            request_id=request_id,
            command=command,
            params=params or {},
            token=token,
        )
        try:
            reader, writer = await asyncio.wait_for(
                asyncio.open_connection(
                    self._host,
                    self._port,
                    limit=MAX_FRAME_BYTES + 1,
                ),
                timeout=self._timeout,
            )
        except (OSError, asyncio.TimeoutError) as exc:
            raise BridgeUnavailableError("SketchUp bridge unavailable") from exc

        try:
            writer.write(encode_frame(request))
            await asyncio.wait_for(writer.drain(), timeout=self._timeout)
            frame = await asyncio.wait_for(reader.readuntil(b"\n"), timeout=self._timeout)
            if len(frame) > MAX_FRAME_BYTES:
                raise BridgeProtocolError("bridge response exceeds maximum size")
            return decode_response(frame, expected_request_id=request_id)
        except asyncio.LimitOverrunError as exc:
            raise BridgeProtocolError("bridge response exceeds maximum size") from exc
        except asyncio.IncompleteReadError as exc:
            raise BridgeProtocolError("bridge closed before a complete response") from exc
        finally:
            writer.close()
            try:
                await writer.wait_closed()
            except OSError:
                pass

    async def probe(self) -> dict[str, Any]:
        """Return a non-throwing observed runtime probe for status/capability tools."""
        try:
            result = await self.call("ping")
        except (BridgeUnavailableError, BridgeProtocolError) as exc:
            return {
                "bridge_connected": False,
                "live_model": False,
                "detail": str(exc),
            }
        if not isinstance(result, dict):
            return {
                "bridge_connected": True,
                "live_model": False,
                "detail": "invalid ping result",
            }
        return {
            "bridge_connected": True,
            "live_model": bool(result.get("live_model")),
            "detail": result.get("detail"),
            "runtime": {
                key: result[key]
                for key in ("sketchup_version", "ruby_version")
                if key in result
            },
        }
