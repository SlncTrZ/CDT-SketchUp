# CDT-SketchUp Architecture

CDT-SketchUp is a **Generic CAD Primitive / Execution Engine for SketchUp exposed through MCP**.

It executes typed, bounded CAD operations and returns semantic model state. It does not contain architecture, structure, MEP, mechanical, interior, infrastructure, code-compliance, TCVN/QCVN or discipline Audit Report business logic. Those concerns belong to external Domain Agents.

## System boundary

```text
User / LLM
    |
    v
External Domain Agent
(discipline rules / standards / audit)
    |
    | generic CAD operations
    v
CDT-SketchUp MCP Provider (Python)
    |
    | authenticated bounded loopback protocol
    v
CDT-SketchUp SketchUp Extension (Ruby)
    |
    | SketchUp Ruby API on main thread
    v
Active SketchUp model
```

## Python MCP provider

The Python layer owns:

- MCP tool schemas and versioned provider contract;
- runtime status and capability discovery;
- public network exposure controls;
- bridge client/protocol validation;
- ergonomic wrappers over native generic CAD commands;
- stable public error normalization.

The Python provider does not invent geometry truth when SketchUp is authoritative.

### Capability registry

The provider has one static capability registry covering every public MCP tool. Tool discovery order and `system_capabilities` metadata derive from the same registry to prevent documentation/contract drift. Runtime probing only merges availability and observed-version state into the static descriptors; it does not rewrite their safety semantics.

The registry separates preferred read paths, strict rollback-capable mutations, bounded non-transactional external side effects, and deprecated compatibility mutations. It computes a deterministic SHA-256 capability fingerprint from static descriptor semantics.

### Unit adapter boundary

Strict public geometry is unit-explicit while SketchUp's native inch representation remains an adapter detail. The Python MCP layer validates the public enum and coordinate-space declaration; the Ruby bridge resolves `model` units and normalizes all dimensional inputs once before opening the mutation transaction. Native semantic extraction and fingerprints remain canonical, then receipt-facing states/validation evidence are projected back into the requested unit.

The only supported public coordinate space is currently `active_context`; no implicit model/world-to-edit-context transform is performed. Nested-target execution may temporarily enter a validated instance path before a strict action, but coordinates remain local to that target edit context.

### Semantic receipt layer

The native semantic kernel emits receipt schema v1 for strict operations, semantic queries, and bounded document side effects. Strict operation receipts are assembled after semantic validation/fingerprinting, rollback receipts verify abort restoration, and document save/open/export uses a distinct `external_side_effect` receipt that never claims a SketchUp transaction or rollback. Exact affected-PID accounting for strict model mutation comes from bounded active-context semantic snapshots taken before and after the native action.

Receipt context identity is live: a process/model/edit-path context ID is paired with a revision derived from the context ID plus canonical model fingerprint. Strict writes may require the caller's prior context and entity semantic fingerprint, and those guards run before native mutation starts. Operation receipts preserve both consumed `context_before` and post-commit `context`. For targeted execution, the caller context is guarded before the edit-path switch, the unchanged inner strict action owns the target-context transaction, and `context_targeting` separately reports verified restoration of the caller edit path.

## SketchUp extension

The Ruby extension runs inside SketchUp and owns native model access. Its bridge binds to loopback and executes SketchUp Ruby API work from SketchUp's main thread. The extension entry point (`extension/cdt_sketchup/main.rb`) is intentionally thin: it only requires the module tree and starts the bridge. Implementation lives in `bridge/` (loopback server, protocol, auth), `kernel/` (errors, limits, primitives, units, registry, transaction, context, entity resolution, semantic state, fingerprints, expectations, receipts) and per-family `actions/` (strict mutations) plus `queries/` (read paths). Dependency direction is one-way — actions/queries call into kernel, never the reverse — and is machine-checked by the offline suite.

For strict autonomous mutations, the extension uses the **Semantic State Loop**:

```text
resolve exact model/context/entity
  -> start AI_Step transaction
  -> execute native CAD action
  -> extract semantic state
  -> validate action invariants
  -> compute deterministic fingerprints before commit
  -> commit only on success
  -> otherwise abort and verify rollback
```

Semantic state may include persistent identity, hierarchy, bounds, transformation, geometry counts, face area/normal, manifold state, volume, tag/material and deterministic fingerprints.

## Generic CAD boundary

Valid provider capability families include:

- geometry and topology;
- transforms and booleans;
- groups/components/instances;
- measurements and spatial queries;
- generic materials/textures/assets;
- camera/scenes;
- safe model import/export and lifecycle operations;
- CAD integrity facts and safe repair primitives;
- transactions, identity, semantic validation and recovery.

Invalid provider capability families include discipline-specific systems such as wall/roof design, structural sizing, MEP routing, interior layout rules, TCVN/QCVN evaluation or engineering Audit Report conclusions.

## Current architecture status

The current implementation exposes a Python MCP provider plus a SketchUp Ruby bridge at contract `0.30` with 68 public MCP tools. Contract 0.29 added an optional caller-owned `operation_id` to generic `execute_geometry`, keeping logical mutation identity stable across MCP retry/reconnect attempts while wire `request_id` remains per-connection. Contract 0.30 adds public read-only `reconcile_operation` and truthful ambiguous-completion handling: once a mutation request has been sent, transport loss is `unknown_commit`, not a definitive rejection; unknown journal entries are not replayable; and rollback is claimed only after model-fingerprint restoration is independently verified. The strict Semantic State Loop covers rollback-capable generic model mutations, including bounded nested-target execution and generic indexed-mesh realization; rooted document and artifact operations are modeled as verified external side effects where native rollback is not claimed. Strong asset identity binds `asset_key + sha256 + native_version` to exact loaded bytes and definition geometry, exact spatial queries operate on bounded triangulated manifold solids without mutating the model, and content-addressed artifact sealing binds accepted SKP bytes to SHA-256 manifests. The complete contract-0.28 gap matrix remains the broad native baseline on SketchUp 2024 `24.0.594` / Ruby `3.2.2`; the contract-0.30 recovery additions are separately live-accepted through real Streamable HTTP response-loss-after-commit fault injection with exactly-once reconciliation/replay. Model/asset/texture roots continue to use canonical containment and `model_open` refuses unsaved active models.

See [Tool Guide](TOOL_GUIDE.md), [Security](SECURITY.md), and [Compatibility](COMPATIBILITY.md).
