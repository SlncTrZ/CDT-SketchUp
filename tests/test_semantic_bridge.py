"""Semantic Bridge Tests — Transaction, rollback, PID state, and fingerprint invariants.
Wing: code | Topic: sketchup_semantic_loop | Updated: 2026-09-11 18:40
"""

from __future__ import annotations

import unittest
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MAIN_RB = ROOT / "extension" / "cdt_sketchup" / "main.rb"

sys.path.insert(0, str(Path(__file__).resolve().parent))

from extension_tree import read_extension_sources  # noqa: E402


class SemanticBridgeTests(unittest.TestCase):
    def test_legacy_transform_bridge_commands_are_not_exposed(self) -> None:
        source = read_extension_sources()
        command_block = source[source.index("COMMANDS = {"):source.index("}.freeze", source.index("COMMANDS = {"))]
        self.assertNotIn('"object_move" =>', command_block)
        self.assertNotIn('"object_rotate" =>', command_block)
        self.assertNotIn('"object_scale" =>', command_block)

    def test_two_semantic_commands_are_explicitly_allowlisted(self) -> None:
        source = read_extension_sources()
        self.assertIn('"execute_geometry" => :handle_execute_geometry', source)
        self.assertIn('"get_entity_state" => :handle_get_entity_state', source)

    def test_ai_step_transaction_validates_before_commit_and_rolls_back(self) -> None:
        source = read_extension_sources()
        self.assertIn('model.start_operation("AI_Step", true)', source)
        self.assertIn("validate_semantic_expectation", source)
        validation_index = source.index("validate_semantic_expectation")
        commit_index = source.index("model.commit_operation", validation_index)
        self.assertLess(validation_index, commit_index)
        self.assertIn("model.abort_operation", source)
        self.assertIn('"rolled_back" => !!aborted', source)
        self.assertIn('"rollback_verified"', source)

    def test_semantic_expectation_schema_is_closed_and_validates_position(self) -> None:
        source = read_extension_sources()
        self.assertIn("SEMANTIC_EXPECT_KEYS = %w[", source)
        self.assertIn("unknown_expect_keys", source)
        self.assertIn('"bounds_min"', source)
        self.assertIn('"bounds_max"', source)
        self.assertIn("validate_numeric_triplet_expectation", source)

    def test_create_box_params_schema_is_closed(self) -> None:
        source = read_extension_sources()
        self.assertIn("CREATE_BOX_PARAM_KEYS = %w[name dimensions origin].freeze", source)
        self.assertIn("unknown_create_box_keys", source)

    def test_after_model_fingerprint_is_computed_before_commit(self) -> None:
        source = read_extension_sources()
        handler_start = source.index("def handle_execute_geometry")
        after_fp_index = source.index(
            "after_fingerprint = semantic_model_fingerprint(model, active_snapshot: after_snapshot)",
            handler_start,
        )
        commit_index = source.index("committed = model.commit_operation", handler_start)
        self.assertLess(after_fp_index, commit_index)

    def test_commit_truth_checks_sketchup_commit_boolean(self) -> None:
        source = read_extension_sources()
        self.assertIn("committed = model.commit_operation", source)
        self.assertIn('"transaction_commit_failed"', source)
        self.assertIn('"SketchUp did not commit AI_Step transaction"', source)
        self.assertIn('"commit_verified" => true', source)

    def test_rollback_truth_uses_abort_result_and_model_fingerprint(self) -> None:
        source = read_extension_sources()
        self.assertIn("semantic_model_fingerprint", source)
        self.assertIn('"model_fingerprint"', source)
        self.assertIn('"rolled_back" => !!aborted', source)
        self.assertIn("rolled_back_fingerprint == before_fingerprint", source)

    def test_invalid_action_is_validated_inside_ai_step_transaction(self) -> None:
        source = read_extension_sources()
        handler_start = source.index("def handle_execute_geometry")
        operation_index = source.index('model.start_operation("AI_Step", true)', handler_start)
        action_validation_index = source.index("action_handler = GEOMETRY_ACTIONS[action]", handler_start)
        self.assertLess(operation_index, action_validation_index)

    def test_entity_state_is_pid_only_and_contains_semantic_fingerprints(self) -> None:
        source = read_extension_sources()
        self.assertIn('params["persistent_id"]', source)
        self.assertIn("find_entity_by_persistent_id", source)
        self.assertIn('"bounds"', source)
        self.assertIn('"vertex_count"', source)
        self.assertIn('"face_count"', source)
        self.assertIn('"manifold"', source)
        self.assertIn('"identity_fingerprint"', source)
        self.assertIn('"semantic_fingerprint"', source)
        self.assertIn('"geometry_fingerprint"', source)
        self.assertIn("Digest::SHA256.hexdigest", source)

    def test_create_box_origin_is_lower_corner_not_upper_corner(self) -> None:
        source = read_extension_sources()
        self.assertIn("face.pushpull(-height)", source)

    def test_expect_requires_geometry_check_beyond_scene_delta(self) -> None:
        source = read_extension_sources()
        self.assertIn(
            'validation_keys = expect.keys - ["tolerance", "active_entity_delta"]',
            source,
        )
        self.assertIn(
            '"expect must contain at least one entity semantic validation field"',
            source,
        )

    def test_rescue_uses_safe_model_fingerprint_and_never_treats_nil_as_verified(self) -> None:
        source = read_extension_sources()
        self.assertIn("safe_semantic_model_fingerprint", source)
        self.assertIn("!before_fingerprint.nil?", source)
        self.assertIn("!rolled_back_fingerprint.nil?", source)
        self.assertIn('"rollback_fingerprint_error"', source)

    def test_transform_action_is_closed_absolute_pid_based_and_invertible(self) -> None:
        source = read_extension_sources()
        self.assertIn('"transform_entity" => :execute_transform_entity', source)
        self.assertIn("TRANSFORM_ENTITY_PARAM_KEYS = %w[persistent_id matrix].freeze", source)
        self.assertIn('require_transformable_entity(model, params["persistent_id"])', source)
        self.assertIn("transformation_from_matrix", source)
        self.assertIn("transformation_determinant", source)
        self.assertIn('"non_invertible_transform"', source)
        self.assertIn("entity.transformation = transformation", source)
        self.assertNotIn("execute_transform_entity(model, params)\n      entity.transform!", source)

    def test_transform_semantic_invariants_preserve_identity_and_geometry(self) -> None:
        source = read_extension_sources()
        self.assertIn("validate_action_semantic_invariants", source)
        self.assertIn('"before_identity_fingerprint"', source)
        self.assertIn('"before_geometry_fingerprint"', source)
        self.assertIn('"requested_transformation"', source)
        self.assertIn('"transformation"', source)
        self.assertIn('"transform_entity requires expect.transformation"', source)
        self.assertIn('"transform_entity requires expect.active_entity_delta = 0"', source)

    def test_boolean_action_is_closed_pid_based_and_manifold_only(self) -> None:
        source = read_extension_sources()
        self.assertIn('"boolean_operation" => :execute_boolean_operation', source)
        self.assertIn("BOOLEAN_OPERATION_PARAM_KEYS = %w[tool_pid target_pid operation_type].freeze", source)
        self.assertIn('require_boolean_solid(model, params["tool_pid"], "tool_pid")', source)
        self.assertIn('require_boolean_solid(model, params["target_pid"], "target_pid")', source)
        self.assertIn('"non_manifold_operand"', source)
        self.assertIn('"locked_object"', source)
        self.assertIn('tool.subtract(target)', source)
        self.assertNotIn('target.subtract(tool)', source)
        self.assertIn('target.union(tool)', source)
        self.assertIn('target.intersect(tool)', source)

    def test_boolean_action_enforces_result_and_operand_invariants(self) -> None:
        source = read_extension_sources()
        self.assertIn('"boolean_operation requires expect.active_entity_delta = -1"', source)
        self.assertIn('"boolean_operation requires expect.type = Group"', source)
        self.assertIn('"boolean_operation requires expect.manifold = true"', source)
        self.assertIn('"action.tool_consumed"', source)
        self.assertIn('"action.target_consumed"', source)
        self.assertIn('"action.result_is_new"', source)
        self.assertIn("validate_boolean_volume_invariant", source)

    def test_pid_lookup_normalizes_native_range_errors_and_object_get_reuses_resolver(self) -> None:
        source = read_extension_sources()
        object_get_start = source.index("def handle_object_get")
        object_get_end = source.index("def handle_get_entity_state", object_get_start)
        object_get_source = source[object_get_start:object_get_end]
        self.assertIn('require_entity_by_pid(model, params["persistent_id"])', object_get_source)
        resolver_start = source.index("def require_entity_by_pid")
        resolver_end = source.index("def require_active_entity", resolver_start)
        resolver_source = source[resolver_start:resolver_end]
        self.assertIn("rescue ArgumentError, RangeError, TypeError", resolver_source)
        self.assertIn('"persistent_id is outside the SketchUp supported range"', resolver_source)

    def test_delete_action_is_closed_pid_based_and_preflighted_before_transaction(self) -> None:
        source = read_extension_sources()
        self.assertIn('"delete_entity" => :execute_delete_entity', source)
        self.assertIn("DELETE_ENTITY_PARAM_KEYS = %w[persistent_id].freeze", source)
        self.assertIn("preflight_delete_entity", source)
        handler_start = source.index("def handle_execute_geometry")
        preflight_index = source.index("preflight_geometry_action", handler_start)
        operation_index = source.index('model.start_operation("AI_Step", true)', handler_start)
        self.assertLess(preflight_index, operation_index)

    def test_delete_action_supports_object_entities_only_and_verifies_pid_consumption(self) -> None:
        source = read_extension_sources()
        self.assertIn("def require_deletable_entity", source)
        self.assertIn("entity.is_a?(Sketchup::Group) || entity.is_a?(Sketchup::ComponentInstance)", source)
        self.assertIn('"delete_entity requires a group/component instance"', source)
        self.assertIn('"locked_object"', source)
        self.assertIn("model.active_entities.erase_entities(entity)", source)
        self.assertIn('"delete_failed"', source)
        self.assertIn('"action.target_consumed"', source)

    def test_delete_expectation_requires_deleted_tombstone_and_exact_delta(self) -> None:
        source = read_extension_sources()
        self.assertIn('"deleted"', source)
        self.assertIn('"delete_entity requires expect.active_entity_delta = -1"', source)
        self.assertIn('"delete_entity requires expect.deleted = true"', source)
        self.assertIn('semantic_check("deleted", expect["deleted"], state["deleted"])', source)

    def test_unified_receipt_v1_is_shared_by_queries_and_all_strict_actions(self) -> None:
        source = read_extension_sources()
        self.assertIn("RECEIPT_SCHEMA_VERSION = 1", source)
        self.assertIn("build_operation_receipt", source)
        self.assertIn("build_query_receipt", source)
        for field in (
            '"receipt_schema_version"', '"receipt_kind"', '"receipt_id"',
            '"command"', '"context"', '"entity_states"', '"duration_ms"', '"limits"',
        ):
            self.assertIn(field, source)
        for field in ('"action"', '"affected"', '"model"', '"validation"', '"rollback"'):
            self.assertIn(field, source)

    def test_affected_pid_accounting_is_generic_not_delete_specific(self) -> None:
        source = read_extension_sources()
        self.assertIn("semantic_active_entity_snapshot", source)
        self.assertIn("semantic_affected_entities", source)
        self.assertIn("entity_alive_by_pid?", source)
        self.assertNotIn('return nil unless action == "delete_entity"', source)
        self.assertIn('"created" => created.sort', source)
        self.assertIn('"modified" => modified.uniq.sort', source)
        self.assertIn('"deleted" => deleted.sort', source)

    def test_native_unit_contract_converts_once_before_geometry_execution(self) -> None:
        source = read_extension_sources()
        self.assertIn("PUBLIC_LENGTH_UNITS = %w[mm cm m in ft model].freeze", source)
        self.assertIn("PUBLIC_COORDINATE_SPACES = %w[active_context].freeze", source)
        self.assertIn("normalize_geometry_request_units", source)
        self.assertIn("length_to_internal_inches", source)
        self.assertIn("semantic_state_in_unit", source)
        handler_start = source.index("def handle_execute_geometry")
        normalize_index = source.index("normalize_geometry_request_units", handler_start)
        operation_index = source.index('model.start_operation("AI_Step", true)', handler_start)
        self.assertLess(normalize_index, operation_index)

    def test_receipts_publish_explicit_unit_and_coordinate_space(self) -> None:
        source = read_extension_sources()
        self.assertIn('"unit" => public_unit', source)
        self.assertIn('"coordinate_space" => coordinate_space', source)
        self.assertIn('"native_length_unit" => "in"', source)
        self.assertIn('"coordinate_space" => coordinate_space', source)
        self.assertIn('PUBLIC_COORDINATE_SPACES = %w[active_context].freeze', source)

    def test_length_tolerance_is_dimensionally_separated_for_area_volume_and_matrix(self) -> None:
        source = read_extension_sources()
        self.assertIn("area_tolerance = [tolerance * tolerance, SEMANTIC_QUANTUM].max", source)
        self.assertIn("volume_tolerance = [tolerance * tolerance * tolerance, SEMANTIC_QUANTUM].max", source)
        self.assertIn("validate_transformation_expectation", source)
        self.assertIn("[12, 13, 14].include?(index) ? length_tolerance : SEMANTIC_QUANTUM", source)

    def test_state_unit_conversion_scales_length_area_volume_and_transform_translation(self) -> None:
        source = read_extension_sources()
        self.assertIn("convert_length_from_internal", source)
        self.assertIn("convert_area_from_internal", source)
        self.assertIn("convert_volume_from_internal", source)
        self.assertIn("converted_transformation[12]", source)
        self.assertIn("converted_transformation[13]", source)
        self.assertIn("converted_transformation[14]", source)

    def test_receipt_context_has_deterministic_session_model_edit_identity_and_revision(self) -> None:
        source = read_extension_sources()
        self.assertIn("def model_session_identity(model)", source)
        self.assertIn("model.guid.to_s", source)
        self.assertIn("Process.pid", source)
        self.assertIn("def edit_context_identity(model)", source)
        self.assertIn('entity.persistent_id', source)
        self.assertIn('definition.guid.to_s', source)
        self.assertIn("def context_revision(context_id, model_fingerprint)", source)
        self.assertIn('"identity_status" => "verified"', source)
        self.assertNotIn('"id" => nil', source)
        self.assertNotIn('"revision" => nil', source)

    def test_write_preconditions_are_checked_before_ai_step_starts(self) -> None:
        source = read_extension_sources()
        handler_start = source.index("def handle_execute_geometry")
        context_index = source.index("validate_if_context", handler_start)
        preflight_index = source.index("preflight_geometry_action", handler_start)
        match_index = source.index("validate_if_match", handler_start)
        operation_index = source.index('model.start_operation("AI_Step", true)', handler_start)
        self.assertLess(context_index, preflight_index)
        self.assertLess(preflight_index, match_index)
        self.assertLess(match_index, operation_index)

    def test_if_context_is_closed_and_compares_both_identity_and_revision(self) -> None:
        source = read_extension_sources()
        self.assertIn("IF_CONTEXT_KEYS = %w[id revision].freeze", source)
        self.assertIn("validate_if_context", source)
        self.assertIn('current_context["id"]', source)
        self.assertIn('current_context["revision"]', source)
        self.assertIn('"context_mismatch"', source)

    def test_if_match_checks_target_semantic_fingerprint_before_mutation(self) -> None:
        source = read_extension_sources()
        self.assertIn("precondition_target_pid", source)
        self.assertIn('state["semantic_fingerprint"]', source)
        self.assertIn('"stale_entity_state"', source)
        self.assertIn('if_match is not supported for this action', source)

    def test_query_receipt_exposes_context_and_entity_fingerprint(self) -> None:
        source = read_extension_sources()
        self.assertIn('"entity_fingerprint" => public_state["semantic_fingerprint"]', source)
        self.assertIn("context: query_context", source)

    def test_operation_receipt_preserves_before_and_after_context_revision(self) -> None:
        source = read_extension_sources()
        self.assertIn('"context_before" => context_before', source)
        self.assertIn('"context" => context', source)
        self.assertIn("context_before: pre_context", source)

    def test_face_and_extrusion_actions_are_closed_and_pid_based(self) -> None:
        source = read_extension_sources()
        self.assertIn('"create_face" => :execute_create_face', source)
        self.assertIn('"extrude_face_to_group" => :execute_extrude_face_to_group', source)
        self.assertIn("CREATE_FACE_PARAM_KEYS = %w[points].freeze", source)
        self.assertIn(
            "EXTRUDE_FACE_PARAM_KEYS = %w[persistent_id distance group_name].freeze",
            source,
        )
        self.assertIn('params["persistent_id"]', source)
        self.assertIn('require_active_entity(model, params["persistent_id"])', source)
        self.assertIn("face.all_connected", source)
        self.assertIn("model.active_entities.add_group(connected_after)", source)

    def test_strict_expectation_validates_explicit_scene_delta_and_volume(self) -> None:
        source = read_extension_sources()
        self.assertIn("active_entity_delta", source)
        self.assertIn('"volume"', source)
        self.assertIn("validate_numeric_expectation", source)
        self.assertNotIn(
            '"active_entity_delta", 1',
            source,
        )

    def test_face_semantics_include_orientation_and_group_solid_state(self) -> None:
        source = read_extension_sources()
        self.assertIn('"normal"', source)
        self.assertIn('"area"', source)
        self.assertIn("semantic_surface_state", source)
        self.assertIn("quantized_point(face.normal)", source)
        self.assertIn("semantic_volume", source)
        self.assertIn('"manifold"', source)

    def test_model_fingerprint_hashes_active_semantic_state_not_pid_type_only(self) -> None:
        source = read_extension_sources()
        self.assertIn("MAX_MODEL_FINGERPRINT_ENTITIES", source)
        self.assertIn("semantic_entity_state(model, entity)", source)
        self.assertIn('state["semantic_fingerprint"]', source)

    def test_extrusion_rejects_non_isolated_face_before_pushpull(self) -> None:
        source = read_extension_sources()
        method_start = source.index("def execute_extrude_face_to_group")
        isolation_index = source.index("isolated_face_for_extrusion?", method_start)
        pushpull_index = source.index("face.pushpull", method_start)
        self.assertLess(isolation_index, pushpull_index)
        self.assertIn('"non_isolated_face"', source)

    def test_connected_push_pull_is_closed_stale_guarded_and_topology_bounded(self) -> None:
        source = read_extension_sources()
        self.assertIn('"push_pull_topology_face" => :execute_push_pull_topology_face', source)
        self.assertIn("PUSH_PULL_TOPOLOGY_PARAM_KEYS = %w[persistent_id distance topology_closure_fingerprint].freeze", source)
        self.assertIn('preflight_push_pull_topology_face(model, action_params) if action == "push_pull_topology_face"', source)
        self.assertIn('"push_pull_topology_face requires a Face"', source)
        self.assertIn('"stale_topology_state"', source)
        self.assertIn("before_closure = bounded_raw_topology_closure(face)", source)
        self.assertIn("face.pushpull(distance, false)", source)
        self.assertIn("after_closure = bounded_raw_topology_closure(current)", source)
        self.assertIn('"action.push_pull_source_survived"', source)
        self.assertIn('"affected.push_pull_old_within_preclosure"', source)
        self.assertIn('"affected.push_pull_new_within_postclosure"', source)
        self.assertIn('action != "push_pull_topology_face"', source)
        self.assertIn('"push_pull_topology_face requires expect.type = Face"', source)

    def test_raw_topology_delete_is_closed_guarded_and_affected_bounded(self) -> None:
        source = read_extension_sources()
        self.assertIn('"delete_topology_entity" => :execute_delete_topology_entity', source)
        self.assertIn("DELETE_TOPOLOGY_PARAM_KEYS = %w[persistent_id topology_closure_fingerprint].freeze", source)
        self.assertIn('preflight_delete_topology_entity(model, action_params) if action == "delete_topology_entity"', source)
        self.assertIn("require_raw_topology_entity", source)
        self.assertIn('"stale_topology_state"', source)
        self.assertIn("raw_topology_closure_fingerprint", source)
        self.assertIn("model.active_entities.erase_entities(entity)", source)
        self.assertIn('"action.topology_target_consumed"', source)
        self.assertIn('"affected.topology_no_created"', source)
        self.assertIn('"affected.topology_within_closure"', source)
        self.assertIn('"affected.topology_target_deleted"', source)
        self.assertIn('action != "delete_topology_entity"', source)
        self.assertIn('"delete_topology_entity requires expect.deleted = true"', source)

    def test_group_entities_is_strict_closed_and_preflighted_before_transaction(self) -> None:
        source = read_extension_sources()
        self.assertIn('"group_entities" => :execute_group_entities', source)
        self.assertIn("GROUP_ENTITIES_PARAM_KEYS = %w[persistent_ids name].freeze", source)
        self.assertIn("preflight_group_entities", source)
        handler_start = source.index("def handle_execute_geometry")
        preflight_index = source.index("preflight_geometry_action", handler_start)
        operation_index = source.index('model.start_operation("AI_Step", true)', handler_start)
        self.assertLess(preflight_index, operation_index)

    def test_group_entities_rejects_partial_raw_topology_and_unsupported_or_locked_targets(self) -> None:
        source = read_extension_sources()
        self.assertIn("complete_groupable_connected_geometry?", source)
        self.assertIn('"partial_connected_geometry"', source)
        self.assertIn('"unsupported_object_type"', source)
        self.assertIn('"locked_object"', source)
        self.assertIn("Sketchup::Edge", source)
        self.assertIn("Sketchup::Face", source)
        self.assertIn("Sketchup::Group", source)
        self.assertIn("Sketchup::ComponentInstance", source)

    def test_group_entities_verifies_exact_reparenting_identity_and_new_group(self) -> None:
        source = read_extension_sources()
        self.assertIn("model.active_entities.add_group(entities)", source)
        self.assertIn('"input_persistent_ids"', source)
        self.assertIn('"input_fingerprints"', source)
        self.assertIn('"group_definition_guid"', source)
        self.assertIn('"action.input_pids_alive"', source)
        self.assertIn('"action.input_parent_definition"', source)
        self.assertIn('"action.group_children_exact"', source)
        self.assertIn('"action.input_semantics_preserved"', source)
        self.assertIn("grouping_reparent_fingerprint", source)
        self.assertIn('"action.composition_bounds_min"', source)
        self.assertIn('"action.composition_bounds_max"', source)
        self.assertIn('"action.result_is_new"', source)
        self.assertIn("validate_action_affected_invariants", source)
        self.assertIn('"affected.created"', source)
        self.assertIn('"affected.modified"', source)
        self.assertIn('"affected.deleted"', source)

    def test_group_entities_expectation_requires_exact_delta_group_and_children(self) -> None:
        source = read_extension_sources()
        self.assertIn('"group_entities requires expect.active_entity_delta = 1 - input count"', source)
        self.assertIn('"group_entities requires expect.type = Group"', source)
        self.assertIn('"group_entities requires expect.child_persistent_ids"', source)
        self.assertIn('if expect.key?("child_persistent_ids")', source)
        self.assertIn("expected_children = normalize_expected_pid_set", source)
        self.assertIn('"child_persistent_ids",', source)

    def test_hierarchy_projection_bounds_large_definitions_without_rejecting_model(self) -> None:
        source = read_extension_sources()
        self.assertIn("child_count = child_entities ? child_entities.length : 0", source)
        self.assertIn("child_count <= MAX_OBJECTS", source)
        self.assertIn('"child_persistent_ids_truncated"', source)
        self.assertNotIn('"Entity hierarchy exceeds child entity limit"', source)

    def test_group_entities_supports_exact_multi_entity_if_match_set(self) -> None:
        source = read_extension_sources()
        self.assertIn("validate_group_if_match_set", source)
        self.assertIn('"if_match for group_entities must be an object keyed by persistent ID"', source)
        self.assertIn('"stale_entity_state"', source)

    def test_legacy_create_group_native_command_is_removed(self) -> None:
        source = read_extension_sources()
        command_block = source[source.index("COMMANDS = {"):source.index("}.freeze", source.index("COMMANDS = {"))]
        self.assertNotIn('"create_group" =>', command_block)
        self.assertNotIn("def handle_create_group", source)

    def test_execute_geometry_has_closed_action_allowlist_not_eval(self) -> None:
        source = read_extension_sources()
        self.assertIn('GEOMETRY_ACTIONS = {', source)
        self.assertIn('"create_box" => :execute_create_box', source)
        self.assertIn('"group_entities" => :execute_group_entities', source)
        self.assertIn('"create_component" => :execute_create_component', source)
        self.assertIn('"place_instance" => :execute_place_instance', source)
        self.assertIn('"make_unique" => :execute_make_unique', source)
        self.assertNotIn("eval(", source)
        self.assertNotIn("instance_eval", source)
        self.assertNotIn("class_eval", source)

    def test_component_actions_are_strict_closed_and_preflighted_before_transaction(self) -> None:
        source = read_extension_sources()
        self.assertIn("CREATE_COMPONENT_PARAM_KEYS = %w[persistent_ids name].freeze", source)
        self.assertIn("PLACE_INSTANCE_PARAM_KEYS = %w[definition_guid matrix].freeze", source)
        self.assertIn("MAKE_UNIQUE_PARAM_KEYS = %w[persistent_id].freeze", source)
        self.assertIn("def execute_create_component", source)
        self.assertIn("def execute_place_instance", source)
        self.assertIn("def execute_make_unique", source)
        self.assertIn("preflight_create_component(model, action_params) if action == \"create_component\"", source)
        self.assertIn("preflight_place_instance(model, action_params) if action == \"place_instance\"", source)
        self.assertIn("preflight_make_unique(model, action_params) if action == \"make_unique\"", source)

    def test_create_component_converts_group_to_component_instance(self) -> None:
        source = read_extension_sources()
        self.assertIn("model.active_entities.add_group(entities)", source)
        self.assertIn(".to_component", source)
        self.assertIn('"component_definition_guid"', source)
        self.assertIn('"create_component supports only edges, faces, groups, and component instances"', source)
        self.assertIn('"create_component targets must be unlocked"', source)

    def test_place_instance_resolves_definition_by_guid(self) -> None:
        source = read_extension_sources()
        self.assertIn("find_definition_by_guid", source)
        self.assertIn("model.active_entities.add_instance(definition", source)
        self.assertIn('"definition_not_found"', source)
        self.assertIn('"place_instance definitions must be component definitions"', source)

    def test_make_unique_verifies_new_definition_guid_and_geometry(self) -> None:
        source = read_extension_sources()
        self.assertIn(".make_unique", source)
        self.assertIn('"component_definition_guid_before"', source)
        self.assertIn('"component_definition_guid_after"', source)
        self.assertIn('"action.definition_guid_changed"', source)
        self.assertIn('"action.definition_geometry_preserved"', source)
        self.assertIn('"make_unique targets only component instances"', source)

    def test_definition_state_exposes_guid_geometry_and_instance_identity(self) -> None:
        source = read_extension_sources()
        self.assertIn("def semantic_definition_state", source)
        self.assertIn("def semantic_definition_geometry_fingerprint", source)
        self.assertIn('"definition_info" => :handle_definition_info', source)
        self.assertIn("DEFINITION_INFO_PARAM_KEYS = %w[definition_guid unit].freeze", source)
        self.assertIn('"definition" =>', source)

    def test_component_expectation_schema_is_closed_per_action(self) -> None:
        source = read_extension_sources()
        self.assertIn('"create_component requires expect.active_entity_delta = 1 - input count"', source)
        self.assertIn('"create_component requires expect.type = ComponentInstance"', source)
        self.assertIn('"place_instance requires expect.active_entity_delta = 1"', source)
        self.assertIn('"place_instance requires expect.definition_guid"', source)
        self.assertIn('"make_unique requires expect.active_entity_delta = 0"', source)
        self.assertIn('"make_unique requires expect.type = ComponentInstance"', source)

    def test_component_preconditions_cover_set_and_definition_match(self) -> None:
        source = read_extension_sources()
        self.assertIn("validate_component_if_match_set", source)
        self.assertIn('"if_match for create_component must be an object keyed by persistent ID"', source)
        self.assertIn('"if_match for place_instance must be a 64-character lowercase SHA-256 hex string"', source)
        self.assertIn('when "transform_entity", "delete_entity", "delete_topology_entity", "extrude_face_to_group", "push_pull_topology_face", "make_unique"', source)

    def test_copy_and_array_actions_are_strict_closed_and_preflighted(self) -> None:
        source = read_extension_sources()
        self.assertIn('"copy_entity" => :execute_copy_entity', source)
        self.assertIn('"linear_array" => :execute_linear_array', source)
        self.assertIn('"radial_array" => :execute_radial_array', source)
        self.assertIn("COPY_ENTITY_PARAM_KEYS = %w[persistent_id].freeze", source)
        self.assertIn("LINEAR_ARRAY_PARAM_KEYS = %w[persistent_id vector count].freeze", source)
        self.assertIn("RADIAL_ARRAY_PARAM_KEYS = %w[persistent_id axis_origin axis degrees count].freeze", source)
        self.assertIn("def execute_copy_entity", source)
        self.assertIn("def execute_linear_array", source)
        self.assertIn("def execute_radial_array", source)
        self.assertIn('preflight_copy_entity(model, action_params) if action == "copy_entity"', source)
        self.assertIn('preflight_linear_array(model, action_params) if action == "linear_array"', source)
        self.assertIn('preflight_radial_array(model, action_params) if action == "radial_array"', source)

    def test_copy_uses_native_group_copy_or_shared_definition_instance(self) -> None:
        source = read_extension_sources()
        self.assertIn("duplicate_object_for_copy", source)
        self.assertIn("model.active_entities.add_instance(definition", source)
        self.assertIn('"copy_entity requires a group/component instance"', source)
        self.assertIn('"copy_entity target must be unlocked"', source)
        self.assertIn('"action.copy_is_new"', source)
        self.assertIn('"action.copy_shares_source"', source)

    def test_array_bounds_count_and_projected_complexity(self) -> None:
        source = read_extension_sources()
        self.assertIn("MAX_ARRAY_COPIES = 100", source)
        self.assertIn("MAX_ARRAY_PROJECTED_ENTITIES = 5000", source)
        self.assertIn('"complexity_budget_exceeded"', source)
        self.assertIn('"array count must contain 1..100 copies"', source)
        self.assertIn('"action.array_count_exact"', source)
        self.assertIn('"action.array_transforms_exact"', source)

    def test_array_expectation_schema_pins_count_and_type(self) -> None:
        source = read_extension_sources()
        self.assertIn('"copy_entity requires expect.active_entity_delta = 1"', source)
        self.assertIn('"linear_array requires expect.active_entity_delta = count"', source)
        self.assertIn('"radial_array requires expect.active_entity_delta = count"', source)
        self.assertIn('"radial_array requires expect.count"', source)

    def test_copy_and_array_share_single_pid_precondition(self) -> None:
        source = read_extension_sources()
        self.assertIn('when "transform_entity", "delete_entity", "delete_topology_entity", "extrude_face_to_group", "push_pull_topology_face", "make_unique", "copy_entity", "linear_array", "radial_array"', source)

    def test_tag_and_material_assign_are_strict_closed_actions(self) -> None:
        source = read_extension_sources()
        self.assertIn('"tag_assign" => :execute_tag_assign', source)
        self.assertIn('"material_assign" => :execute_material_assign', source)
        self.assertIn("TAG_ASSIGN_PARAM_KEYS = %w[persistent_id tag].freeze", source)
        self.assertIn("MATERIAL_ASSIGN_PARAM_KEYS = %w[persistent_id material side].freeze", source)
        self.assertIn("def execute_tag_assign", source)
        self.assertIn("def execute_material_assign", source)
        self.assertIn('preflight_tag_assign(model, action_params) if action == "tag_assign"', source)
        self.assertIn('preflight_material_assign(model, action_params) if action == "material_assign"', source)

    def test_strict_assign_rejects_unknown_resources_before_mutation(self) -> None:
        source = read_extension_sources()
        self.assertIn('"Tags are assigned only to groups/components"', source)
        self.assertIn('"tag_not_found"', source)
        self.assertIn('"material_not_found"', source)
        self.assertIn('"Material side semantics require a Face"', source)
        self.assertIn('"action.assign_same_pid"', source)
        self.assertIn('"action.geometry_preserved"', source)

    def test_strict_assign_expectation_schema_pins_delta_and_value(self) -> None:
        source = read_extension_sources()
        self.assertIn('"tag_assign requires expect.active_entity_delta = 0"', source)
        self.assertIn('"tag_assign requires expect.tag"', source)
        self.assertIn('"material_assign requires expect.active_entity_delta = 0"', source)
        self.assertIn('"material_assign requires expect.material"', source)

    def test_strict_assign_shares_single_pid_precondition(self) -> None:
        source = read_extension_sources()
        self.assertIn('"tag_assign", "material_assign"', source)

    def test_curve_actions_are_strict_closed_and_preflighted(self) -> None:
        source = read_extension_sources()
        self.assertIn('"create_polyline" => :execute_create_polyline', source)
        self.assertIn('"create_rectangle" => :execute_create_rectangle', source)
        self.assertIn('"create_circle" => :execute_create_circle', source)
        self.assertIn('"create_arc" => :execute_create_arc', source)
        self.assertIn('"create_polygon" => :execute_create_polygon', source)
        self.assertIn("POLYLINE_PARAM_KEYS = %w[points closed].freeze", source)
        self.assertIn("RECTANGLE_PARAM_KEYS = %w[origin width height normal].freeze", source)
        self.assertIn("CIRCLE_PARAM_KEYS = %w[center normal radius segments].freeze", source)
        self.assertIn("ARC_PARAM_KEYS = %w[center normal radius start_degrees end_degrees segments].freeze", source)
        self.assertIn("POLYGON_PARAM_KEYS = %w[center normal radius sides].freeze", source)
        self.assertIn("def execute_create_polyline", source)
        self.assertIn("def execute_create_circle", source)
        self.assertIn("def execute_create_polygon", source)
        self.assertIn('preflight_create_polyline(model, action_params) if action == "create_polyline"', source)
        self.assertIn('preflight_create_circle(model, action_params) if action == "create_circle"', source)

    def test_curve_primitives_use_native_arc_and_face_constructors(self) -> None:
        source = read_extension_sources()
        self.assertIn("add_circle", source)
        self.assertIn("add_arc", source)
        self.assertIn("add_face", source)
        self.assertIn("add_line", source)
        self.assertIn("orthonormal_basis", source)
        self.assertIn("scaled_vector", source)
        self.assertIn('"action.radius_exact"', source)
        self.assertIn('"action.total_length_exact"', source)
        self.assertIn('"action.polygon_area_exact"', source)

    def test_curve_bounds_and_degenerate_inputs(self) -> None:
        source = read_extension_sources()
        self.assertIn("MAX_CURVE_SEGMENTS = 360", source)
        self.assertIn("MAX_POLYLINE_POINTS = 512", source)
        self.assertIn('"radius must be positive"', source)
        self.assertIn('"polyline points must be pairwise distinct"', source)
        self.assertIn('"arc sweep must be non-zero"', source)
        self.assertIn('"normal must be non-zero"', source)
        self.assertIn('"sides must contain 3..360 sides"', source)

    def test_curve_expectation_schema_pins_counts(self) -> None:
        source = read_extension_sources()
        self.assertIn('"create_polyline requires expect.active_entity_delta = 1"', source)
        self.assertIn('"create_circle requires expect.edge_count"', source)
        self.assertIn('"create_rectangle requires expect.edge_count"', source)
        self.assertIn('"create_polygon requires expect.edge_count"', source)
        self.assertIn('"create_arc requires expect.edge_count"', source)

    def test_sweep_action_is_strict_closed_and_preflighted(self) -> None:
        source = read_extension_sources()
        self.assertIn('"sweep_profile" => :execute_sweep_profile', source)
        self.assertIn("SWEEP_PROFILE_PARAM_KEYS = %w[face_pid path_pids].freeze", source)
        self.assertIn("def execute_sweep_profile", source)
        self.assertIn('preflight_sweep_profile(model, action_params) if action == "sweep_profile"', source)
        self.assertIn(".followme(", source)
        self.assertIn('"sweep_profile requires an isolated profile face"', source)
        self.assertIn('"sweep_profile path must contain 1..64 connected edges"', source)
        self.assertIn('"sweep_profile requires expect.active_entity_delta = 1 - input count"', source)
        self.assertIn('"sweep_profile requires expect.manifold"', source)
        self.assertIn('"action.sweep_manifold"', source)
        self.assertIn('"action.sweep_volume_positive"', source)
        self.assertIn('"action.profile_accounted"', source)
        self.assertIn('"action.lengths_preserved"', source)
        self.assertIn('"action.no_collateral_consumed"', source)

    def test_topology_closure_is_bounded_incrementally_and_reused(self) -> None:
        source = read_extension_sources()
        self.assertIn("def bounded_raw_topology_closure", source)
        self.assertIn("queue.shift", source)
        self.assertIn("vertex.edges", source)
        self.assertIn("edge.faces", source)
        self.assertIn("seen.length > MAX_TOPOLOGY_RESULTS", source)
        self.assertIn('"topology_closure_too_large"', source)
        self.assertIn("raw_topology_closure_fingerprint", source)
        self.assertIn("bounded_raw_topology_closure(entity)", source)
        self.assertIn("closure = bounded_raw_topology_closure(entity)", source)

    def test_measurement_queries_are_read_only_and_bounded(self) -> None:
        source = read_extension_sources()
        self.assertIn('"measure_distance" => :handle_measure_distance', source)
        self.assertIn('"query_topology" => :handle_query_topology', source)
        self.assertIn('"query_overlap" => :handle_query_overlap', source)
        self.assertIn("def query_pid_pair(params, keys)", source)
        self.assertIn("def handle_measure_distance", source)
        self.assertIn("def handle_query_topology", source)
        self.assertIn("def handle_query_overlap", source)
        self.assertIn('"center_distance"', source)
        self.assertIn('"bounds_gap"', source)
        self.assertIn('"overlap"', source)
        self.assertIn('"connected_persistent_ids"', source)
        self.assertIn('"loop_count"', source)
        self.assertIn("MAX_TOPOLOGY_RESULTS = 500", source)
        self.assertIn("def connected_entities(entity)", source)
        self.assertIn("entity.definition.entities.to_a", source)

    def test_asset_registry_is_allowlisted_and_bounded(self) -> None:
        source = read_extension_sources()
        self.assertIn('"asset_list" => :handle_asset_list', source)
        self.assertIn('"place_asset" => :execute_place_asset', source)
        self.assertIn("ASSET_MANIFEST_FILENAME = \"assets.json\".freeze", source)
        self.assertIn("MAX_ASSET_BYTES = 67108864", source)
        self.assertIn("def asset_registry_root", source)
        self.assertIn("def asset_registry_manifest", source)
        self.assertIn("def resolve_asset_file", source)
        self.assertIn('"asset_not_found"', source)
        self.assertIn('"asset_too_large"', source)
        self.assertIn('"asset_path_escape"', source)
        self.assertIn('"place_asset requires expect.active_entity_delta = 1"', source)
        self.assertIn('"action.asset_transform_exact"', source)

    def test_texture_registry_is_allowlisted_and_bounded(self) -> None:
        source = read_extension_sources()
        self.assertIn('"texture_list" => :handle_texture_list', source)
        self.assertIn('"material_apply_texture" => :execute_material_apply_texture', source)
        self.assertIn('"material_info" => :handle_material_info', source)
        self.assertIn('TEXTURE_MANIFEST_FILENAME = "textures.json".freeze', source)
        self.assertIn("MAX_TEXTURE_BYTES = 16777216", source)
        self.assertIn("def resolve_texture_file", source)
        self.assertIn('"texture_not_found"', source)
        self.assertIn('"texture_too_large"', source)
        self.assertIn('"texture_path_escape"', source)
        self.assertIn(".texture = ", source)
        self.assertIn(".size = ", source)
        self.assertIn('"material_apply_texture requires expect.active_entity_delta = 0"', source)
        self.assertIn('"material_apply_texture requires expect.material"', source)
        self.assertIn('"action.texture_dims_exact"', source)
        self.assertIn("MATERIAL_INFO_PARAM_KEYS = %w[material unit].freeze", source)

    def test_integrity_report_is_read_only_and_bounded(self) -> None:
        source = read_extension_sources()
        self.assertIn('"integrity_report" => :handle_integrity_report', source)
        self.assertIn("MAX_INTEGRITY_SCAN = 5000", source)
        self.assertIn("def handle_integrity_report", source)
        self.assertIn('"degenerate_edges"', source)
        self.assertIn('"non_manifold_edges"', source)
        self.assertIn('"unused_definitions"', source)
        self.assertIn('"unused_materials"', source)
        self.assertIn('"tag_hygiene"', source)
        self.assertIn('"invalid_transforms"', source)
        self.assertIn('"model_complexity"', source)
        self.assertIn('"scan_truncated"', source)

    def test_repair_actions_are_strict_and_exact(self) -> None:
        source = read_extension_sources()
        self.assertIn('"repair_reverse_face" => :execute_repair_reverse_face', source)
        self.assertIn('"repair_erase_degenerate" => :execute_repair_erase_degenerate', source)
        self.assertIn("REVERSE_FACE_PARAM_KEYS = %w[persistent_id].freeze", source)
        self.assertIn("ERASE_DEGENERATE_PARAM_KEYS = %w[persistent_id].freeze", source)
        self.assertIn("def execute_repair_reverse_face", source)
        self.assertIn("def execute_repair_erase_degenerate", source)
        self.assertIn(".reverse!", source)
        self.assertIn(".erase_entities", source)
        self.assertIn('"repair_reverse_face requires expect.active_entity_delta = 0"', source)
        self.assertIn('"repair_erase_degenerate requires expect.deleted = true"', source)
        self.assertIn('"action.face_reversed"', source)
        self.assertIn('"action.degenerate_erased"', source)
        self.assertIn('"degenerate edge bounds faces"', source)

    def test_camera_and_scene_paths_use_native_view_and_pages(self) -> None:
        source = read_extension_sources()
        self.assertIn('"camera_get" => :handle_camera_get', source)
        self.assertIn('"camera_set" => :execute_camera_set', source)
        self.assertIn('"scene_list" => :handle_scene_list', source)
        self.assertIn('"scene_create" => :execute_scene_create', source)
        self.assertIn("CAMERA_SET_PARAM_KEYS = %w[eye target up fov].freeze", source)
        self.assertIn("SCENE_CREATE_PARAM_KEYS = %w[name].freeze", source)
        self.assertIn("def camera_semantic_state", source)
        self.assertIn("def execute_camera_set", source)
        self.assertIn("def execute_scene_create", source)
        self.assertIn("model.pages", source)
        self.assertIn('"camera_set requires expect.camera_fov"', source)
        self.assertIn('"scene_create requires expect.scene_name"', source)
        self.assertIn('"action.camera_eye_exact"', source)
        self.assertIn('"action.camera_fov_exact"', source)
        self.assertIn("def compensate_non_undoable_action", source)
        self.assertIn('"Aborted scene was not removed"', source)
        self.assertIn('"Aborted camera was not restored"', source)

    def test_model_io_is_rooted_and_typed(self) -> None:
        source = read_extension_sources()
        self.assertIn('"model_save" => :handle_model_save', source)
        self.assertIn('"model_save_as" => :handle_model_save_as', source)
        self.assertIn('"model_open" => :handle_model_open', source)
        self.assertIn('"model_export" => :handle_model_export', source)
        self.assertIn('"model_list" => :handle_model_list', source)
        self.assertIn("MODEL_FILES_ROOTNAME = \"models\".freeze", source)
        self.assertIn("MODEL_SAVE_AS_PARAM_KEYS = %w[file overwrite].freeze", source)
        self.assertIn("MODEL_OPEN_PARAM_KEYS = %w[file if_model_guid].freeze", source)
        self.assertIn("MODEL_EXPORT_PARAM_KEYS = %w[file format overwrite width height].freeze", source)
        self.assertIn("MODEL_EXPORT_FORMATS = %w[dae kmz png jpg].freeze", source)
        self.assertIn("def resolve_model_file", source)
        self.assertIn('"model_path_escape"', source)
        self.assertIn('"model_already_exists"', source)
        self.assertIn('"model_not_found"', source)
        self.assertIn('"model_save_failed"', source)
        self.assertIn('"model_export_failed"', source)
        self.assertIn("write_image", source)
        self.assertIn('"action.file_saved"', source)
        self.assertIn('"action.file_opened"', source)
        self.assertIn('"action.file_exported"', source)
        self.assertIn('"action.scene_created"', source)


if __name__ == "__main__":
    unittest.main()
