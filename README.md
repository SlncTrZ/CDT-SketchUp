# CDT-SketchUp

Domain-neutral SketchUp MCP execution provider. Typed Python tools dispatch to
a Ruby extension on SketchUp's main thread; engineering design rules belong to
CDT_Engineer.

Provider `0.1.0` · Contract `0.31`. Measured native scopes target
SketchUp 2024 `24.0.594` / Ruby `3.2.2`; see
[compatibility](docs/COMPATIBILITY.md) for versioned acceptance limits.

## Install and run

Python 3.11+ is required. Use the platform lock and reproducible installation
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
- [Documentation index](docs/README.md).

No arbitrary Ruby/script execution surface is exposed. Current runtime discovery
and ownership checks remain required before starting, draining or stopping work.
