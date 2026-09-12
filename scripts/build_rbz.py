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
    """Create a byte-reproducible RBZ archive of the extension tree.

    ZIP entry timestamps and permissions are fixed so identical sources
    always produce an identical archive checksum.
    """
    sources = sorted(path for path in EXTENSION_ROOT.rglob("*") if path.is_file())
    if not sources:
        raise RuntimeError("extension source is empty")

    output.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(output, "w", compression=zipfile.ZIP_DEFLATED) as archive:
        for source in sources:
            info = zipfile.ZipInfo(
                source.relative_to(EXTENSION_ROOT).as_posix(),
                date_time=(1980, 1, 1, 0, 0, 0),
            )
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = 0o644 << 16
            archive.writestr(info, source.read_bytes())
    return output


def main() -> None:
    """CLI entry point."""
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    args = parser.parse_args()
    print(build(args.output))


if __name__ == "__main__":
    main()
