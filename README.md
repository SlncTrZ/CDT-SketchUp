# CDT-SketchUp

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Python 3.10+](https://img.shields.io/badge/python-3.10%20%7C%203.11%20%7C%203.12-blue.svg)](pyproject.toml)
[![MCP Protocol](https://img.shields.io/badge/MCP-Standard-orange.svg)](https://modelcontextprotocol.io)
[![Platform](https://img.shields.io/badge/platform-Windows%20%7C%20macOS-lightgrey.svg)](docs/COMPATIBILITY.md)
[![Tools](https://img.shields.io/badge/tools-68%20callable-green.svg)](docs/TOOL_GUIDE.md)

Domain-neutral SketchUp MCP execution provider. Typed Python tools dispatch to
a Ruby extension on SketchUp's main thread; engineering design rules belong to
CDT_Engineer.

Provider `0.1.2` · Contract `0.31` · 68 public tools. Measured native scopes target
SketchUp 2024 `24.0.594` / Ruby `3.2.2`; see
[compatibility](docs/COMPATIBILITY.md) for versioned acceptance limits.

---

## Quickstart / MCP Client Configuration

### Claude Desktop (`claude_desktop_config.json`)
```json
{
  "mcpServers": {
    "cdt-sketchup": {
      "command": "uvx",
      "args": ["cdt-sketchup"]
    }
  }
}
```

### Cursor (`~/.cursor/mcp.json`)
```json
{
  "mcpServers": {
    "cdt-sketchup": {
      "command": "uvx",
      "args": ["cdt-sketchup"]
    }
  }
}
```

---

## Install and run

Python 3.10+ is required. Use the platform lock and reproducible installation
procedure in [REPRODUCIBLE_BASELINE](docs/REPRODUCIBLE_BASELINE.md).

```bash
python scripts/build_rbz.py
cdt-sketchup --transport stdio
```

Install the generated RBZ through SketchUp Extension Manager, enable the bridge
in the intended interactive session, and provide bridge authentication through
the deployment environment. The provider-to-extension connection is
authenticated and loopback-only.

## Use safely

1. Call `help`, `system_status` and `system_capabilities`.
2. Select the capability's declared safety class, units and coordinate space.
3. Bind strict mutations to the expected context/fingerprint and use semantic
   feature chunks with independent read-back.
4. For retry-sensitive calls, supply `execute_geometry.operation_id`.
   `unknown_commit` requires `reconcile_operation` before replay or dependent work.

Strict mutation, compatibility tools and external file effects have different
guarantees. Shared component definitions require explicit `make_unique` when
independent editing is intended. A successful save or render is not engineering QA.

## Reference

- [Tool contract](docs/TOOL_GUIDE.md).
- [Architecture](docs/ARCHITECTURE.md).
- [Security](docs/SECURITY.md).
- [Compatibility](docs/COMPATIBILITY.md).
- [Stable release, installation and rollback](docs/RELEASE_AND_DEPLOYMENT.md).
- [Documentation index](docs/README.md).

No arbitrary Ruby/script execution surface is exposed. Current runtime discovery
and ownership checks remain required before starting, draining or stopping work.

## License

Distributed under the open-source MIT License. See [LICENSE](LICENSE).
