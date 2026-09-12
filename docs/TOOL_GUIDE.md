# CDT-SketchUp Tool Guide

> Status: contract 0.12 · measured live acceptance on SketchUp 2024 · Updated: 2026-09-12

## Runtime model

The Python MCP provider is separate from SketchUp. Live tools call a loopback Ruby extension bridge; the extension executes SketchUp API work from a repeating `UI.start_timer` callback on SketchUp's main thread.

Provider status and capability tools remain callable if SketchUp is absent. They report degraded/unsupported live state rather than pretending headless support.

## System and query tools

### `help`

Read-only provider identity, versions, transport, current tool surface, and safety invariants.

### `system_status`

Read-only live probe. `ready` requires both reachable bridge and an active SketchUp model; otherwise status is `degraded`.

### `system_capabilities`

Read-only capability map using **metadata schema v2**. Provider/system capabilities are always available; live-model capabilities fail closed unless bridge + model are observed. Availability is dynamic, while the static descriptor contract is represented by a deterministic `capability_fingerprint`.

Top-level fields include:

- `capability_schema_version`;
- `capability_fingerprint`;
- `observed_runtime`;
- `preferred_tools`;
- `compatibility_tools`;
- `capabilities`.

Every public tool has exactly one descriptor with these planning/safety fields:

```text
key / tool / supported / mode
safety_class / read_only / destructive
transactional / rollback_verified
identity_semantics / unit_semantics / coordinate_space
idempotence / limits / runtime_versions
deprecated / replacement / preferred
preconditions
```

`safety_class` is one of `read_only`, `strict_mutation`, or `deprecated_legacy`. `preferred_tools` contains read-only and strict paths intended for autonomous planning; compatibility mutations remain callable for transition but appear in `compatibility_tools` and are explicitly `preferred=false`. A replacement such as `execute_geometry:create_face` names a strict action selector rather than a separate MCP tool.

`runtime_versions` records measured native evidence and is **not** an allowlist for unmeasured SketchUp versions. The currently observed bridge runtime is returned separately as `observed_runtime`.

### `document_info`

Returns active model title/path/modified state, active edit path, entity count, and unit metadata.

### `object_list`

Lists entities in the **active edit context**. `limit` is 1..500 (default 100); optional `type` filters SketchUp typename.

### `object_get`

Gets one entity by SketchUp `persistent_id`.

## Domain-neutrality rule

This MCP server is a **Generic CAD Primitive / Execution Engine**. Tool contracts must describe generic SketchUp/CAD operations, not architecture/structure/MEP/mechanical/interior workflows.

Allowed examples: generic face/profile extrusion, transform, boolean, group/component, copy/array/mirror, measurement, topology, collision, material/UV, asset insertion, camera/scene and import/export.

Forbidden examples: `generate_wall_system`, `generate_floor_slab`, `generate_roof`, TCVN/QCVN checks, structural member design, room-layout business rules, or discipline Audit Report generation. External Domain Agents own those semantics and compose the generic tools documented here.

## Unified receipt schema v1

The semantic surface uses one additive receipt envelope. `execute_geometry` and its strict wrappers return `receipt_kind="operation"`; `get_entity_state` returns `receipt_kind="query"`. `system_capabilities` advertises `receipt_kind` and `receipt_schema_version` per tool, so clients can discover this without probing result shapes.

Common receipt fields are:

```text
receipt_schema_version
receipt_kind
receipt_id
command
context
entity_states
duration_ms
limits
```

Operation receipts additionally expose:

```text
action
committed / commit_verified
affected / affected_verified
model.before / model.after / model.after_rollback
validation
rollback
error
```

`affected` always uses `{created, modified, deleted}` PID arrays. The native layer compares bounded before/after semantic snapshots. A PID that leaves the active context but still resolves elsewhere in the model is `modified` rather than `deleted`; this is important for grouping/extrusion, where SketchUp reparents source geometry. On a verified rollback, affected sets must return to empty and `model.before.model_fingerprint == model.after_rollback.model_fingerprint`.

Receipt context is now verified. `context.id` deterministically binds the current provider process/model/edit path; `context.revision` binds that context to the current canonical model fingerprint. Query receipts also expose `entity_fingerprint` as the target semantic fingerprint.

Strict writes accept optional `if_context={id, revision}` and `if_match=<64-char semantic SHA-256>`. Context mismatch is checked before action-specific preflight and before `AI_Step`; entity-state mismatch is checked before `AI_Step`. Typed failures are `context_mismatch` and `stale_entity_state`. `if_match` targets the action's identity-sensitive entity (for boolean operations, `target_pid`); actions without a target reject `if_match`. Successful operation receipts expose `context_before` plus the post-commit `context`.

Contract `0.9` compatibility aliases such as top-level `state`, `persistent_id`, `before`, `after`, `rolled_back`, and flat semantic-state fields remain temporarily available; new integrations should use the canonical receipt fields.

## Strict unit and coordinate contract

Preferred strict tools accept an explicit `unit` enum: `mm`, `cm`, `m`, `in`, `ft`, or `model`. `coordinate_space` currently accepts only `active_context`. The compatibility default is `unit="in"`; new clients should still send the desired unit explicitly so intent is machine-readable.

`model` means the active SketchUp model's configured display length unit. Receipts expose `unit`, `resolved_unit`, `native_length_unit="in"`, and `coordinate_space`. Dimensional semantics are:

```text
point / origin / bounds / distance / tolerance -> unit
area                                      -> unit^2
volume                                    -> unit^3
transform matrix [12,13,14]               -> unit
transform rotation/scale terms            -> unitless
normal vectors                            -> unitless
```

The adapter converts to native inches once before `AI_Step`; semantic extraction/fingerprints remain canonical native facts, while public state and validation values are converted back for the receipt. Length tolerance is converted once; area and volume comparisons use squared/cubed dimensional tolerances with the semantic quantization floor, while non-translation matrix terms use the fixed semantic quantum.

`active_context` means coordinates are interpreted in the currently open SketchUp edit context. `model`/world coordinate space is not yet claimed and fails closed. Earlier compatibility tools documented below continue to use raw internal inches and remain `deprecated_legacy` in capability metadata.

## Strict Semantic State Loop

### `execute_geometry(action, params, expect)`

Executes one closed geometry action inside `model.start_operation("AI_Step", true)`.

Current action allowlist:

- `create_box`
- `create_face`
- `extrude_face_to_group`
- `transform_entity`
- `boolean_operation`
- `delete_entity`
- `group_entities`
- `create_component`
- `place_instance`
- `make_unique`
- `copy_entity`
- `linear_array`
- `radial_array`

The action, semantic extraction and validation all happen before commit. A successful step requires SketchUp to return a successful `commit_operation`; the response reports `commit_verified=true`.

Every strict request must provide `expect.active_entity_delta` and at least one additional entity semantic check. Validation supports:

- exact entity type;
- bounding-box min/max/size with tolerance;
- vertex and face counts;
- face area and oriented normal;
- manifold state;
- solid volume;
- absolute 4x4 transformation;
- tag;
- explicit active-entity delta.

`create_face` uses a closed `points` schema and returns the Face PID. `extrude_face_to_group` accepts only a Face `persistent_id`, a non-zero signed distance, and optional group name. For safety it requires the source face to be isolated; after push/pull it groups the connected shell and returns the new Group PID so the result can be validated as a SketchUp Solid and targeted by later transforms.

If execution or validation fails, the bridge calls `abort_operation` and reports both `rolled_back` and `rollback_verified`. Verification requires the pre/post active entity count and model fingerprint to match.

### `transform_entity(persistent_id, matrix)`

Strict generic CAD transform. Targets only an active-context Group or ComponentInstance by persistent ID and **sets** an absolute SketchUp 4x4 transformation instead of multiplying a relative transform. `matrix` must contain exactly 16 finite affine values and must be invertible. The semantic loop requires `active_entity_delta=0`, validates the exact requested transformation, and additionally proves PID, identity fingerprint, and definition-geometry fingerprint remain unchanged before commit. Repeating the same absolute matrix is therefore intended to be idempotent.

### `boolean_operation(tool_pid, target_pid, operation_type)`

Strict generic CAD boolean for `union`, `difference`, or `intersect`. Both operands must be distinct, unlocked active-context Group/ComponentInstance manifold solids. Contract `difference` is explicitly **`target - tool`**. A valid result must be a new active-context manifold `Group`; both input PIDs must be consumed, and an operation-specific volume relation is checked before commit. SketchUp failure, non-manifold operands/results, context escape, or semantic mismatch causes transaction abort and rollback verification.

> **Acceptance:** strict transform and boolean remain live-accepted on SketchUp 2024 `24.0.594` / Ruby `3.2.2`. Transform passed absolute/idempotent placement and verified rollback paths; boolean passed asymmetric difference, union, intersect, result/operand invariants, and non-manifold verified rollback.

### `delete_entity(persistent_id)`

Strict generic object delete for one unlocked active-context `Group` or `ComponentInstance`. The wrapper routes through `execute_geometry` with exact `active_entity_delta=-1` and `deleted=true` expectations.

Before opening `AI_Step`, the native bridge validates the closed PID-only parameter schema, resolves the target, checks active edit context, supported object type and lock state. Unsupported raw `Edge`/`Face` targets fail before mutation because deleting raw SketchUp geometry can cascade through connected topology.

A committed result returns a tombstone semantic state with the original PID/type and `deleted=true`; the PID must no longer resolve before commit. Contract `0.10` retains a deliberately narrow affected-entity receipt for this action:

```json
{
  "affected": {
    "created": [],
    "modified": [],
    "deleted": [12345]
  }
}
```

If post-delete semantic validation fails, SketchUp aborts the operation. A verified rollback returns empty affected sets and the original target must be restored by exact model/entity fingerprints. PID values that the native SketchUp lookup cannot represent are normalized to `invalid_argument`; an in-range PID that does not exist returns `object_not_found`.

### `group_entities(persistent_ids, name?)`

Strict generic CAD composition for an exact active-context PID set of 1..500 unique entities. Supported inputs are edges, faces, groups, and component instances; locked targets fail before mutation. A loose raw Edge/Face shell is accepted only as a complete connected topology set — partial raw topology is rejected before `AI_Step` so native grouping cannot silently consume connected geometry.

`expect` must pin the exact composition: `active_entity_delta = 1 - input count`, `type = Group`, and `child_persistent_ids` equal to the input set. Input identities are reparented (reported as `modified`), the new Group is reported as `created`, and nothing is reported `deleted`:

```json
{
  "affected": {
    "created": [901],
    "modified": [11, 12],
    "deleted": []
  }
}
```

`if_match` for this action is an object keyed by persistent ID covering exactly the input set, mapping each PID to its 64-char semantic fingerprint. Grouping an already-nested entity fails as `inactive_edit_context` without mutation; a wrong hierarchy expectation aborts with fingerprint-verified rollback and empty affected sets. Optional `name` is metadata only, at most 128 characters.

> **Acceptance:** strict group composition is live-accepted on SketchUp 2024 `24.0.594` / Ruby `3.2.2` for object grouping with reparent identity proof, isolated raw-shell grouping, context-escape rejection, wrong-hierarchy verified rollback, and the `create_group` strict-wrapper alias.

### `create_component(persistent_ids, name?)`

Strict generic CAD component composition for an exact active-context PID set of 1..500 unique entities, with the same input identity rules as `group_entities` (edges, faces, groups, component instances; unlocked; complete raw topology only). The native bridge groups the set inside `AI_Step` and converts the group with `to_component`, returning the new `ComponentInstance` so repeated placement can share one definition.

`expect` must pin `active_entity_delta = 1 - input count`, `type = ComponentInstance`, and exact `child_persistent_ids`. Inputs are reparented into the new definition (reported as `modified`), the instance is `created`, nothing is `deleted`. `if_match` is an exact per-PID fingerprint set like `group_entities`. Optional `name` sets the instance name (metadata only, up to 128 characters).

### `place_instance(definition_guid, matrix)`

Strict generic CAD instance placement. The definition is resolved by exact GUID string — never by name or index — and image definitions are rejected before `AI_Step`. `matrix` is an absolute invertible 4x4 transform with unit-aware translation terms, exactly like `transform_entity`. `expect` must pin `active_entity_delta = 1`, `type = ComponentInstance`, the same `definition_guid`, and the absolute `transformation`.

`if_match` is the definition geometry fingerprint (64-char SHA-256): placement fails as `stale_entity_state` if the definition changed since the receipt. Unknown GUIDs fail as `definition_not_found` before any mutation. Repeated placements share one definition GUID while each instance keeps its own PID and transform.

### `make_unique(persistent_id)`

Strict generic CAD instance fork for one active-context `ComponentInstance`. The bridge calls native `make_unique` inside `AI_Step`: the instance keeps its PID and geometry, but its definition GUID must change. The invariant proves the fork (old GUID ≠ new GUID) and geometry preservation (definition geometry fingerprint identical before/after), while sibling instances keep the original definition. `expect` must pin `active_entity_delta = 0` and `type = ComponentInstance`; `if_match` guards the instance semantic fingerprint.

Transforming an instance never alters its definition geometry fingerprint — the definition block (`guid`, `name`, `geometry_fingerprint`) exposed on every instance state proves this without guessing.

> **Acceptance:** strict component/instance semantics are live-accepted on SketchUp 2024 `24.0.594` / Ruby `3.2.2` for exact-set composition with reparent proof, definition query, shared-definition placement, transform definition-invariance, definition-forking make-unique, wrong-expectation verified rollback, nested-context escape rejection, and unknown-definition fail-closed behavior.

### `definition_info(definition_guid)`

Read-only component definition lookup by exact GUID. Returns the definition name, group/image flags, instance count with member instance PIDs, bounds, geometry counts, and the canonical definition geometry fingerprint. It never falls back to names or indices; unknown GUIDs return `definition_not_found`.

### `copy_entity(persistent_id)`

Strict generic CAD copy for one unlocked active-context `Group` or `ComponentInstance`. Groups duplicate with native `copy`; instances place a new instance of the same definition at the same transform. The copy keeps the source transform and shares the source definition (instances) or geometry (groups) while receiving a new PID. `expect` must pin `active_entity_delta = 1` and the source `type`. `if_match` guards the source semantic fingerprint.

### `linear_array(persistent_id, vector, count)` / `radial_array(persistent_id, axis_origin, axis, degrees, count)`

Strict generic CAD duplication producing exactly `count` new objects in a single `AI_Step` transaction — either all copies commit with verified transforms or the whole array aborts with fingerprint-verified rollback. Linear steps offset each copy by `i × vector`; radial steps rotate each copy by `i × degrees` about the explicit axis. Copies share the source definition (instances) or geometry (groups).

`count` is bounded to 1..100 and the projected entity load (`member entities × count`) is capped at 5000; violations fail as `invalid_argument` or `complexity_budget_exceeded` before `AI_Step`. `expect` must pin `active_entity_delta = count`, the matching `count`, and the source `type`. `vector`/`axis_origin` use the explicit unit contract; `degrees` is unitless.

### `mirror_entity(persistent_id, plane_point, plane_normal)`

Strict generic CAD mirror through the absolute `transform_entity` engine: the provider reads the current semantic transform, builds the explicit reflection target for the given plane, and submits it with automatic `if_context`/`if_match` guards. The mirrored result carries a negative-determinant transform while the definition geometry fingerprint is provably unchanged.

### `get_entity_state(persistent_id)`

Read-only PID lookup. It never falls back to names, indices or transient entity IDs.

Returns semantic JSON including:

- bounding box min/max/center/size;
- vertex/edge/face counts;
- face area + oriented normal when the target is a Face;
- tag and material;
- manifold state and volume when available;
- transform and hierarchy;
- identity, geometry and semantic SHA-256 fingerprints.

See [Architecture](ARCHITECTURE.md) for the public semantic-loop model.

> **Boundary:** mutation tools below are now machine-labeled `deprecated_legacy` in capability metadata v2. They remain callable for compatibility, but they are excluded from `preferred_tools`, do not claim verified rollback, and must not be treated as strict autonomous-CAD actions until migrated.

## S0 geometry

### `create_edge(start, end)`

Creates one active-context edge. Points are finite `[x,y,z]` in SketchUp internal inches; coincident endpoints are refused.

### `create_face(points)`

Creates one face from 3..512 finite 3D points. SketchUp remains geometry authority; invalid face construction aborts the operation.

### `create_group(persistent_ids, name?)`

Deprecated compatibility alias for strict `group_entities`. It routes through the same strict composition engine with internal-inch units and returns an operation receipt with `action="group_entities"`; the former direct native grouping command is no longer exposed and fails closed as `unsupported_command`. New integrations must call `group_entities`.

## S1 common modeling tools

### `selection_by_ids(persistent_ids, replace=true)`

Selects 1..500 entities by persistent ID. Every requested entity must belong to the active edit context. `replace=false` extends the existing selection.

### `selection_clear()`

Clears the SketchUp selection without changing model geometry.

### `object_delete(persistent_id)`

Deletes one active-context entity inside an undo operation.

### `object_move(persistent_id, vector)`

Moves a group/component instance by `[dx,dy,dz]` in internal inches.

### `object_rotate(persistent_id, axis_origin, axis, degrees)`

Rotates a group/component instance around an explicit non-zero axis.

### `object_scale(persistent_id, factors, origin?)`

Scales a group/component instance. Factors are three finite non-zero values; omitted origin uses the object's bounds center.

## S1 SketchUp-native tools

### `push_pull_face(persistent_id, distance)`

Push/pulls one active-context face by a finite non-zero internal-inch distance.

### `component_create_box(name, dimensions, origin?)`

Creates a new named component definition containing a rectangular solid and places one instance in the active edit context. Dimensions must be three positive values; duplicate definition names are refused. `origin` is the lower bounding-box corner.

### `tag_create(name)`

Creates a SketchUp tag (Ruby API `Layer`) or returns the existing tag of the same name.

### `tag_assign(persistent_id, tag)`

Assigns an existing tag to an active-context group/component instance. Raw edges/faces are intentionally refused to preserve SketchUp modeling hygiene.

### `material_create(name, color?)`

Creates or updates a material. Optional color is integer RGB `[r,g,b]`, each channel 0..255.

### `material_assign(persistent_id, material, side="both")`

Assigns an existing material. Faces support `front`, `back`, or `both`; non-face entities accept only `both`.

## Active edit-context rule

Mutation tools resolve by persistent ID and then require the entity parent to match the parent of `model.active_entities`. This prevents a request from mutating nested geometry outside the context currently open for editing.

## Error behavior

The provider never returns fake success for a failed live action. Representative typed kinds include:

- `live_bridge_unavailable`
- `live_model_unavailable`
- `invalid_argument`
- `invalid_geometry`
- `object_not_found`
- `inactive_edit_context`
- `unsupported_object_type`
- `already_exists`
- `tag_not_found`
- `material_not_found`
- `unauthorized`
- `unsupported_command`
- `unsupported_geometry_action`
- `transaction_start_failed`
- `transaction_commit_failed`
- `semantic_state_too_large`
- `geometry_execution_failed`
- `non_isolated_face`
- `context_mismatch`
- `non_invertible_transform`
- `non_manifold_operand`
- `locked_object`
- `boolean_failed`
- `definition_not_found`
- `copy_failed`
- `component_failed`
- `group_failed`
- `complexity_budget_exceeded`

## Security

- Ruby bridge: `127.0.0.1` only + per-user random credential.
- Arbitrary Ruby/script execution: **not supported**.
- Network MCP bind: strong Bearer credential + exact Host allowlist required.
- Secrets are not returned in tools or normal logs.
- Strict autonomous geometry uses `AI_Step`, validates semantic state before commit, and verifies rollback by model fingerprint.
- Legacy model mutations remain native SketchUp undo operations and abort on exception while they await semantic-path migration.
- Transform operations reject zero scale factors.

## Acceptance status

Measured native acceptance on SketchUp 2024 `24.0.594` / Ruby `3.2.2` covers the live bridge plus strict box, face, isolated extrusion-to-group, absolute transform, manifold boolean, Group/ComponentInstance delete, strict group composition, strict component/instance semantics and strict copy/array/mirror duplication, including negative/rollback cases. The current provider exposes **38 tools** at contract **`0.12`**. The current public tree automated suite is **115/115 PASS**. A Streamable HTTP MCP smoke verified all 38 tools have metadata schema v2 descriptors, stable static capability fingerprinting, observed SketchUp `24.0.594`, strict/deprecated separation, operation/query receipt metadata, ready live status and the proven committed strict array. Receipt v1 itself was live-accepted for box, face, extrusion, transform, boolean, delete, group, component, place, unique, copy, array, mirror, rollback, query and public MCP transport. See [Compatibility](COMPATIBILITY.md) for the supported-runtime claim.
