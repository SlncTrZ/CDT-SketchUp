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

The registry separates preferred read/strict paths from deprecated compatibility mutations and computes a deterministic SHA-256 capability fingerprint from static descriptor semantics.

### Unit adapter boundary

Strict public geometry is unit-explicit while SketchUp's native inch representation remains an adapter detail. The Python MCP layer validates the public enum and coordinate-space declaration; the Ruby bridge resolves `model` units and normalizes all dimensional inputs once before opening the mutation transaction. Native semantic extraction and fingerprints remain canonical, then receipt-facing states/validation evidence are projected back into the requested unit.

The only supported public coordinate space is currently `active_context`; no implicit model/world-to-edit-context transform is performed.

### Semantic receipt layer

The native semantic kernel emits receipt schema v1 for strict operations and semantic entity queries. Operation receipts are assembled by one shared builder after semantic validation/fingerprinting, while rollback receipts use the same envelope after abort verification. Exact affected-PID accounting comes from bounded active-context semantic snapshots taken before and after the native action.

Receipt context identity is live: a process/model/edit-path context ID is paired with a revision derived from the context ID plus canonical model fingerprint. Strict writes may require the caller's prior context and entity semantic fingerprint, and those guards run before native mutation starts. Operation receipts preserve both consumed `context_before` and post-commit `context`.

## SketchUp extension

The Ruby extension runs inside SketchUp and owns native model access. Its bridge binds to loopback and executes SketchUp Ruby API work from SketchUp's main thread.

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

The current released implementation exposes a Python MCP provider plus a SketchUp Ruby bridge. The strict Semantic State Loop is proven for a subset of generic mutation operations, including strict Group/ComponentInstance deletion, strict group composition, strict component/instance semantics, strict copy/array/mirror duplication, strict tag/material assignment, strict curve/polyline primitives, strict profile sweep, read-only measurement/topology queries, allowlisted asset placement, real-world texture scale, camera/scene control, rooted document lifecycle and CAD integrity with safe repair at contract `0.21`; some earlier mutation tools remain compatibility paths while migration continues. Capability documentation distinguishes those paths rather than treating them as equivalent.

See [Tool Guide](TOOL_GUIDE.md), [Security](SECURITY.md), and [Compatibility](COMPATIBILITY.md).
