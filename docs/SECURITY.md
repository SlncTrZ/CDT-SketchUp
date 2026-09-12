# CDT-SketchUp Security Model

CDT-SketchUp is designed to expose useful SketchUp automation without exposing arbitrary Ruby or shell execution.

## Trust boundaries

### MCP network surface

The provider defaults to loopback. If explicitly bound beyond loopback, startup fails closed unless a bearer token of at least 32 characters and an exact Host allowlist are configured. Optional browser-origin allowlisting is also supported.

Production remote exposure should still be placed behind the deployment's normal TLS/reverse-proxy boundary.

### Provider-to-SketchUp bridge

The Ruby extension bridge:

- binds to `127.0.0.1` only;
- uses a random per-user credential stored outside the repository;
- accepts only a versioned, bounded JSON protocol;
- limits request/response frame size;
- does not accept arbitrary Ruby code strings.

### SketchUp model mutation

Relative transform convenience calls do not have a separate native mutation authority. Preferred move/rotate/scale tools and their deprecated compatibility aliases resolve semantic state and route through strict absolute `transform_entity`; the former direct Ruby bridge move/rotate/scale commands are not exposed.

Strict optimistic-concurrency guards prevent stale autonomous writes. `if_context` is a closed `{id, revision}` object and `if_match` is a lowercase SHA-256 semantic fingerprint. Context mismatch is evaluated before action preflight, and entity-state mismatch before `AI_Step`; neither failure opens a mutation transaction.

Identity-sensitive mutations target SketchUp persistent IDs and active edit context. Strict mutations use a SketchUp operation transaction, semantic validation before commit and verified rollback on failure.

A transport-level response is not considered proof that geometry is correct.

Strict dimensional inputs are fail-closed: accepted units are `mm|cm|m|in|ft|model`, and the only claimed coordinate space is `active_context`. Unknown units/spaces are rejected before native mutation begins; no silent world/local coordinate conversion is attempted. Legacy internal-inch mutations remain explicitly deprecated.

The machine-readable capability registry prevents clients from having to guess which mutation path has stronger guarantees. `strict_mutation` means Semantic State Loop execution with verified rollback semantics. File/application actions such as save/open/export are labeled `external_side_effect`, report `transactional=false` and `rollback_verified=false`, and return verified-completion receipts instead of pretending native undo/rollback exists. Compatibility mutations are explicitly marked `deprecated_legacy` and excluded from the preferred autonomous tool set.

Strict operation receipts include an `affected_verified` flag. Successful strict commits set it only after bounded semantic snapshot comparison; rollback receipts set it only when the abort result and exact before/after-rollback model fingerprints prove restoration. A reparented PID that still resolves is classified as modified, not deleted.

Strict object delete remains limited to unlocked active-context Groups and ComponentInstances. Raw Edge/Face deletion and connected-face push/pull use separate topology-aware contracts. An incremental bounded closure is fingerprinted before mutation and rechecked immediately before native erase/pushpull. Raw delete requires every modified/deleted PID to remain inside the pre-closure. Connected push/pull additionally requires the source Face PID to survive, all modified/deleted pre-existing PIDs to remain inside the pre-closure, and all created PIDs to belong to the bounded post-closure rooted at the surviving source Face. Stale closure fingerprints, closure budget overflow, or collateral effects outside those sets force transaction abort. Contract 0.24 implementation is regression-verified but still pending native SketchUp acceptance.

## Current bounded-work controls

The current runtime includes limits for bridge frames, concurrent bridge clients, object scans, face point counts and semantic fingerprint complexity. Limits may evolve as performance is measured; `system_capabilities` and public tool documentation are the authoritative released surface.

## Secrets

Bridge and MCP bearer credentials must never be returned by MCP tools or written to normal logs. The repository must not contain credentials.

## Files and assets

Current released tools do not provide a raw arbitrary filesystem execution surface. Model files use an explicit owner-local `models/` root; component and texture assets use allowlisted registries. Plain-name/extension checks are combined with canonical `realpath` containment, including existing symlink/reparse targets and canonical parent checks for new output files, so an allowed-root entry that resolves outside the root fails closed.

## Fail-closed behavior

Examples of states that must fail rather than silently continue include:

- live SketchUp bridge unavailable;
- active model unavailable;
- unsupported or inactive edit context;
- malformed/non-finite geometry input;
- non-invertible strict transformation;
- invalid/non-manifold boolean operands;
- semantic validation failure;
- result semantic state exceeding configured bounds;
- unverifiable rollback;
- unsaved active model before `model_open`;
- rooted file/asset target whose canonical path escapes its allowed root.

## Domain security boundary

CDT-SketchUp does not evaluate TCVN/QCVN, discipline compliance or engineering approval. Those are Domain Agent responsibilities and must not be confused with generic CAD integrity checks such as manifold validity, bounds, volume, collisions or topology.

Security issues should be assessed against the exact released version and supported SketchUp runtime listed in [Compatibility](COMPATIBILITY.md).
