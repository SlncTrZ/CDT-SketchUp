"""MCP Server Tests — Discovery, forwarding, degradation, and network safety.
Wing: code | Topic: sketchup_s1 | Updated: 2026-09-11 18:40
"""

from __future__ import annotations

import os
import sys
import unittest
from pathlib import Path
from unittest.mock import AsyncMock, patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))

from mcp import Client  # noqa: E402

from cdt_sketchup.server import (  # noqa: E402
    BearerAuthMiddleware,
    create_app,
    mcp,
)


class MCPServerTests(unittest.IsolatedAsyncioTestCase):
    async def test_discovery_exposes_baseline_tools(self) -> None:
        async with Client(mcp, raise_exceptions=True) as client:
            tools = await client.list_tools()
        self.assertEqual(
            [tool.name for tool in tools.tools],
            [
                "help",
                "system_status",
                "system_capabilities",
                "document_info",
                "object_list",
                "object_get",
                "execute_geometry",
                "get_entity_state",
                "transform_entity",
                "move_entity",
                "rotate_entity",
                "scale_entity",
                "boolean_operation",
                "delete_entity",
                "group_entities",
                "create_component",
                "place_instance",
                "make_unique",
                "copy_entity",
                "linear_array",
                "radial_array",
                "mirror_entity",
                "definition_info",
                "create_edge",
                "create_face",
                "create_group",
                "selection_by_ids",
                "selection_clear",
                "object_delete",
                "object_move",
                "object_rotate",
                "object_scale",
                "push_pull_face",
                "component_create_box",
                "tag_create",
                "tag_assign",
                "material_create",
                "material_assign",
            ],
        )

    async def test_system_capabilities_includes_observed_runtime_metadata(self) -> None:
        probe = AsyncMock(return_value={
            "bridge_connected": True,
            "live_model": True,
            "runtime": {"sketchup_version": "24.0.594", "ruby_version": "3.2.2"},
        })
        with patch("cdt_sketchup.server._bridge.probe", probe):
            async with Client(mcp, raise_exceptions=True) as client:
                result = await client.call_tool("system_capabilities", {})
        self.assertFalse(result.is_error)
        payload = result.structured_content
        self.assertEqual(payload["capability_schema_version"], 2)
        self.assertEqual(payload["observed_runtime"]["sketchup_version"], "24.0.594")
        self.assertIn("delete_entity", payload["preferred_tools"])
        self.assertIn("group_entities", payload["preferred_tools"])
        self.assertIn("object_delete", payload["compatibility_tools"])
        self.assertIn("create_group", payload["compatibility_tools"])

    async def test_semantic_loop_tools_forward_closed_payloads(self) -> None:
        call = AsyncMock(return_value={"committed": True, "persistent_id": 77})
        with patch("cdt_sketchup.server._bridge.call", call):
            async with Client(mcp, raise_exceptions=True) as client:
                result = await client.call_tool(
                    "execute_geometry",
                    {
                        "action": "create_box",
                        "params": {
                            "name": "AI_BOX",
                            "dimensions": [10.0, 20.0, 30.0],
                            "origin": [0.0, 0.0, 0.0],
                        },
                        "expect": {
                            "active_entity_delta": 1,
                            "type": "ComponentInstance",
                            "bounds_size": [10.0, 20.0, 30.0],
                            "manifold": True,
                        },
                    },
                )
        self.assertFalse(result.is_error)
        call.assert_awaited_once_with(
            "execute_geometry",
            {
                "action": "create_box",
                "params": {
                    "name": "AI_BOX",
                    "dimensions": [10.0, 20.0, 30.0],
                    "origin": [0.0, 0.0, 0.0],
                },
                "expect": {
                    "active_entity_delta": 1,
                    "type": "ComponentInstance",
                    "bounds_size": [10.0, 20.0, 30.0],
                    "manifold": True,
                },
                "unit": "in",
                "coordinate_space": "active_context",
            },
        )

        call.reset_mock()
        call.return_value = {"persistent_id": 77, "semantic_fingerprint": "abc"}
        with patch("cdt_sketchup.server._bridge.call", call):
            async with Client(mcp, raise_exceptions=True) as client:
                state = await client.call_tool("get_entity_state", {"persistent_id": 77})
        self.assertFalse(state.is_error)
        call.assert_awaited_once_with(
            "get_entity_state",
            {"persistent_id": 77, "unit": "in", "coordinate_space": "active_context"},
        )

    async def test_strict_dimensional_tools_forward_explicit_units_and_coordinate_space(self) -> None:
        call = AsyncMock(return_value={"receipt_schema_version": 1, "committed": True})
        with patch("cdt_sketchup.server._bridge.call", call):
            async with Client(mcp, raise_exceptions=True) as client:
                result = await client.call_tool(
                    "execute_geometry",
                    {
                        "action": "create_box",
                        "params": {"name": "MM_BOX", "dimensions": [25.4, 50.8, 76.2], "origin": [0.0, 0.0, 0.0]},
                        "expect": {"active_entity_delta": 1, "type": "ComponentInstance", "bounds_size": [25.4, 50.8, 76.2], "manifold": True},
                        "unit": "mm",
                        "coordinate_space": "active_context",
                    },
                )
        self.assertFalse(result.is_error)
        call.assert_awaited_once_with(
            "execute_geometry",
            {
                "action": "create_box",
                "params": {"name": "MM_BOX", "dimensions": [25.4, 50.8, 76.2], "origin": [0.0, 0.0, 0.0]},
                "expect": {"active_entity_delta": 1, "type": "ComponentInstance", "bounds_size": [25.4, 50.8, 76.2], "manifold": True},
                "unit": "mm",
                "coordinate_space": "active_context",
            },
        )

        call.reset_mock()
        with patch("cdt_sketchup.server._bridge.call", call):
            async with Client(mcp, raise_exceptions=True) as client:
                queried = await client.call_tool(
                    "get_entity_state",
                    {"persistent_id": 77, "unit": "ft", "coordinate_space": "active_context"},
                )
        self.assertFalse(queried.is_error)
        call.assert_awaited_once_with(
            "get_entity_state",
            {"persistent_id": 77, "unit": "ft", "coordinate_space": "active_context"},
        )

    async def test_public_unit_and_coordinate_contract_fails_closed_before_bridge(self) -> None:
        call = AsyncMock()
        with patch("cdt_sketchup.server._bridge.call", call):
            async with Client(mcp, raise_exceptions=False) as client:
                bad_unit = await client.call_tool(
                    "get_entity_state",
                    {"persistent_id": 77, "unit": "yard", "coordinate_space": "active_context"},
                )
                bad_space = await client.call_tool(
                    "get_entity_state",
                    {"persistent_id": 77, "unit": "mm", "coordinate_space": "model"},
                )
        self.assertTrue(bad_unit.is_error)
        self.assertTrue(bad_space.is_error)
        call.assert_not_awaited()

    async def test_strict_preconditions_forward_context_object_and_entity_match(self) -> None:
        call = AsyncMock(return_value={"receipt_schema_version": 1, "committed": True})
        context = {"id": "a" * 64, "revision": "b" * 64}
        fingerprint = "c" * 64
        with patch("cdt_sketchup.server._bridge.call", call):
            async with Client(mcp, raise_exceptions=True) as client:
                result = await client.call_tool(
                    "transform_entity",
                    {
                        "persistent_id": 77,
                        "matrix": [1.0,0.0,0.0,0.0,0.0,1.0,0.0,0.0,0.0,0.0,1.0,0.0,10.0,20.0,30.0,1.0],
                        "if_context": context,
                        "if_match": fingerprint,
                    },
                )
        self.assertFalse(result.is_error)
        payload = call.await_args.args[1]
        self.assertEqual(payload["if_context"], context)
        self.assertEqual(payload["if_match"], fingerprint)

        call.reset_mock()
        with patch("cdt_sketchup.server._bridge.call", call):
            async with Client(mcp, raise_exceptions=True) as client:
                deleted = await client.call_tool(
                    "delete_entity",
                    {"persistent_id": 77, "if_context": context, "if_match": fingerprint},
                )
        self.assertFalse(deleted.is_error)
        payload = call.await_args.args[1]
        self.assertEqual(payload["if_context"], context)
        self.assertEqual(payload["if_match"], fingerprint)

    async def test_generic_execute_geometry_forwards_optional_preconditions_only_when_supplied(self) -> None:
        call = AsyncMock(return_value={"receipt_schema_version": 1, "committed": True})
        context = {"id": "a" * 64, "revision": "b" * 64}
        with patch("cdt_sketchup.server._bridge.call", call):
            async with Client(mcp, raise_exceptions=True) as client:
                result = await client.call_tool(
                    "execute_geometry",
                    {
                        "action": "create_box",
                        "params": {"name": "CTX_BOX", "dimensions": [1.0,2.0,3.0]},
                        "expect": {"active_entity_delta": 1, "type": "ComponentInstance"},
                        "if_context": context,
                    },
                )
        self.assertFalse(result.is_error)
        payload = call.await_args.args[1]
        self.assertEqual(payload["if_context"], context)
        self.assertNotIn("if_match", payload)

    async def test_structural_kernel_tools_route_through_semantic_loop(self) -> None:
        matrix = [1.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 10.0, 20.0, 30.0, 1.0]
        call = AsyncMock(return_value={"committed": True, "persistent_id": 99})
        with patch("cdt_sketchup.server._bridge.call", call):
            async with Client(mcp, raise_exceptions=True) as client:
                transformed = await client.call_tool("transform_entity", {"persistent_id": 77, "matrix": matrix})
        self.assertFalse(transformed.is_error)
        call.assert_awaited_once_with("execute_geometry", {
            "action": "transform_entity",
            "params": {"persistent_id": 77, "matrix": matrix},
            "expect": {"active_entity_delta": 0, "transformation": matrix},
            "unit": "in",
            "coordinate_space": "active_context",
        })

        call.reset_mock()
        with patch("cdt_sketchup.server._bridge.call", call):
            async with Client(mcp, raise_exceptions=True) as client:
                booleaned = await client.call_tool("boolean_operation", {"tool_pid": 11, "target_pid": 22, "operation_type": "difference"})
        self.assertFalse(booleaned.is_error)
        call.assert_awaited_once_with("execute_geometry", {
            "action": "boolean_operation",
            "params": {"tool_pid": 11, "target_pid": 22, "operation_type": "difference"},
            "expect": {"active_entity_delta": -1, "type": "Group", "manifold": True},
            "unit": "in",
            "coordinate_space": "active_context",
        })

        call.reset_mock()
        with patch("cdt_sketchup.server._bridge.call", call):
            async with Client(mcp, raise_exceptions=True) as client:
                deleted = await client.call_tool("delete_entity", {"persistent_id": 77})
        self.assertFalse(deleted.is_error)
        call.assert_awaited_once_with("execute_geometry", {
            "action": "delete_entity",
            "params": {"persistent_id": 77},
            "expect": {"active_entity_delta": -1, "deleted": True},
            "unit": "in",
            "coordinate_space": "active_context",
        })

    async def test_bridge_tools_return_structured_content(self) -> None:
        call = AsyncMock(return_value={"persistent_id": 42, "type": "Edge"})
        with patch("cdt_sketchup.server._bridge.call", call):
            async with Client(mcp, raise_exceptions=True) as client:
                result = await client.call_tool(
                    "create_edge",
                    {"start": [0.0, 0.0, 0.0], "end": [1.0, 0.0, 0.0]},
                )
        self.assertFalse(result.is_error)
        self.assertEqual(
            result.structured_content,
            {"persistent_id": 42, "type": "Edge"},
        )

    async def test_group_entities_forwards_exact_set_and_multi_entity_preconditions(self) -> None:
        call = AsyncMock(return_value={"receipt_schema_version": 1, "committed": True})
        context = {"id": "a" * 64, "revision": "b" * 64}
        matches = {"11": "c" * 64, "12": "d" * 64}
        with patch("cdt_sketchup.server._bridge.call", call):
            async with Client(mcp, raise_exceptions=True) as client:
                result = await client.call_tool(
                    "group_entities",
                    {
                        "persistent_ids": [11, 12],
                        "name": "Grouped",
                        "if_context": context,
                        "if_match": matches,
                    },
                )
        self.assertFalse(result.is_error)
        call.assert_awaited_once_with(
            "execute_geometry",
            {
                "action": "group_entities",
                "params": {"persistent_ids": [11, 12], "name": "Grouped"},
                "expect": {
                    "active_entity_delta": -1,
                    "type": "Group",
                    "child_persistent_ids": [11, 12],
                },
                "unit": "in",
                "coordinate_space": "active_context",
                "if_context": context,
                "if_match": matches,
            },
        )

    async def test_create_component_forwards_exact_set_and_match_set(self) -> None:
        call = AsyncMock(return_value={"receipt_schema_version": 1, "committed": True})
        context = {"id": "a" * 64, "revision": "b" * 64}
        matches = {"11": "c" * 64, "12": "d" * 64}
        with patch("cdt_sketchup.server._bridge.call", call):
            async with Client(mcp, raise_exceptions=True) as client:
                result = await client.call_tool(
                    "create_component",
                    {
                        "persistent_ids": [11, 12],
                        "name": "Composed",
                        "if_context": context,
                        "if_match": matches,
                    },
                )
        self.assertFalse(result.is_error)
        call.assert_awaited_once_with(
            "execute_geometry",
            {
                "action": "create_component",
                "params": {"persistent_ids": [11, 12], "name": "Composed"},
                "expect": {
                    "active_entity_delta": -1,
                    "type": "ComponentInstance",
                    "child_persistent_ids": [11, 12],
                },
                "unit": "in",
                "coordinate_space": "active_context",
                "if_context": context,
                "if_match": matches,
            },
        )

    async def test_place_instance_forwards_definition_guid_and_matrix(self) -> None:
        call = AsyncMock(return_value={"receipt_schema_version": 1, "committed": True})
        matrix = [1.0,0.0,0.0,0.0, 0.0,1.0,0.0,0.0, 0.0,0.0,1.0,0.0, 10.0,20.0,30.0,1.0]
        with patch("cdt_sketchup.server._bridge.call", call):
            async with Client(mcp, raise_exceptions=True) as client:
                result = await client.call_tool(
                    "place_instance",
                    {"definition_guid": "g" * 32, "matrix": matrix, "unit": "mm"},
                )
        self.assertFalse(result.is_error)
        call.assert_awaited_once_with(
            "execute_geometry",
            {
                "action": "place_instance",
                "params": {"definition_guid": "g" * 32, "matrix": matrix},
                "expect": {
                    "active_entity_delta": 1,
                    "type": "ComponentInstance",
                    "definition_guid": "g" * 32,
                    "transformation": matrix,
                },
                "unit": "mm",
                "coordinate_space": "active_context",
            },
        )

    async def test_make_unique_forwards_pid_and_preconditions(self) -> None:
        call = AsyncMock(return_value={"receipt_schema_version": 1, "committed": True})
        context = {"id": "a" * 64, "revision": "b" * 64}
        fingerprint = "c" * 64
        with patch("cdt_sketchup.server._bridge.call", call):
            async with Client(mcp, raise_exceptions=True) as client:
                result = await client.call_tool(
                    "make_unique",
                    {"persistent_id": 77, "if_context": context, "if_match": fingerprint},
                )
        self.assertFalse(result.is_error)
        call.assert_awaited_once_with(
            "execute_geometry",
            {
                "action": "make_unique",
                "params": {"persistent_id": 77},
                "expect": {"active_entity_delta": 0, "type": "ComponentInstance"},
                "unit": "in",
                "coordinate_space": "active_context",
                "if_context": context,
                "if_match": fingerprint,
            },
        )

    async def test_copy_entity_queries_type_then_forwards_strict_copy(self) -> None:
        identity = [1.0,0.0,0.0,0.0, 0.0,1.0,0.0,0.0, 0.0,0.0,1.0,0.0, 0.0,0.0,0.0,1.0]
        context = {"id": "a" * 64, "revision": "b" * 64}
        fingerprint = "c" * 64
        query_receipt = {
            "context": context,
            "entity_fingerprint": fingerprint,
            "result": {"persistent_id": 42, "type": "ComponentInstance", "transformation": identity},
        }
        call = AsyncMock(side_effect=[query_receipt, {"committed": True, "persistent_id": 43}])
        with patch("cdt_sketchup.server._bridge.call", call):
            async with Client(mcp, raise_exceptions=True) as client:
                result = await client.call_tool("copy_entity", {"persistent_id": 42})
        self.assertFalse(result.is_error)
        self.assertEqual(call.await_count, 2)
        strict = call.await_args_list[1].args
        self.assertEqual(strict[0], "execute_geometry")
        self.assertEqual(strict[1]["action"], "copy_entity")
        self.assertEqual(strict[1]["params"], {"persistent_id": 42})
        self.assertEqual(strict[1]["expect"], {"active_entity_delta": 1, "type": "ComponentInstance"})
        self.assertEqual(strict[1]["if_context"], context)
        self.assertEqual(strict[1]["if_match"], fingerprint)

    async def test_linear_array_forwards_vector_count_and_guards(self) -> None:
        context = {"id": "a" * 64, "revision": "b" * 64}
        fingerprint = "c" * 64
        query_receipt = {
            "context": context,
            "entity_fingerprint": fingerprint,
            "result": {"persistent_id": 42, "type": "Group"},
        }
        call = AsyncMock(side_effect=[query_receipt, {"committed": True}])
        with patch("cdt_sketchup.server._bridge.call", call):
            async with Client(mcp, raise_exceptions=True) as client:
                result = await client.call_tool(
                    "linear_array",
                    {"persistent_id": 42, "vector": [10.0, 0.0, 0.0], "count": 3, "unit": "mm"},
                )
        self.assertFalse(result.is_error)
        strict = call.await_args_list[1].args
        self.assertEqual(strict[0], "execute_geometry")
        self.assertEqual(strict[1]["action"], "linear_array")
        self.assertEqual(strict[1]["params"], {"persistent_id": 42, "vector": [10.0, 0.0, 0.0], "count": 3})
        self.assertEqual(strict[1]["expect"], {"active_entity_delta": 3, "type": "Group", "count": 3})
        self.assertEqual(strict[1]["unit"], "mm")
        self.assertEqual(strict[1]["if_context"], context)
        self.assertEqual(strict[1]["if_match"], fingerprint)

    async def test_radial_array_forwards_axis_and_step(self) -> None:
        context = {"id": "a" * 64, "revision": "b" * 64}
        fingerprint = "c" * 64
        query_receipt = {
            "context": context,
            "entity_fingerprint": fingerprint,
            "result": {"persistent_id": 42, "type": "ComponentInstance"},
        }
        call = AsyncMock(side_effect=[query_receipt, {"committed": True}])
        with patch("cdt_sketchup.server._bridge.call", call):
            async with Client(mcp, raise_exceptions=True) as client:
                result = await client.call_tool(
                    "radial_array",
                    {"persistent_id": 42, "axis_origin": [0.0, 0.0, 0.0], "axis": [0.0, 0.0, 1.0], "degrees": 90.0, "count": 4},
                )
        self.assertFalse(result.is_error)
        strict = call.await_args_list[1].args
        self.assertEqual(strict[1]["action"], "radial_array")
        self.assertEqual(
            strict[1]["params"],
            {"persistent_id": 42, "axis_origin": [0.0, 0.0, 0.0], "axis": [0.0, 0.0, 1.0], "degrees": 90.0, "count": 4},
        )
        self.assertEqual(strict[1]["expect"], {"active_entity_delta": 4, "type": "ComponentInstance", "count": 4})

    async def test_mirror_entity_builds_reflection_through_strict_transform(self) -> None:
        identity = [1.0,0.0,0.0,0.0, 0.0,1.0,0.0,0.0, 0.0,0.0,1.0,0.0, 0.0,0.0,0.0,1.0]
        context = {"id": "a" * 64, "revision": "b" * 64}
        fingerprint = "c" * 64
        query_receipt = {
            "context": context,
            "entity_fingerprint": fingerprint,
            "result": {"persistent_id": 42, "transformation": identity},
        }
        call = AsyncMock(side_effect=[query_receipt, {"committed": True}])
        with patch("cdt_sketchup.server._bridge.call", call):
            async with Client(mcp, raise_exceptions=True) as client:
                result = await client.call_tool(
                    "mirror_entity",
                    {"persistent_id": 42, "plane_point": [0.0, 0.0, 0.0], "plane_normal": [1.0, 0.0, 0.0]},
                )
        self.assertFalse(result.is_error)
        self.assertEqual(call.await_count, 2)
        strict = call.await_args_list[1].args
        self.assertEqual(strict[0], "execute_geometry")
        self.assertEqual(strict[1]["action"], "transform_entity")
        matrix = strict[1]["params"]["matrix"]
        self.assertEqual(len(matrix), 16)
        self.assertAlmostEqual(matrix[0], -1.0)
        self.assertAlmostEqual(matrix[5], 1.0)
        self.assertAlmostEqual(matrix[10], 1.0)
        self.assertEqual(strict[1]["if_context"], context)
        self.assertEqual(strict[1]["if_match"], fingerprint)

    async def test_definition_info_forwards_guid_query(self) -> None:
        call = AsyncMock(return_value={"guid": "g" * 32, "name": "Composed"})
        with patch("cdt_sketchup.server._bridge.call", call):
            async with Client(mcp, raise_exceptions=True) as client:
                result = await client.call_tool("definition_info", {"definition_guid": "g" * 32})
        self.assertFalse(result.is_error)
        call.assert_awaited_once_with("definition_info", {"definition_guid": "g" * 32, "unit": "in"})

    async def test_legacy_create_group_uses_strict_group_engine(self) -> None:
        call = AsyncMock(return_value={"receipt_schema_version": 1, "committed": True})
        with patch("cdt_sketchup.server._bridge.call", call):
            async with Client(mcp, raise_exceptions=True) as client:
                result = await client.call_tool(
                    "create_group",
                    {"persistent_ids": [11, 12], "name": "Grouped"},
                )
        self.assertFalse(result.is_error)
        self.assertNotIn("create_group", [entry.args[0] for entry in call.await_args_list])
        call.assert_awaited_once_with(
            "execute_geometry",
            {
                "action": "group_entities",
                "params": {"persistent_ids": [11, 12], "name": "Grouped"},
                "expect": {
                    "active_entity_delta": -1,
                    "type": "Group",
                    "child_persistent_ids": [11, 12],
                },
                "unit": "in",
                "coordinate_space": "active_context",
            },
        )

    async def test_transform_convenience_wrappers_query_then_use_strict_transform(self) -> None:
        identity = [1.0,0.0,0.0,0.0, 0.0,1.0,0.0,0.0, 0.0,0.0,1.0,0.0, 0.0,0.0,0.0,1.0]
        context = {"id": "a" * 64, "revision": "b" * 64}
        fingerprint = "c" * 64
        query_receipt = {
            "context": context,
            "entity_fingerprint": fingerprint,
            "result": {"persistent_id": 42, "transformation": identity},
        }
        committed = {"committed": True, "persistent_id": 42}
        call = AsyncMock(side_effect=[query_receipt, committed])
        with patch("cdt_sketchup.server._bridge.call", call):
            async with Client(mcp, raise_exceptions=True) as client:
                result = await client.call_tool(
                    "move_entity",
                    {"persistent_id": 42, "vector": [1.0, 2.0, 3.0]},
                )
        self.assertFalse(result.is_error)
        self.assertEqual(call.await_count, 2)
        self.assertEqual(call.await_args_list[0].args, (
            "get_entity_state",
            {"persistent_id": 42, "unit": "in", "coordinate_space": "active_context"},
        ))
        strict = call.await_args_list[1].args
        self.assertEqual(strict[0], "execute_geometry")
        self.assertEqual(strict[1]["action"], "transform_entity")
        self.assertEqual(strict[1]["params"]["matrix"][12:15], [1.0, 2.0, 3.0])
        self.assertEqual(strict[1]["if_context"], context)
        self.assertEqual(strict[1]["if_match"], fingerprint)

    async def test_rotation_and_scale_wrappers_construct_absolute_targets(self) -> None:
        identity = [1.0,0.0,0.0,0.0, 0.0,1.0,0.0,0.0, 0.0,0.0,1.0,0.0, 0.0,0.0,0.0,1.0]
        context = {"id": "a"*64, "revision": "b"*64}
        query = {"context": context, "entity_fingerprint": "c"*64, "result": {"transformation": identity, "bounds": {"center": [0.0,0.0,0.0]}}}
        for tool, args in (
            ("rotate_entity", {"persistent_id":42,"axis_origin":[0.0,0.0,0.0],"axis":[0.0,0.0,1.0],"degrees":90.0}),
            ("scale_entity", {"persistent_id":42,"factors":[2.0,3.0,4.0]}),
        ):
            call = AsyncMock(side_effect=[query, {"committed": True}])
            with patch("cdt_sketchup.server._bridge.call", call):
                async with Client(mcp, raise_exceptions=True) as client:
                    result = await client.call_tool(tool, args)
            self.assertFalse(result.is_error)
            payload = call.await_args_list[-1].args[1]
            self.assertEqual(payload["action"], "transform_entity")
            self.assertEqual(payload["if_context"], context)
            self.assertEqual(payload["if_match"], "c"*64)
            self.assertEqual(len(payload["params"]["matrix"]), 16)

    async def test_legacy_transform_aliases_use_same_strict_wrapper_not_native_legacy_commands(self) -> None:
        identity = [1.0,0.0,0.0,0.0, 0.0,1.0,0.0,0.0, 0.0,0.0,1.0,0.0, 0.0,0.0,0.0,1.0]
        query = {"context": {"id": "a"*64, "revision": "b"*64}, "entity_fingerprint": "c"*64, "result": {"transformation": identity}}
        call = AsyncMock(side_effect=[query, {"committed": True}])
        with patch("cdt_sketchup.server._bridge.call", call):
            async with Client(mcp, raise_exceptions=True) as client:
                result = await client.call_tool("object_move", {"persistent_id": 42, "vector": [1.0,2.0,3.0]})
        self.assertFalse(result.is_error)
        self.assertNotIn("object_move", [entry.args[0] for entry in call.await_args_list])
        self.assertEqual(call.await_args_list[-1].args[0], "execute_geometry")

    async def test_status_degrades_without_live_bridge(self) -> None:
        with patch.dict(
            os.environ,
            {"CDT_SKETCHUP_BRIDGE_TOKEN_FILE": "/definitely/missing/bridge.token"},
            clear=False,
        ):
            async with Client(mcp, raise_exceptions=True) as client:
                result = await client.call_tool("system_status", {})
        self.assertFalse(result.is_error)
        self.assertEqual(result.structured_content["status"], "degraded")
        self.assertFalse(result.structured_content["bridge"]["connected"])

    def test_any_configured_bearer_token_must_be_strong(self) -> None:
        with patch.dict(
            os.environ,
            {
                "CDT_SKETCHUP_MCP_HOST": "127.0.0.1",
                "CDT_SKETCHUP_MCP_TOKEN": "too-short",
            },
            clear=False,
        ):
            with self.assertRaisesRegex(RuntimeError, "at least 32"):
                create_app()

    def test_non_loopback_bind_requires_bearer_token(self) -> None:
        with patch.dict(
            os.environ,
            {
                "CDT_SKETCHUP_MCP_HOST": "0.0.0.0",
                "CDT_SKETCHUP_MCP_TOKEN": "",
                "CDT_SKETCHUP_ALLOWED_HOSTS": "mcp.example.test",
            },
            clear=False,
        ):
            with self.assertRaisesRegex(RuntimeError, "MCP_TOKEN"):
                create_app()

    def test_non_loopback_bind_requires_host_allowlist(self) -> None:
        with patch.dict(
            os.environ,
            {
                "CDT_SKETCHUP_MCP_HOST": "0.0.0.0",
                "CDT_SKETCHUP_MCP_TOKEN": "x" * 64,
                "CDT_SKETCHUP_ALLOWED_HOSTS": "",
            },
            clear=False,
        ):
            with self.assertRaisesRegex(RuntimeError, "ALLOWED_HOSTS"):
                create_app()

    def test_non_loopback_app_is_bearer_guarded(self) -> None:
        with patch.dict(
            os.environ,
            {
                "CDT_SKETCHUP_MCP_HOST": "0.0.0.0",
                "CDT_SKETCHUP_MCP_TOKEN": "y" * 64,
                "CDT_SKETCHUP_ALLOWED_HOSTS": "mcp.example.test",
                "CDT_SKETCHUP_ALLOWED_ORIGINS": "",
            },
            clear=False,
        ):
            app = create_app()
        self.assertIsInstance(app, BearerAuthMiddleware)


if __name__ == "__main__":
    unittest.main()
