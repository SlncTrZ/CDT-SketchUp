# CDT-SketchUp — Release and deployment

**CDT package:** `0.1.1` · tag `v.0.1.1` · **independent** public contract `0.31`. The accepted SketchUp native baseline is **SketchUp 2024 (24.0.594) / Ruby 3.2.2**, not every later release.

A GitHub [source release](https://github.com/SlncTrZ/CDT-SketchUp/releases) does not imply the Ruby RBZ is attached or installed on the target Windows host.

## Install and connect

1. Select the tagged source and use [reproducible dependencies](REPRODUCIBLE_BASELINE.md). Build the Ruby extension with `python scripts/build_rbz.py` and check its generated artifact/hash before installing through SketchUp Extension Manager.
2. Keep SketchUp running in its intended interactive Windows session. The Python provider attaches to the localhost-only Ruby bridge. Use [runtime operations](RUNTIME_OPERATIONS.md) for split-host SSH forwarding and existing agent credentials.
3. Call `help`, `system_status`, `system_capabilities` and verify the **installed** contract, model, bridge generation and permitted roots. User-owned dirty models must be saved by the user; an installer must not close or reset them.

## Upgrade and rollback

Stage a new immutable Python environment and matching RBZ side by side; retain the original extension, agent binding and credentials. Compare authentication, native object count and readback of a disposable model before updating Gateway discovery. A timeout is uncertain until `reconcile_operation` resolves the operation. Roll back the provider and Ruby extension together on failed verification.

[Runtime operation](RUNTIME_OPERATIONS.md) · [Security](SECURITY.md) · [Compatibility](COMPATIBILITY.md) · [Tool guide](TOOL_GUIDE.md).
