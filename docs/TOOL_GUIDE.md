# CDT-SketchUp Tool Guide

> Status: contract 0.28 · measured native acceptance on SketchUp 2024 `24.0.594` / Ruby `3.2.2` · 67 public MCP tools · Updated: 2026-09-14

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

`safety_class` is one of `read_only`, `strict_mutation`, `external_side_effect`, or `deprecated_legacy`. `strict_mutation` means a native/compensated Semantic State Loop write with verified rollback semantics. `external_side_effect` is a preferred bounded file/application action whose completion is verified but which does **not** claim a SketchUp transaction or rollback. Compatibility mutations remain callable for transition but appear in `compatibility_tools` and are explicitly `preferred=false`. A replacement such as `execute_geometry:create_face` names a strict action selector rather than a separate MCP tool.

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

The semantic surface uses discoverable receipt envelopes. `execute_geometry` and its strict wrappers return `receipt_kind="operation"`; read-only semantic queries return `receipt_kind="query"`; document save/open/export actions return `receipt_kind="external_side_effect"`. `system_capabilities` advertises `receipt_kind` and `receipt_schema_version` per tool, so clients can discover this without probing result shapes.

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

Strict operation receipts additionally expose:

```text
action
committed / commit_verified
affected / affected_verified
model.before / model.after / model.after_rollback
validation
rollback
error
```

External-side-effect receipts instead expose `transactional=false`, `rollback_supported=false`, `rollback_verified=false`, `side_effect_completed`, `side_effect_verified`, `validation`, and the verified file/application result. They never imply that a SketchUp `AI_Step` transaction was committed.

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

### `execute_geometry(action, params, expect, target_context?)`

Executes one closed geometry action inside `model.start_operation("AI_Step", true)`. Contract `0.26` optionally accepts `target_context={"instance_path":[...]}` to execute the same closed action inside a bounded nested edit context without exposing arbitrary Ruby or an unrestricted context-navigation API.

`instance_path` contains 1..32 persistent IDs from outermost to innermost Group/ComponentInstance. The native bridge resolves every PID, rejects duplicates and locked/invalid paths, constructs a native `Sketchup::InstancePath`, enters it **before** starting `AI_Step`, and restores the caller edit path after the inner strict operation finishes. This ordering is intentional: changing SketchUp's active edit context is not treated as part of the mutation transaction. Invalid/stale nesting fails before mutation as `context_target_unavailable`.

With `target_context`, `if_context` guards the caller context before the switch. `if_match` is then evaluated by the normal strict action in the target context. Input coordinates still use `coordinate_space="active_context"`, which means **local coordinates of the targeted edit context**; no world/model-space conversion is implied. The operation receipt keeps its normal `context_before`/`context` for the target execution and adds `context_targeting` with the requested instance path, caller context before/after, target execution contexts, and a verified restoration record.

Component definition edits are shared by all instances using that definition. For instance-specific geometry, call the existing strict `make_unique` on the ComponentInstance while it is targetable in its parent context, then perform the nested edit. The provider never silently makes a component unique. If a committed target operation succeeds but caller-context restoration later cannot be verified, the committed receipt remains authoritative and `context_targeting.restoration.verified=false`; callers must inspect that state and must not blindly retry.

Current action allowlist:

- `create_box`
- `create_face`
- `extrude_face_to_group`
- `transform_entity`
- `boolean_operation`
- `delete_entity`
- `delete_topology_entity`
- `push_pull_topology_face`
- `group_entities`
- `create_component`
- `place_instance`
- `make_unique`
- `copy_entity`
- `linear_array`
- `radial_array`
- `create_polyline`
- `create_rectangle`
- `create_circle`
- `create_arc`
- `create_polygon`
- `create_mesh`
- `sweep_profile`

The action, semantic extraction and validation all happen before commit. A successful step requires SketchUp to return a successful `commit_operation`; the response reports `commit_verified=true`.

Strict requests normally provide `expect.active_entity_delta` plus at least one additional entity semantic check. `delete_topology_entity` and `push_pull_topology_face` are deliberate topology exceptions because native raw-geometry operations can cascade. Raw delete requires `expect.deleted=true`; connected push/pull requires `expect.type=Face`. Both verify exact affected PID containment instead of asking the caller to guess an entity delta. Validation supports:

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

Before opening `AI_Step`, the native bridge validates the closed PID-only parameter schema, resolves the target, checks active edit context, supported object type and lock state. Raw `Edge`/`Face` targets remain intentionally excluded from this object-delete contract; they use the separate topology-aware action below.

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

### `delete_topology_entity(persistent_id, topology_closure_fingerprint)`

Closed `execute_geometry` action for one active-context raw `Edge` or `Face`. The caller first obtains `topology_closure_fingerprint` from `query_topology`, then submits that fingerprint with the target PID and `expect={deleted:true}` (optional `type=Edge|Face`). `active_entity_delta` is intentionally not accepted for this action because native edge deletion can invalidate adjacent faces.

Preflight incrementally computes the bounded raw topology closure and rejects a stale fingerprint before `AI_Step`. Inside the transaction the bridge recomputes and rechecks the same closure immediately before `erase_entities`, preventing a topology race between preflight and mutation. After deletion, strict affected-set validation requires: no created PIDs, the target PID is deleted, and every modified/deleted PID is contained in the exact pre-mutation closure. Any collateral effect outside that closure aborts the transaction and goes through verified rollback.

Contract `0.23` raw topology deletion is now natively accepted on SketchUp 2024 `24.0.594` / Ruby `3.2.2` through the contract `0.24` topology smoke, including exact closure fingerprinting, current-fingerprint delete authorization, and verified affected-set containment.

### `push_pull_topology_face(persistent_id, distance, topology_closure_fingerprint)`

Closed `execute_geometry` action for in-place push/pull of an active-context Face even when it participates in connected raw topology. The caller first obtains `topology_closure_fingerprint` from `query_topology`, then submits that fingerprint with the target PID, non-zero signed `distance`, and `expect={type:"Face"}`. `active_entity_delta` is intentionally not accepted because SketchUp can create side faces and split/merge connected raw geometry.

The bridge verifies the bounded pre-mutation closure before `AI_Step` and recomputes it again immediately before `Face#pushpull`. The source Face PID must survive and remain in the active edit context. After mutation, the bridge computes a bounded post-closure from the surviving source Face. Commit is allowed only if every modified/deleted pre-existing PID belongs to the original pre-closure and every newly created PID belongs to the post-closure. Any unrelated existing geometry touched by native push/pull, any created entity outside the resulting connected topology, source-face loss, stale closure, or closure budget overflow aborts the operation and goes through verified rollback.

Contract `0.24` connected push/pull is now natively accepted on SketchUp 2024 `24.0.594` / Ruby `3.2.2`. Two fresh disposable-model runs measured a 9-entity connected pre-closure; push/pull committed with 13 created / 5 modified / 0 deleted PIDs, produced a changed post-topology fingerprint, and a stale pre-push fingerprint was rejected without mutation.

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

### `measure_distance(first_pid, second_pid, unit?)`

Read-only exact spatial measurement for two distinct manifold Group/ComponentInstance solids. The result preserves legacy `center_distance`, `bounds_gap` and `bounds_overlap` facts, then adds bounded triangulated-surface truth: `relationship=disjoint|touching|penetrating`, `surface_clearance`, collision/intersection booleans and `exact=true`. Triangle extraction includes bounded nested groups/components; non-manifold operands or triangle/pair budgets fail closed. The query performs no SketchUp boolean/copy mutation and native acceptance proves the active model count is unchanged.

### `query_topology(persistent_id)`

Read-only connectivity facts for one entity: bounded connected PID set (500 max, with unresolved-entity accounting for members without persistent IDs), vertex/edge/face counts, face loop count, manifold state, and `topology_closure_fingerprint` for raw Edge/Face topology. Raw topology uses an incremental bounded BFS over native face/edge/vertex adjacency instead of materializing an unbounded `all_connected` result first; the same closure primitive is reused by strict grouping preflight. Groups expose members and instances expose definition members.

### `query_overlap(first_pid, second_pid, unit?)`

Read-only exact relation for two distinct manifold Group/ComponentInstance solids. Bounding-box overlap/box facts remain as broad-phase evidence, while the authoritative relation is derived from bounded native-face triangulation and reports `disjoint`, `touching`, or `penetrating`; a rotated-solid acceptance case proves that AABB overlap alone does not create a false collision. `clearance` is exact surface clearance for disjoint operands and zero for touching/penetrating operands. Non-manifold inputs fail as `non_manifold_operand`; no intersection geometry is created.

### `asset_list()`

Read-only listing of the owner-curated component asset registry. Contract `0.26` makes registry identity cryptographic rather than filename-only: each `assets.json` entry must provide a plain `.skp` `file`, a lowercase 64-hex `sha256` for the exact file bytes, and a non-empty `native_version` owned by the catalog/release process; `name` remains optional display metadata. `native_version` is an asset/catalog version, not the SketchUp runtime version.

The bridge enforces canonical containment, the 64 MiB per-file cap, at most 256 manifest entries, and at most 512 MiB of aggregate hashing work per listing. `asset_list` hashes the actual file and reports `available=true` only when the bytes match the declared SHA-256; verified rows expose `asset_key`, `file`, `size_bytes`, `sha256`, and `native_version`. Invalid, missing, mismatched, or over-budget entries remain visible as `available=false` with a sanitized reason so consumers can fail closed instead of mistaking omission for success.

Example manifest entry:

```json
{
  "drawer_box": {
    "name": "Drawer Box",
    "file": "drawer_box.skp",
    "sha256": "<64 lowercase hex characters>",
    "native_version": "2026.09.14-1"
  }
}
```

### `place_asset(asset_key, matrix, target_context?)`

Strict placement of a **verified** registry asset as a new component instance at an absolute transform, optionally using the same bounded nested `target_context` as `execute_geometry`. The MCP caller passes only the asset key — never a path. The bridge re-hashes the file before placement, detects incompatible/unbound same-path definitions already loaded in the model, and fails closed as `asset_definition_identity_mismatch` rather than trusting SketchUp definition-cache reuse.

For a newly loaded definition, the file is hashed again after `definitions.load`; changed bytes fail as `asset_changed_during_load` and the transaction is aborted. A successful new load binds `{asset_key, sha256, native_version}` into definition attributes and reads the binding back before an instance may be placed. Reused definitions must already carry the exact same binding. `get_entity_state` and `definition_info` expose that `asset_identity`, so the placement evidence names the exact registry identity used rather than only a filename or definition GUID.

Contract 0.28 native acceptance verifies cryptographic placement end-to-end: wrong hash, missing/oversized/changed bytes, exact identity reuse, version drift, used-definition identity collision, save/reopen persistence, `make_unique` instance isolation and shared-definition geometry drift all fail/pass according to the strong identity contract. Verified asset evidence also resolves through CDT_Engineer's catalog resolver; mismatched SHA-256 is blocked. Capability metadata therefore records SketchUp `24.0.594` for these semantics.

### `texture_list()`

Read-only listing of the owner-curated texture registry (`textures.json` beside the asset manifest): neutral metadata per texture (key, file, size). Raster images only (`.png`/`.jpg`/`.jpeg`/`.bmp`), 16 MiB cap, same traversal containment as components.

### `material_apply_texture(material, texture_key, width, height)`

Strict application of a registry texture to an existing material at an explicit real-world size, using the native `texture.size` scale. Unknown materials fail as `material_not_found` and unknown textures as `texture_not_found`, both before any mutation. The applied dimensions are read back from the native texture object and verified exactly; the queryable material state reports real-world width/height in the requested unit plus pixel dimensions and file name. Material mutations do not move active-entity fingerprints, so the proof here is read-back verification plus abort semantics rather than fingerprint deltas — stated honestly because the loop must not pretend otherwise.

### `material_info(material)`

Read-only material state by exact name: color, texture file/dimensions/pixels, and fingerprint. Unknown names return `material_not_found`.

### `camera_get(unit?)`

Read-only active-view camera state: eye/target in the requested length unit, unitless up direction, field of view in degrees, and perspective flag, plus a camera fingerprint for stale-view guards.

### `camera_set(eye, target, up?, fov?, unit?)`

Strict active-view camera placement through the native `Camera#set` API (SketchUp 2024 exposes no per-component setters). Eye/target honor the explicit unit contract; `up` defaults to the current up and `fov` to the current field of view. Verified per commit: exact eye/target/fov plus a proven-orthogonal up vector (SketchUp orthogonalizes `up` against the view direction, so the invariant checks orthogonality and half-space rather than naive equality). `if_match` guards the camera fingerprint, so orbiting between query and write fails as `stale_entity_state` without mutation.

Camera moves are view state, not model state: native undo does not cover them. Rollback therefore uses explicit compensation (restore previous camera, verify fingerprint) rather than pretending `abort_operation` suffices — measured live, including a stale-guard rejection that left the camera untouched.

### `scene_list()`

Read-only model scene registry: names and count.

### `scene_create(name)`

Strict model scene creation with exact-name semantics; duplicates fail as `already_exists` before mutation. Measured live: `abort_operation` does **not** revert `pages.add`, so rollback here is also explicit compensation (erase the created page, verify absence) — proven by a wrong-expectation abort that left no leaked scene. Scene update/delete remain deferred.

### `model_save()` / `model_save_as(file, overwrite=false)` / `model_open(file, if_model_guid?)` / `model_export(file, format, overwrite=false, width?, height?)` / `model_list()`

Rooted document lifecycle under the owner-local `models/` directory (beside the bridge credential and asset registry). Only plain file names are accepted — traversal, absolute paths, non-allowlisted extensions, and canonical-path escapes through symlinks/reparse points fail closed before I/O. `model_save` requires an existing path (`model_save_failed` otherwise — use `model_save_as`); `model_save_as` enforces `.skp` plus explicit overwrite (`model_already_exists` without it); `model_open` enforces existence, requires the active model to have no unsaved changes (`unsaved_model_changes`), and supports an optional stale-model GUID guard (`context_mismatch`); `model_export` supports `dae`/`kmz` through the model exporter and `png`/`jpg` through view image capture (raster exports accept optional pixel dimensions, default 1024×768). These file/application actions are machine-labeled `external_side_effect`: completion is verified, but no SketchUp transaction or rollback is claimed. `model_list` reports neutral file metadata.

### `artifact_seal(file)` / `artifact_verify(file, sha256)`

`artifact_seal` accepts only the saved active rooted SKP and creates a content-addressed accepted copy plus JSON manifest under the owner-local `accepted/` root. It hashes the source before and after copying, hashes the temporary copy, caps work at 1 GiB, uses atomic rename for new accepted files/manifests, and refuses unsaved or changing source state. Repeating a seal for identical bytes is replay-safe and verifies the existing content-addressed copy.

`artifact_verify` checks the accepted copy/manifest, source SHA-256/size, active model identity and unsaved-change state. Mutation makes prior evidence stale; if a later save rewrites bytes, the old SHA-256 remains stale and a new seal receives a new content identity. Native contract-0.28 acceptance verifies seal, stale-after-mutation, reseal-after-byte-change and verify-after-reopen behavior.

### `integrity_report(unit?)`

Read-only generic CAD integrity facts — never discipline conclusions: per-type entity counts, degenerate edges (zero-length, 1e-6 in threshold), non-manifold edges (3+ faces), raw-edge/face tag hygiene (off `Layer0`/`Untagged` defaults), invalid transforms, unused component definitions and materials, model complexity, and a total issue count. Scans are bounded (5000 active entities, definition walk capped) with an explicit truncation flag. Reversed-face detection is intentionally absent: orientation truth lives in solid context, not in a fact query.

### `repair_reverse_face(persistent_id)`

Strict single-face orientation repair: same PID, flipped normal, identical area, geometry otherwise untouched. Wrong expectations abort with fingerprint-verified rollback.

### `repair_erase_degenerate(persistent_id)`

Strict erasure of one zero-length edge that bounds no faces, returning the exact deleted-PID receipt. Preflight rejects healthy edges (`invalid_argument`) and face-bounding degenerates (`unsupported_object_type`) before any mutation. Measured limitation, stated honestly: SketchUp merges sub-tolerance segments at creation, so provider-side fabrication of a degenerate edge for positive-path live proof is impossible — the positive path is offline-verified (schema/invariants/affected) with all negative gates live-proven. Real degenerates arrive via imported files, which is exactly the population this repair serves. Whole-model purge remains deferred: it cannot name exact affected IDs, violating the repair-flow contract.

### `create_polyline(points, closed=false)`

Strict edge-chain creation returning one Group. Points are 2..512 explicit triples; consecutive duplicates are rejected before `AI_Step`. The chain is built inside a fresh group so no stray top-level edges escape, and the total edge length is verified against the input geometry (proving no snapping or drift). A closed planar chain deterministically caps exactly one face with Newell-area proof; open or non-planar chains contain none. `expect` pins `active_entity_delta = 1`, `Group` type, and exact edge/vertex counts.

### `create_rectangle(origin, width, height, normal)`

Strict rectangle profile returning one Group containing four edges plus the capped face. The orthonormal basis is derived deterministically from the explicit plane normal (no hidden snapping), and the four corners are verified as an exact set against the requested origin/dimensions — compared in global coordinates because grouping rebases members into group-local space. Width/height must be positive; degenerate input fails before mutation.

### `create_circle(center, normal, radius, segments)` / `create_arc(center, normal, radius, start_degrees, end_degrees, segments)`

Strict circle/arc loops built with native `add_circle`/`add_arc` inside a fresh group (3..360 segments). Every member vertex is proven at exactly `radius` distance from the center; arc endpoints are additionally proven at the requested start/end angles. Zero radius, zero normal, or zero sweep fail before mutation. `expect` pins `active_entity_delta = 1`, `Group` type, and the exact segment count.

### `create_polygon(center, normal, radius, sides)`

Strict regular-polygon profile returning one Group containing the face plus its side edges (3..360 sides). Vertices are constructed deterministically on the explicit plane, then the face area is verified against the exact `sides/2·r²·sin(2π/sides)` formula and every vertex against the radius. `expect` pins `active_entity_delta = 1`, `Group` type, and exact side counts.

### `create_mesh(name, points, faces, unit?)`

Strict generic indexed-mesh creation for externally planned complex geometry. It creates exactly one isolated Group from 3..2048 unique vertices and 1..4096 polygon faces; each face has 3..16 unique in-range indexes and total index references are capped at 32768. Duplicate vertex coordinates, duplicate face vertex-sets, malformed indexes and budget overflow fail before commit. The strict expectation pins one created Group plus exact vertex/face counts; affected-set validation requires only the resulting Group to be created. Wrong semantic expectations abort with verified rollback.

Native contract-0.28 evidence covers tetrahedron, frustum, four-section loft, ellipsoid, rounded closed profile and open curved molding/ribbon geometry, with measured topology/read-back, manifold/volume checks where applicable, malformed/budget negatives and forced rollback. Shape meaning/tessellation remains the external Domain Agent's responsibility; the executor only consumes the bounded indexed mesh.

### `sweep_profile(face_pid, path_pids)`

Strict Follow-Me sweep of one profile face along an exact connected edge path (1..64 edges), returning one manifold Group. The profile face plus its boundary edges and the path form a closed world: nothing outside that set may connect to them, and the sweep consumes the path rail while the profile survives as the end cap (both outcomes are verified, never assumed). Proven per commit: no collateral consumption, exact reparenting, preserved edge lengths and profile area, manifold result with positive volume, and the exact created/modified/deleted receipt.

Measured native rules worth knowing: `followme` returns only success/failure, so the resulting shell is discovered by snapshot diff and grouped in the same transaction; `add_group` rebases members into group-local coordinates, so positional checks map through the group transform.

Connected-face push/pull is available through `push_pull_topology_face` under contract 0.24 with bounded pre/post topology closure and affected-set containment, and is natively accepted on SketchUp 2024 `24.0.594`. `extrude_face_to_group` stays intentionally isolated-only because it has a different contract: consume an isolated source face, extrude a closed shell, then wrap that shell into a new Group.

### `copy_entity(persistent_id)`

Strict generic CAD copy for one unlocked active-context `Group` or `ComponentInstance`. Groups duplicate with native `copy`; instances place a new instance of the same definition at the same transform. Contract `0.25` additionally propagates and verifies generic instance-level properties: material, tag, name, hidden state, `casts_shadows`, and `receives_shadows`. The copy keeps the source transform and shares the source definition (instances) or geometry (groups) while receiving a new PID. Property mismatch is a semantic validation failure, so the transaction aborts instead of silently producing a visually/classificationally degraded copy. `expect` must pin `active_entity_delta = 1` and the source `type`. `if_match` guards the source semantic fingerprint.

### `linear_array(persistent_id, vector, count)` / `radial_array(persistent_id, axis_origin, axis, degrees, count)`

Strict generic CAD duplication producing exactly `count` new objects in a single `AI_Step` transaction — either all copies commit with verified transforms/properties or the whole array aborts with fingerprint-verified rollback. Linear steps offset each copy by `i × vector`; radial steps rotate each copy by `i × degrees` about the explicit axis. Copies share the source definition (instances) or geometry (groups), and under contract `0.25` every created copy must preserve the source material, tag, name, hidden state and shadow flags.

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

Strict tag assignment for one unlocked active-context `Group` or `ComponentInstance`. Raw edges/faces are rejected before `AI_Step` as generic SketchUp modeling hygiene, and unknown tags fail as `tag_not_found` before any mutation. The assignment keeps the same PID and provably preserves geometry and transform fingerprints; only the tag changes. `expect` must pin `active_entity_delta = 0` and the applied `tag`. `tag_create` remains the idempotent compatibility path for ensuring a tag exists.

### `material_create(name, color?)`

Creates or updates a material. Optional color is integer RGB `[r,g,b]`, each channel 0..255.

### `material_assign(persistent_id, material, side="both")`

Strict material assignment against an existing material — unknown names fail as `material_not_found` before `AI_Step`. Faces support `front`, `back`, or `both`; non-face entities accept only `both`. The assignment keeps the same PID and provably preserves geometry and transform fingerprints. Face back-material is a first-class semantic fact: it participates in the entity fingerprint, stale-write guards, and affected-set accounting exactly like front material. `expect` must pin `active_entity_delta = 0` and the applied `material`.

## Active edit-context rule

Strict action primitives still mutate only `model.active_entities`; entity guards continue requiring the target parent to match the active edit-context parent. Contract `0.26` does **not** bypass that rule. Instead, the generic `execute_geometry(..., target_context={instance_path:[...]})` path performs a bounded, validated native edit-context switch before the strict transaction, executes the unchanged action/guards in that context, and then attempts verified restoration of the caller context. Convenience tools without `target_context` retain the prior active-context-only behavior.

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
- `topology_closure_too_large`
- `topology_unresolvable`
- `stale_topology_state`
- `geometry_execution_failed`
- `non_isolated_face`
- `context_mismatch`
- `non_invertible_transform`
- `non_manifold_operand`
- `locked_object`
- `boolean_failed`
- `definition_not_found`
- `copy_failed`
- `assign_failed`
- `sweep_failed`
- `asset_not_found`
- `asset_too_large`
- `asset_path_escape`
- `asset_registry_too_large`
- `asset_identity_unverified`
- `asset_changed_during_load`
- `asset_definition_identity_mismatch`
- `context_target_unavailable`
- `context_restore_failed`
- `texture_not_found`
- `texture_too_large`
- `texture_path_escape`
- `camera_failed`
- `scene_failed`
- `model_path_escape`
- `model_already_exists`
- `model_not_found`
- `model_save_failed`
- `model_open_failed`
- `unsaved_model_changes`
- `model_export_failed`
- `repair_failed`
- `geometry_execution_failed`
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

Measured native acceptance on SketchUp 2024 `24.0.594` / Ruby `3.2.2` is current through contract **`0.28`** and **67 MCP tools**. In addition to the established semantic-loop baseline, the measured gap matrix proves bounded three-level target-context mutation/restoration, cryptographic asset identity and CDT_Engineer resolver E2E, bounded indexed mesh realization/rollback/budget gates, exact manifold-solid clearance/overlap including rotated AABB false positives, non-manifold fail-closed behavior, uncertain-completion reconciliation + compensation, content-addressed artifact seal/staleness/reseal/reopen, and post-reopen instance-specific/shared-definition asset behavior. The public `runtime_versions` evidence for these capabilities therefore includes `24.0.594`; no other SketchUp major release is implied supported. See [Compatibility](COMPATIBILITY.md).
