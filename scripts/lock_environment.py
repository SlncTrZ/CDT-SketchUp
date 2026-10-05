"""Generate portable platform PEP 751 locks from the project dependency declarations."""
from __future__ import annotations

import importlib.metadata
import subprocess
import sys
from pathlib import Path

import tomllib

ROOT = Path(__file__).resolve().parents[1]
PIP_VERSION = "26.1.2"


def main() -> int:
    if sys.version_info[:2] != (3, 12):
        raise SystemExit("canonical locks require CPython 3.12")
    if sys.platform not in {"linux", "win32"}:
        raise SystemExit("canonical target must be Linux or Windows")
    if importlib.metadata.version("pip") != PIP_VERSION:
        raise SystemExit(f"lock generation requires pip {PIP_VERSION}")
    data = tomllib.loads((ROOT / "pyproject.toml").read_text(encoding="utf-8"))
    dependencies = [
        *data["project"]["dependencies"],
        *data["project"]["optional-dependencies"]["dev"],
        *data["build-system"]["requires"],
    ]
    lock = ROOT / ("pylock.windows.toml" if sys.platform == "win32" else "pylock.linux.toml")
    subprocess.run([sys.executable, "-m", "pip", "lock", "-o", str(lock), *dependencies], cwd=ROOT, check=True)
    lock.write_text(lock.read_text(encoding="utf-8"), encoding="utf-8", newline="\n")
    print(lock)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
