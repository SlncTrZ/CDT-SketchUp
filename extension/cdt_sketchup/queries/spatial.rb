# cdt_sketchup/queries/spatial.rb — bounded exact solid relation and surface clearance
# Wing: code | Topic: sketchup_bridge | Updated: 2026-09-17

module CDTSketchUp
  class BridgeServer
    private

    SPATIAL_EPSILON = 1e-7
    SPATIAL_EPSILON_SQ = SPATIAL_EPSILON * SPATIAL_EPSILON
    # Must clear the surface epsilon while remaining tiny relative to normal CAD features.
    SPATIAL_INTERIOR_PROBE_OFFSET = SPATIAL_EPSILON * 32.0
    SPATIAL_RAY_DIRECTIONS = [
      [1.0, 0.371, 0.529],
      [0.293, 1.0, 0.617],
      [0.413, 0.257, 1.0]
    ].freeze

    def require_spatial_solid(model, persistent_id)
      entity = require_active_entity(model, persistent_id)
      unless entity.is_a?(Sketchup::Group) || entity.is_a?(Sketchup::ComponentInstance)
        raise BridgeError.new(
          "unsupported_object_type",
          "Exact spatial queries require a Group or ComponentInstance"
        )
      end
      unless semantic_manifold(entity) == true
        raise BridgeError.new(
          "non_manifold_operand",
          "Exact spatial queries require manifold solids"
        )
      end
      entity
    end

    def spatial_child_entities(entity)
      if entity.is_a?(Sketchup::Group)
        entity.entities
      elsif entity.is_a?(Sketchup::ComponentInstance)
        entity.definition.entities
      end
    end

    def spatial_entity_triangles(entity)
      triangles = []
      entities = spatial_child_entities(entity)
      unless entities
        raise BridgeError.new("unsupported_object_type", "Exact spatial query target has no solid entities")
      end
      spatial_collect_triangles(entities, entity.transformation, 1, triangles)
      if triangles.empty?
        raise BridgeError.new("invalid_geometry", "Exact spatial query target contains no triangulated faces")
      end
      triangles
    end

    def spatial_collect_triangles(entities, transformation, depth, triangles)
      if depth > MAX_SPATIAL_NESTING
        raise BridgeError.new("spatial_query_too_large", "Exact spatial nesting exceeds the bounded depth")
      end
      entities.each do |entity|
        case entity
        when Sketchup::Face
          mesh = entity.mesh(0)
          mesh.polygons.each do |polygon|
            points = polygon.map do |index|
              point = mesh.point_at(index.abs)
              point_to_triplet(point.transform(transformation))
            end
            next if points.length < 3
            (1...(points.length - 1)).each do |offset|
              triangles << [points[0], points[offset], points[offset + 1]]
              if triangles.length > MAX_SPATIAL_TRIANGLES
                raise BridgeError.new(
                  "spatial_query_too_large",
                  "Exact spatial triangulation exceeds the bounded triangle budget"
                )
              end
            end
          end
        when Sketchup::Group
          spatial_collect_triangles(
            entity.entities,
            transformation * entity.transformation,
            depth + 1,
            triangles
          )
        when Sketchup::ComponentInstance
          spatial_collect_triangles(
            entity.definition.entities,
            transformation * entity.transformation,
            depth + 1,
            triangles
          )
        end
      end
      triangles
    end

    def spatial_subtract(left, right)
      [left[0] - right[0], left[1] - right[1], left[2] - right[2]]
    end

    def spatial_add(left, right)
      [left[0] + right[0], left[1] + right[1], left[2] + right[2]]
    end

    def spatial_scale(vector, factor)
      [vector[0] * factor, vector[1] * factor, vector[2] * factor]
    end

    def spatial_dot(left, right)
      left[0] * right[0] + left[1] * right[1] + left[2] * right[2]
    end

    def spatial_cross(left, right)
      [
        left[1] * right[2] - left[2] * right[1],
        left[2] * right[0] - left[0] * right[2],
        left[0] * right[1] - left[1] * right[0]
      ]
    end

    def spatial_length_sq(vector)
      spatial_dot(vector, vector)
    end

    def spatial_distance_sq(left, right)
      spatial_length_sq(spatial_subtract(left, right))
    end

    def spatial_point_segment_distance_sq(point, start_point, end_point)
      segment = spatial_subtract(end_point, start_point)
      denominator = spatial_length_sq(segment)
      return spatial_distance_sq(point, start_point) if denominator <= SPATIAL_EPSILON_SQ

      t = spatial_dot(spatial_subtract(point, start_point), segment) / denominator
      t = [[t, 0.0].max, 1.0].min
      projection = spatial_add(start_point, spatial_scale(segment, t))
      spatial_distance_sq(point, projection)
    end

    def spatial_segment_segment_distance_sq(p1, q1, p2, q2)
      d1 = spatial_subtract(q1, p1)
      d2 = spatial_subtract(q2, p2)
      r = spatial_subtract(p1, p2)
      a = spatial_dot(d1, d1)
      e = spatial_dot(d2, d2)
      f = spatial_dot(d2, r)

      if a <= SPATIAL_EPSILON_SQ && e <= SPATIAL_EPSILON_SQ
        return spatial_distance_sq(p1, p2)
      end

      if a <= SPATIAL_EPSILON_SQ
        s = 0.0
        t = [[f / e, 0.0].max, 1.0].min
      else
        c = spatial_dot(d1, r)
        if e <= SPATIAL_EPSILON_SQ
          t = 0.0
          s = [[-c / a, 0.0].max, 1.0].min
        else
          b = spatial_dot(d1, d2)
          denominator = a * e - b * b
          s = denominator.abs > SPATIAL_EPSILON_SQ ? [[(b * f - c * e) / denominator, 0.0].max, 1.0].min : 0.0
          t = (b * s + f) / e
          if t < 0.0
            t = 0.0
            s = [[-c / a, 0.0].max, 1.0].min
          elsif t > 1.0
            t = 1.0
            s = [[(b - c) / a, 0.0].max, 1.0].min
          end
        end
      end

      first = spatial_add(p1, spatial_scale(d1, s))
      second = spatial_add(p2, spatial_scale(d2, t))
      spatial_distance_sq(first, second)
    end

    def spatial_point_triangle_distance_sq(point, a, b, c)
      ab = spatial_subtract(b, a)
      ac = spatial_subtract(c, a)
      ap = spatial_subtract(point, a)
      d1 = spatial_dot(ab, ap)
      d2 = spatial_dot(ac, ap)
      return spatial_length_sq(ap) if d1 <= 0.0 && d2 <= 0.0

      bp = spatial_subtract(point, b)
      d3 = spatial_dot(ab, bp)
      d4 = spatial_dot(ac, bp)
      return spatial_length_sq(bp) if d3 >= 0.0 && d4 <= d3

      vc = d1 * d4 - d3 * d2
      if vc <= 0.0 && d1 >= 0.0 && d3 <= 0.0
        v = d1 / (d1 - d3)
        projection = spatial_add(a, spatial_scale(ab, v))
        return spatial_distance_sq(point, projection)
      end

      cp = spatial_subtract(point, c)
      d5 = spatial_dot(ab, cp)
      d6 = spatial_dot(ac, cp)
      return spatial_length_sq(cp) if d6 >= 0.0 && d5 <= d6

      vb = d5 * d2 - d1 * d6
      if vb <= 0.0 && d2 >= 0.0 && d6 <= 0.0
        w = d2 / (d2 - d6)
        projection = spatial_add(a, spatial_scale(ac, w))
        return spatial_distance_sq(point, projection)
      end

      va = d3 * d6 - d5 * d4
      if va <= 0.0 && (d4 - d3) >= 0.0 && (d5 - d6) >= 0.0
        edge = spatial_subtract(c, b)
        w = (d4 - d3) / ((d4 - d3) + (d5 - d6))
        projection = spatial_add(b, spatial_scale(edge, w))
        return spatial_distance_sq(point, projection)
      end

      denominator = va + vb + vc
      if denominator.abs <= SPATIAL_EPSILON_SQ
        return [
          spatial_point_segment_distance_sq(point, a, b),
          spatial_point_segment_distance_sq(point, b, c),
          spatial_point_segment_distance_sq(point, c, a)
        ].min
      end
      inverse = 1.0 / denominator
      v = vb * inverse
      w = vc * inverse
      projection = spatial_add(a, spatial_add(spatial_scale(ab, v), spatial_scale(ac, w)))
      spatial_distance_sq(point, projection)
    end

    def spatial_segment_triangle_hit(start_point, end_point, triangle, proper: false)
      a, b, c = triangle
      direction = spatial_subtract(end_point, start_point)
      edge1 = spatial_subtract(b, a)
      edge2 = spatial_subtract(c, a)
      h = spatial_cross(direction, edge2)
      determinant = spatial_dot(edge1, h)
      return false if determinant.abs <= SPATIAL_EPSILON

      inverse = 1.0 / determinant
      s = spatial_subtract(start_point, a)
      u = inverse * spatial_dot(s, h)
      q = spatial_cross(s, edge1)
      v = inverse * spatial_dot(direction, q)
      t = inverse * spatial_dot(edge2, q)
      if proper
        return t > SPATIAL_EPSILON && t < 1.0 - SPATIAL_EPSILON &&
          u > SPATIAL_EPSILON && v > SPATIAL_EPSILON &&
          u + v < 1.0 - SPATIAL_EPSILON
      end
      t >= -SPATIAL_EPSILON && t <= 1.0 + SPATIAL_EPSILON &&
        u >= -SPATIAL_EPSILON && v >= -SPATIAL_EPSILON &&
        u + v <= 1.0 + SPATIAL_EPSILON
    end

    def spatial_triangle_pair_metrics(first, second)
      first_edges = [[first[0], first[1]], [first[1], first[2]], [first[2], first[0]]]
      second_edges = [[second[0], second[1]], [second[1], second[2]], [second[2], second[0]]]
      proper = first_edges.any? { |edge| spatial_segment_triangle_hit(edge[0], edge[1], second, proper: true) } ||
        second_edges.any? { |edge| spatial_segment_triangle_hit(edge[0], edge[1], first, proper: true) }
      return [0.0, true] if proper

      candidates = []
      first.each { |point| candidates << spatial_point_triangle_distance_sq(point, *second) }
      second.each { |point| candidates << spatial_point_triangle_distance_sq(point, *first) }
      first_edges.each do |first_edge|
        second_edges.each do |second_edge|
          candidates << spatial_segment_segment_distance_sq(
            first_edge[0], first_edge[1], second_edge[0], second_edge[1]
          )
        end
      end
      [candidates.min, false]
    end

    def spatial_triangle_bounds(triangle)
      [
        3.times.map { |index| triangle.map { |point| point[index] }.min },
        3.times.map { |index| triangle.map { |point| point[index] }.max }
      ]
    end

    def spatial_bounds_gap_sq(first_bounds, second_bounds)
      gaps = 3.times.map do |index|
        [
          first_bounds[0][index] - second_bounds[1][index],
          second_bounds[0][index] - first_bounds[1][index],
          0.0
        ].max
      end
      spatial_dot(gaps, gaps)
    end

    def spatial_surface_metrics(first_triangles, second_triangles)
      if first_triangles.length * second_triangles.length > MAX_SPATIAL_PAIR_TESTS
        raise BridgeError.new(
          "spatial_query_too_large",
          "Exact spatial triangle-pair budget would be exceeded"
        )
      end
      first_bounds = first_triangles.map { |triangle| spatial_triangle_bounds(triangle) }
      second_bounds = second_triangles.map { |triangle| spatial_triangle_bounds(triangle) }
      best = Float::INFINITY
      proper_crossing = false
      pair_tests = 0

      first_triangles.each_with_index do |first, first_index|
        second_triangles.each_with_index do |second, second_index|
          lower_bound = spatial_bounds_gap_sq(first_bounds[first_index], second_bounds[second_index])
          next if lower_bound > best

          pair_tests += 1
          distance_sq, proper = spatial_triangle_pair_metrics(first, second)
          proper_crossing ||= proper
          best = distance_sq if distance_sq < best
          return [0.0, true, pair_tests] if proper_crossing
        end
      end
      [best, proper_crossing, pair_tests]
    end

    def spatial_ray_triangle_t(point, direction, triangle)
      a, b, c = triangle
      edge1 = spatial_subtract(b, a)
      edge2 = spatial_subtract(c, a)
      h = spatial_cross(direction, edge2)
      determinant = spatial_dot(edge1, h)
      return nil if determinant.abs <= SPATIAL_EPSILON

      inverse = 1.0 / determinant
      s = spatial_subtract(point, a)
      u = inverse * spatial_dot(s, h)
      return nil if u < -SPATIAL_EPSILON || u > 1.0 + SPATIAL_EPSILON
      q = spatial_cross(s, edge1)
      v = inverse * spatial_dot(direction, q)
      return nil if v < -SPATIAL_EPSILON || u + v > 1.0 + SPATIAL_EPSILON
      t = inverse * spatial_dot(edge2, q)
      t > SPATIAL_EPSILON ? t : nil
    end

    def spatial_point_on_surface?(point, triangles)
      triangles.any? do |triangle|
        spatial_point_triangle_distance_sq(point, *triangle) <= SPATIAL_EPSILON_SQ
      end
    end

    def spatial_point_inside_mesh?(point, triangles)
      return false if spatial_point_on_surface?(point, triangles)

      votes = SPATIAL_RAY_DIRECTIONS.count do |direction|
        hits = triangles.filter_map { |triangle| spatial_ray_triangle_t(point, direction, triangle) }.sort
        unique_hits = []
        hits.each do |value|
          unique_hits << value if unique_hits.empty? || (value - unique_hits.last).abs > SPATIAL_EPSILON
        end
        unique_hits.length.odd?
      end
      votes >= 2
    end

    def spatial_triangle_centroid(triangle)
      [
        (triangle[0][0] + triangle[1][0] + triangle[2][0]) / 3.0,
        (triangle[0][1] + triangle[1][1] + triangle[2][1]) / 3.0,
        (triangle[0][2] + triangle[1][2] + triangle[2][2]) / 3.0
      ]
    end

    def spatial_triangle_unit_normal(triangle)
      edge1 = spatial_subtract(triangle[1], triangle[0])
      edge2 = spatial_subtract(triangle[2], triangle[0])
      normal = spatial_cross(edge1, edge2)
      length_sq = spatial_length_sq(normal)
      return nil if length_sq <= SPATIAL_EPSILON_SQ

      spatial_scale(normal, 1.0 / Math.sqrt(length_sq))
    end

    def spatial_sample_points(triangles)
      samples = []
      triangles.each do |triangle|
        samples << triangle[0]
        samples << spatial_triangle_centroid(triangle)
        break if samples.length >= MAX_SPATIAL_SAMPLE_POINTS
      end
      samples
    end

    def spatial_mesh_has_inside_sample?(candidate_triangles, container_triangles)
      spatial_sample_points(candidate_triangles).any? do |point|
        spatial_point_inside_mesh?(point, container_triangles)
      end
    end

    def spatial_mesh_has_shared_interior_probe?(candidate_triangles, container_triangles)
      candidate_triangles.first(MAX_SPATIAL_SAMPLE_POINTS).any? do |triangle|
        normal = spatial_triangle_unit_normal(triangle)
        next false unless normal

        centroid = spatial_triangle_centroid(triangle)
        offset = spatial_scale(normal, SPATIAL_INTERIOR_PROBE_OFFSET)
        probes = [
          spatial_add(centroid, offset),
          spatial_subtract(centroid, offset)
        ]
        probes.any? do |probe|
          spatial_point_inside_mesh?(probe, candidate_triangles) &&
            spatial_point_inside_mesh?(probe, container_triangles)
        end
      end
    end

    def exact_spatial_relation(model, first_pid, second_pid, unit_info)
      if first_pid == second_pid
        raise BridgeError.new("invalid_argument", "Spatial query operands must be different entities")
      end
      first = require_spatial_solid(model, first_pid)
      second = require_spatial_solid(model, second_pid)
      first_triangles = spatial_entity_triangles(first)
      second_triangles = spatial_entity_triangles(second)
      surface_distance_sq, proper_crossing, pair_tests = spatial_surface_metrics(
        first_triangles, second_triangles
      )
      surface_distance = Math.sqrt(surface_distance_sq)
      touching_surface = surface_distance <= SPATIAL_EPSILON
      first_inside_second = spatial_mesh_has_inside_sample?(first_triangles, second_triangles)
      second_inside_first = spatial_mesh_has_inside_sample?(second_triangles, first_triangles)
      penetrating = proper_crossing || first_inside_second || second_inside_first
      if touching_surface && !penetrating
        penetrating =
          spatial_mesh_has_shared_interior_probe?(first_triangles, second_triangles) ||
          spatial_mesh_has_shared_interior_probe?(second_triangles, first_triangles)
      end
      touching = touching_surface && !penetrating
      relationship = if penetrating
                       "penetrating"
                     elsif touching
                       "touching"
                     else
                       "disjoint"
                     end
      resolved = unit_info["resolved_unit"]
      {
        "relationship" => relationship,
        "overlap" => penetrating,
        "intersects" => penetrating || touching,
        "touching" => touching,
        "surface_clearance" => quantize_public_number(
          convert_length_from_internal(surface_distance, resolved)
        ),
        "clearance" => penetrating || touching ? 0.0 : quantize_public_number(
          convert_length_from_internal(surface_distance, resolved)
        ),
        "first_triangle_count" => first_triangles.length,
        "second_triangle_count" => second_triangles.length,
        "triangle_pair_tests" => pair_tests,
        "exact" => true
      }
    end
  end
end
