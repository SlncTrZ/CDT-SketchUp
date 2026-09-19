"""Release Gate Tests — machine-checkable 1.0 release invariants.

Wing: code | Topic: sketchup_release | Updated: 2026-09-12
"""

from __future__ import annotations

import importlib.util
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import AsyncMock, patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))
sys.path.insert(0, str(Path(__file__).resolve().parent))

from cdt_sketchup import capabilities as capability_module  # noqa: E402
from cdt_sketchup import doctor  # noqa: E402
from cdt_sketchup.contract import (  # noqa: E402
    CONTRACT_VERSION,
    PROVIDER_VERSION,
    build_capabilities,
    build_help,
)
from extension_tree import EXTENSION_ROOT, read_extension_sources  # noqa: E402

REPO = Path(__file__).resolve().parents[1]


def load_script(name: str):
    spec = importlib.util.spec_from_file_location(name, REPO / "scripts" / f"{name}.py")
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def load_native_bench_b4():
    spec = importlib.util.spec_from_file_location(
        "native_bench_b4",
        REPO / "scripts" / "native_bench_b4.py",
    )
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def git(*args: str) -> subprocess.CompletedProcess:
    return subprocess.run(
        ["git", *args], capture_output=True, text=True, cwd=str(REPO), timeout=60
    )


class ReleaseGateTests(unittest.TestCase):
    def test_no_internal_private_files_are_tracked(self) -> None:
        completed = git("ls-files", "_private")
        if completed.returncode != 0:
            self.skipTest("git unavailable")
        self.assertEqual(completed.stdout.strip(), "", "tracked _private files present")

    def test_no_secret_like_files_are_tracked(self) -> None:
        completed = git("ls-files")
        if completed.returncode != 0:
            self.skipTest("git unavailable")
        tracked = completed.stdout.splitlines()
        forbidden = (".env", ".pem", ".key", "bridge.token")
        offenders = [
            name for name in tracked
            if any(name == token or name.endswith(token) for token in forbidden)
        ]
        self.assertEqual(offenders, [], f"secret-like tracked files: {offenders}")

    def test_public_docs_do_not_depend_on_private_tree(self) -> None:
        for path in (REPO / "docs").rglob("*.md"):
            text = path.read_text(encoding="utf-8")
            self.assertNotIn("_private/", text, str(path))

    def test_capability_registry_matches_public_tool_surface(self) -> None:
        help_tools = set(build_help()["tools"])
        payload = build_capabilities(bridge_connected=True, live_model=True)
        registered = {row["tool"] for row in payload["capabilities"]}
        self.assertEqual(help_tools, registered)

    def test_contract_versions_are_internally_consistent(self) -> None:
        self.assertEqual(PROVIDER_VERSION, "0.1.0")
        help_payload = build_help()
        self.assertEqual(help_payload["provider_version"], PROVIDER_VERSION)
        self.assertEqual(help_payload["contract_version"], CONTRACT_VERSION)

    def test_capability_safety_class_matches_rollback_model(self) -> None:
        payload = build_capabilities(bridge_connected=True, live_model=True)
        for row in payload["capabilities"]:
            if row["safety_class"] == "strict_mutation":
                self.assertTrue(row["rollback_verified"], row["tool"])
                self.assertTrue(row["transactional"], row["tool"])
                self.assertEqual(row["receipt_kind"], "operation", row["tool"])
            elif row["safety_class"] == "external_side_effect":
                self.assertFalse(row["rollback_verified"], row["tool"])
                self.assertFalse(row["transactional"], row["tool"])
                self.assertEqual(row["receipt_kind"], "external_side_effect", row["tool"])

    def test_preferred_and_compatibility_surfaces_are_disjoint(self) -> None:
        payload = build_capabilities(bridge_connected=True, live_model=True)
        preferred = set(payload["preferred_tools"])
        compatibility = set(payload["compatibility_tools"])
        self.assertEqual(preferred & compatibility, set())

    def test_no_domain_specific_tool_names_exist(self) -> None:
        source = read_extension_sources().lower()
        for forbidden in ("wall_system", "create_beam", "check_tcvn", "roof_design", "mep_route"):
            self.assertNotIn(forbidden, source, forbidden)

    def test_extension_entry_point_is_thin_and_tree_is_modular(self) -> None:
        main_lines = (EXTENSION_ROOT / "cdt_sketchup" / "main.rb").read_text(encoding="utf-8").splitlines()
        self.assertLess(len(main_lines), 300)
        for dirname in ("bridge", "kernel", "actions", "queries"):
            self.assertTrue(list((EXTENSION_ROOT / "cdt_sketchup" / dirname).glob("*.rb")), dirname)

    def test_release_manifest_binds_exact_source_runtime_and_evidence(self) -> None:
        manifest_module = load_script("release_manifest")
        manifest = manifest_module.build_manifest(
            evidence_paths=[REPO / "scripts" / "native_bench_b4.py"],
        )
        self.assertRegex(manifest["source"]["revision"], r"^[0-9a-f]{40}$")
        self.assertRegex(manifest["source"]["tree"], r"^[0-9a-f]{40}$")
        self.assertIn("python", manifest["runtime"])
        self.assertIn("platform", manifest["runtime"])
        self.assertIn("runner_os", manifest["ci"])
        self.assertIn("github_sha", manifest["ci"])
        self.assertEqual(
            manifest["contract"]["contract_version"],
            CONTRACT_VERSION,
        )
        self.assertEqual(
            manifest["contract"]["capability_fingerprint"],
            capability_module.CAPABILITY_FINGERPRINT,
        )
        evidence = manifest["evidence"]
        self.assertEqual(len(evidence), 1)
        self.assertEqual(evidence[0]["path"], "scripts/native_bench_b4.py")
        self.assertRegex(evidence[0]["sha256"], r"^[0-9a-f]{64}$")

    def test_public_spatial_exactness_claims_are_bounded(self) -> None:
        docs = {
            path.name: path.read_text(encoding="utf-8")
            for path in (
                REPO / "README.md",
                REPO / "docs" / "ARCHITECTURE.md",
                REPO / "docs" / "COMPATIBILITY.md",
                REPO / "docs" / "TOOL_GUIDE.md",
            )
        }
        for name, text in docs.items():
            if "exact spatial" in text or "exact manifold-solid" in text:
                self.assertIn("1e-7", text, name)
                self.assertIn("1024", text, name)
                self.assertIn("1048576", text, name)

    def test_ci_emits_exact_source_release_manifest_on_linux_and_windows(self) -> None:
        workflow = (REPO / ".github" / "workflows" / "ci.yml").read_text(
            encoding="utf-8"
        )
        self.assertIn("ubuntu-latest", workflow)
        self.assertIn("windows-latest", workflow)
        self.assertIn("scripts/release_manifest.py", workflow)
        self.assertIn("--require-clean", workflow)
        self.assertIn("actions/upload-artifact@v4", workflow)

    def test_rbz_build_is_reproducible(self) -> None:
        spec = importlib.util.spec_from_file_location("build_rbz", REPO / "scripts" / "build_rbz.py")
        assert spec is not None and spec.loader is not None
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        with tempfile.TemporaryDirectory() as tmpdir:
            first = Path(tmpdir) / "a.rbz"
            second = Path(tmpdir) / "b.rbz"
            module.build(first)
            module.build(second)
            self.assertEqual(doctor.file_sha256(first), doctor.file_sha256(second))

    def test_doctor_offline_exit_code_is_defined(self) -> None:
        checks, code = doctor.run_doctor(live=False)
        self.assertIn(code, (0, 1))
        self.assertTrue(checks)

    def test_b4_certification_accepts_only_clean_report(self) -> None:
        bench = load_native_bench_b4()
        report = {
            "workloads": {
                "state": {"errors": 0},
                "create": {"errors": 0},
            },
            "over_budget": {"fail_closed": True, "crashed": False},
            "cleanup": {"residual": 0},
        }
        self.assertEqual(bench.certification_violations(report), [])

    def test_b4_certification_rejects_errors_residual_and_fail_open(self) -> None:
        bench = load_native_bench_b4()
        report = {
            "workloads": {
                "state": {"errors": 2},
                "create": {"errors": 0},
            },
            "over_budget": {"fail_closed": False, "crashed": False},
            "cleanup": {"residual": 1},
        }
        violations = bench.certification_violations(report)
        self.assertTrue(any("workload_errors" in item for item in violations))
        self.assertTrue(any("fail_closed" in item for item in violations))
        self.assertTrue(any("cleanup_residual" in item for item in violations))

    def test_b4_certify_cli_fails_machine_gate_but_run_remains_report_only(self) -> None:
        bench = load_native_bench_b4()
        outcome = {
            "bridge_available": True,
            "report": {
                "workloads": {"state": {"errors": 1}},
                "over_budget": {"fail_closed": True, "crashed": False},
                "cleanup": {"residual": 0},
            },
        }
        with patch.object(bench, "run_bench", new=AsyncMock(return_value=outcome)):
            self.assertEqual(
                bench.main(["--certify", "--iterations", "1", "--warmup", "0"]),
                1,
            )
        with patch.object(bench, "run_bench", new=AsyncMock(return_value=outcome)):
            self.assertEqual(
                bench.main(["--run", "--iterations", "1", "--warmup", "0"]),
                0,
            )

    def test_capability_fingerprint_is_stable(self) -> None:
        first = build_capabilities(bridge_connected=True, live_model=True)["capability_fingerprint"]
        second = build_capabilities(bridge_connected=False, live_model=False)["capability_fingerprint"]
        self.assertEqual(first, second)
        self.assertEqual(first, capability_module.CAPABILITY_FINGERPRINT)


if __name__ == "__main__":
    unittest.main()
