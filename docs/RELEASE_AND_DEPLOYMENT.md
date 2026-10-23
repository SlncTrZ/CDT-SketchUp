# CDT-SketchUp — Release and deployment

**CDT package:** `0.1.2` · tag `v.0.1.2` · **independent** public contract `0.31`. The accepted SketchUp native baseline is **SketchUp 2024 (24.0.594) / Ruby 3.2.2**, not every later release.

A GitHub [source release](https://github.com/SlncTrZ/CDT-SketchUp/releases) does not imply the Ruby RBZ is attached or installed on the target Windows host.

## Install and connect

1. Select the tagged source and use [reproducible dependencies](REPRODUCIBLE_BASELINE.md). Build the Ruby extension with `python scripts/build_rbz.py` and check its generated artifact/hash before installing through SketchUp Extension Manager.
2. Keep SketchUp running in its intended interactive Windows session. The Python provider attaches to the localhost-only Ruby bridge. Use [runtime operations](RUNTIME_OPERATIONS.md) for split-host SSH forwarding and existing agent credentials.
3. Call `help`, `system_status`, `system_capabilities` and verify the **installed** contract, model, bridge generation and permitted roots. User-owned dirty models must be saved by the user; an installer must not close or reset them.

## Managed `.227` deployment

The managed service is `cdt-sketchup.service`, running an immutable wheel built from exact tag `v.0.1.1` and serving authenticated Streamable HTTP at `http://127.0.0.1:8814/mcp`. Direct Gateway-adapter acceptance discovers all 68 tools with zero normalized drift. The prior stdio owner is retired and the systemd service owns the single-owner binding lock. If the workstation agent generation changes while SketchUp is closed, the provider must remain degraded and require explicit rebind after native ping and document readback; never auto-adopt a new generation.

## Upgrade and rollback

Stage a new immutable Python environment and matching RBZ side by side; retain the original extension, agent binding and credentials. Compare authentication, native object count and readback of a disposable model before updating Gateway discovery. A timeout is uncertain until `reconcile_operation` resolves the operation. Roll back the provider and Ruby extension together on failed verification.

[Runtime operation](RUNTIME_OPERATIONS.md) · [Security](SECURITY.md) · [Compatibility](COMPATIBILITY.md) · [Tool guide](TOOL_GUIDE.md).
