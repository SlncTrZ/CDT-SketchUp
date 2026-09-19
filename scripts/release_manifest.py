"""Release manifest — exact source/runtime/evidence provenance.

Wing: code | Topic: sketchup_release | Updated: 2026-09-19

Produces a deterministic JSON manifest binding the current Git commit/tree,
provider contract, capability fingerprint, Python/platform runtime and optional
evidence file SHA-256 values. The manifest records dirty paths explicitly;
callers may require a clean worktree for release certification.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import platform
import subprocess
import sys
from pathlib import Path
from typing import Iterable

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "src"))

from cdt_sketchup.capabilities import CAPABILITY_FINGERPRINT  # noqa: E402
from cdt_sketchup.contract import CONTRACT_VERSION, PROVIDER_VERSION  # noqa: E402


def _git(*args: str) -> str:
    completed = subprocess.run(
        ["git", *args],
        cwd=ROOT,
        capture_output=True,
        text=True,
        check=False,
        timeout=60,
    )
    if completed.returncode != 0:
        detail = completed.stderr.strip() or completed.stdout.strip()
        raise RuntimeError(f"git {' '.join(args)} failed: {detail}")
    return completed.stdout.strip()


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _repo_relative(path: Path) -> str:
    resolved = path.resolve()
    try:
        return resolved.relative_to(ROOT.resolve()).as_posix()
    except ValueError as exc:
        raise ValueError(f"evidence path is outside repository: {path}") from exc


def build_manifest(evidence_paths: Iterable[Path] = ()) -> dict:
    dirty = [line for line in _git("status", "--porcelain=v1").splitlines() if line]
    evidence = []
    for path in sorted((Path(item) for item in evidence_paths), key=lambda item: str(item)):
        if not path.is_file():
            raise FileNotFoundError(path)
        evidence.append(
            {
                "path": _repo_relative(path),
                "sha256": _sha256(path),
                "size_bytes": path.stat().st_size,
            }
        )

    return {
        "schema_version": 1,
        "source": {
            "revision": _git("rev-parse", "HEAD"),
            "tree": _git("rev-parse", "HEAD^{tree}"),
            "dirty": bool(dirty),
            "dirty_paths": dirty,
        },
        "runtime": {
            "python": platform.python_version(),
            "implementation": platform.python_implementation(),
            "platform": platform.platform(),
            "machine": platform.machine(),
        },
        "contract": {
            "provider_version": PROVIDER_VERSION,
            "contract_version": CONTRACT_VERSION,
            "capability_fingerprint": CAPABILITY_FINGERPRINT,
        },
        "ci": {
            "github_sha": os.environ.get("GITHUB_SHA"),
            "github_run_id": os.environ.get("GITHUB_RUN_ID"),
            "github_run_attempt": os.environ.get("GITHUB_RUN_ATTEMPT"),
            "runner_os": os.environ.get("RUNNER_OS"),
            "runner_arch": os.environ.get("RUNNER_ARCH"),
            "image_os": os.environ.get("ImageOS"),
        },
        "evidence": evidence,
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Write exact-source release manifest")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--evidence", type=Path, action="append", default=[])
    parser.add_argument("--require-clean", action="store_true")
    args = parser.parse_args(argv)

    manifest = build_manifest(args.evidence)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(
        json.dumps(manifest, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    if args.require_clean and manifest["source"]["dirty"]:
        print("release manifest: worktree is dirty", file=sys.stderr)
        return 1
    print(args.output)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
