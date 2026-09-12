"""S1 Extension Tests — Static invariants for SketchUp-native modeling commands.
Wing: code | Topic: sketchup_s1 | Updated: 2026-09-09 23:12
"""

from __future__ import annotations

import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MAIN_RB = ROOT / "extension" / "cdt_sketchup" / "main.rb"


class S1ExtensionTests(unittest.TestCase):
    def test_s1_command_allowlist_is_typed_and_explicit(self) -> None:
        source = MAIN_RB.read_text(encoding="utf-8")
        for command in (
            "selection_by_ids",
            "selection_clear",
            "object_delete",
            "push_pull_face",
            "component_create_box",
            "tag_create",
            "tag_assign",
            "material_create",
            "material_assign",
        ):
            self.assertIn(f'"{command}" => :handle_{command}', source)

    def test_mutations_validate_active_edit_context(self) -> None:
        source = MAIN_RB.read_text(encoding="utf-8")
        self.assertIn("require_active_entity", source)
        self.assertIn("find_entity_by_persistent_id", source)
        self.assertIn("entity.parent == model.active_entities.parent", source)

    def test_face_creation_maps_sketchup_argument_errors_to_invalid_geometry(self) -> None:
        source = MAIN_RB.read_text(encoding="utf-8")
        self.assertIn('rescue ArgumentError', source)
        self.assertIn(
            'BridgeError.new("invalid_geometry", "SketchUp rejected face geometry")',
            source,
        )

    def test_grouping_uses_strict_semantic_action_not_legacy_bridge_handler(self) -> None:
        source = MAIN_RB.read_text(encoding="utf-8")
        self.assertIn('"group_entities" => :execute_group_entities', source)
        self.assertIn('entities = persistent_ids.map { |value| require_active_entity(model, value) }', source)
        self.assertIn('model.active_entities.add_group(entities)', source)
        self.assertNotIn("def handle_create_group", source)

    def test_component_semantics_use_native_definition_primitives(self) -> None:
        source = MAIN_RB.read_text(encoding="utf-8")
        self.assertIn('"definition_info" => :handle_definition_info', source)
        self.assertIn("model.definitions", source)
        self.assertIn(".to_component", source)
        self.assertIn(".make_unique", source)
        self.assertIn(".guid", source)
        self.assertIn(".instances", source)

    def test_duplication_uses_native_copy_and_instance_primitives(self) -> None:
        source = MAIN_RB.read_text(encoding="utf-8")
        self.assertIn(".copy", source)
        self.assertIn("Geom::Transformation.translation", source)
        self.assertIn("Geom::Transformation.rotation", source)
        self.assertIn('"linear_array" => :execute_linear_array', source)
        self.assertIn('"radial_array" => :execute_radial_array', source)

    def test_s1_uses_native_sketchup_primitives(self) -> None:
        source = MAIN_RB.read_text(encoding="utf-8")
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
