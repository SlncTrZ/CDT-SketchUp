"""RBZ Builder — Reproducibly package the SketchUp extension source.
Wing: code | Topic: sketchup_distribution | Updated: 2026-09-09 19:05
"""

from __future__ import annotations

import argparse
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
EXTENSION_ROOT = ROOT / "extension"
DEFAULT_OUTPUT = ROOT / "dist" / "cdt-sketchup-bridge-0.1.0.rbz"


def build(output: Path) -> Path:
    """Create an RBZ archive containing only the extension loader and package tree."""
    sources = sorted(path for path in EXTENSION_ROOT.rglob("*") if path.is_file())
    if not sources:
        raise RuntimeError("extension source is empty")

    output.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(output, "w", compression=zipfile.ZIP_DEFLATED) as archive:
        for source in sources:
            archive.write(source, source.relative_to(EXTENSION_ROOT).as_posix())
    return output


def main() -> None:
    """CLI entry point."""
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    args = parser.parse_args()
    print(build(args.output))


if __name__ == "__main__":
    main()
