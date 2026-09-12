"""Modular Tree Tests — main.rb stays thin, kernel/actions/queries stay separated.

Wing: code | Topic: sketchup_bridge | Updated: 2026-09-12
"""

from __future__ import annotations

import shutil
import subprocess
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))
sys.path.insert(0, str(Path(__file__).resolve().parent))

from extension_tree import (  # noqa: E402
    EXTENSION_ROOT,
    MAIN_RB,
    extension_ruby_files,
    read_extension_sources,
)

MODULE_DIRS = ("bridge", "kernel", "actions", "queries")

KERNEL_BUILDERS = (
    "def semantic_model_fingerprint",
    "def semantic_entity_state",
    "def build_operation_receipt",
    "def build_query_receipt",
    "def build_rollback_result",
    "def semantic_affected_entities",
    "def validate_semantic_expectation",
)


class ModularTreeTests(unittest.TestCase):
    def test_main_entry_is_thin(self) -> None:
        lines = MAIN_RB.read_text(encoding="utf-8").splitlines()
        self.assertLess(len(lines), 300, f"main.rb has {len(lines)} lines")

    def test_module_tree_exists(self) -> None:
        package = EXTENSION_ROOT / "cdt_sketchup"
        for dirname in MODULE_DIRS:
            entries = list((package / dirname).glob("*.rb"))
            self.assertTrue(entries, f"extension/cdt_sketchup/{dirname}/ has no Ruby modules")

    def test_main_requires_every_module(self) -> None:
        main_source = MAIN_RB.read_text(encoding="utf-8")
        package = EXTENSION_ROOT / "cdt_sketchup"
        loader = EXTENSION_ROOT / "cdt_sketchup.rb"
        for path in extension_ruby_files():
            if path == MAIN_RB or path == loader:
                continue
            relative = path.relative_to(package).with_suffix("").as_posix()
            self.assertIn(f'require_relative "{relative}"', main_source)

    def test_kernel_and_bridge_hold_no_action_handlers(self) -> None:
        package = EXTENSION_ROOT / "cdt_sketchup"
        for path in (package / "kernel").glob("*.rb"):
            source = path.read_text(encoding="utf-8")
            self.assertNotIn("def handle_", source, str(path))
            self.assertNotIn("def execute_", source, str(path))
        for path in (package / "bridge").glob("*.rb"):
            source = path.read_text(encoding="utf-8")
            self.assertNotIn("def execute_", source, str(path))
        server_source = (package / "bridge" / "server.rb").read_text(encoding="utf-8")
        for line in server_source.splitlines():
            if "def handle_" in line:
                self.assertIn(
                    line.strip(),
                    ("def handle_ping(_params)", "def handle_execute_geometry(params)"),
                    f"unexpected handler in bridge/server.rb: {line}",
                )

    def test_actions_and_queries_hold_no_kernel_builders(self) -> None:
        package = EXTENSION_ROOT / "cdt_sketchup"
        for dirname in ("actions", "queries"):
            for path in (package / dirname).glob("*.rb"):
                source = path.read_text(encoding="utf-8")
                for token in KERNEL_BUILDERS:
                    self.assertNotIn(token, source, f"{path}: {token}")

    def test_every_module_parses(self) -> None:
        ruby = shutil.which("ruby")
        if ruby is None:
            self.skipTest("ruby interpreter is unavailable")
        for path in extension_ruby_files():
            completed = subprocess.run(
                [ruby, "-c", str(path)], capture_output=True, text=True, timeout=60
            )
            self.assertEqual(completed.returncode, 0, f"{path}: {completed.stderr}")

    def test_rbz_build_includes_every_module(self) -> None:
        import importlib.util  # noqa: E402

        script = Path(__file__).resolve().parents[1] / "scripts" / "build_rbz.py"
        spec = importlib.util.spec_from_file_location("build_rbz", script)
        module = importlib.util.module_from_spec(spec)
        assert spec is not None and spec.loader is not None
        spec.loader.exec_module(module)

        with tempfile.TemporaryDirectory() as tmpdir:
            output = Path(tmpdir) / "test.rbz"
            module.build(output)
            with zipfile.ZipFile(output) as archive:
                names = set(archive.namelist())
        for path in extension_ruby_files():
            self.assertIn(path.relative_to(EXTENSION_ROOT).as_posix(), names)

    def test_tree_wide_source_still_exposes_strict_surface(self) -> None:
        source = read_extension_sources()
        self.assertIn('"sweep_profile" => :execute_sweep_profile', source)
        self.assertIn("def execute_repair_erase_degenerate", source)
        self.assertIn("def handle_integrity_report", source)

    def test_lifecycle_stays_public_while_internals_stay_private(self) -> None:
        package = EXTENSION_ROOT / "cdt_sketchup"
        server_source = (package / "bridge" / "server.rb").read_text(encoding="utf-8")
        public_block = server_source.split("    private")[0]
        self.assertIn("    def start\n", public_block)
        self.assertIn("    def stop\n", public_block)
        self.assertIn("    def initialize(port: DEFAULT_PORT)\n", public_block)


if __name__ == "__main__":
    unittest.main()
