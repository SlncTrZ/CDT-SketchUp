# CDT-SketchUp

SketchUp-native MCP provider implementing a **Generic CAD Primitive / Execution Engine** with bounded native execution, semantic state and verified transactional mutation paths.

> Current provider version: `0.1.0` · Contract: `0.25`
> Measured native runtime: SketchUp 2024 `24.0.594` / Ruby `3.2.2`

## What it is

CDT-SketchUp lets MCP clients query and manipulate the active SketchUp model through typed generic CAD tools. It is intentionally domain-neutral: architecture, structure, MEP, mechanical, interior, infrastructure, TCVN/QCVN and engineering Audit Report logic belong to external Domain Agents.

```text
Domain Agent / MCP client
        ↓
CDT-SketchUp Python MCP provider
        ↓ bounded authenticated loopback JSON
CDT-SketchUp Ruby extension
        ↓ SketchUp Ruby API on main thread
active SketchUp model
```

No arbitrary Ruby/script execution tool is exposed.

## Current callable surface

Read/system tools:

- `help`
- `system_status`
- `system_capabilities`
- `document_info`
- `object_list`
- `object_get`
- `get_entity_state`
- `definition_info`
- `measure_distance`
- `query_topology`
- `query_overlap`
- `asset_list`
- `place_asset`
- `texture_list`
- `material_apply_texture`
- `material_info`
- `camera_get`
- `camera_set`
- `scene_list`
- `scene_create`
- `model_save`
- `model_save_as`
- `model_open`
- `model_export`
- `model_list`
- `integrity_report`
- `repair_reverse_face`
- `repair_erase_degenerate`

Strict Semantic State Loop surface:

- `execute_geometry`
- `transform_entity`
- `move_entity`
- `rotate_entity`
- `scale_entity`
- `boolean_operation`
- `delete_entity`
- `group_entities`
- `create_component`
- `place_instance`
- `make_unique`
- `copy_entity`
- `linear_array`
- `radial_array`
- `mirror_entity`
- `create_polyline`
- `create_rectangle`
- `create_circle`
- `create_arc`
- `create_polygon`

Current closed strict actions:

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
- `sweep_profile`

`delete_entity` remains the preferred strict object-deletion path for unlocked active-context Groups and ComponentInstances. Raw Edge/Face deletion uses `execute_geometry(action="delete_topology_entity")`; connected-face push/pull uses `execute_geometry(action="push_pull_topology_face")`. Both require a prior `topology_closure_fingerprint` from `query_topology`, recheck that closure before and inside `AI_Step`, and commit only when affected PID accounting stays inside the bounded pre/post topology contract. The topology additions in contracts `0.23`–`0.24` are now natively accepted on SketchUp 2024 `24.0.594` / Ruby `3.2.2`; document/path safety changes from `0.22` remain a separate acceptance scope.

Contract `0.25` closes a copy-fidelity gap discovered by the townhouse stress test: `copy_entity`, `linear_array`, and `radial_array` now preserve generic instance-level appearance/classification properties (material, tag, name, hidden state and shadow flags) for Groups and ComponentInstances, and the strict receipt validation aborts if those properties do not survive duplication.

Compatibility modeling tools currently also include edge/face/group creation, selection, delete, move/rotate/scale, push/pull, box component, tags and basic materials. These older mutation paths are not claimed equivalent to the strict pre-commit semantic-validation path; see the [Tool Guide](docs/TOOL_GUIDE.md).

## Machine-readable capability safety

`system_capabilities` now returns **capability metadata schema v2** for every public MCP tool. Clients can select safe paths from JSON instead of inferring from prose. Each descriptor reports the tool/capability key, live support state, `safety_class`, read-only/destructive status, transaction and verified-rollback guarantees, identity semantics, unit/coordinate semantics, idempotence, limits, measured runtime versions, deprecation/replacement state, and whether the tool is preferred.

The four safety classes are:

- `read_only` — no model mutation;
- `strict_mutation` — Semantic State Loop mutation with transaction/compensation + pre-commit validation + verified rollback;
- `external_side_effect` — bounded preferred file/application action with verified completion but no claimed SketchUp transaction or rollback;
- `deprecated_legacy` — compatibility mutation path retained temporarily but excluded from `preferred_tools`.

A deterministic `capability_fingerprint` hashes only static descriptor semantics, so runtime availability changes do not masquerade as contract changes. `observed_runtime` is reported separately from the measured `runtime_versions` evidence list.

## Unified semantic receipts

Strict mutations, semantic queries, and document side effects expose discoverable **receipt schema v1**. Strict geometry returns `operation` receipts, semantic reads return `query` receipts, and document save/open/export returns `external_side_effect` receipts.

Strict operation receipts include `receipt_id`, command/action, commit truth, context, exact affected PID sets, entity states, before/after model fingerprints, validation, rollback detail, duration and non-secret limits. External-side-effect receipts explicitly report `transactional=false`, `rollback_supported=false`, and verified completion rather than pretending a SketchUp transaction was committed.

Affected PID accounting is derived from bounded semantic snapshots of the active edit context: created entities are new PIDs, changed/reparented surviving PIDs are `modified`, and only PIDs that no longer resolve are `deleted`. This avoids falsely describing extrusion source topology as deleted when SketchUp has moved it inside the new Group.

Receipt context identity is now verified at contract `0.9`: query receipts provide deterministic `context.id`, `context.revision`, and `entity_fingerprint`; successful operations preserve `context_before` and return the new post-commit `context`.

## Explicit units and coordinate space

Strict semantic tools no longer require clients to know SketchUp's native length storage. `execute_geometry`, `get_entity_state`, `transform_entity`, `boolean_operation`, and `delete_entity` expose `unit` with `mm | cm | m | in | ft | model` and `coordinate_space="active_context"`. The default remains `in` for contract-`0.9` compatibility, but new integrations should send a unit explicitly.

The native bridge converts dimensional request values exactly once at its boundary, performs SketchUp operations in native inches, and converts semantic states/validation evidence back to the requested unit. `model` resolves to the active model's configured length unit and the receipt reports both `unit` and `resolved_unit`. Bounds/points/distances use the declared length unit, areas use its square, volumes its cube, and transformation matrix translations at indices 12–14 use the declared length unit; rotation/scale matrix terms remain unitless.

Only active-edit-context coordinates are claimed today. Model/world coordinate input is rejected rather than silently transformed. Legacy compatibility mutation tools retain their documented internal-inch behavior until migrated.

## Strict transform convenience tools

`move_entity`, `rotate_entity`, and `scale_entity` are preferred ergonomic tools over the absolute `transform_entity` matrix API. Each convenience call first reads the current semantic transform/context/fingerprint, constructs an explicit absolute target transform, then submits that target through the same strict `transform_entity` Semantic State Loop with automatic `if_context` and `if_match` guards. Relative transform math never opens a second native mutation path. `mirror_entity` follows the same pattern with an explicit reflection target (negative-determinant absolute transform).

The older `object_move`, `object_rotate`, and `object_scale` MCP names remain deprecated compatibility aliases, but they now route through the same strict wrapper engine and return operation receipts. Their former direct Ruby bridge commands are no longer exposed.

## Context identity and stale-write protection

Contract `0.9` adds deterministic optimistic-concurrency guards for strict mutations. `get_entity_state` returns a verified context object plus the entity semantic fingerprint. Strict mutation tools accept optional `if_context={id, revision}` and `if_match=<semantic_fingerprint>`.

`context.id` identifies the current SketchUp process/model/edit path using a process-session token, model GUID, and active-path persistent/definition identity. `context.revision` hashes that context identity with the canonical model fingerprint, so model-state changes advance the revision while an unchanged edit path retains the same context ID.

Guards fail before `AI_Step`: a changed model/edit context returns `context_mismatch`; a changed target entity returns `stale_entity_state`. Successful operation receipts retain both `context_before` and the new post-commit `context`, allowing clients to chain safely without guessing which revision the operation consumed.

For low-LLM-dependency usage, the intended flow is: query → echo `context` as `if_context` and `entity_fingerprint` as `if_match` → mutate. `system_capabilities` advertises supported preconditions per strict tool.

## Semantic State Loop

Strict autonomous mutations use:

```text
exact target/context
  -> AI_Step transaction
  -> native SketchUp action
  -> semantic extraction
  -> invariant + fingerprint validation before commit
  -> commit or verified rollback
```

Machine geometry validation uses semantic model state, not viewport screenshots.

## Requirements

- Python 3.10+
- `mcp>=2.2,<3`
- SketchUp Desktop with Ruby API
- no third-party Ruby gems

See [Compatibility](docs/COMPATIBILITY.md) for measured native support.

## Build and install the SketchUp extension

```bash
python scripts/build_rbz.py
```

Install `dist/cdt-sketchup-bridge-0.1.0.rbz` from SketchUp Extension Manager. The extension registers `CDT-SketchUp Bridge` and starts a loopback bridge on `127.0.0.1:9876`.

The extension creates a random per-user bridge credential outside the repository:

- Windows: `%LOCALAPPDATA%\\CDT-SketchUp\\bridge.token`
- other supported development environments: `~/.cdt-sketchup/bridge.token`

## Run the MCP provider

```bash
python -m pip install -e .
cdt-sketchup
```

Default endpoint:

```text
http://127.0.0.1:8765/mcp
```

Loopback is the default. For an explicit non-loopback bind, startup requires:

- `CDT_SKETCHUP_MCP_TOKEN` — at least 32 characters;
- `CDT_SKETCHUP_ALLOWED_HOSTS` — exact comma-separated Host allowlist.

Optional browser origins use `CDT_SKETCHUP_ALLOWED_ORIGINS`. Remote production deployments still need normal TLS/reverse-proxy protection.

## Safety highlights

- Ruby bridge is loopback-only;
- random local bridge credential;
- bounded bridge frames and object/geometry work;
- no arbitrary Ruby, shell or script execution surface;
- persistent-ID targeting for identity-sensitive operations;
- active edit-context checks;
- strict semantic validation before commit;
- verified rollback for strict failure paths;
- fail-closed live capability discovery;
- domain-neutral provider boundary.

See [Security](docs/SECURITY.md).

## Verification

Offline tests:

```bash
python -m unittest discover -s tests -v
```

The current public tree automated suite is **202/202 PASS** on the measured Windows development environment.

Native acceptance has been measured on SketchUp 2024 for the baseline bridge plus strict box, face, isolated extrusion-to-group, absolute transform, manifold boolean, object delete, strict group composition, strict component/instance semantics, strict copy/array/mirror duplication, strict tag/material assignment, strict curve/polyline primitives, strict profile sweep, read-only measurement/topology queries, allowlisted asset placement, real-world texture scale, camera/scene control, rooted document lifecycle and CAD integrity with safe repair, including negative/rollback cases. The public HTTP MCP surface was live-smoked at contract `0.21` with 64 tools. Contract `0.22` corrected safety semantics for document I/O, error sanitization, rooted-path containment, and unsaved-model protection. Contract `0.23` added bounded topology closure plus topology-aware raw Edge/Face deletion; contract `0.24` added guarded connected-face push/pull under the same 64-tool MCP surface. The `0.23`–`0.24` topology path has now been natively exercised twice on fresh disposable SketchUp 2024 models, including connected closure discovery, successful connected push/pull, stale-fingerprint fail-closed behavior, and topology-aware raw delete. Contract `0.25` additionally natively verifies generic copy-property fidelity across direct copy, linear array, radial array and Group copy. Contract `0.22` document/path safety remains a separate native-acceptance scope.

`cdt-sketchup-doctor` provides offline and live health checks (`doctor`, `doctor --live`), extension install/uninstall, token repair, and a sanitized `support-bundle` that never includes credential material. The RBZ build is byte-reproducible (fixed archive metadata).

## Public documentation

- [Documentation index](docs/README.md)
- [Architecture](docs/ARCHITECTURE.md)
- [Security](docs/SECURITY.md)
- [Tool Guide](docs/TOOL_GUIDE.md)
- [Compatibility](docs/COMPATIBILITY.md)

Public product use does not depend on local development plans or session handoff files.
