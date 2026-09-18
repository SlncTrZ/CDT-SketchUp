"""Stable mutation identity — canonical hash and envelope for B2 retry safety.
Wing: code | Topic: sketchup_recovery | Updated: 2026-09-18
"""

from __future__ import annotations

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))

from cdt_sketchup.mutation import (
    canonical_json,
    mutation_envelope,
    new_mutation_id,
    request_hash,
    valid_mutation_id,
)


class CanonicalJsonTests(unittest.TestCase):
    def test_key_order_is_canonical(self) -> None:
        first = canonical_json({"b": 1, "a": {"d": 4, "c": 3}})
        second = canonical_json({"a": {"c": 3, "d": 4}, "b": 1})
        self.assertEqual(first, second)
        self.assertEqual(first, '{"a":{"c":3,"d":4},"b":1}')

    def test_float_format_is_stable(self) -> None:
        self.assertEqual(canonical_json({"v": 100.0}), '{"v":100.0}')
        self.assertEqual(canonical_json({"v": 0.5}), '{"v":0.5}')

    def test_unicode_value_preserved(self) -> None:
        self.assertIn("Bàn", canonical_json({"name": "Bàn"}))


class MutationEnvelopeTests(unittest.TestCase):
    def test_new_id_is_hex32_and_valid(self) -> None:
        first, second = new_mutation_id(), new_mutation_id()
        self.assertNotEqual(first, second)
        self.assertTrue(valid_mutation_id(first))
        self.assertFalse(valid_mutation_id("xyz"))
        self.assertFalse(valid_mutation_id("Z" * 32))

    def test_envelope_binds_canonical_request(self) -> None:
        body = {
            "action": "create_box",
            "params": {"name": "B", "origin": [0, 0, 0],
                       "dimensions": [1, 1, 1]},
            "expect": {"active_entity_delta": 1,
                       "type": "ComponentInstance"},
            "unit": "in",
        }
        first = mutation_envelope("ab" * 16, body)
        second = mutation_envelope("ab" * 16, dict(body))
        self.assertEqual(first["request_hash"], second["request_hash"])
        self.assertEqual(len(first["request_hash"]), 64)
        changed = dict(body)
        changed["unit"] = "mm"
        self.assertNotEqual(
            mutation_envelope("ab" * 16, changed)["request_hash"],
            first["request_hash"],
        )

    def test_envelope_rejects_bad_id(self) -> None:
        with self.assertRaises(ValueError):
            mutation_envelope("nope", {"action": "create_box"})


class CrossRuntimeVectorTests(unittest.TestCase):
    """Byte parity with kernel/mutation_journal.rb (Ruby vectors in
    tests/test_mutation_journal.rb). Breaks on either side on drift."""

    V1 = ('{"action":"create_box","expect":{"active_entity_delta":1},'
          '"params":{"dimensions":[1,1,1],"name":"B","origin":[0,0,0]},'
          '"unit":"in"}')
    V1_HASH = ("c453690b97197b39a17e3a1767ec9176b429fea27748e1f5718f13c862f6e4d6")
    V2 = ('{"action":"transform_entity","params":{"matrix":'
          '[1,0,0,0,0,1,0,0,0,0,1,0,2.5,0,0,1],"persistent_id":7}}')

    def test_canonical_matches_ruby(self) -> None:
        import json

        self.assertEqual(canonical_json(json.loads(self.V1)), self.V1)
        self.assertEqual(canonical_json(json.loads(self.V2)), self.V2)

    def test_hash_matches_ruby(self) -> None:
        import json

        body = json.loads(self.V1)
        self.assertEqual(request_hash(body["action"], body), self.V1_HASH)


if __name__ == "__main__":
    unittest.main()
