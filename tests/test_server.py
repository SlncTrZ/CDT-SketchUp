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
                "create_polyline",
                "create_rectangle",
                "create_circle",
                "create_arc",
                "create_polygon",
                "sweep_profile",
                "measure_distance",
                "query_topology",
                "query_overlap",
                "asset_list",
                "place_asset",
                "texture_list",
                "material_apply_texture",
                "material_info",
                "camera_get",
                "camera_set",
                "scene_list",
                "scene_create",
                "model_save",
                "model_save_as",
                "model_open",
                "model_export",
                "model_list",
                "integrity_report",
                "repair_reverse_face",
                "repair_erase_degenerate",
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

    async def test_tag_assign_queries_then_uses_strict_engine(self) -> None:
        context = {"id": "a" * 64, "revision": "b" * 64}
        fingerprint = "c" * 64
        query_receipt = {
            "context": context,
            "entity_fingerprint": fingerprint,
            "result": {"persistent_id": 42, "type": "ComponentInstance"},
        }
        call = AsyncMock(side_effect=[query_receipt, {"committed": True, "persistent_id": 42}])
        with patch("cdt_sketchup.server._bridge.call", call):
            async with Client(mcp, raise_exceptions=True) as client:
                result = await client.call_tool("tag_assign", {"persistent_id": 42, "tag": "Walls"})
        self.assertFalse(result.is_error)
        self.assertEqual(call.await_count, 2)
        self.assertNotIn("tag_assign", [entry.args[0] for entry in call.await_args_list])
        strict = call.await_args_list[1].args
        self.assertEqual(strict[0], "execute_geometry")
        self.assertEqual(strict[1]["action"], "tag_assign")
        self.assertEqual(strict[1]["params"], {"persistent_id": 42, "tag": "Walls"})
        self.assertEqual(strict[1]["expect"], {"active_entity_delta": 0, "type": "ComponentInstance", "tag": "Walls"})
        self.assertEqual(strict[1]["if_context"], context)
        self.assertEqual(strict[1]["if_match"], fingerprint)

    async def test_material_assign_queries_then_uses_strict_engine(self) -> None:
        context = {"id": "a" * 64, "revision": "b" * 64}
        fingerprint = "c" * 64
        query_receipt = {
            "context": context,
            "entity_fingerprint": fingerprint,
            "result": {"persistent_id": 42, "type": "ComponentInstance"},
        }
        call = AsyncMock(side_effect=[query_receipt, {"committed": True, "persistent_id": 42}])
        with patch("cdt_sketchup.server._bridge.call", call):
            async with Client(mcp, raise_exceptions=True) as client:
                result = await client.call_tool(
                    "material_assign", {"persistent_id": 42, "material": "Brick", "side": "both"}
                )
        self.assertFalse(result.is_error)
        self.assertEqual(call.await_count, 2)
        self.assertNotIn("material_assign", [entry.args[0] for entry in call.await_args_list])
        strict = call.await_args_list[1].args
        self.assertEqual(strict[0], "execute_geometry")
        self.assertEqual(strict[1]["action"], "material_assign")
        self.assertEqual(
            strict[1]["params"], {"persistent_id": 42, "material": "Brick", "side": "both"}
        )
        self.assertEqual(
            strict[1]["expect"],
            {"active_entity_delta": 0, "type": "ComponentInstance", "material": "Brick"},
        )
        self.assertEqual(strict[1]["if_context"], context)
        self.assertEqual(strict[1]["if_match"], fingerprint)

    async def test_create_polyline_forwards_points_and_counts(self) -> None:
        call = AsyncMock(return_value={"receipt_schema_version": 1, "committed": True})
        points = [[0.0, 0.0, 0.0], [10.0, 0.0, 0.0], [10.0, 10.0, 0.0]]
        with patch("cdt_sketchup.server._bridge.call", call):
            async with Client(mcp, raise_exceptions=True) as client:
                result = await client.call_tool(
                    "create_polyline", {"points": points, "closed": False, "unit": "mm"}
                )
        self.assertFalse(result.is_error)
        call.assert_awaited_once_with(
            "execute_geometry",
            {
                "action": "create_polyline",
                "params": {"points": points, "closed": False},
                "expect": {"active_entity_delta": 1, "type": "Group", "edge_count": 2, "vertex_count": 3},
                "unit": "mm",
                "coordinate_space": "active_context",
            },
        )

    async def test_create_rectangle_forwards_profile_and_area(self) -> None:
        call = AsyncMock(return_value={"receipt_schema_version": 1, "committed": True})
        with patch("cdt_sketchup.server._bridge.call", call):
            async with Client(mcp, raise_exceptions=True) as client:
                result = await client.call_tool(
                    "create_rectangle",
                    {"origin": [0.0, 0.0, 0.0], "width": 10.0, "height": 20.0,
                     "normal": [0.0, 0.0, 1.0], "unit": "mm"},
                )
        self.assertFalse(result.is_error)
        call.assert_awaited_once_with(
            "execute_geometry",
            {
                "action": "create_rectangle",
                "params": {"origin": [0.0, 0.0, 0.0], "width": 10.0, "height": 20.0, "normal": [0.0, 0.0, 1.0]},
                "expect": {"active_entity_delta": 1, "type": "Group", "edge_count": 4, "vertex_count": 4},
                "unit": "mm",
                "coordinate_space": "active_context",
            },
        )

    async def test_create_circle_forwards_segments(self) -> None:
        call = AsyncMock(return_value={"receipt_schema_version": 1, "committed": True})
        with patch("cdt_sketchup.server._bridge.call", call):
            async with Client(mcp, raise_exceptions=True) as client:
                result = await client.call_tool(
                    "create_circle",
                    {"center": [0.0, 0.0, 0.0], "normal": [0.0, 0.0, 1.0], "radius": 5.0, "segments": 24, "unit": "mm"},
                )
        self.assertFalse(result.is_error)
        call.assert_awaited_once_with(
            "execute_geometry",
            {
                "action": "create_circle",
                "params": {"center": [0.0, 0.0, 0.0], "normal": [0.0, 0.0, 1.0], "radius": 5.0, "segments": 24},
                "expect": {"active_entity_delta": 1, "type": "Group", "edge_count": 24},
                "unit": "mm",
                "coordinate_space": "active_context",
            },
        )

    async def test_create_arc_forwards_angles(self) -> None:
        call = AsyncMock(return_value={"receipt_schema_version": 1, "committed": True})
        with patch("cdt_sketchup.server._bridge.call", call):
            async with Client(mcp, raise_exceptions=True) as client:
                result = await client.call_tool(
                    "create_arc",
                    {"center": [0.0, 0.0, 0.0], "normal": [0.0, 0.0, 1.0], "radius": 5.0,
                     "start_degrees": 0.0, "end_degrees": 90.0, "segments": 12, "unit": "mm"},
                )
        self.assertFalse(result.is_error)
        call.assert_awaited_once_with(
            "execute_geometry",
            {
                "action": "create_arc",
                "params": {"center": [0.0, 0.0, 0.0], "normal": [0.0, 0.0, 1.0], "radius": 5.0,
                           "start_degrees": 0.0, "end_degrees": 90.0, "segments": 12},
                "expect": {"active_entity_delta": 1, "type": "Group", "edge_count": 12},
                "unit": "mm",
                "coordinate_space": "active_context",
            },
        )

    async def test_create_polygon_forwards_sides_and_area(self) -> None:
        call = AsyncMock(return_value={"receipt_schema_version": 1, "committed": True})
        with patch("cdt_sketchup.server._bridge.call", call):
            async with Client(mcp, raise_exceptions=True) as client:
                result = await client.call_tool(
                    "create_polygon",
                    {"center": [0.0, 0.0, 0.0], "normal": [0.0, 0.0, 1.0], "radius": 10.0, "sides": 6, "unit": "mm"},
                )
        self.assertFalse(result.is_error)
        payload = call.await_args.args[1]
        self.assertEqual(payload["action"], "create_polygon")
        self.assertEqual(payload["expect"]["active_entity_delta"], 1)
        self.assertEqual(payload["expect"]["type"], "Group")
        self.assertEqual(payload["expect"]["vertex_count"], 6)
        self.assertEqual(payload["expect"]["edge_count"], 6)

    async def test_sweep_profile_forwards_face_path_and_match_set(self) -> None:
        call = AsyncMock(return_value={"receipt_schema_version": 1, "committed": True})
        context = {"id": "a" * 64, "revision": "b" * 64}
        matches = {"11": "c" * 64, "12": "d" * 64}
        query_receipt = {
            "context": context,
            "entity_fingerprint": "c" * 64,
            "result": {
                "persistent_id": 11,
                "type": "Face",
                "hierarchy": {"edge_persistent_ids": [21, 22, 23, 24]},
            },
        }
        call = AsyncMock(side_effect=[query_receipt, {"receipt_schema_version": 1, "committed": True}])
        with patch("cdt_sketchup.server._bridge.call", call):
            async with Client(mcp, raise_exceptions=True) as client:
                result = await client.call_tool(
                    "sweep_profile",
                    {"face_pid": 11, "path_pids": [12], "unit": "mm",
                     "if_context": context, "if_match": matches},
                )
        self.assertFalse(result.is_error)
        self.assertEqual(call.await_count, 2)
        strict = call.await_args_list[1].args
        self.assertEqual(strict[0], "execute_geometry")
        self.assertEqual(
            strict[1],
            {
                "action": "sweep_profile",
                "params": {"face_pid": 11, "path_pids": [12]},
                "expect": {"active_entity_delta": -5, "type": "Group", "manifold": True},
                "unit": "mm",
                "coordinate_space": "active_context",
                "if_context": context,
                "if_match": matches,
            },
        )

    async def test_measure_distance_forwards_pid_pair_and_unit(self) -> None:
        call = AsyncMock(return_value={"center_distance": 250.0, "unit": "mm"})
        with patch("cdt_sketchup.server._bridge.call", call):
            async with Client(mcp, raise_exceptions=True) as client:
                result = await client.call_tool(
                    "measure_distance", {"first_pid": 11, "second_pid": 12, "unit": "mm"}
                )
        self.assertFalse(result.is_error)
        call.assert_awaited_once_with(
            "measure_distance", {"first_pid": 11, "second_pid": 12, "unit": "mm"}
        )

    async def test_query_topology_forwards_pid(self) -> None:
        call = AsyncMock(return_value={"persistent_id": 11, "connected_persistent_ids": []})
        with patch("cdt_sketchup.server._bridge.call", call):
            async with Client(mcp, raise_exceptions=True) as client:
                result = await client.call_tool("query_topology", {"persistent_id": 11})
        self.assertFalse(result.is_error)
        call.assert_awaited_once_with("query_topology", {"persistent_id": 11, "unit": "in"})

    async def test_query_overlap_forwards_pid_pair(self) -> None:
        call = AsyncMock(return_value={"overlap": False})
        with patch("cdt_sketchup.server._bridge.call", call):
            async with Client(mcp, raise_exceptions=True) as client:
                result = await client.call_tool(
                    "query_overlap", {"first_pid": 11, "second_pid": 12, "unit": "mm"}
                )
        self.assertFalse(result.is_error)
        call.assert_awaited_once_with(
            "query_overlap", {"first_pid": 11, "second_pid": 12, "unit": "mm"}
        )

    async def test_asset_list_forwards_registry_query(self) -> None:
        call = AsyncMock(return_value={"assets": [], "asset_root": "assets"})
        with patch("cdt_sketchup.server._bridge.call", call):
            async with Client(mcp, raise_exceptions=True) as client:
                result = await client.call_tool("asset_list", {})
        self.assertFalse(result.is_error)
        call.assert_awaited_once_with("asset_list", {"unit": "in"})

    async def test_place_asset_forwards_key_matrix_and_name(self) -> None:
        matrix = [1.0,0.0,0.0,0.0, 0.0,1.0,0.0,0.0, 0.0,0.0,1.0,0.0, 10.0,20.0,30.0,1.0]
        registry = {"assets": [{"asset_key": "farmhouse", "name": "farmhouse", "file": "farmhouse.skp"}]}
        call = AsyncMock(side_effect=[registry, {"receipt_schema_version": 1, "committed": True}])
        with patch("cdt_sketchup.server._bridge.call", call):
            async with Client(mcp, raise_exceptions=True) as client:
                result = await client.call_tool(
                    "place_asset", {"asset_key": "farmhouse", "matrix": matrix, "unit": "mm"}
                )
        self.assertFalse(result.is_error)
        self.assertEqual(call.await_count, 2)
        strict = call.await_args_list[1].args
        self.assertEqual(strict[0], "execute_geometry")
        self.assertEqual(
            strict[1],
            {
                "action": "place_asset",
                "params": {"asset_key": "farmhouse", "matrix": matrix},
                "expect": {
                    "active_entity_delta": 1,
                    "type": "ComponentInstance",
                    "transformation": matrix,
                },
                "unit": "mm",
                "coordinate_space": "active_context",
            },
        )

    async def test_place_asset_fails_closed_for_unknown_key(self) -> None:
        call = AsyncMock(return_value={"assets": []})
        with patch("cdt_sketchup.server._bridge.call", call):
            async with Client(mcp, raise_exceptions=True) as client:
                result = await client.call_tool(
                    "place_asset", {"asset_key": "nope", "matrix": [1.0] * 16}
                )
        self.assertFalse(result.is_error)
        payload = result.structured_content
        self.assertEqual(payload.get("ok"), False)
        self.assertEqual(payload["error"]["kind"], "asset_not_found")
        call.assert_awaited_once_with("asset_list", {"unit": "in"})

    async def test_texture_list_forwards_registry_query(self) -> None:
        call = AsyncMock(return_value={"assets": [], "asset_root": "assets"})
        with patch("cdt_sketchup.server._bridge.call", call):
            async with Client(mcp, raise_exceptions=True) as client:
                result = await client.call_tool("texture_list", {})
        self.assertFalse(result.is_error)
        call.assert_awaited_once_with("texture_list", {"unit": "in"})

    async def test_material_apply_texture_forwards_dims_and_guards(self) -> None:
        call = AsyncMock(return_value={"receipt_schema_version": 1, "committed": True})
        context = {"id": "a" * 64, "revision": "b" * 64}
        with patch("cdt_sketchup.server._bridge.call", call):
            async with Client(mcp, raise_exceptions=True) as client:
                result = await client.call_tool(
                    "material_apply_texture",
                    {"material": "Brick", "texture_key": "brick", "width": 1016.0,
                     "height": 508.0, "unit": "mm", "if_context": context},
                )
        self.assertFalse(result.is_error)
        call.assert_awaited_once_with(
            "execute_geometry",
            {
                "action": "material_apply_texture",
                "params": {"material": "Brick", "texture_key": "brick", "width": 1016.0, "height": 508.0},
                "expect": {"active_entity_delta": 0, "material": "Brick"},
                "unit": "mm",
                "coordinate_space": "active_context",
                "if_context": context,
            },
        )

    async def test_material_info_forwards_name_query(self) -> None:
        call = AsyncMock(return_value={"material": "Brick"})
        with patch("cdt_sketchup.server._bridge.call", call):
            async with Client(mcp, raise_exceptions=True) as client:
                result = await client.call_tool("material_info", {"material": "Brick"})
        self.assertFalse(result.is_error)
        call.assert_awaited_once_with("material_info", {"material": "Brick", "unit": "in"})

    async def test_camera_get_forwards_unit_query(self) -> None:
        call = AsyncMock(return_value={"eye": [0.0, 0.0, 100.0]})
        with patch("cdt_sketchup.server._bridge.call", call):
            async with Client(mcp, raise_exceptions=True) as client:
                result = await client.call_tool("camera_get", {"unit": "mm"})
        self.assertFalse(result.is_error)
        call.assert_awaited_once_with("camera_get", {"unit": "mm"})

    async def test_camera_set_forwards_absolute_camera(self) -> None:
        call = AsyncMock(return_value={"receipt_schema_version": 1, "committed": True})
        context = {"id": "a" * 64, "revision": "b" * 64}
        fingerprint = "c" * 64
        with patch("cdt_sketchup.server._bridge.call", call):
            async with Client(mcp, raise_exceptions=True) as client:
                result = await client.call_tool(
                    "camera_set",
                    {"eye": [0.0, 0.0, 100.0], "target": [0.0, 0.0, 0.0],
                     "up": [0.0, 1.0, 0.0], "fov": 35.0, "unit": "mm",
                     "if_context": context, "if_match": fingerprint},
                )
        self.assertFalse(result.is_error)
        call.assert_awaited_once_with(
            "execute_geometry",
            {
                "action": "camera_set",
                "params": {"eye": [0.0, 0.0, 100.0], "target": [0.0, 0.0, 0.0],
                           "up": [0.0, 1.0, 0.0], "fov": 35.0},
                "expect": {"active_entity_delta": 0, "camera_fov": 35.0},
                "unit": "mm",
                "coordinate_space": "active_context",
                "if_context": context,
                "if_match": fingerprint,
            },
        )

    async def test_scene_list_forwards_query(self) -> None:
        call = AsyncMock(return_value={"scenes": [], "scene_count": 0})
        with patch("cdt_sketchup.server._bridge.call", call):
            async with Client(mcp, raise_exceptions=True) as client:
                result = await client.call_tool("scene_list", {})
        self.assertFalse(result.is_error)
        call.assert_awaited_once_with("scene_list", {"unit": "in"})

    async def test_scene_create_forwards_name(self) -> None:
        call = AsyncMock(return_value={"receipt_schema_version": 1, "committed": True})
        with patch("cdt_sketchup.server._bridge.call", call):
            async with Client(mcp, raise_exceptions=True) as client:
                result = await client.call_tool("scene_create", {"name": "View A"})
        self.assertFalse(result.is_error)
        call.assert_awaited_once_with(
            "execute_geometry",
            {
                "action": "scene_create",
                "params": {"name": "View A"},
                "expect": {"active_entity_delta": 0, "scene_name": "View A"},
                "unit": "in",
                "coordinate_space": "active_context",
            },
        )

    async def test_model_save_forwards_no_arg_call(self) -> None:
        call = AsyncMock(return_value={"receipt_schema_version": 1, "saved": True})
        with patch("cdt_sketchup.server._bridge.call", call):
            async with Client(mcp, raise_exceptions=True) as client:
                result = await client.call_tool("model_save", {})
        self.assertFalse(result.is_error)
        call.assert_awaited_once_with("model_save", {})

    async def test_model_save_as_forwards_file_and_overwrite(self) -> None:
        call = AsyncMock(return_value={"receipt_schema_version": 1, "saved": True})
        with patch("cdt_sketchup.server._bridge.call", call):
            async with Client(mcp, raise_exceptions=True) as client:
                result = await client.call_tool(
                    "model_save_as", {"file": "test.skp", "overwrite": True}
                )
        self.assertFalse(result.is_error)
        call.assert_awaited_once_with("model_save_as", {"file": "test.skp", "overwrite": True})

    async def test_model_open_forwards_file_and_model_guard(self) -> None:
        call = AsyncMock(return_value={"receipt_schema_version": 1, "opened": True})
        with patch("cdt_sketchup.server._bridge.call", call):
            async with Client(mcp, raise_exceptions=True) as client:
                result = await client.call_tool(
                    "model_open", {"file": "test.skp", "if_model_guid": "g" * 32}
                )
        self.assertFalse(result.is_error)
        call.assert_awaited_once_with("model_open", {"file": "test.skp", "if_model_guid": "g" * 32})

    async def test_model_export_forwards_format(self) -> None:
        call = AsyncMock(return_value={"receipt_schema_version": 1, "exported": True})
        with patch("cdt_sketchup.server._bridge.call", call):
            async with Client(mcp, raise_exceptions=True) as client:
                result = await client.call_tool(
                    "model_export", {"file": "test.dae", "format": "dae", "overwrite": False}
                )
        self.assertFalse(result.is_error)
        call.assert_awaited_once_with(
            "model_export", {"file": "test.dae", "format": "dae", "overwrite": False}
        )

    async def test_model_list_forwards_query(self) -> None:
        call = AsyncMock(return_value={"models": [], "model_count": 0})
        with patch("cdt_sketchup.server._bridge.call", call):
            async with Client(mcp, raise_exceptions=True) as client:
                result = await client.call_tool("model_list", {})
        self.assertFalse(result.is_error)
        call.assert_awaited_once_with("model_list", {})

    async def test_integrity_report_forwards_query(self) -> None:
        call = AsyncMock(return_value={"issue_count": 0})
        with patch("cdt_sketchup.server._bridge.call", call):
            async with Client(mcp, raise_exceptions=True) as client:
                result = await client.call_tool("integrity_report", {"unit": "mm"})
        self.assertFalse(result.is_error)
        call.assert_awaited_once_with("integrity_report", {"unit": "mm"})

    async def test_repair_reverse_face_queries_then_forwards(self) -> None:
        context = {"id": "a" * 64, "revision": "b" * 64}
        fingerprint = "c" * 64
        query_receipt = {
            "context": context,
            "entity_fingerprint": fingerprint,
            "result": {"persistent_id": 42, "type": "Face"},
        }
        call = AsyncMock(side_effect=[query_receipt, {"committed": True, "persistent_id": 42}])
        with patch("cdt_sketchup.server._bridge.call", call):
            async with Client(mcp, raise_exceptions=True) as client:
                result = await client.call_tool("repair_reverse_face", {"persistent_id": 42})
        self.assertFalse(result.is_error)
        self.assertEqual(call.await_count, 2)
        strict = call.await_args_list[1].args
        self.assertEqual(strict[0], "execute_geometry")
        self.assertEqual(strict[1]["action"], "repair_reverse_face")
        self.assertEqual(strict[1]["params"], {"persistent_id": 42})
        self.assertEqual(strict[1]["expect"], {"active_entity_delta": 0, "type": "Face"})
        self.assertEqual(strict[1]["if_context"], context)
        self.assertEqual(strict[1]["if_match"], fingerprint)

    async def test_repair_erase_degenerate_queries_then_forwards(self) -> None:
        context = {"id": "a" * 64, "revision": "b" * 64}
        fingerprint = "c" * 64
        query_receipt = {
            "context": context,
            "entity_fingerprint": fingerprint,
            "result": {"persistent_id": 42, "type": "Edge"},
        }
        call = AsyncMock(side_effect=[query_receipt, {"committed": True, "persistent_id": 42}])
        with patch("cdt_sketchup.server._bridge.call", call):
            async with Client(mcp, raise_exceptions=True) as client:
                result = await client.call_tool("repair_erase_degenerate", {"persistent_id": 42})
        self.assertFalse(result.is_error)
        strict = call.await_args_list[1].args
        self.assertEqual(strict[1]["action"], "repair_erase_degenerate")
        self.assertEqual(strict[1]["params"], {"persistent_id": 42})
        self.assertEqual(strict[1]["expect"], {"active_entity_delta": -1, "deleted": True})

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
