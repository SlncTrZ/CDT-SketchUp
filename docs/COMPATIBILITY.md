# CDT-SketchUp Compatibility

This document lists **measured** compatibility only. Unmeasured newer SketchUp versions are not implied to be supported.

## Current native acceptance

| Component | Measured version | Status |
| --- | --- | --- |
| SketchUp Desktop | 2024 `24.0.594` | live accepted for current baseline |
| SketchUp Ruby | `3.2.2` | live accepted |
| Python | `3.10+` contract | package requirement |
| MCP Python package | `>=2.2,<3` | package requirement |

The current native acceptance includes the baseline live bridge and strict semantic-loop proof for box, face, isolated extrusion-to-group, absolute transform, manifold boolean, Group/ComponentInstance delete, strict group composition, strict component/instance semantics, strict copy/array/mirror duplication, strict tag/material assignment, strict curve/polyline primitives, strict profile sweep, read-only measurement/topology queries, allowlisted asset placement, real-world texture scale, camera/scene control, rooted document lifecycle and CAD integrity with safe repair. Contract `0.21` was live-smoked through the Streamable HTTP MCP surface with 64 discovered tools. Contract `0.22` corrected safety semantics for document I/O and rooted paths; contract `0.23` added bounded topology closure/fingerprinting and topology-aware raw Edge/Face deletion; current contract `0.24` keeps the same 64 MCP tools and adds guarded connected-face push/pull as an `execute_geometry` action. The topology additions from `0.23`–`0.24` are now natively accepted on SketchUp 2024 `24.0.594` / Ruby `3.2.2` through two fresh disposable-model runs. Each measured a 9-entity adjacent-face closure, committed connected push/pull with 13 created / 5 modified / 0 deleted PIDs, observed a changed post-topology fingerprint, rejected the stale pre-push fingerprint without mutation, and committed topology-aware raw delete with 4 modified / 1 deleted PID. Contract `0.22` document/path safety remains a separate native-acceptance scope.

Explicit-unit acceptance on the same native runtime proves `25.4×50.8×76.2 mm` and `1×2×3 in` produce equivalent semantic geometry, `254/508/762 mm` transform translation reads back as `10/20/30 in`, `unit=model` resolves the active model unit, and unsupported coordinate spaces fail closed. Public Streamable HTTP MCP smoke also verified explicit-mm create, inch query, capability metadata, and strict cleanup.


## Other SketchUp releases

Later SketchUp major releases may work but are **not claimed supported until separately live-tested**. Native API behavior can change across versions, including transformation semantics and solid operations.

## Platform

The measured live acceptance was performed on Windows. Other desktop platforms require separate runtime verification before they are advertised as supported.

## Version truth

`system_status` and `system_capabilities` report observed live runtime state. If the bridge or model is unavailable, live capabilities fail closed rather than pretending headless support.


Context/stale-write acceptance on SketchUp 2024 proves a real `active_path` switch causes an old guarded write to fail as `context_mismatch` with no semantic mutation; an entity changed after query causes stale `if_match` deletion to fail as `stale_entity_state`; unchanged fresh context/fingerprint permits the guarded write and advances revision. The same three cases were independently verified through the public Streamable HTTP MCP surface.

## Measured performance and bounds

Loopback read paths sit at a ~62 ms p50 floor (dominated by the bridge poll interval); `get_entity_state` measured 124–189 ms p50 and strict create 211–373 ms p50 as the active context grows from 1 to ~120 entities on the measured runtime. Bounded work fails closed rather than degrading: a strict-create overload probe refused the next operation at exactly **499 boxes** against the `MAX_OBJECTS=500` fingerprint budget. These are single-runtime measurements on one machine, not guarantees; re-measure on new hardware or SketchUp versions before advertising budgets.

A three-domain composition benchmark (architecture-style boolean opening, structure-style column array, interior-style tag/material/camera/scene) completed using only generic primitives with the provider tool set unchanged, confirming that external Domain Agents can compose workflows without provider modifications.
