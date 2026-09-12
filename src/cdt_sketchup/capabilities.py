"""Capability Registry — Machine-readable safety and usability metadata for every public tool.
Wing: code | Topic: sketchup_capability_metadata | Updated: 2026-09-11 19:58
"""

from __future__ import annotations

from dataclasses import asdict, dataclass
import hashlib
import json
from typing import Any

CAPABILITY_SCHEMA_VERSION = 2
VERIFIED_SKETCHUP_RUNTIME_VERSIONS = ("24.0.594",)
BRIDGE_FRAME_BYTES = 256 * 1024
MAX_OBJECTS = 500
MAX_FACE_POINTS = 512
MAX_FINGERPRINT_EDGES = 20_000


@dataclass(frozen=True)
class CapabilityDescriptor:
    """Static contract metadata for one public MCP tool."""

    tool: str
    key: str
    mode: str
    safety_class: str
    read_only: bool
    destructive: bool
    transactional: bool
    rollback_verified: bool
    identity_semantics: str
    unit_semantics: str
    coordinate_space: tuple[str, ...]
    idempotence: str
    limits: dict[str, int]
    runtime_versions: tuple[str, ...]
    deprecated: bool
    replacement: str | None
    preferred: bool
    receipt_kind: str | None
    receipt_schema_version: int | None
    preconditions: tuple[str, ...]

    def static_payload(self) -> dict[str, Any]:
        payload = asdict(self)
        payload["coordinate_space"] = list(self.coordinate_space)
        payload["runtime_versions"] = list(self.runtime_versions)
        payload["preconditions"] = list(self.preconditions)
        return payload


def _provider(
    tool: str,
    key: str,
    *,
    identity: str = "none",
    idempotence: str = "read_only",
) -> CapabilityDescriptor:
    return CapabilityDescriptor(
        tool=tool,
        key=key,
        mode="provider",
        safety_class="read_only",
        read_only=True,
        destructive=False,
        transactional=False,
        rollback_verified=False,
        identity_semantics=identity,
        unit_semantics="none",
        coordinate_space=("provider",),
        idempotence=idempotence,
        limits={},
        runtime_versions=(),
        deprecated=False,
        replacement=None,
        preferred=True,
        receipt_kind=None,
        receipt_schema_version=None,
        preconditions=(),
    )


def _read(
    tool: str,
    key: str,
    *,
    identity: str,
    units: str = "none",
    limits: dict[str, int] | None = None,
    receipt_kind: str | None = None,
) -> CapabilityDescriptor:
    merged_limits = {"bridge_frame_bytes": BRIDGE_FRAME_BYTES}
    if limits:
        merged_limits.update(limits)
    return CapabilityDescriptor(
        tool=tool,
        key=key,
        mode="live_sketchup",
        safety_class="read_only",
        read_only=True,
        destructive=False,
        transactional=False,
        rollback_verified=False,
        identity_semantics=identity,
        unit_semantics=units,
        coordinate_space=("active_context",),
        idempotence="read_only",
        limits=merged_limits,
        runtime_versions=VERIFIED_SKETCHUP_RUNTIME_VERSIONS,
        deprecated=False,
        replacement=None,
        preferred=True,
        receipt_kind=receipt_kind,
        receipt_schema_version=1 if receipt_kind else None,
        preconditions=(),
    )


def _strict(
    tool: str,
    key: str,
    *,
    destructive: bool,
    identity: str,
    units: str,
    idempotence: str,
    limits: dict[str, int] | None = None,
    preconditions: tuple[str, ...] = ("if_context", "if_match"),
) -> CapabilityDescriptor:
    merged_limits = {
        "bridge_frame_bytes": BRIDGE_FRAME_BYTES,
        "max_model_entities_for_fingerprint": MAX_OBJECTS,
        "max_fingerprint_edges": MAX_FINGERPRINT_EDGES,
    }
    if limits:
        merged_limits.update(limits)
    return CapabilityDescriptor(
        tool=tool,
        key=key,
        mode="live_sketchup",
        safety_class="strict_mutation",
        read_only=False,
        destructive=destructive,
        transactional=True,
        rollback_verified=True,
        identity_semantics=identity,
        unit_semantics=units,
        coordinate_space=("active_context",),
        idempotence=idempotence,
        limits=merged_limits,
        runtime_versions=VERIFIED_SKETCHUP_RUNTIME_VERSIONS,
        deprecated=False,
        replacement=None,
        preferred=True,
        receipt_kind="operation",
        receipt_schema_version=1,
        preconditions=preconditions,
    )


def _legacy(
    tool: str,
    key: str,
    *,
    destructive: bool,
    transactional: bool,
    identity: str,
    units: str,
    idempotence: str,
    replacement: str | None = None,
    limits: dict[str, int] | None = None,
    coordinate_space: tuple[str, ...] = ("active_context",),
) -> CapabilityDescriptor:
    merged_limits = {"bridge_frame_bytes": BRIDGE_FRAME_BYTES}
    if limits:
        merged_limits.update(limits)
    return CapabilityDescriptor(
        tool=tool,
        key=key,
        mode="live_sketchup",
        safety_class="deprecated_legacy",
        read_only=False,
        destructive=destructive,
        transactional=transactional,
        rollback_verified=False,
        identity_semantics=identity,
        unit_semantics=units,
        coordinate_space=coordinate_space,
        idempotence=idempotence,
        limits=merged_limits,
        runtime_versions=VERIFIED_SKETCHUP_RUNTIME_VERSIONS,
        deprecated=True,
        replacement=replacement,
        preferred=False,
        receipt_kind=None,
        receipt_schema_version=None,
        preconditions=(),
    )


def _compat_strict(
    tool: str,
    key: str,
    *,
    units: str,
    replacement: str,
    destructive: bool = False,
    identity: str = "persistent_id_same",
    idempotence: str = "relative_not_idempotent",
    limits: dict[str, int] | None = None,
    preconditions: tuple[str, ...] = ("if_context", "if_match"),
) -> CapabilityDescriptor:
    base = _strict(
        tool,
        key,
        destructive=destructive,
        identity=identity,
        units=units,
        idempotence=idempotence,
        limits=limits,
        preconditions=preconditions,
    )
    return CapabilityDescriptor(
        **{**asdict(base), "deprecated": True, "replacement": replacement, "preferred": False}
    )


CAPABILITY_DESCRIPTORS: tuple[CapabilityDescriptor, ...] = (
    _provider("help", "common.system.help"),
    _provider("system_status", "common.system.status"),
    _provider("system_capabilities", "common.system.capabilities"),
    _read("document_info", "common.document.info", identity="model_context"),
    _read(
        "object_list",
        "common.object.list",
        identity="active_context_entities",
        units="sketchup_internal_inches",
        limits={"max_entities": MAX_OBJECTS},
    ),
    _read(
        "object_get",
        "common.object.get",
        identity="persistent_id_exact",
        units="sketchup_internal_inches",
    ),
    _strict(
        "execute_geometry",
        "sketchup.semantic.execute_geometry",
        destructive=True,
        identity="action_defined",
        units="explicit:mm|cm|m|in|ft|model",
        idempotence="action_defined",
        limits={"max_face_points": MAX_FACE_POINTS},
    ),
    _read(
        "get_entity_state",
        "sketchup.semantic.entity_state",
        identity="persistent_id_exact",
        units="explicit:mm|cm|m|in|ft|model",
        limits={"max_fingerprint_edges": MAX_FINGERPRINT_EDGES},
        receipt_kind="query",
    ),
    _strict(
        "transform_entity",
        "sketchup.geometry.transform_matrix",
        destructive=False,
        identity="persistent_id_same",
        units="explicit:mm|cm|m|in|ft|model",
        idempotence="absolute_replay_safe",
    ),
    _strict("move_entity","sketchup.geometry.move",destructive=False,identity="persistent_id_same",units="explicit:mm|cm|m|in|ft|model",idempotence="relative_guarded"),
    _strict("rotate_entity","sketchup.geometry.rotate",destructive=False,identity="persistent_id_same",units="explicit:mm|cm|m|in|ft|model+degrees",idempotence="relative_guarded"),
    _strict("scale_entity","sketchup.geometry.scale",destructive=False,identity="persistent_id_same",units="explicit:mm|cm|m|in|ft|model+unitless_factors",idempotence="relative_guarded"),
    _strict(
        "boolean_operation",
        "sketchup.geometry.boolean",
        destructive=True,
        identity="two_input_pids_consumed_new_result_pid",
        units="explicit:mm|cm|m|in|ft|model",
        idempotence="not_idempotent",
    ),
    _strict(
        "delete_entity",
        "common.object.delete_strict",
        destructive=True,
        identity="persistent_id_consumed",
        units="none",
        idempotence="not_idempotent",
    ),
    _strict(
        "group_entities",
        "sketchup.geometry.group_compose",
        destructive=False,
        identity="input_pids_reparented_new_group_pid",
        units="none",
        idempotence="not_idempotent",
        limits={"max_entity_ids": MAX_OBJECTS},
        preconditions=("if_context", "if_match_set"),
    ),
    _strict(
        "create_component",
        "sketchup.component.create",
        destructive=False,
        identity="input_pids_reparented_new_component_pid",
        units="none",
        idempotence="not_idempotent",
        limits={"max_entity_ids": MAX_OBJECTS},
        preconditions=("if_context", "if_match_set"),
    ),
    _strict(
        "place_instance",
        "sketchup.component.place",
        destructive=False,
        identity="new_instance_shared_definition",
        units="explicit:mm|cm|m|in|ft|model",
        idempotence="not_idempotent",
    ),
    _strict(
        "make_unique",
        "sketchup.component.make_unique",
        destructive=False,
        identity="persistent_id_same_new_definition",
        units="none",
        idempotence="not_idempotent",
    ),
    _strict(
        "copy_entity",
        "sketchup.object.copy",
        destructive=False,
        identity="new_pid_shared_definition_or_geometry",
        units="none",
        idempotence="not_idempotent",
    ),
    _strict(
        "linear_array",
        "sketchup.object.array_linear",
        destructive=False,
        identity="count_new_pids_shared_source",
        units="explicit:mm|cm|m|in|ft|model",
        idempotence="not_idempotent",
        limits={"max_array_copies": 100, "max_projected_entities": 5000},
    ),
    _strict(
        "radial_array",
        "sketchup.object.array_radial",
        destructive=False,
        identity="count_new_pids_shared_source",
        units="explicit:mm|cm|m|in|ft|model",
        idempotence="not_idempotent",
        limits={"max_array_copies": 100, "max_projected_entities": 5000},
    ),
    _strict(
        "mirror_entity",
        "sketchup.geometry.mirror",
        destructive=False,
        identity="persistent_id_same",
        units="explicit:mm|cm|m|in|ft|model",
        idempotence="relative_guarded",
    ),
    _read(
        "definition_info",
        "sketchup.component.definition_info",
        identity="definition_guid_exact",
        units="explicit:mm|cm|m|in|ft|model",
        limits={"max_fingerprint_edges": MAX_FINGERPRINT_EDGES},
        receipt_kind="query",
    ),
    _legacy(
        "create_edge",
        "sketchup.geometry.edge_create",
        destructive=False,
        transactional=True,
        identity="new_entity",
        units="internal_inches",
        idempotence="not_idempotent",
    ),
    _legacy(
        "create_face",
        "sketchup.geometry.face_create",
        destructive=False,
        transactional=True,
        identity="new_entity",
        units="internal_inches",
        idempotence="not_idempotent",
        replacement="execute_geometry:create_face",
        limits={"max_face_points": MAX_FACE_POINTS},
    ),
    _compat_strict(
        "create_group",
        "sketchup.geometry.group_create",
        units="none",
        replacement="group_entities",
        destructive=False,
        identity="input_pids_reparented_new_group_pid",
        idempotence="not_idempotent",
        limits={"max_entity_ids": MAX_OBJECTS},
        preconditions=(),
    ),
    _legacy(
        "selection_by_ids",
        "common.selection.by_ids",
        destructive=False,
        transactional=False,
        identity="persistent_id_set",
        units="none",
        idempotence="conditional_replace_state",
        limits={"max_entity_ids": MAX_OBJECTS},
    ),
    _legacy(
        "selection_clear",
        "common.selection.clear",
        destructive=False,
        transactional=False,
        identity="selection_state",
        units="none",
        idempotence="replay_safe",
    ),
    _legacy(
        "object_delete",
        "common.object.delete",
        destructive=True,
        transactional=True,
        identity="persistent_id_target",
        units="none",
        idempotence="not_idempotent",
        replacement="delete_entity",
    ),
    _compat_strict("object_move","common.object.move",units="internal_inches",replacement="move_entity"),
    _compat_strict("object_rotate","common.object.rotate",units="degrees_and_internal_inches_origin",replacement="rotate_entity"),
    _compat_strict("object_scale","common.object.scale",units="unitless_factors_and_internal_inches_origin",replacement="scale_entity"),
    _legacy(
        "push_pull_face",
        "sketchup.geometry.push_pull",
        destructive=True,
        transactional=True,
        identity="face_pid_topology_mutates",
        units="internal_inches",
        idempotence="not_idempotent",
    ),
    _legacy(
        "component_create_box",
        "sketchup.component.box_create",
        destructive=False,
        transactional=True,
        identity="new_component_instance",
        units="internal_inches",
        idempotence="not_idempotent",
        replacement="execute_geometry:create_box",
    ),
    _legacy(
        "tag_create",
        "sketchup.organization.tag_create",
        destructive=False,
        transactional=True,
        identity="name_identity",
        units="none",
        idempotence="name_upsert",
        coordinate_space=("model",),
    ),
    _legacy(
        "tag_assign",
        "sketchup.organization.tag_assign",
        destructive=False,
        transactional=True,
        identity="persistent_id_same",
        units="none",
        idempotence="assignment_replay_safe",
    ),
    _legacy(
        "material_create",
        "sketchup.material.create",
        destructive=False,
        transactional=True,
        identity="name_identity",
        units="none",
        idempotence="name_upsert",
        coordinate_space=("model",),
    ),
    _legacy(
        "material_assign",
        "sketchup.material.assign",
        destructive=False,
        transactional=True,
        identity="persistent_id_same",
        units="none",
        idempotence="assignment_replay_safe",
    ),
)

TOOL_NAMES: tuple[str, ...] = tuple(row.tool for row in CAPABILITY_DESCRIPTORS)


def capability_fingerprint(
    descriptors: tuple[CapabilityDescriptor, ...] = CAPABILITY_DESCRIPTORS,
) -> str:
    """Hash only static descriptor semantics so live availability cannot change the contract fingerprint."""
    canonical = [row.static_payload() for row in descriptors]
    encoded = json.dumps(canonical, sort_keys=True, separators=(",", ":"), ensure_ascii=True)
    return hashlib.sha256(encoded.encode("utf-8")).hexdigest()


CAPABILITY_FINGERPRINT = capability_fingerprint()


def build_capability_payload(
    *,
    provider_id: str,
    bridge_connected: bool,
    live_model: bool,
    runtime: dict[str, Any] | None = None,
) -> dict[str, Any]:
    """Merge static capability metadata with observed fail-closed live availability."""
    live_supported = bridge_connected and live_model
    if not bridge_connected:
        live_reason = "live_bridge_unavailable"
    elif not live_model:
        live_reason = "live_model_unavailable"
    else:
        live_reason = None

    capabilities: list[dict[str, Any]] = []
    for descriptor in CAPABILITY_DESCRIPTORS:
        row = descriptor.static_payload()
        if descriptor.mode == "provider":
            row["supported"] = True
        else:
            row["supported"] = live_supported
            row["dependency"] = "SketchUp Ruby bridge"
            if live_reason:
                row["reason"] = live_reason
        capabilities.append(row)

    return {
        "provider_id": provider_id,
        "capability_schema_version": CAPABILITY_SCHEMA_VERSION,
        "capability_fingerprint": CAPABILITY_FINGERPRINT,
        "observed_runtime": dict(runtime or {}),
        "preferred_tools": [row.tool for row in CAPABILITY_DESCRIPTORS if row.preferred],
        "compatibility_tools": [row.tool for row in CAPABILITY_DESCRIPTORS if row.deprecated],
        "capabilities": capabilities,
    }
