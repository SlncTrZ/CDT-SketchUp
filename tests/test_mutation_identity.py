"""Stable mutation identity — canonical hash and envelope for B2 retry safety.
Wing: code | Topic: sketchup_recovery | Updated: 2026-09-19
"""

from __future__ import annotations

import json
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
        self.assertEqual(
            first,
            '["o",[["61",["o",[["63",["i","3"]],["64",["i","4"]]]]],'
            '["62",["i","1"]]]]',
        )

    def test_float_format_is_runtime_independent(self) -> None:
        self.assertEqual(
            canonical_json({"v": 100.0}),
            '["o",[["76",["f","4059000000000000"]]]]',
        )
        self.assertEqual(
            canonical_json({"v": 0.5}),
            '["o",[["76",["f","3fe0000000000000"]]]]',
        )
        self.assertEqual(
            canonical_json({"v": 1e-7}),
            '["o",[["76",["f","3e7ad7f29abcaf48"]]]]',
        )

    def test_signed_zero_normalizes(self) -> None:
        self.assertEqual(canonical_json({"v": -0.0}), canonical_json({"v": 0.0}))

    def test_unicode_is_bound_by_utf8_bytes(self) -> None:
        self.assertIn("42c3a06e", canonical_json({"name": "Bàn"}))

    def test_non_finite_float_rejected(self) -> None:
        for value in (float("nan"), float("inf"), float("-inf")):
            with self.assertRaises(ValueError):
                canonical_json({"v": value})


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

    def test_envelope_binds_routing_and_preconditions(self) -> None:
        body = {
            "action": "create_box",
            "params": {"origin": [0, 0, 0], "dimensions": [1, 1, 1]},
            "if_context": {"id": "ctx-a", "revision": "rev-1"},
            "if_match": "entity-fp-1",
            "target_context": {"instance_path": [11, 22]},
        }
        baseline = request_hash(body["action"], body)

        variants = []
        changed_if_context = dict(body)
        changed_if_context["if_context"] = {"id": "ctx-a", "revision": "rev-2"}
        variants.append(changed_if_context)

        changed_target = dict(body)
        changed_target["target_context"] = {"instance_path": [11, 23]}
        variants.append(changed_target)

        changed_match = dict(body)
        changed_match["if_match"] = "entity-fp-2"
        variants.append(changed_match)

        for changed in variants:
            with self.subTest(changed=changed):
                self.assertNotEqual(
                    request_hash(changed["action"], changed),
                    baseline,
                )

    def test_envelope_rejects_bad_id(self) -> None:
        with self.assertRaises(ValueError):
            mutation_envelope("nope", {"action": "create_box"})


class CrossRuntimeVectorTests(unittest.TestCase):
    """Byte parity with kernel/mutation_journal.rb.

    Ruby exercises the same expected canonical bytes and SHA-256 constants in
    tests/test_mutation_journal.rb. Drift on either runtime breaks the gate.
    """

    V1 = (
        '{"action":"create_box","expect":{"active_entity_delta":1},'
        '"params":{"dimensions":[1,1,1],"name":"B","origin":[0,0,0]},'
        '"unit":"in"}'
    )
    V1_CANON = (
        '["o",[["616374696f6e",["s","6372656174655f626f78"]],'
        '["657870656374",["o",[["6163746976655f656e746974795f64656c7461",'
        '["i","1"]]]]],["706172616d73",["o",[["64696d656e73696f6e73",'
        '["a",[["i","1"],["i","1"],["i","1"]]]],["6e616d65",["s","42"]],'
        '["6f726967696e",["a",[["i","0"],["i","0"],["i","0"]]]]]]],'
        '["756e6974",["s","696e"]]]]'
    )
    V1_HASH = "92a81cd784c92befb1be3192f25a4adaaedf851a0999eae0c5b53361ef91c08f"

    V_NUMERIC = (
        '{"action":"probe","params":{"values":'
        '[1e-7,1e20,-0.0,0.0,0.1,1.2345678901234567]}}'
    )
    V_NUMERIC_CANON = (
        '["o",[["616374696f6e",["s","70726f6265"]],'
        '["706172616d73",["o",[["76616c756573",["a",'
        '[["f","3e7ad7f29abcaf48"],["f","4415af1d78b58c40"],'
        '["f","0000000000000000"],["f","0000000000000000"],'
        '["f","3fb999999999999a"],["f","3ff3c0ca428c59fb"]]]]]]]]]'
    )
    V_NUMERIC_HASH = "2b667560010250e46fac27ece9ff5a7ff910d3deda78beae265cbbb6ddc8d593"

    def test_canonical_matches_ruby_vectors(self) -> None:
        self.assertEqual(canonical_json(json.loads(self.V1)), self.V1_CANON)
        self.assertEqual(
            canonical_json(json.loads(self.V_NUMERIC)),
            self.V_NUMERIC_CANON,
        )

    def test_hash_matches_ruby_vectors(self) -> None:
        for raw, expected in (
            (self.V1, self.V1_HASH),
            (self.V_NUMERIC, self.V_NUMERIC_HASH),
        ):
            body = json.loads(raw)
            with self.subTest(raw=raw):
                self.assertEqual(
                    request_hash(body["action"], body),
                    expected,
                )


if __name__ == "__main__":
    unittest.main()
