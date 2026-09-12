"""S1 Extension Tests — Static invariants for SketchUp-native modeling commands.
Wing: code | Topic: sketchup_s1 | Updated: 2026-09-09 23:12
"""

from __future__ import annotations

import unittest
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MAIN_RB = ROOT / "extension" / "cdt_sketchup" / "main.rb"

sys.path.insert(0, str(Path(__file__).resolve().parent))

from extension_tree import read_extension_sources  # noqa: E402


class S1ExtensionTests(unittest.TestCase):
    def test_s1_command_allowlist_is_typed_and_explicit(self) -> None:
        source = read_extension_sources()
        for command in (
            "selection_by_ids",
            "selection_clear",
            "object_delete",
            "push_pull_face",
            "component_create_box",
            "tag_create",
            "material_create",
        ):
            self.assertIn(f'"{command}" => :handle_{command}', source)

    def test_mutations_validate_active_edit_context(self) -> None:
        source = read_extension_sources()
        self.assertIn("require_active_entity", source)
        self.assertIn("find_entity_by_persistent_id", source)
        self.assertIn("entity.parent == model.active_entities.parent", source)

    def test_face_creation_maps_sketchup_argument_errors_to_invalid_geometry(self) -> None:
        source = read_extension_sources()
        self.assertIn('rescue ArgumentError', source)
        self.assertIn(
            'BridgeError.new("invalid_geometry", "SketchUp rejected face geometry")',
            source,
        )

    def test_grouping_uses_strict_semantic_action_not_legacy_bridge_handler(self) -> None:
        source = read_extension_sources()
        self.assertIn('"group_entities" => :execute_group_entities', source)
        self.assertIn('entities = persistent_ids.map { |value| require_active_entity(model, value) }', source)
        self.assertIn('model.active_entities.add_group(entities)', source)
        self.assertNotIn("def handle_create_group", source)

    def test_component_semantics_use_native_definition_primitives(self) -> None:
        source = read_extension_sources()
        self.assertIn('"definition_info" => :handle_definition_info', source)
        self.assertIn("model.definitions", source)
        self.assertIn(".to_component", source)
        self.assertIn(".make_unique", source)
        self.assertIn(".guid", source)
        self.assertIn(".instances", source)

    def test_duplication_uses_native_copy_and_instance_primitives(self) -> None:
        source = read_extension_sources()
        self.assertIn(".copy", source)
        self.assertIn("Geom::Transformation.translation", source)
        self.assertIn("Geom::Transformation.rotation", source)
        self.assertIn('"linear_array" => :execute_linear_array', source)
        self.assertIn('"radial_array" => :execute_radial_array', source)

    def test_strict_assign_uses_semantic_actions_not_legacy_handlers(self) -> None:
        source = read_extension_sources()
        self.assertIn('"tag_assign" => :execute_tag_assign', source)
        self.assertIn('"material_assign" => :execute_material_assign', source)
        self.assertIn("entity.layer = tag", source)
        self.assertIn("entity.back_material = material", source)
        self.assertNotIn("def handle_tag_assign", source)
        self.assertNotIn("def handle_material_assign", source)

    def test_curve_primitives_use_native_constructors(self) -> None:
        source = read_extension_sources()
        self.assertIn("add_circle", source)
        self.assertIn("add_arc", source)
        self.assertIn("add_face", source)
        self.assertIn("add_line", source)
        self.assertIn('"create_polyline" => :execute_create_polyline', source)
        self.assertIn('"create_polygon" => :execute_create_polygon', source)

    def test_sweep_uses_native_followme(self) -> None:
        source = read_extension_sources()
        self.assertIn('"sweep_profile" => :execute_sweep_profile', source)
        self.assertIn(".followme(", source)

    def test_measurement_queries_use_native_bounds_and_topology(self) -> None:
        source = read_extension_sources()
        self.assertIn('"measure_distance" => :handle_measure_distance', source)
        self.assertIn('"query_topology" => :handle_query_topology', source)
        self.assertIn('"query_overlap" => :handle_query_overlap', source)
        self.assertIn(".bounds", source)
        self.assertIn(".all_connected", source)
        self.assertIn(".loops", source)

    def test_asset_placement_uses_native_definition_load(self) -> None:
        source = read_extension_sources()
        self.assertIn('"asset_list" => :handle_asset_list', source)
        self.assertIn('"place_asset" => :execute_place_asset', source)
        self.assertIn("definitions.load", source)
        self.assertIn("model.active_entities.add_instance(definition", source)

    def test_textured_material_uses_native_texture_scale(self) -> None:
        source = read_extension_sources()
        self.assertIn(".texture = ", source)
        self.assertIn(".size = ", source)
        self.assertIn(".image_width", source)
        self.assertIn('"material_apply_texture" => :execute_material_apply_texture', source)

    def test_camera_and_scenes_use_native_view_pages(self) -> None:
        source = read_extension_sources()
        self.assertIn("active_view", source)
        self.assertIn(".camera", source)
        self.assertIn("model.pages", source)
        self.assertIn('"camera_get" => :handle_camera_get', source)
        self.assertIn('"scene_list" => :handle_scene_list', source)

    def test_model_io_uses_native_save_open_export(self) -> None:
        source = read_extension_sources()
        self.assertIn("model.save", source)
        self.assertIn("Sketchup.open_file", source)
        self.assertIn("model.export", source)
        self.assertIn('"model_save" => :handle_model_save', source)
        self.assertIn('"model_list" => :handle_model_list', source)

    def test_integrity_uses_native_inspection_primitives(self) -> None:
        source = read_extension_sources()
        self.assertIn('"integrity_report" => :handle_integrity_report', source)
        self.assertIn(".reverse!", source)
        self.assertIn("erase_entities", source)
        self.assertIn("count_used_instances", source)

    def test_s1_uses_native_sketchup_primitives(self) -> None:
        source = read_extension_sources()
        for token in (
            "Geom::Transformation.translation",
            "Geom::Transformation.rotation",
            "Geom::Transformation.scaling",
            ".pushpull(",
            "model.layers.add",
            "model.materials.add",
            "model.selection",
            "model.definitions.add",
            "model.active_entities.add_instance",
        ):
            self.assertIn(token, source)


if __name__ == "__main__":
    unittest.main()
