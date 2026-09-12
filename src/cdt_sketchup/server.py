"""MCP Server — Streamable HTTP tools backed by the live SketchUp bridge.
Wing: code | Topic: sketchup_semantic_loop | Updated: 2026-09-11 18:43
"""

from __future__ import annotations

import hmac
import math
import os
from typing import Any, Awaitable, Callable

from mcp.server import MCPServer
from mcp.server.transport_security import TransportSecuritySettings

from .bridge import BridgeClient, BridgeProtocolError, BridgeUnavailableError
from .contract import (
    PROVIDER_NAME,
    PROVIDER_VERSION,
    build_capabilities,
    build_help,
    build_status,
)

from .units import (
    DEFAULT_COORDINATE_SPACE,
    DEFAULT_PUBLIC_UNIT,
    validate_coordinate_space,
    validate_public_unit,
)

DEFAULT_MCP_HOST = "127.0.0.1"
DEFAULT_MCP_PORT = 8765
LOOPBACK_HOSTS = {"127.0.0.1", "::1", "localhost"}

mcp = MCPServer(
    PROVIDER_NAME,
    version=PROVIDER_VERSION,
    instructions=(
        "SketchUp-native CAD automation. Live-model tools require the "
        "CDT-SketchUp Ruby extension bridge. Capabilities fail closed."
    ),
)
_bridge = BridgeClient()


def _error(kind: str, message: str, *, retryable: bool) -> dict[str, Any]:
    return {
        "ok": False,
        "error": {
            "kind": kind,
            "message": message,
            "retryable": retryable,
        },
    }


async def _call_bridge(command: str, params: dict[str, Any] | None = None) -> dict[str, Any]:
    try:
        return await _bridge.call(command, params)
    except BridgeUnavailableError:
        return _error(
            "live_bridge_unavailable",
            "SketchUp live bridge is unavailable.",
            retryable=True,
        )
    except BridgeProtocolError as exc:
        kind = str(exc).partition(":")[0] or "bridge_error"
        return _error(kind, "SketchUp bridge rejected the operation.", retryable=False)


def _matrix_multiply(left: list[float], right: list[float]) -> list[float]:
    if len(left) != 16 or len(right) != 16:
        raise ValueError("transform matrices must contain exactly 16 numbers")
    return [sum(left[row + 4*k] * right[k + 4*col] for k in range(4)) for col in range(4) for row in range(4)]

def _translation_matrix(vector: list[float]) -> list[float]:
    if len(vector) != 3:
        raise ValueError("vector must contain exactly 3 numbers")
    x,y,z=(float(v) for v in vector)
    if not all(math.isfinite(v) for v in (x,y,z)):
        raise ValueError("vector must contain finite numbers")
    return [1.,0.,0.,0., 0.,1.,0.,0., 0.,0.,1.,0., x,y,z,1.]

def _rotation_matrix(origin: list[float], axis: list[float], degrees: float) -> list[float]:
    if len(origin)!=3 or len(axis)!=3:
        raise ValueError("axis_origin and axis must contain exactly 3 numbers")
    ox,oy,oz=(float(v) for v in origin); ax,ay,az=(float(v) for v in axis); deg=float(degrees)
    if not all(math.isfinite(v) for v in (ox,oy,oz,ax,ay,az,deg)):
        raise ValueError("rotation inputs must be finite")
    length=math.sqrt(ax*ax+ay*ay+az*az)
    if length==0.: raise ValueError("axis must be non-zero")
    x,y,z=ax/length,ay/length,az/length; a=math.radians(deg); c=math.cos(a); q=math.sin(a); t=1.-c
    r=[t*x*x+c,t*x*y+q*z,t*x*z-q*y,0., t*x*y-q*z,t*y*y+c,t*y*z+q*x,0., t*x*z+q*y,t*y*z-q*x,t*z*z+c,0., 0.,0.,0.,1.]
    return _matrix_multiply(_translation_matrix([ox,oy,oz]),_matrix_multiply(r,_translation_matrix([-ox,-oy,-oz])))

def _scale_matrix(origin: list[float], factors: list[float]) -> list[float]:
    if len(origin)!=3 or len(factors)!=3: raise ValueError("origin and factors must contain exactly 3 numbers")
    ox,oy,oz=(float(v) for v in origin); sx,sy,sz=(float(v) for v in factors)
    if not all(math.isfinite(v) for v in (ox,oy,oz,sx,sy,sz)): raise ValueError("scale inputs must be finite")
    if 0. in (sx,sy,sz): raise ValueError("scale factors must be non-zero")
    scale=[sx,0.,0.,0., 0.,sy,0.,0., 0.,0.,sz,0., 0.,0.,0.,1.]
    return _matrix_multiply(_translation_matrix([ox,oy,oz]),_matrix_multiply(scale,_translation_matrix([-ox,-oy,-oz])))

def _reflection_matrix(plane_point: list[float], plane_normal: list[float]) -> list[float]:
    if len(plane_point) != 3 or len(plane_normal) != 3:
        raise ValueError("plane_point and plane_normal must contain exactly 3 numbers")
    px, py, pz = (float(v) for v in plane_point)
    nx, ny, nz = (float(v) for v in plane_normal)
    if not all(math.isfinite(v) for v in (px, py, pz, nx, ny, nz)):
        raise ValueError("mirror plane inputs must be finite")
    length = math.sqrt(nx * nx + ny * ny + nz * nz)
    if length == 0.:
        raise ValueError("plane_normal must be non-zero")
    nx, ny, nz = nx / length, ny / length, nz / length
    linear = [
        1. - 2. * nx * nx, -2. * nx * ny, -2. * nx * nz, 0.,
        -2. * nx * ny, 1. - 2. * ny * ny, -2. * ny * nz, 0.,
        -2. * nx * nz, -2. * ny * nz, 1. - 2. * nz * nz, 0.,
        0., 0., 0., 1.,
    ]
    return _matrix_multiply(_translation_matrix([px, py, pz]), _matrix_multiply(linear, _translation_matrix([-px, -py, -pz])))

async def _strict_object_guards(persistent_id:int, *, unit:str, coordinate_space:str, if_context:dict[str,str]|None, if_match:str|None, allowed:tuple[str,...]=("Group","ComponentInstance"), kind:str="Duplication")->dict[str,Any]:
    unit=validate_public_unit(unit); coordinate_space=validate_coordinate_space(coordinate_space)
    receipt=await _call_bridge("get_entity_state",{"persistent_id":persistent_id,"unit":unit,"coordinate_space":coordinate_space})
    if receipt.get("ok") is False: return receipt
    state=receipt.get("result",{}); obj_type=state.get("type")
    if obj_type not in allowed: return _error("unsupported_object_type",f"{kind} does not support this entity type.",retryable=False)
    current_context={key:receipt["context"][key] for key in ("id","revision")}
    if if_context is not None and if_context != current_context: return _error("context_mismatch","Active model/edit context changed since the supplied receipt.",retryable=False)
    if if_match is not None and if_match != receipt.get("entity_fingerprint"): return _error("stale_entity_state","Target entity state changed since the supplied receipt.",retryable=False)
    return {"unit":unit,"coordinate_space":coordinate_space,"context":current_context,"match":receipt["entity_fingerprint"],"type":obj_type}

async def _strict_relative_transform(persistent_id:int, delta:list[float] | Callable[[dict[str,Any]],list[float]], *, unit:str, coordinate_space:str, if_context:dict[str,str]|None, if_match:str|None)->dict[str,Any]:
    unit=validate_public_unit(unit); coordinate_space=validate_coordinate_space(coordinate_space)
    receipt=await _call_bridge("get_entity_state",{"persistent_id":persistent_id,"unit":unit,"coordinate_space":coordinate_space})
    if receipt.get("ok") is False: return receipt
    state=receipt.get("result",{}); current=state.get("transformation")
    if not isinstance(current,list) or len(current)!=16: return _error("unsupported_object_type","Entity does not expose a transform.",retryable=False)
    current_context={key:receipt["context"][key] for key in ("id","revision")}
    if if_context is not None and if_context != current_context: return _error("context_mismatch","Active model/edit context changed since the supplied receipt.",retryable=False)
    if if_match is not None and if_match != receipt.get("entity_fingerprint"): return _error("stale_entity_state","Target entity state changed since the supplied receipt.",retryable=False)
    relative=delta(state) if callable(delta) else delta; target=_matrix_multiply(relative,[float(v) for v in current])
    return await _call_bridge("execute_geometry",{"action":"transform_entity","params":{"persistent_id":persistent_id,"matrix":target},"expect":{"active_entity_delta":0,"transformation":target},"unit":unit,"coordinate_space":coordinate_space,"if_context":current_context,"if_match":receipt["entity_fingerprint"]})


@mcp.tool()
def help() -> dict[str, Any]:
    """Return provider identity, versions, safety invariants, and callable S0 tools."""
    return build_help()


@mcp.tool()
async def system_status() -> dict[str, Any]:
    """Probe live bridge/model readiness without mutating SketchUp."""
    probe = await _bridge.probe()
    return build_status(**probe)


@mcp.tool()
async def system_capabilities() -> dict[str, Any]:
    """Return capability declarations derived from current live state."""
    probe = await _bridge.probe()
    return build_capabilities(
        bridge_connected=probe["bridge_connected"],
        live_model=probe["live_model"],
        runtime=probe.get("runtime"),
    )


@mcp.tool()
async def document_info() -> dict[str, Any]:
    """Return information for the active SketchUp model and edit context."""
    return await _call_bridge("document_info")


@mcp.tool()
async def object_list(limit: int = 100, type: str | None = None) -> dict[str, Any]:
    """List bounded entities from the active SketchUp edit context."""
    params: dict[str, Any] = {"limit": limit}
    if type is not None:
        params["type"] = type
    return await _call_bridge("object_list", params)


@mcp.tool()
async def object_get(persistent_id: int) -> dict[str, Any]:
    """Get one SketchUp entity by persistent ID."""
    return await _call_bridge("object_get", {"persistent_id": persistent_id})


@mcp.tool()
async def execute_geometry(
    action: str,
    params: dict[str, Any],
    expect: dict[str, Any],
    unit: str = DEFAULT_PUBLIC_UNIT,
    coordinate_space: str = DEFAULT_COORDINATE_SPACE,
    if_context: dict[str, str] | None = None,
    if_match: str | dict[str, str] | None = None,
) -> dict[str, Any]:
    """Execute one closed action with optional optimistic context/entity preconditions."""
    unit = validate_public_unit(unit)
    coordinate_space = validate_coordinate_space(coordinate_space)
    payload: dict[str, Any] = {
        "action": action,
        "params": params,
        "expect": expect,
        "unit": unit,
        "coordinate_space": coordinate_space,
    }
    if if_context is not None:
        payload["if_context"] = if_context
    if if_match is not None:
        payload["if_match"] = if_match
    return await _call_bridge("execute_geometry", payload)


@mcp.tool()
async def get_entity_state(
    persistent_id: int,
    unit: str = DEFAULT_PUBLIC_UNIT,
    coordinate_space: str = DEFAULT_COORDINATE_SPACE,
) -> dict[str, Any]:
    """Return one semantic entity state in an explicit public length unit."""
    unit = validate_public_unit(unit)
    coordinate_space = validate_coordinate_space(coordinate_space)
    return await _call_bridge(
        "get_entity_state",
        {"persistent_id": persistent_id, "unit": unit, "coordinate_space": coordinate_space},
    )


@mcp.tool()
async def transform_entity(
    persistent_id: int,
    matrix: list[float],
    unit: str = DEFAULT_PUBLIC_UNIT,
    coordinate_space: str = DEFAULT_COORDINATE_SPACE,
    if_context: dict[str, str] | None = None,
    if_match: str | None = None,
) -> dict[str, Any]:
    """Set an absolute transform with optional context and entity-state preconditions."""
    unit = validate_public_unit(unit)
    coordinate_space = validate_coordinate_space(coordinate_space)
    payload: dict[str, Any] = {
        "action": "transform_entity",
        "params": {"persistent_id": persistent_id, "matrix": matrix},
        "expect": {"active_entity_delta": 0, "transformation": matrix},
        "unit": unit,
        "coordinate_space": coordinate_space,
    }
    if if_context is not None:
        payload["if_context"] = if_context
    if if_match is not None:
        payload["if_match"] = if_match
    return await _call_bridge("execute_geometry", payload)


@mcp.tool()
async def move_entity(persistent_id:int, vector:list[float], unit:str=DEFAULT_PUBLIC_UNIT, coordinate_space:str=DEFAULT_COORDINATE_SPACE, if_context:dict[str,str]|None=None, if_match:str|None=None)->dict[str,Any]:
    """Move relatively through the strict absolute-transform engine."""
    return await _strict_relative_transform(persistent_id,_translation_matrix(vector),unit=unit,coordinate_space=coordinate_space,if_context=if_context,if_match=if_match)

@mcp.tool()
async def rotate_entity(persistent_id:int, axis_origin:list[float], axis:list[float], degrees:float, unit:str=DEFAULT_PUBLIC_UNIT, coordinate_space:str=DEFAULT_COORDINATE_SPACE, if_context:dict[str,str]|None=None, if_match:str|None=None)->dict[str,Any]:
    """Rotate relatively through the strict absolute-transform engine."""
    return await _strict_relative_transform(persistent_id,_rotation_matrix(axis_origin,axis,degrees),unit=unit,coordinate_space=coordinate_space,if_context=if_context,if_match=if_match)

@mcp.tool()
async def scale_entity(persistent_id:int, factors:list[float], origin:list[float]|None=None, unit:str=DEFAULT_PUBLIC_UNIT, coordinate_space:str=DEFAULT_COORDINATE_SPACE, if_context:dict[str,str]|None=None, if_match:str|None=None)->dict[str,Any]:
    """Scale relatively through the strict absolute-transform engine."""
    def build_delta(state:dict[str,Any])->list[float]:
        chosen=origin if origin is not None else state.get("bounds",{}).get("center")
        if not isinstance(chosen,list): raise ValueError("scale origin is unavailable")
        return _scale_matrix(chosen,factors)
    return await _strict_relative_transform(persistent_id,build_delta,unit=unit,coordinate_space=coordinate_space,if_context=if_context,if_match=if_match)

@mcp.tool()
async def boolean_operation(
    tool_pid: int,
    target_pid: int,
    operation_type: str,
    unit: str = DEFAULT_PUBLIC_UNIT,
    coordinate_space: str = DEFAULT_COORDINATE_SPACE,
    if_context: dict[str, str] | None = None,
    if_match: str | None = None,
) -> dict[str, Any]:
    """Apply a strict boolean; if_match guards the target_pid semantic state."""
    unit = validate_public_unit(unit)
    coordinate_space = validate_coordinate_space(coordinate_space)
    payload: dict[str, Any] = {
        "action": "boolean_operation",
        "params": {
            "tool_pid": tool_pid,
            "target_pid": target_pid,
            "operation_type": operation_type,
        },
        "expect": {"active_entity_delta": -1, "type": "Group", "manifold": True},
        "unit": unit,
        "coordinate_space": coordinate_space,
    }
    if if_context is not None:
        payload["if_context"] = if_context
    if if_match is not None:
        payload["if_match"] = if_match
    return await _call_bridge("execute_geometry", payload)


@mcp.tool()
async def delete_entity(
    persistent_id: int,
    unit: str = DEFAULT_PUBLIC_UNIT,
    coordinate_space: str = DEFAULT_COORDINATE_SPACE,
    if_context: dict[str, str] | None = None,
    if_match: str | None = None,
) -> dict[str, Any]:
    """Strictly delete one object with optional context and entity-state preconditions."""
    unit = validate_public_unit(unit)
    coordinate_space = validate_coordinate_space(coordinate_space)
    payload: dict[str, Any] = {
        "action": "delete_entity",
        "params": {"persistent_id": persistent_id},
        "expect": {"active_entity_delta": -1, "deleted": True},
        "unit": unit,
        "coordinate_space": coordinate_space,
    }
    if if_context is not None:
        payload["if_context"] = if_context
    if if_match is not None:
        payload["if_match"] = if_match
    return await _call_bridge("execute_geometry", payload)


@mcp.tool()
async def group_entities(
    persistent_ids: list[int],
    name: str | None = None,
    unit: str = DEFAULT_PUBLIC_UNIT,
    coordinate_space: str = DEFAULT_COORDINATE_SPACE,
    if_context: dict[str, str] | None = None,
    if_match: dict[str, str] | None = None,
) -> dict[str, Any]:
    """Strictly group an exact active-context PID set while preserving input identities."""
    unit = validate_public_unit(unit)
    coordinate_space = validate_coordinate_space(coordinate_space)
    params: dict[str, Any] = {"persistent_ids": persistent_ids}
    if name is not None:
        params["name"] = name
    payload: dict[str, Any] = {
        "action": "group_entities",
        "params": params,
        "expect": {
            "active_entity_delta": 1 - len(persistent_ids),
            "type": "Group",
            "child_persistent_ids": persistent_ids,
        },
        "unit": unit,
        "coordinate_space": coordinate_space,
    }
    if if_context is not None:
        payload["if_context"] = if_context
    if if_match is not None:
        payload["if_match"] = if_match
    return await _call_bridge("execute_geometry", payload)


@mcp.tool()
async def create_component(
    persistent_ids: list[int],
    name: str | None = None,
    unit: str = DEFAULT_PUBLIC_UNIT,
    coordinate_space: str = DEFAULT_COORDINATE_SPACE,
    if_context: dict[str, str] | None = None,
    if_match: dict[str, str] | None = None,
) -> dict[str, Any]:
    """Strictly compose an exact active-context PID set into a new component definition."""
    unit = validate_public_unit(unit)
    coordinate_space = validate_coordinate_space(coordinate_space)
    params: dict[str, Any] = {"persistent_ids": persistent_ids}
    if name is not None:
        params["name"] = name
    payload: dict[str, Any] = {
        "action": "create_component",
        "params": params,
        "expect": {
            "active_entity_delta": 1 - len(persistent_ids),
            "type": "ComponentInstance",
            "child_persistent_ids": persistent_ids,
        },
        "unit": unit,
        "coordinate_space": coordinate_space,
    }
    if if_context is not None:
        payload["if_context"] = if_context
    if if_match is not None:
        payload["if_match"] = if_match
    return await _call_bridge("execute_geometry", payload)


@mcp.tool()
async def place_instance(
    definition_guid: str,
    matrix: list[float],
    unit: str = DEFAULT_PUBLIC_UNIT,
    coordinate_space: str = DEFAULT_COORDINATE_SPACE,
    if_context: dict[str, str] | None = None,
    if_match: str | None = None,
) -> dict[str, Any]:
    """Place a new instance of a component definition at an absolute transform."""
    unit = validate_public_unit(unit)
    coordinate_space = validate_coordinate_space(coordinate_space)
    payload: dict[str, Any] = {
        "action": "place_instance",
        "params": {"definition_guid": definition_guid, "matrix": matrix},
        "expect": {
            "active_entity_delta": 1,
            "type": "ComponentInstance",
            "definition_guid": definition_guid,
            "transformation": matrix,
        },
        "unit": unit,
        "coordinate_space": coordinate_space,
    }
    if if_context is not None:
        payload["if_context"] = if_context
    if if_match is not None:
        payload["if_match"] = if_match
    return await _call_bridge("execute_geometry", payload)


@mcp.tool()
async def make_unique(
    persistent_id: int,
    unit: str = DEFAULT_PUBLIC_UNIT,
    coordinate_space: str = DEFAULT_COORDINATE_SPACE,
    if_context: dict[str, str] | None = None,
    if_match: str | None = None,
) -> dict[str, Any]:
    """Make one component instance unique with optional context and entity-state preconditions."""
    unit = validate_public_unit(unit)
    coordinate_space = validate_coordinate_space(coordinate_space)
    payload: dict[str, Any] = {
        "action": "make_unique",
        "params": {"persistent_id": persistent_id},
        "expect": {"active_entity_delta": 0, "type": "ComponentInstance"},
        "unit": unit,
        "coordinate_space": coordinate_space,
    }
    if if_context is not None:
        payload["if_context"] = if_context
    if if_match is not None:
        payload["if_match"] = if_match
    return await _call_bridge("execute_geometry", payload)


@mcp.tool()
async def copy_entity(
    persistent_id: int,
    unit: str = DEFAULT_PUBLIC_UNIT,
    coordinate_space: str = DEFAULT_COORDINATE_SPACE,
    if_context: dict[str, str] | None = None,
    if_match: str | None = None,
) -> dict[str, Any]:
    """Copy one group/component instance sharing its definition or geometry."""
    guards = await _strict_object_guards(persistent_id, unit=unit, coordinate_space=coordinate_space, if_context=if_context, if_match=if_match)
    if guards.get("ok") is False:
        return guards
    return await _call_bridge("execute_geometry", {
        "action": "copy_entity",
        "params": {"persistent_id": persistent_id},
        "expect": {"active_entity_delta": 1, "type": guards["type"]},
        "unit": guards["unit"],
        "coordinate_space": guards["coordinate_space"],
        "if_context": guards["context"],
        "if_match": guards["match"],
    })


@mcp.tool()
async def linear_array(
    persistent_id: int,
    vector: list[float],
    count: int,
    unit: str = DEFAULT_PUBLIC_UNIT,
    coordinate_space: str = DEFAULT_COORDINATE_SPACE,
    if_context: dict[str, str] | None = None,
    if_match: str | None = None,
) -> dict[str, Any]:
    """Duplicate one object into a linear array of count copies in one transaction."""
    if len(vector) != 3:
        raise ValueError("vector must contain exactly 3 numbers")
    guards = await _strict_object_guards(persistent_id, unit=unit, coordinate_space=coordinate_space, if_context=if_context, if_match=if_match)
    if guards.get("ok") is False:
        return guards
    return await _call_bridge("execute_geometry", {
        "action": "linear_array",
        "params": {"persistent_id": persistent_id, "vector": [float(v) for v in vector], "count": count},
        "expect": {"active_entity_delta": count, "type": guards["type"], "count": count},
        "unit": guards["unit"],
        "coordinate_space": guards["coordinate_space"],
        "if_context": guards["context"],
        "if_match": guards["match"],
    })


@mcp.tool()
async def radial_array(
    persistent_id: int,
    axis_origin: list[float],
    axis: list[float],
    degrees: float,
    count: int,
    unit: str = DEFAULT_PUBLIC_UNIT,
    coordinate_space: str = DEFAULT_COORDINATE_SPACE,
    if_context: dict[str, str] | None = None,
    if_match: str | None = None,
) -> dict[str, Any]:
    """Duplicate one object into a radial array of count copies in one transaction."""
    if len(axis_origin) != 3 or len(axis) != 3:
        raise ValueError("axis_origin and axis must contain exactly 3 numbers")
    guards = await _strict_object_guards(persistent_id, unit=unit, coordinate_space=coordinate_space, if_context=if_context, if_match=if_match)
    if guards.get("ok") is False:
        return guards
    return await _call_bridge("execute_geometry", {
        "action": "radial_array",
        "params": {
            "persistent_id": persistent_id,
            "axis_origin": [float(v) for v in axis_origin],
            "axis": [float(v) for v in axis],
            "degrees": float(degrees),
            "count": count,
        },
        "expect": {"active_entity_delta": count, "type": guards["type"], "count": count},
        "unit": guards["unit"],
        "coordinate_space": guards["coordinate_space"],
        "if_context": guards["context"],
        "if_match": guards["match"],
    })


@mcp.tool()
async def mirror_entity(persistent_id:int, plane_point:list[float], plane_normal:list[float], unit:str=DEFAULT_PUBLIC_UNIT, coordinate_space:str=DEFAULT_COORDINATE_SPACE, if_context:dict[str,str]|None=None, if_match:str|None=None)->dict[str,Any]:
    """Mirror relatively through the strict absolute-transform engine."""
    return await _strict_relative_transform(persistent_id,_reflection_matrix(plane_point,plane_normal),unit=unit,coordinate_space=coordinate_space,if_context=if_context,if_match=if_match)

@mcp.tool()
async def create_polyline(
    points: list[list[float]],
    closed: bool = False,
    unit: str = DEFAULT_PUBLIC_UNIT,
    coordinate_space: str = DEFAULT_COORDINATE_SPACE,
    if_context: dict[str, str] | None = None,
) -> dict[str, Any]:
    """Create a strict edge-chain polyline grouped as one object."""
    unit = validate_public_unit(unit)
    coordinate_space = validate_coordinate_space(coordinate_space)
    expect: dict[str, Any] = {"active_entity_delta": 1, "type": "Group"}
    try:
        tuples = [tuple(p) for p in points]
        edges = len(tuples) - 1 + (1 if closed and tuples[0] != tuples[-1] else 0)
        expect["edge_count"] = edges
        expect["vertex_count"] = len(set(tuples))
    except TypeError:
        pass
    payload: dict[str, Any] = {
        "action": "create_polyline",
        "params": {"points": points, "closed": closed},
        "expect": expect,
        "unit": unit,
        "coordinate_space": coordinate_space,
    }
    if if_context is not None:
        payload["if_context"] = if_context
    return await _call_bridge("execute_geometry", payload)


@mcp.tool()
async def create_rectangle(
    origin: list[float],
    width: float,
    height: float,
    normal: list[float],
    unit: str = DEFAULT_PUBLIC_UNIT,
    coordinate_space: str = DEFAULT_COORDINATE_SPACE,
    if_context: dict[str, str] | None = None,
) -> dict[str, Any]:
    """Create a strict rectangle face from origin, dimensions and plane normal."""
    unit = validate_public_unit(unit)
    coordinate_space = validate_coordinate_space(coordinate_space)
    payload: dict[str, Any] = {
        "action": "create_rectangle",
        "params": {"origin": origin, "width": width, "height": height, "normal": normal},
        "expect": {
            "active_entity_delta": 1,
            "type": "Group",
            "edge_count": 4,
            "vertex_count": 4,
        },
        "unit": unit,
        "coordinate_space": coordinate_space,
    }
    if if_context is not None:
        payload["if_context"] = if_context
    return await _call_bridge("execute_geometry", payload)


@mcp.tool()
async def create_circle(
    center: list[float],
    normal: list[float],
    radius: float,
    segments: int,
    unit: str = DEFAULT_PUBLIC_UNIT,
    coordinate_space: str = DEFAULT_COORDINATE_SPACE,
    if_context: dict[str, str] | None = None,
) -> dict[str, Any]:
    """Create a strict circle edge loop grouped as one object."""
    unit = validate_public_unit(unit)
    coordinate_space = validate_coordinate_space(coordinate_space)
    payload: dict[str, Any] = {
        "action": "create_circle",
        "params": {"center": center, "normal": normal, "radius": radius, "segments": segments},
        "expect": {"active_entity_delta": 1, "type": "Group", "edge_count": segments},
        "unit": unit,
        "coordinate_space": coordinate_space,
    }
    if if_context is not None:
        payload["if_context"] = if_context
    return await _call_bridge("execute_geometry", payload)


@mcp.tool()
async def create_arc(
    center: list[float],
    normal: list[float],
    radius: float,
    start_degrees: float,
    end_degrees: float,
    segments: int,
    unit: str = DEFAULT_PUBLIC_UNIT,
    coordinate_space: str = DEFAULT_COORDINATE_SPACE,
    if_context: dict[str, str] | None = None,
) -> dict[str, Any]:
    """Create a strict arc edge chain grouped as one object."""
    unit = validate_public_unit(unit)
    coordinate_space = validate_coordinate_space(coordinate_space)
    payload: dict[str, Any] = {
        "action": "create_arc",
        "params": {
            "center": center,
            "normal": normal,
            "radius": radius,
            "start_degrees": start_degrees,
            "end_degrees": end_degrees,
            "segments": segments,
        },
        "expect": {"active_entity_delta": 1, "type": "Group", "edge_count": segments},
        "unit": unit,
        "coordinate_space": coordinate_space,
    }
    if if_context is not None:
        payload["if_context"] = if_context
    return await _call_bridge("execute_geometry", payload)


@mcp.tool()
async def create_polygon(
    center: list[float],
    normal: list[float],
    radius: float,
    sides: int,
    unit: str = DEFAULT_PUBLIC_UNIT,
    coordinate_space: str = DEFAULT_COORDINATE_SPACE,
    if_context: dict[str, str] | None = None,
) -> dict[str, Any]:
    """Create a strict regular-polygon face from center, normal, radius and side count."""
    unit = validate_public_unit(unit)
    coordinate_space = validate_coordinate_space(coordinate_space)
    payload: dict[str, Any] = {
        "action": "create_polygon",
        "params": {"center": center, "normal": normal, "radius": radius, "sides": sides},
        "expect": {
            "active_entity_delta": 1,
            "type": "Group",
            "edge_count": sides,
            "vertex_count": sides,
        },
        "unit": unit,
        "coordinate_space": coordinate_space,
    }
    if if_context is not None:
        payload["if_context"] = if_context
    return await _call_bridge("execute_geometry", payload)


@mcp.tool()
async def sweep_profile(
    face_pid: int,
    path_pids: list[int],
    unit: str = DEFAULT_PUBLIC_UNIT,
    coordinate_space: str = DEFAULT_COORDINATE_SPACE,
    if_context: dict[str, str] | None = None,
    if_match: dict[str, str] | None = None,
) -> dict[str, Any]:
    """Sweep an isolated profile face along a connected edge path into a manifold group."""
    unit = validate_public_unit(unit)
    coordinate_space = validate_coordinate_space(coordinate_space)
    face_receipt = await _call_bridge(
        "get_entity_state",
        {"persistent_id": face_pid, "unit": unit, "coordinate_space": coordinate_space},
    )
    if face_receipt.get("ok") is False:
        return face_receipt
    face_result = face_receipt.get("result", {})
    if face_result.get("type") != "Face":
        return _error("unsupported_object_type", "Sweep profile must be a Face.", retryable=False)
    face_edge_ids = (face_result.get("hierarchy") or {}).get("edge_persistent_ids")
    if not isinstance(face_edge_ids, list):
        raise ValueError("profile face is too large to sweep exactly")
    full_inputs = [face_pid, *face_edge_ids, *path_pids]
    payload: dict[str, Any] = {
        "action": "sweep_profile",
        "params": {"face_pid": face_pid, "path_pids": path_pids},
        "expect": {
            "active_entity_delta": 1 - len(full_inputs),
            "type": "Group",
            "manifold": True,
        },
        "unit": unit,
        "coordinate_space": coordinate_space,
    }
    if if_context is not None:
        payload["if_context"] = if_context
    if if_match is not None:
        payload["if_match"] = if_match
    return await _call_bridge("execute_geometry", payload)


@mcp.tool()
async def measure_distance(
    first_pid: int,
    second_pid: int,
    unit: str = DEFAULT_PUBLIC_UNIT,
) -> dict[str, Any]:
    """Measure center distance and bounds gap between two entities."""
    unit = validate_public_unit(unit)
    return await _call_bridge(
        "measure_distance", {"first_pid": first_pid, "second_pid": second_pid, "unit": unit}
    )


@mcp.tool()
async def query_topology(
    persistent_id: int,
    unit: str = DEFAULT_PUBLIC_UNIT,
) -> dict[str, Any]:
    """Return bounded connectivity and loop facts for one entity."""
    unit = validate_public_unit(unit)
    return await _call_bridge("query_topology", {"persistent_id": persistent_id, "unit": unit})


@mcp.tool()
async def query_overlap(
    first_pid: int,
    second_pid: int,
    unit: str = DEFAULT_PUBLIC_UNIT,
) -> dict[str, Any]:
    """Report bounding-box overlap between two entities."""
    unit = validate_public_unit(unit)
    return await _call_bridge(
        "query_overlap", {"first_pid": first_pid, "second_pid": second_pid, "unit": unit}
    )


@mcp.tool()
async def asset_list(
    unit: str = DEFAULT_PUBLIC_UNIT,
) -> dict[str, Any]:
    """List owner-curated component assets available for strict placement."""
    unit = validate_public_unit(unit)
    return await _call_bridge("asset_list", {"unit": unit})


@mcp.tool()
async def place_asset(
    asset_key: str,
    matrix: list[float],
    unit: str = DEFAULT_PUBLIC_UNIT,
    coordinate_space: str = DEFAULT_COORDINATE_SPACE,
    if_context: dict[str, str] | None = None,
) -> dict[str, Any]:
    """Place a new instance of a registry asset at an absolute transform."""
    unit = validate_public_unit(unit)
    coordinate_space = validate_coordinate_space(coordinate_space)
    registry = await _call_bridge("asset_list", {"unit": unit})
    if registry.get("ok") is False:
        return registry
    assets = registry.get("assets", [])
    match = next((row for row in assets if row.get("asset_key") == asset_key), None)
    if match is None:
        return _error("asset_not_found", "Component asset was not found.", retryable=False)
    payload: dict[str, Any] = {
        "action": "place_asset",
        "params": {"asset_key": asset_key, "matrix": matrix},
        "expect": {
            "active_entity_delta": 1,
            "type": "ComponentInstance",
            "transformation": matrix,
        },
        "unit": unit,
        "coordinate_space": coordinate_space,
    }
    if if_context is not None:
        payload["if_context"] = if_context
    return await _call_bridge("execute_geometry", payload)


@mcp.tool()
async def texture_list(
    unit: str = DEFAULT_PUBLIC_UNIT,
) -> dict[str, Any]:
    """List owner-curated texture assets available for material use."""
    unit = validate_public_unit(unit)
    return await _call_bridge("texture_list", {"unit": unit})


@mcp.tool()
async def material_apply_texture(
    material: str,
    texture_key: str,
    width: float,
    height: float,
    unit: str = DEFAULT_PUBLIC_UNIT,
    coordinate_space: str = DEFAULT_COORDINATE_SPACE,
    if_context: dict[str, str] | None = None,
) -> dict[str, Any]:
    """Apply a registry texture to a material at an explicit real-world size."""
    unit = validate_public_unit(unit)
    coordinate_space = validate_coordinate_space(coordinate_space)
    payload: dict[str, Any] = {
        "action": "material_apply_texture",
        "params": {"material": material, "texture_key": texture_key, "width": width, "height": height},
        "expect": {"active_entity_delta": 0, "material": material},
        "unit": unit,
        "coordinate_space": coordinate_space,
    }
    if if_context is not None:
        payload["if_context"] = if_context
    return await _call_bridge("execute_geometry", payload)


@mcp.tool()
async def material_info(
    material: str,
    unit: str = DEFAULT_PUBLIC_UNIT,
) -> dict[str, Any]:
    """Return one material state with texture facts by name."""
    unit = validate_public_unit(unit)
    return await _call_bridge("material_info", {"material": material, "unit": unit})


@mcp.tool()
async def camera_get(
    unit: str = DEFAULT_PUBLIC_UNIT,
) -> dict[str, Any]:
    """Return the active view camera state in an explicit length unit."""
    unit = validate_public_unit(unit)
    return await _call_bridge("camera_get", {"unit": unit})


@mcp.tool()
async def camera_set(
    eye: list[float],
    target: list[float],
    up: list[float] | None = None,
    fov: float | None = None,
    unit: str = DEFAULT_PUBLIC_UNIT,
    coordinate_space: str = DEFAULT_COORDINATE_SPACE,
    if_context: dict[str, str] | None = None,
    if_match: str | None = None,
) -> dict[str, Any]:
    """Set the active view camera with optional stale-view guards."""
    unit = validate_public_unit(unit)
    coordinate_space = validate_coordinate_space(coordinate_space)
    if up is None or fov is None:
        current = await _call_bridge("camera_get", {"unit": unit})
        if current.get("ok") is False:
            return current
        if up is None:
            up = current.get("camera_up", [0.0, 1.0, 0.0])
        if fov is None:
            fov = current.get("camera_fov", 35.0)
    payload: dict[str, Any] = {
        "action": "camera_set",
        "params": {"eye": eye, "target": target, "up": up, "fov": fov},
        "expect": {"active_entity_delta": 0, "camera_fov": fov},
        "unit": unit,
        "coordinate_space": coordinate_space,
    }
    if if_context is not None:
        payload["if_context"] = if_context
    if if_match is not None:
        payload["if_match"] = if_match
    return await _call_bridge("execute_geometry", payload)


@mcp.tool()
async def scene_list(
    unit: str = DEFAULT_PUBLIC_UNIT,
) -> dict[str, Any]:
    """List model scenes by name."""
    unit = validate_public_unit(unit)
    return await _call_bridge("scene_list", {"unit": unit})


@mcp.tool()
async def scene_create(
    name: str,
    unit: str = DEFAULT_PUBLIC_UNIT,
    coordinate_space: str = DEFAULT_COORDINATE_SPACE,
    if_context: dict[str, str] | None = None,
) -> dict[str, Any]:
    """Create one model scene with an exact name."""
    unit = validate_public_unit(unit)
    coordinate_space = validate_coordinate_space(coordinate_space)
    payload: dict[str, Any] = {
        "action": "scene_create",
        "params": {"name": name},
        "expect": {"active_entity_delta": 0, "scene_name": name},
        "unit": unit,
        "coordinate_space": coordinate_space,
    }
    if if_context is not None:
        payload["if_context"] = if_context
    return await _call_bridge("execute_geometry", payload)


@mcp.tool()
async def model_save() -> dict[str, Any]:
    """Save the active model to its current path."""
    return await _call_bridge("model_save", {})


@mcp.tool()
async def model_save_as(file: str, overwrite: bool = False) -> dict[str, Any]:
    """Save the active model under a rooted file name with explicit overwrite."""
    return await _call_bridge("model_save_as", {"file": file, "overwrite": overwrite})


@mcp.tool()
async def model_open(file: str, if_model_guid: str | None = None) -> dict[str, Any]:
    """Open a rooted model file, optionally guarded by the current model GUID."""
    params: dict[str, Any] = {"file": file}
    if if_model_guid is not None:
        params["if_model_guid"] = if_model_guid
    return await _call_bridge("model_open", params)


@mcp.tool()
async def model_export(
    file: str,
    format: str,
    overwrite: bool = False,
    width: int | None = None,
    height: int | None = None,
) -> dict[str, Any]:
    """Export the active model to a rooted file in a supported format."""
    params: dict[str, Any] = {"file": file, "format": format, "overwrite": overwrite}
    if width is not None:
        params["width"] = width
    if height is not None:
        params["height"] = height
    return await _call_bridge("model_export", params)


@mcp.tool()
async def model_list() -> dict[str, Any]:
    """List saved models in the rooted models directory."""
    return await _call_bridge("model_list", {})


@mcp.tool()
async def integrity_report(
    unit: str = DEFAULT_PUBLIC_UNIT,
) -> dict[str, Any]:
    """Report generic CAD integrity facts without discipline conclusions."""
    unit = validate_public_unit(unit)
    return await _call_bridge("integrity_report", {"unit": unit})


@mcp.tool()
async def repair_reverse_face(
    persistent_id: int,
    unit: str = DEFAULT_PUBLIC_UNIT,
    coordinate_space: str = DEFAULT_COORDINATE_SPACE,
    if_context: dict[str, str] | None = None,
    if_match: str | None = None,
) -> dict[str, Any]:
    """Strictly reverse one face with stale-state guards."""
    guards = await _strict_object_guards(
        persistent_id, unit=unit, coordinate_space=coordinate_space,
        if_context=if_context, if_match=if_match,
        allowed=("Face",), kind="Face repair",
    )
    if guards.get("ok") is False:
        return guards
    return await _call_bridge("execute_geometry", {
        "action": "repair_reverse_face",
        "params": {"persistent_id": persistent_id},
        "expect": {"active_entity_delta": 0, "type": "Face"},
        "unit": guards["unit"],
        "coordinate_space": guards["coordinate_space"],
        "if_context": guards["context"],
        "if_match": guards["match"],
    })


@mcp.tool()
async def repair_erase_degenerate(
    persistent_id: int,
    unit: str = DEFAULT_PUBLIC_UNIT,
    coordinate_space: str = DEFAULT_COORDINATE_SPACE,
    if_context: dict[str, str] | None = None,
    if_match: str | None = None,
) -> dict[str, Any]:
    """Strictly erase one degenerate edge with stale-state guards."""
    guards = await _strict_object_guards(
        persistent_id, unit=unit, coordinate_space=coordinate_space,
        if_context=if_context, if_match=if_match,
        allowed=("Edge",), kind="Degenerate repair",
    )
    if guards.get("ok") is False:
        return guards
    return await _call_bridge("execute_geometry", {
        "action": "repair_erase_degenerate",
        "params": {"persistent_id": persistent_id},
        "expect": {"active_entity_delta": -1, "deleted": True},
        "unit": guards["unit"],
        "coordinate_space": guards["coordinate_space"],
        "if_context": guards["context"],
        "if_match": guards["match"],
    })


@mcp.tool()
async def definition_info(
    definition_guid: str,
    unit: str = DEFAULT_PUBLIC_UNIT,
) -> dict[str, Any]:
    """Return one component definition state by GUID in an explicit public length unit."""
    unit = validate_public_unit(unit)
    return await _call_bridge("definition_info", {"definition_guid": definition_guid, "unit": unit})


@mcp.tool()
async def create_edge(start: list[float], end: list[float]) -> dict[str, Any]:
    """Create one edge in the active edit context using internal-inch coordinates."""
    return await _call_bridge("create_edge", {"start": start, "end": end})


@mcp.tool()
async def create_face(points: list[list[float]]) -> dict[str, Any]:
    """Create one face in the active edit context from 3D points."""
    return await _call_bridge("create_face", {"points": points})


@mcp.tool()
async def create_group(persistent_ids: list[int], name: str | None = None) -> dict[str, Any]:
    """Deprecated compatibility alias for strict group_entities using internal-inch units."""
    params: dict[str, Any] = {"persistent_ids": persistent_ids}
    if name is not None:
        params["name"] = name
    return await _call_bridge(
        "execute_geometry",
        {
            "action": "group_entities",
            "params": params,
            "expect": {
                "active_entity_delta": 1 - len(persistent_ids),
                "type": "Group",
                "child_persistent_ids": persistent_ids,
            },
            "unit": "in",
            "coordinate_space": DEFAULT_COORDINATE_SPACE,
        },
    )


@mcp.tool()
async def selection_by_ids(persistent_ids: list[int], replace: bool = True) -> dict[str, Any]:
    """Select bounded active-context entities by persistent ID."""
    return await _call_bridge(
        "selection_by_ids",
        {"persistent_ids": persistent_ids, "replace": replace},
    )


@mcp.tool()
async def selection_clear() -> dict[str, Any]:
    """Clear the active SketchUp selection."""
    return await _call_bridge("selection_clear")


@mcp.tool()
async def object_delete(persistent_id: int) -> dict[str, Any]:
    """Delete one entity from the active edit context."""
    return await _call_bridge("object_delete", {"persistent_id": persistent_id})


@mcp.tool()
async def object_move(persistent_id:int, vector:list[float])->dict[str,Any]:
    """Deprecated alias for strict move_entity using internal inches."""
    return await _strict_relative_transform(persistent_id,_translation_matrix(vector),unit="in",coordinate_space=DEFAULT_COORDINATE_SPACE,if_context=None,if_match=None)

@mcp.tool()
async def object_rotate(persistent_id:int, axis_origin:list[float], axis:list[float], degrees:float)->dict[str,Any]:
    """Deprecated alias for strict rotate_entity using internal inches."""
    return await _strict_relative_transform(persistent_id,_rotation_matrix(axis_origin,axis,degrees),unit="in",coordinate_space=DEFAULT_COORDINATE_SPACE,if_context=None,if_match=None)

@mcp.tool()
async def object_scale(persistent_id:int, factors:list[float], origin:list[float]|None=None)->dict[str,Any]:
    """Deprecated alias for strict scale_entity using internal inches."""

    def build_delta(state:dict[str,Any])->list[float]:
        chosen=origin if origin is not None else state.get("bounds",{}).get("center")
        if not isinstance(chosen,list): raise ValueError("scale origin is unavailable")
        return _scale_matrix(chosen,factors)
    return await _strict_relative_transform(persistent_id,build_delta,unit="in",coordinate_space=DEFAULT_COORDINATE_SPACE,if_context=None,if_match=None)


@mcp.tool()
async def push_pull_face(persistent_id: int, distance: float) -> dict[str, Any]:
    """Push/pull one active-context face by an internal-inch distance."""
    return await _call_bridge(
        "push_pull_face",
        {"persistent_id": persistent_id, "distance": distance},
    )


@mcp.tool()
async def component_create_box(
    name: str,
    dimensions: list[float],
    origin: list[float] | None = None,
) -> dict[str, Any]:
    """Create a box component definition and one instance in the active context."""
    return await _call_bridge(
        "component_create_box",
        {
            "name": name,
            "dimensions": dimensions,
            "origin": origin or [0.0, 0.0, 0.0],
        },
    )


@mcp.tool()
async def tag_create(name: str) -> dict[str, Any]:
    """Create or return one SketchUp tag by name."""
    return await _call_bridge("tag_create", {"name": name})


@mcp.tool()
async def tag_assign(
    persistent_id: int,
    tag: str,
    unit: str = DEFAULT_PUBLIC_UNIT,
    coordinate_space: str = DEFAULT_COORDINATE_SPACE,
    if_context: dict[str, str] | None = None,
    if_match: str | None = None,
) -> dict[str, Any]:
    """Strictly assign one object to an existing tag with stale-write guards."""
    guards = await _strict_object_guards(persistent_id, unit=unit, coordinate_space=coordinate_space, if_context=if_context, if_match=if_match, kind="Tag assignment")
    if guards.get("ok") is False:
        return guards
    return await _call_bridge("execute_geometry", {
        "action": "tag_assign",
        "params": {"persistent_id": persistent_id, "tag": tag},
        "expect": {"active_entity_delta": 0, "type": guards["type"], "tag": tag},
        "unit": guards["unit"],
        "coordinate_space": guards["coordinate_space"],
        "if_context": guards["context"],
        "if_match": guards["match"],
    })


@mcp.tool()
async def material_create(name: str, color: list[int] | None = None) -> dict[str, Any]:
    """Create or update one SketchUp material with an optional RGB color."""
    params: dict[str, Any] = {"name": name}
    if color is not None:
        params["color"] = color
    return await _call_bridge("material_create", params)


@mcp.tool()
async def material_assign(
    persistent_id: int,
    material: str,
    side: str = "both",
    unit: str = DEFAULT_PUBLIC_UNIT,
    coordinate_space: str = DEFAULT_COORDINATE_SPACE,
    if_context: dict[str, str] | None = None,
    if_match: str | None = None,
) -> dict[str, Any]:
    """Strictly assign an existing material; faces support front/back/both side semantics."""
    guards = await _strict_object_guards(persistent_id, unit=unit, coordinate_space=coordinate_space, if_context=if_context, if_match=if_match, allowed=("Group", "ComponentInstance", "Face"), kind="Material assignment")
    if guards.get("ok") is False:
        return guards
    return await _call_bridge("execute_geometry", {
        "action": "material_assign",
        "params": {"persistent_id": persistent_id, "material": material, "side": side},
        "expect": {"active_entity_delta": 0, "type": guards["type"], "material": material},
        "unit": guards["unit"],
        "coordinate_space": guards["coordinate_space"],
        "if_context": guards["context"],
        "if_match": guards["match"],
    })


class BearerAuthMiddleware:
    """Small ASGI bearer gate for deployments that expose MCP beyond loopback."""

    def __init__(self, app: Callable[..., Awaitable[Any]], token: str) -> None:
        self._app = app
        self._token = token

    async def __call__(
        self,
        scope: dict[str, Any],
        receive: Callable[..., Awaitable[Any]],
        send: Callable[..., Awaitable[Any]],
    ) -> None:
        if scope["type"] != "http":
            await self._app(scope, receive, send)
            return

        supplied = self._bearer_token(scope.get("headers", []))
        if supplied is None or not hmac.compare_digest(supplied, self._token):
            await send(
                {
                    "type": "http.response.start",
                    "status": 401,
                    "headers": [
                        (b"content-type", b"application/json"),
                        (b"www-authenticate", b"Bearer"),
                    ],
                }
            )
            await send(
                {
                    "type": "http.response.body",
                    "body": b'{"error":"unauthorized"}',
                }
            )
            return
        await self._app(scope, receive, send)

    @staticmethod
    def _bearer_token(headers: list[tuple[bytes, bytes]]) -> str | None:
        for raw_name, raw_value in headers:
            if raw_name.lower() != b"authorization":
                continue
            try:
                value = raw_value.decode("ascii")
            except UnicodeDecodeError:
                return None
            scheme, separator, credential = value.partition(" ")
            if separator and scheme.lower() == "bearer" and credential:
                return credential
            return None
        return None


def _csv_env(name: str) -> list[str]:
    value = os.environ.get(name, "")
    return [item.strip() for item in value.split(",") if item.strip()]


def create_app() -> Any:
    """Create the ASGI app with fail-closed network exposure controls."""
    host = os.environ.get("CDT_SKETCHUP_MCP_HOST", DEFAULT_MCP_HOST).strip()
    token = os.environ.get("CDT_SKETCHUP_MCP_TOKEN", "")
    allowed_hosts = _csv_env("CDT_SKETCHUP_ALLOWED_HOSTS")
    allowed_origins = _csv_env("CDT_SKETCHUP_ALLOWED_ORIGINS")

    security: TransportSecuritySettings | None = None
    if token and len(token) < 32:
        raise RuntimeError("CDT_SKETCHUP_MCP_TOKEN must be at least 32 characters")
    if host not in LOOPBACK_HOSTS:
        if len(token) < 32:
            raise RuntimeError(
                "CDT_SKETCHUP_MCP_TOKEN (>=32 chars) is required for non-loopback bind"
            )
        if not allowed_hosts:
            raise RuntimeError(
                "CDT_SKETCHUP_ALLOWED_HOSTS is required for non-loopback bind"
            )
        security = TransportSecuritySettings(
            allowed_hosts=allowed_hosts,
            allowed_origins=allowed_origins,
        )

    app = mcp.streamable_http_app(
        host=host,
        json_response=True,
        transport_security=security,
    )
    if token:
        app = BearerAuthMiddleware(app, token)
    return app


def main() -> None:
    """Run the local Streamable HTTP provider."""
    import uvicorn

    host = os.environ.get("CDT_SKETCHUP_MCP_HOST", DEFAULT_MCP_HOST).strip()
    try:
        port = int(os.environ.get("CDT_SKETCHUP_MCP_PORT", str(DEFAULT_MCP_PORT)))
    except ValueError as exc:
        raise RuntimeError("CDT_SKETCHUP_MCP_PORT must be an integer") from exc
    if not (1 <= port <= 65535):
        raise RuntimeError("CDT_SKETCHUP_MCP_PORT must be 1..65535")

    uvicorn.run(create_app(), host=host, port=port, log_level="info")


if __name__ == "__main__":
    main()
