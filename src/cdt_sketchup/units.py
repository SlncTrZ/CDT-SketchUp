"""Public Units — Validate explicit public length units and coordinate spaces.
Wing: code | Topic: sketchup_units | Updated: 2026-09-11 18:22
"""

from __future__ import annotations

PUBLIC_LENGTH_UNITS = ("mm", "cm", "m", "in", "ft", "model")
PUBLIC_COORDINATE_SPACES = ("active_context",)
DEFAULT_PUBLIC_UNIT = "in"
DEFAULT_COORDINATE_SPACE = "active_context"


def validate_public_unit(value: str) -> str:
    if value not in PUBLIC_LENGTH_UNITS:
        raise ValueError(f"unit must be one of: {', '.join(PUBLIC_LENGTH_UNITS)}")
    return value


def validate_coordinate_space(value: str) -> str:
    if value not in PUBLIC_COORDINATE_SPACES:
        raise ValueError("coordinate_space must be active_context")
    return value
