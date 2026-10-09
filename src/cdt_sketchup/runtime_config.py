"""Explicit remote configuration; the default remains the local Ruby bridge."""
from __future__ import annotations

import os
from pathlib import Path

from .bridge import read_bridge_token
from .remote_runtime import RemoteSketchUpRuntimeAdapter
from .runtime_transport import RemoteSketchUpTransport


def configured_runtime():
    names = ("ENDPOINT", "TOKEN_FILE", "STATE_FILE")
    values = {name: os.environ.get("CDT_SKETCHUP_RUNTIME_" + name, "").strip() for name in names}
    if not any(values.values()):
        return None
    if not all(values.values()):
        raise ValueError("Remote runtime requires ENDPOINT, TOKEN_FILE and STATE_FILE")
    transport = RemoteSketchUpTransport(
        values["ENDPOINT"], read_bridge_token(Path(values["TOKEN_FILE"]))
    )
    return RemoteSketchUpRuntimeAdapter(transport, state_file=Path(values["STATE_FILE"]))
