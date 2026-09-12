"""Extension Safety Tests — Static invariants for the in-SketchUp Ruby bridge.
Wing: code | Topic: sketchup_bridge | Updated: 2026-09-09 22:47
"""

from __future__ import annotations

import unittest
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MAIN_RB = ROOT / "extension" / "cdt_sketchup" / "main.rb"

sys.path.insert(0, str(Path(__file__).resolve().parent))

from extension_tree import read_extension_sources  # noqa: E402


class ExtensionSafetyTests(unittest.TestCase):
    def test_bridge_is_loopback_only_and_main_thread_polled(self) -> None:
        source = read_extension_sources()
        self.assertIn('LOOPBACK = "127.0.0.1"', source)
        self.assertIn("UI.start_timer", source)
        self.assertNotIn("Thread.new", source)
        self.assertNotIn("Thread.start", source)

    def test_arbitrary_code_execution_is_not_exposed(self) -> None:
        source = read_extension_sources()
        forbidden = ("eval(", "instance_eval", "class_eval", "Kernel.system")
        for token in forbidden:
            self.assertNotIn(token, source)

    def test_private_handlers_use_allowlisted_private_dispatch(self) -> None:
        source = read_extension_sources()
        self.assertIn('handler = COMMANDS[payload["command"]]', source)
        self.assertNotIn("public_send(handler", source)
        self.assertIn('send(handler, payload["params"])', source)

    def test_mutations_use_sketchup_undo_operations(self) -> None:
        source = read_extension_sources()
        self.assertIn("start_operation", source)
        self.assertIn("commit_operation", source)
        self.assertIn("abort_operation", source)

    def test_public_errors_do_not_expose_temporary_native_debug_details(self) -> None:
        source = read_extension_sources()
        self.assertNotIn("DEBUG-TEMP", source)

    def test_rooted_file_access_uses_canonical_containment(self) -> None:
        source = read_extension_sources()
        self.assertIn("def canonical_contained_path", source)
        self.assertIn("File.realpath", source)
        self.assertIn("File.symlink?", source)
        self.assertIn('canonical_contained_path(root, resolved, "asset_path_escape")', source)
        self.assertIn('canonical_contained_path(root, resolved, "texture_path_escape")', source)
        self.assertIn('canonical_contained_path(root, resolved, "model_path_escape"', source)

    def test_document_side_effect_receipts_do_not_claim_transactions(self) -> None:
        source = read_extension_sources()
        self.assertIn('"receipt_kind" => "external_side_effect"', source)
        self.assertIn('"transactional" => false', source)
        self.assertIn('"rollback_supported" => false', source)
        self.assertIn('"unsaved_model_changes"', source)


if __name__ == "__main__":
    unittest.main()
