"""Extension tree helper — concatenated Ruby source for static invariant tests.

Wing: code | Topic: sketchup_bridge | Updated: 2026-09-12
"""

from __future__ import annotations

from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
EXTENSION_ROOT = ROOT / "extension"
MAIN_RB = EXTENSION_ROOT / "cdt_sketchup" / "main.rb"


def extension_ruby_files() -> list[Path]:
    """All Ruby sources of the SketchUp extension in deterministic order."""
    return sorted(EXTENSION_ROOT.rglob("*.rb"))


def read_extension_sources() -> str:
    """Concatenated extension sources for tree-wide static assertions."""
    return "\n".join(path.read_text(encoding="utf-8") for path in extension_ruby_files())
