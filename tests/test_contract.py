"""Contract Tests — Provider foundation and S1 modeling capability expectations.
Wing: code | Topic: sketchup_s1 | Updated: 2026-09-11 18:40
"""

from __future__ import annotations

import sys
import unittest
from dataclasses import replace
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))

from cdt_sketchup.capabilities import (  # noqa: E402
    CAPABILITY_DESCRIPTORS,
    capability_fingerprint,
)
from cdt_sketchup.contract import (  # noqa: E402
    COMMON_CONTRACT_VERSION,
    CONTRACT_VERSION,
    PROVIDER_ID,
    PROVIDER_VERSION,
    SKETCHUP_EXTENSION_VERSION,
    build_capabilities,
    build_help,
    build_status,
)


class ContractTests(unittest.TestCase):
    def test_provider_identity_is_stable(self) -> None:
        self.assertEqual(PROVIDER_ID, "cdt_sketchup")
        self.assertEqual(PROVIDER_VERSION, "0.1.0")
        self.assertEqual(CONTRACT_VERSION, "0.22")
        self.assertEqual(COMMON_CONTRACT_VERSION, "0.1")
        self.assertEqual(SKETCHUP_EXTENSION_VERSION, "0.1")

    def test_help_claims_only_implemented_baseline_surface(self) -> None:
        payload = build_help()
        self.assertEqual(payload["provider_id"], PROVIDER_ID)
        self.assertEqual(payload["transport"], "streamable-http")
        self.assertNotIn("eval_ruby", payload["tools"])
        self.assertEqual(
            payload["tools"],
            [
                "help",
                "system_status",
                "system_capabilities",
                "document_info",
                "object_list",
                "object_get",
                "execute_geometry",
                "get_entity_state",
                "transform_entity",
                "move_entity",
                "rotate_entity",
                "scale_entity",
                "boolean_operation",
                "delete_entity",
                "group_entities",
                "create_component",
                "place_instance",
                "make_unique",
                "copy_entity",
                "linear_array",
                "radial_array",
                "mirror_entity",
                "create_polyline",
                "create_rectangle",
                "create_circle",
                "create_arc",
                "create_polygon",
                "sweep_profile",
                "measure_distance",
                "query_topology",
                "query_overlap",
                "asset_list",
                "place_asset",
                "texture_list",
                "material_apply_texture",
                "material_info",
                "camera_get",
                "camera_set",
                "scene_list",
                "scene_create",
                "model_save",
                "model_save_as",
                "model_open",
                "model_export",
                "model_list",
                "integrity_report",
                "repair_reverse_face",
                "repair_erase_degenerate",
                "definition_info",
                "create_edge",
                "create_face",
                "create_group",
                "selection_by_ids",
                "selection_clear",
                "object_delete",
                "object_move",
                "object_rotate",
                "object_scale",
                "push_pull_face",
                "component_create_box",
                "tag_create",
                "tag_assign",
                "material_create",
                "material_assign",
            ],
        )

    def test_status_reports_degraded_when_live_bridge_is_absent(self) -> None:
        payload = build_status(bridge_connected=False, live_model=False, detail="bridge unavailable")
        self.assertEqual(payload["status"], "degraded")
        self.assertFalse(payload["bridge"]["connected"])
        self.assertFalse(payload["runtime"]["live_model"])
        self.assertEqual(payload["detail"], "bridge unavailable")

    def test_live_capabilities_fail_closed_without_bridge(self) -> None:
        payload = build_capabilities(bridge_connected=False, live_model=False)
        by_key = {row["key"]: row for row in payload["capabilities"]}
        self.assertTrue(by_key["common.system.help"]["supported"])
        self.assertFalse(by_key["common.document.info"]["supported"])
        self.assertEqual(by_key["common.document.info"]["reason"], "live_bridge_unavailable")
        self.assertFalse(by_key["sketchup.geometry.edge_create"]["supported"])
        self.assertFalse(by_key["sketchup.geometry.boolean"]["supported"])
        self.assertFalse(by_key["common.object.delete_strict"]["supported"])
        self.assertFalse(by_key["sketchup.geometry.group_compose"]["supported"])
        self.assertFalse(by_key["sketchup.component.create"]["supported"])
        self.assertFalse(by_key["sketchup.component.place"]["supported"])
        self.assertFalse(by_key["common.object.move"]["supported"])
        self.assertFalse(by_key["sketchup.material.assign"]["supported"])

    def test_live_capabilities_require_model(self) -> None:
        payload = build_capabilities(bridge_connected=True, live_model=False)
        by_key = {row["key"]: row for row in payload["capabilities"]}
        self.assertFalse(by_key["common.document.info"]["supported"])
        self.assertEqual(by_key["common.document.info"]["reason"], "live_model_unavailable")
        self.assertFalse(by_key["sketchup.geometry.group_create"]["supported"])
        self.assertFalse(by_key["sketchup.component.box_create"]["supported"])

    def test_capability_metadata_v2_covers_every_public_tool(self) -> None:
        help_payload = build_help()
        payload = build_capabilities(bridge_connected=True, live_model=True)
        self.assertEqual(payload["capability_schema_version"], 2)
        by_tool = {row["tool"]: row for row in payload["capabilities"]}
        self.assertEqual(set(by_tool), set(help_payload["tools"]))
        required = {
            "key", "tool", "supported", "mode", "safety_class", "read_only",
            "destructive", "transactional", "rollback_verified",
            "identity_semantics", "unit_semantics", "coordinate_space",
            "idempotence", "limits", "runtime_versions", "deprecated",
            "replacement", "preferred", "receipt_kind", "receipt_schema_version", "preconditions",
        }
        for row in by_tool.values():
            self.assertTrue(required.issubset(row), row["tool"])

    def test_capability_metadata_v2_separates_preferred_and_legacy_paths(self) -> None:
        payload = build_capabilities(bridge_connected=True, live_model=True)
        by_tool = {row["tool"]: row for row in payload["capabilities"]}
        self.assertEqual(by_tool["transform_entity"]["safety_class"], "strict_mutation")
        self.assertTrue(by_tool["transform_entity"]["rollback_verified"])
        self.assertEqual(by_tool["object_move"]["safety_class"], "strict_mutation")
        self.assertTrue(by_tool["object_move"]["deprecated"])
        self.assertEqual(by_tool["object_move"]["replacement"], "move_entity")
        self.assertEqual(by_tool["object_delete"]["replacement"], "delete_entity")
        self.assertEqual(by_tool["create_group"]["replacement"], "group_entities")
        self.assertIn("transform_entity", payload["preferred_tools"])
        self.assertIn("move_entity", payload["preferred_tools"])
        self.assertIn("rotate_entity", payload["preferred_tools"])
        self.assertIn("scale_entity", payload["preferred_tools"])
        self.assertIn("group_entities", payload["preferred_tools"])
        self.assertIn("create_component", payload["preferred_tools"])
        self.assertIn("place_instance", payload["preferred_tools"])
        self.assertIn("make_unique", payload["preferred_tools"])
        self.assertIn("definition_info", payload["preferred_tools"])
        self.assertIn("copy_entity", payload["preferred_tools"])
        self.assertIn("linear_array", payload["preferred_tools"])
        self.assertIn("radial_array", payload["preferred_tools"])
        self.assertIn("mirror_entity", payload["preferred_tools"])
        self.assertIn("create_polyline", payload["preferred_tools"])
        self.assertIn("create_rectangle", payload["preferred_tools"])
        self.assertIn("create_circle", payload["preferred_tools"])
        self.assertIn("create_arc", payload["preferred_tools"])
        self.assertIn("create_polygon", payload["preferred_tools"])
        self.assertIn("sweep_profile", payload["preferred_tools"])
        self.assertIn("measure_distance", payload["preferred_tools"])
        self.assertIn("query_topology", payload["preferred_tools"])
        self.assertIn("query_overlap", payload["preferred_tools"])
        self.assertIn("asset_list", payload["preferred_tools"])
        self.assertIn("place_asset", payload["preferred_tools"])
        self.assertIn("texture_list", payload["preferred_tools"])
        self.assertIn("material_apply_texture", payload["preferred_tools"])
        self.assertIn("material_info", payload["preferred_tools"])
        self.assertIn("camera_get", payload["preferred_tools"])
        self.assertIn("camera_set", payload["preferred_tools"])
        self.assertIn("scene_list", payload["preferred_tools"])
        self.assertIn("scene_create", payload["preferred_tools"])
        self.assertIn("model_save", payload["preferred_tools"])
        self.assertIn("model_save_as", payload["preferred_tools"])
        self.assertIn("model_open", payload["preferred_tools"])
        self.assertIn("model_export", payload["preferred_tools"])
        self.assertIn("model_list", payload["preferred_tools"])
        self.assertIn("integrity_report", payload["preferred_tools"])
        self.assertIn("repair_reverse_face", payload["preferred_tools"])
        self.assertIn("repair_erase_degenerate", payload["preferred_tools"])
        self.assertNotIn("object_move", payload["preferred_tools"])
        self.assertIn("object_move", payload["compatibility_tools"])
        self.assertEqual(by_tool["delete_entity"]["receipt_kind"], "operation")
        self.assertEqual(by_tool["delete_entity"]["receipt_schema_version"], 1)
        self.assertEqual(by_tool["get_entity_state"]["receipt_kind"], "query")
        self.assertEqual(by_tool["get_entity_state"]["receipt_schema_version"], 1)
        self.assertEqual(by_tool["move_entity"]["safety_class"], "strict_mutation")
        self.assertTrue(by_tool["move_entity"]["rollback_verified"])
        self.assertEqual(by_tool["move_entity"]["receipt_kind"], "operation")
        self.assertEqual(by_tool["move_entity"]["preconditions"], ["if_context", "if_match"])
        self.assertEqual(by_tool["object_move"]["receipt_kind"], "operation")
        self.assertTrue(by_tool["object_move"]["rollback_verified"])
        self.assertEqual(by_tool["transform_entity"]["preconditions"], ["if_context", "if_match"])
        self.assertEqual(by_tool["delete_entity"]["preconditions"], ["if_context", "if_match"])
        self.assertEqual(by_tool["group_entities"]["safety_class"], "strict_mutation")
        self.assertTrue(by_tool["group_entities"]["rollback_verified"])
        self.assertEqual(by_tool["group_entities"]["identity_semantics"], "input_pids_reparented_new_group_pid")
        self.assertEqual(by_tool["group_entities"]["preconditions"], ["if_context", "if_match_set"])
        self.assertEqual(by_tool["group_entities"]["limits"]["max_entity_ids"], 500)
        self.assertEqual(by_tool["create_component"]["safety_class"], "strict_mutation")
        self.assertTrue(by_tool["create_component"]["rollback_verified"])
        self.assertEqual(by_tool["create_component"]["identity_semantics"], "input_pids_reparented_new_component_pid")
        self.assertEqual(by_tool["create_component"]["preconditions"], ["if_context", "if_match_set"])
        self.assertEqual(by_tool["place_instance"]["safety_class"], "strict_mutation")
        self.assertTrue(by_tool["place_instance"]["rollback_verified"])
        self.assertEqual(by_tool["place_instance"]["identity_semantics"], "new_instance_shared_definition")
        self.assertEqual(by_tool["place_instance"]["preconditions"], ["if_context", "if_match"])
        self.assertEqual(by_tool["make_unique"]["safety_class"], "strict_mutation")
        self.assertTrue(by_tool["make_unique"]["rollback_verified"])
        self.assertEqual(by_tool["make_unique"]["identity_semantics"], "persistent_id_same_new_definition")
        self.assertEqual(by_tool["make_unique"]["preconditions"], ["if_context", "if_match"])
        self.assertEqual(by_tool["definition_info"]["safety_class"], "read_only")
        self.assertFalse(by_tool["definition_info"]["deprecated"])
        self.assertEqual(by_tool["definition_info"]["receipt_kind"], "query")
        self.assertEqual(by_tool["copy_entity"]["safety_class"], "strict_mutation")
        self.assertTrue(by_tool["copy_entity"]["rollback_verified"])
        self.assertEqual(by_tool["copy_entity"]["identity_semantics"], "new_pid_shared_definition_or_geometry")
        self.assertEqual(by_tool["copy_entity"]["preconditions"], ["if_context", "if_match"])
        self.assertEqual(by_tool["linear_array"]["safety_class"], "strict_mutation")
        self.assertTrue(by_tool["linear_array"]["rollback_verified"])
        self.assertEqual(by_tool["linear_array"]["identity_semantics"], "count_new_pids_shared_source")
        self.assertEqual(by_tool["linear_array"]["preconditions"], ["if_context", "if_match"])
        self.assertEqual(by_tool["linear_array"]["limits"]["max_array_copies"], 100)
        self.assertEqual(by_tool["radial_array"]["safety_class"], "strict_mutation")
        self.assertTrue(by_tool["radial_array"]["rollback_verified"])
        self.assertEqual(by_tool["radial_array"]["preconditions"], ["if_context", "if_match"])
        self.assertEqual(by_tool["mirror_entity"]["safety_class"], "strict_mutation")
        self.assertTrue(by_tool["mirror_entity"]["rollback_verified"])
        self.assertEqual(by_tool["mirror_entity"]["identity_semantics"], "persistent_id_same")
        self.assertEqual(by_tool["mirror_entity"]["preconditions"], ["if_context", "if_match"])
        self.assertEqual(by_tool["tag_assign"]["safety_class"], "strict_mutation")
        self.assertTrue(by_tool["tag_assign"]["rollback_verified"])
        self.assertEqual(by_tool["tag_assign"]["identity_semantics"], "persistent_id_same")
        self.assertEqual(by_tool["tag_assign"]["preconditions"], ["if_context", "if_match"])
        self.assertEqual(by_tool["tag_assign"]["receipt_kind"], "operation")
        self.assertFalse(by_tool["tag_assign"]["deprecated"])
        self.assertIn("tag_assign", payload["preferred_tools"])
        self.assertEqual(by_tool["material_assign"]["safety_class"], "strict_mutation")
        self.assertTrue(by_tool["material_assign"]["rollback_verified"])
        self.assertEqual(by_tool["material_assign"]["identity_semantics"], "persistent_id_same")
        self.assertEqual(by_tool["material_assign"]["preconditions"], ["if_context", "if_match"])
        self.assertEqual(by_tool["material_assign"]["receipt_kind"], "operation")
        self.assertFalse(by_tool["material_assign"]["deprecated"])
        self.assertIn("material_assign", payload["preferred_tools"])
        self.assertEqual(by_tool["create_polyline"]["safety_class"], "strict_mutation")
        self.assertTrue(by_tool["create_polyline"]["rollback_verified"])
        self.assertEqual(by_tool["create_polyline"]["identity_semantics"], "new_group_edge_chain")
        self.assertEqual(by_tool["create_polyline"]["preconditions"], ["if_context"])
        self.assertEqual(by_tool["create_rectangle"]["safety_class"], "strict_mutation")
        self.assertEqual(by_tool["create_rectangle"]["identity_semantics"], "new_group_rectangle")
        self.assertEqual(by_tool["create_circle"]["safety_class"], "strict_mutation")
        self.assertEqual(by_tool["create_circle"]["identity_semantics"], "new_group_circle")
        self.assertEqual(by_tool["create_arc"]["safety_class"], "strict_mutation")
        self.assertEqual(by_tool["create_polygon"]["safety_class"], "strict_mutation")
        self.assertEqual(by_tool["create_polygon"]["identity_semantics"], "new_group_polygon")
        self.assertEqual(by_tool["sweep_profile"]["safety_class"], "strict_mutation")
        self.assertTrue(by_tool["sweep_profile"]["rollback_verified"])
        self.assertEqual(by_tool["sweep_profile"]["identity_semantics"], "profile_path_reparented_new_group_pid")
        self.assertEqual(by_tool["sweep_profile"]["preconditions"], ["if_context", "if_match_set"])
        self.assertEqual(by_tool["sweep_profile"]["limits"]["max_path_edges"], 64)
        self.assertEqual(by_tool["measure_distance"]["safety_class"], "read_only")
        self.assertEqual(by_tool["measure_distance"]["receipt_kind"], "query")
        self.assertEqual(by_tool["measure_distance"]["unit_semantics"], "explicit:mm|cm|m|in|ft|model")
        self.assertEqual(by_tool["query_topology"]["safety_class"], "read_only")
        self.assertEqual(by_tool["query_topology"]["receipt_kind"], "query")
        self.assertEqual(by_tool["query_overlap"]["safety_class"], "read_only")
        self.assertEqual(by_tool["query_overlap"]["receipt_kind"], "query")
        self.assertEqual(by_tool["asset_list"]["safety_class"], "read_only")
        self.assertEqual(by_tool["asset_list"]["receipt_kind"], "query")
        self.assertFalse(by_tool["asset_list"]["deprecated"])
        self.assertEqual(by_tool["place_asset"]["safety_class"], "strict_mutation")
        self.assertTrue(by_tool["place_asset"]["rollback_verified"])
        self.assertEqual(by_tool["place_asset"]["identity_semantics"], "new_instance_shared_definition")
        self.assertEqual(by_tool["place_asset"]["preconditions"], ["if_context"])
        self.assertEqual(by_tool["place_asset"]["limits"]["max_asset_bytes"], 67108864)
        self.assertEqual(by_tool["texture_list"]["safety_class"], "read_only")
        self.assertEqual(by_tool["texture_list"]["receipt_kind"], "query")
        self.assertEqual(by_tool["material_info"]["safety_class"], "read_only")
        self.assertEqual(by_tool["material_info"]["receipt_kind"], "query")
        self.assertEqual(by_tool["material_apply_texture"]["safety_class"], "strict_mutation")
        self.assertTrue(by_tool["material_apply_texture"]["rollback_verified"])
        self.assertEqual(by_tool["material_apply_texture"]["identity_semantics"], "material_name_same")
        self.assertEqual(by_tool["material_apply_texture"]["preconditions"], ["if_context"])
        self.assertEqual(by_tool["material_apply_texture"]["limits"]["max_texture_bytes"], 16777216)
        self.assertEqual(by_tool["camera_get"]["safety_class"], "read_only")
        self.assertEqual(by_tool["camera_get"]["receipt_kind"], "query")
        self.assertEqual(by_tool["camera_set"]["safety_class"], "strict_mutation")
        self.assertTrue(by_tool["camera_set"]["rollback_verified"])
        self.assertEqual(by_tool["camera_set"]["identity_semantics"], "active_view_camera")
        self.assertEqual(by_tool["camera_set"]["preconditions"], ["if_context", "if_match"])
        self.assertEqual(by_tool["scene_list"]["safety_class"], "read_only")
        self.assertEqual(by_tool["scene_list"]["receipt_kind"], "query")
        self.assertEqual(by_tool["scene_create"]["safety_class"], "strict_mutation")
        self.assertTrue(by_tool["scene_create"]["rollback_verified"])
        self.assertEqual(by_tool["scene_create"]["identity_semantics"], "new_page_name")
        self.assertEqual(by_tool["scene_create"]["preconditions"], ["if_context"])
        for tool in ("model_save", "model_save_as", "model_open", "model_export"):
            self.assertEqual(by_tool[tool]["safety_class"], "external_side_effect")
            self.assertFalse(by_tool[tool]["transactional"])
            self.assertFalse(by_tool[tool]["rollback_verified"])
            self.assertEqual(by_tool[tool]["receipt_kind"], "external_side_effect")
        self.assertEqual(by_tool["model_list"]["safety_class"], "read_only")
        self.assertEqual(by_tool["model_list"]["receipt_kind"], "query")
        self.assertEqual(by_tool["integrity_report"]["safety_class"], "read_only")
        self.assertEqual(by_tool["integrity_report"]["receipt_kind"], "query")
        self.assertEqual(by_tool["repair_reverse_face"]["safety_class"], "strict_mutation")
        self.assertTrue(by_tool["repair_reverse_face"]["rollback_verified"])
        self.assertEqual(by_tool["repair_reverse_face"]["identity_semantics"], "persistent_id_same")
        self.assertEqual(by_tool["repair_reverse_face"]["preconditions"], ["if_context", "if_match"])
        self.assertEqual(by_tool["repair_erase_degenerate"]["safety_class"], "strict_mutation")
        self.assertTrue(by_tool["repair_erase_degenerate"]["rollback_verified"])
        self.assertEqual(by_tool["repair_erase_degenerate"]["identity_semantics"], "persistent_id_consumed")
        self.assertEqual(by_tool["repair_erase_degenerate"]["preconditions"], ["if_context", "if_match"])
        self.assertTrue(by_tool["tag_create"]["deprecated"] or not by_tool["tag_create"]["preferred"])
        self.assertTrue(by_tool["material_create"]["deprecated"] or not by_tool["material_create"]["preferred"])
        self.assertEqual(by_tool["get_entity_state"]["preconditions"], [])

    def test_capability_fingerprint_is_deterministic_and_runtime_status_independent(self) -> None:
        ready = build_capabilities(bridge_connected=True, live_model=True)
        unavailable = build_capabilities(bridge_connected=False, live_model=False)
        self.assertEqual(ready["capability_fingerprint"], unavailable["capability_fingerprint"])
        self.assertEqual(len(ready["capability_fingerprint"]), 64)
        self.assertNotEqual(
            {row["tool"]: row["supported"] for row in ready["capabilities"]},
            {row["tool"]: row["supported"] for row in unavailable["capabilities"]},
        )

    def test_capability_fingerprint_changes_when_static_descriptor_semantics_change(self) -> None:
        original = capability_fingerprint()
        changed = (
            replace(CAPABILITY_DESCRIPTORS[0], identity_semantics="provider_identity"),
            *CAPABILITY_DESCRIPTORS[1:],
        )
        self.assertNotEqual(original, capability_fingerprint(changed))
        self.assertEqual(capability_fingerprint(changed), capability_fingerprint(changed))

    def test_capability_metadata_advertises_explicit_strict_units_and_active_context_only(self) -> None:
        payload = build_capabilities(bridge_connected=True, live_model=True)
        by_tool = {row["tool"]: row for row in payload["capabilities"]}
        self.assertEqual(by_tool["execute_geometry"]["unit_semantics"], "explicit:mm|cm|m|in|ft|model")
        self.assertEqual(by_tool["transform_entity"]["unit_semantics"], "explicit:mm|cm|m|in|ft|model")
        self.assertEqual(by_tool["get_entity_state"]["unit_semantics"], "explicit:mm|cm|m|in|ft|model")
        self.assertEqual(by_tool["execute_geometry"]["coordinate_space"], ["active_context"])
        self.assertEqual(by_tool["object_move"]["unit_semantics"], "internal_inches")

    def test_capability_metadata_reports_observed_runtime_without_turning_it_into_support_policy(self) -> None:
        payload = build_capabilities(
            bridge_connected=True,
            live_model=True,
            runtime={"sketchup_version": "24.0.594", "ruby_version": "3.2.2"},
        )
        self.assertEqual(payload["observed_runtime"]["sketchup_version"], "24.0.594")
        self.assertEqual(payload["observed_runtime"]["ruby_version"], "3.2.2")
        strict = {row["tool"]: row for row in payload["capabilities"]}["delete_entity"]
        self.assertEqual(strict["runtime_versions"], ["24.0.594"])


if __name__ == "__main__":
    unittest.main()
