"""Extension Safety Tests — Static invariants for the in-SketchUp Ruby bridge.
Wing: code | Topic: sketchup_bridge | Updated: 2026-09-09 22:47
"""

from __future__ import annotations

import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MAIN_RB = ROOT / "extension" / "cdt_sketchup" / "main.rb"


class ExtensionSafetyTests(unittest.TestCase):
    def test_bridge_is_loopback_only_and_main_thread_polled(self) -> None:
        source = MAIN_RB.read_text(encoding="utf-8")
        self.assertIn('LOOPBACK = "127.0.0.1"', source)
        self.assertIn("UI.start_timer", source)
        self.assertNotIn("Thread.new", source)
        self.assertNotIn("Thread.start", source)

    def test_arbitrary_code_execution_is_not_exposed(self) -> None:
        source = MAIN_RB.read_text(encoding="utf-8")
        forbidden = ("eval(", "instance_eval", "class_eval", "Kernel.system")
        for token in forbidden:
            self.assertNotIn(token, source)

    def test_private_handlers_use_allowlisted_private_dispatch(self) -> None:
        source = MAIN_RB.read_text(encoding="utf-8")
        self.assertIn('handler = COMMANDS[payload["command"]]', source)
        self.assertNotIn("public_send(handler", source)
        self.assertIn('send(handler, payload["params"])', source)

    def test_mutations_use_sketchup_undo_operations(self) -> None:
        source = MAIN_RB.read_text(encoding="utf-8")
        self.assertIn("start_operation", source)
        self.assertIn("commit_operation", source)
        self.assertIn("abort_operation", source)


if __name__ == "__main__":
    unittest.main()
