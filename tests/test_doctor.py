"""Doctor Tests — install/verify/repair flows without touching live systems.

Wing: code | Topic: sketchup_product | Updated: 2026-09-12
"""

from __future__ import annotations

import importlib.util
import json
import os
import sys
import tempfile
import unittest
import unittest.mock
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))
sys.path.insert(0, str(Path(__file__).resolve().parent))

from cdt_sketchup import doctor  # noqa: E402

REPO = Path(__file__).resolve().parents[1]


class DoctorTests(unittest.TestCase):
    def test_plugins_and_token_paths_honor_env_overrides(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            plugins = Path(tmpdir) / "Plugins"
            token = Path(tmpdir) / "bridge.token"
            with unittest.mock.patch.dict(
                os.environ,
                {"CDT_SKETCHUP_PLUGINS_DIR": str(plugins),
                 "CDT_SKETCHUP_BRIDGE_TOKEN_FILE": str(token)},
            ):
                self.assertEqual(doctor.plugins_dir(), plugins)
                self.assertEqual(doctor.bridge_token_file(), token)

    def test_install_and_uninstall_roundtrip_in_isolated_dir(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            plugins = Path(tmpdir) / "Plugins"
            with unittest.mock.patch.dict(
                os.environ, {"CDT_SKETCHUP_PLUGINS_DIR": str(plugins)}
            ):
                self.assertEqual(doctor.install_extension(), 0)
                main = plugins / "cdt_sketchup" / "main.rb"
                self.assertTrue(main.is_file())
                self.assertEqual(doctor.check_extension_installed().passed, True)
                self.assertEqual(doctor.uninstall_extension(), 0)
                self.assertFalse((plugins / "cdt_sketchup").exists())

    def test_support_bundle_never_contains_token_material(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            token = Path(tmpdir) / "bridge.token"
            token.write_text("super-secret-token-material", encoding="utf-8")
            with unittest.mock.patch.dict(
                os.environ, {"CDT_SKETCHUP_BRIDGE_TOKEN_FILE": str(token)}
            ):
                bundle = doctor.support_bundle()
        text = json.dumps(bundle)
        self.assertNotIn("super-secret-token-material", text)
        self.assertTrue(bundle["token_present"])

    def test_rbz_build_is_byte_reproducible(self) -> None:
        spec = importlib.util.spec_from_file_location(
            "build_rbz", REPO / "scripts" / "build_rbz.py"
        )
        assert spec is not None and spec.loader is not None
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        with tempfile.TemporaryDirectory() as tmpdir:
            first = Path(tmpdir) / "first.rbz"
            second = Path(tmpdir) / "second.rbz"
            module.build(first)
            module.build(second)
            self.assertEqual(doctor.file_sha256(first), doctor.file_sha256(second))

    def test_doctor_offline_reports_structured_checks(self) -> None:
        checks, _code = doctor.run_doctor(live=False)
        names = [check.name for check in checks]
        self.assertEqual(
            names,
            ["python", "extension-sources", "extension-installed", "bridge-token", "ports"],
        )
        for check in checks:
            self.assertIsInstance(check.passed, bool)
            self.assertTrue(check.detail)


if __name__ == "__main__":
    unittest.main()
