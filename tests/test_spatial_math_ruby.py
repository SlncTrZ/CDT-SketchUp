"""Spatial math regression tests — execute the Ruby classifier without SketchUp.
Wing: code | Topic: sketchup_spatial | Updated: 2026-09-17 11:45
"""

from __future__ import annotations

import json
from pathlib import Path
import shutil
import subprocess
import textwrap
import unittest


REPO = Path(__file__).resolve().parents[1]
LIMITS = REPO / "extension" / "cdt_sketchup" / "kernel" / "limits.rb"
SPATIAL = REPO / "extension" / "cdt_sketchup" / "queries" / "spatial.rb"


class SpatialMathRubyTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.ruby = shutil.which("ruby")
        if cls.ruby is None:
            raise unittest.SkipTest("standalone Ruby is unavailable")

    def test_solid_relation_matrix_distinguishes_coincident_volume_from_touching(self) -> None:
        script = textwrap.dedent(
            f"""
            require "json"
            load {json.dumps(LIMITS.as_posix())}
            load {json.dumps(SPATIAL.as_posix())}

            server = CDTSketchUp::BridgeServer.allocate
            faces = [
              [0,2,1],[0,3,2],[4,5,6],[4,6,7],
              [0,1,5],[0,5,4],[1,2,6],[1,6,5],
              [2,3,7],[2,7,6],[3,0,4],[3,4,7]
            ]

            def cube_triangles(faces, origin, size)
              ox, oy, oz = origin
              vertices = [
                [ox,oy,oz],[ox+size,oy,oz],[ox+size,oy+size,oz],[ox,oy+size,oz],
                [ox,oy,oz+size],[ox+size,oy,oz+size],[ox+size,oy+size,oz+size],[ox,oy+size,oz+size]
              ]
              faces.map {{ |triangle| triangle.map {{ |index| vertices[index] }} }}
            end

            def rotate_z(triangles, center, degrees)
              cx, cy = center
              radians = degrees * Math::PI / 180.0
              cos = Math.cos(radians)
              sin = Math.sin(radians)
              triangles.map do |triangle|
                triangle.map do |point|
                  x = point[0] - cx
                  y = point[1] - cy
                  [cx + x * cos - y * sin, cy + x * sin + y * cos, point[2]]
                end
              end
            end

            def relation(server, first, second)
              distance_sq, proper_crossing, = server.send(:spatial_surface_metrics, first, second)
              first_inside_second = server.send(:spatial_mesh_has_inside_sample?, first, second)
              second_inside_first = server.send(:spatial_mesh_has_inside_sample?, second, first)
              penetrating = proper_crossing || first_inside_second || second_inside_first
              if !penetrating && Math.sqrt(distance_sq) <= CDTSketchUp::BridgeServer::SPATIAL_EPSILON &&
                 server.respond_to?(:spatial_mesh_has_shared_interior_probe?, true)
                penetrating =
                  server.send(:spatial_mesh_has_shared_interior_probe?, first, second) ||
                  server.send(:spatial_mesh_has_shared_interior_probe?, second, first)
              end
              touching = Math.sqrt(distance_sq) <= CDTSketchUp::BridgeServer::SPATIAL_EPSILON && !penetrating
              penetrating ? "penetrating" : (touching ? "touching" : "disjoint")
            end

            cases = {{
              identical: [cube_triangles(faces,[0.0,0.0,0.0],1.0), cube_triangles(faces,[0.0,0.0,0.0],1.0)],
              face_touch: [cube_triangles(faces,[0.0,0.0,0.0],1.0), cube_triangles(faces,[1.0,0.0,0.0],1.0)],
              partial_overlap: [cube_triangles(faces,[0.0,0.0,0.0],1.0), cube_triangles(faces,[0.5,0.0,0.0],1.0)],
              containment: [cube_triangles(faces,[0.0,0.0,0.0],2.0), cube_triangles(faces,[0.5,0.5,0.5],0.5)],
              disjoint: [cube_triangles(faces,[0.0,0.0,0.0],1.0), cube_triangles(faces,[2.0,0.0,0.0],1.0)],
              edge_touch: [cube_triangles(faces,[0.0,0.0,0.0],1.0), cube_triangles(faces,[1.0,1.0,0.0],1.0)],
              point_touch: [cube_triangles(faces,[0.0,0.0,0.0],1.0), cube_triangles(faces,[1.0,1.0,1.0],1.0)],
              rotated_overlap: [
                cube_triangles(faces,[0.0,0.0,0.0],1.0),
                rotate_z(cube_triangles(faces,[0.0,0.0,0.0],1.0), [0.5,0.5,0.5], 30.0)
              ]
            }}
            puts JSON.generate(cases.transform_values {{ |pair| relation(server, pair[0], pair[1]) }})
            """
        )
        completed = subprocess.run(
            [self.ruby, "-e", script],
            cwd=REPO,
            capture_output=True,
            text=True,
            timeout=30,
            check=False,
        )
        self.assertEqual(completed.returncode, 0, completed.stderr)
        actual = json.loads(completed.stdout)
        self.assertEqual(
            actual,
            {
                "identical": "penetrating",
                "face_touch": "touching",
                "partial_overlap": "penetrating",
                "containment": "penetrating",
                "disjoint": "disjoint",
                "edge_touch": "touching",
                "point_touch": "touching",
                "rotated_overlap": "penetrating",
            },
        )


if __name__ == "__main__":
    unittest.main()
