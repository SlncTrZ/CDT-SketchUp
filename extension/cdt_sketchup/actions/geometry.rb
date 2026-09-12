# cdt_sketchup/actions/geometry.rb — strict box/face/extrusion/curve profile actions
# Wing: code | Topic: sketchup_bridge | Updated: 2026-09-12

module CDTSketchUp
  class BridgeServer
    private

    def unit_normal_vector(value, name)
      triplet = numeric_triplet(value, name)
      vector = Geom::Vector3d.new(triplet[0], triplet[1], triplet[2])
      if vector.length == 0.0
        raise BridgeError.new("invalid_argument", "normal must be non-zero")
      end
      vector.normalize
    end

    def orthonormal_basis(normal)
      helper = normal.z.abs < 0.9 ? Geom::Vector3d.new(0, 0, 1) : Geom::Vector3d.new(0, 1, 0)
      u = (helper * normal).normalize
      v = (normal * u).normalize
      [u, v]
    end

    def scaled_vector(vector, factor)
      Geom::Vector3d.new(vector.x * factor, vector.y * factor, vector.z * factor)
    end

    def validate_curve_segments(value, name)
      segments = begin
        Integer(value)
      rescue ArgumentError, TypeError
        raise BridgeError.new("invalid_argument", "#{name} must be an integer")
      end
      unless segments.between?(3, MAX_CURVE_SEGMENTS)
        raise BridgeError.new("invalid_argument", "#{name} must contain 3..#{MAX_CURVE_SEGMENTS} segments")
      end
      segments
    end

    def validate_positive_length(value, name, message)
      number = finite_number(value, name)
      unless number.positive?
        raise BridgeError.new("invalid_argument", message)
      end
      number
    end

    def validate_polyline_params(params)
      unless params.is_a?(Hash)
        raise BridgeError.new("invalid_argument", "create_polyline params must be an object")
      end
      unknown_keys = params.keys - POLYLINE_PARAM_KEYS
      unless unknown_keys.empty?
        raise BridgeError.new(
          "invalid_argument",
          "create_polyline params contain unsupported keys: #{unknown_keys.sort.join(', ')}"
        )
      end
      raw_points = params["points"]
      unless raw_points.is_a?(Array) && raw_points.length.between?(2, MAX_POLYLINE_POINTS)
        raise BridgeError.new(
          "invalid_argument",
          "points must contain 2..#{MAX_POLYLINE_POINTS} points"
        )
      end
      points = raw_points.each_with_index.map do |point, index|
        numeric_triplet(point, "points[#{index}]")
      end
      points.each_cons(2).each_with_index do |pair, index|
        if pair[0] == pair[1]
          raise BridgeError.new(
            "invalid_geometry",
            "polyline points must be pairwise distinct"
          )
        end
      end
      closed = params["closed"]
      unless closed == true || closed == false
        raise BridgeError.new("invalid_argument", "closed must be boolean")
      end
      [points, closed]
    end

    def validate_rectangle_params(params)
      unless params.is_a?(Hash)
        raise BridgeError.new("invalid_argument", "create_rectangle params must be an object")
      end
      unknown_keys = params.keys - RECTANGLE_PARAM_KEYS
      unless unknown_keys.empty?
        raise BridgeError.new(
          "invalid_argument",
          "create_rectangle params contain unsupported keys: #{unknown_keys.sort.join(', ')}"
        )
      end
      origin = numeric_triplet(params["origin"], "origin")
      width = validate_positive_length(params["width"], "width", "width must be positive")
      height = validate_positive_length(params["height"], "height", "height must be positive")
      normal = unit_normal_vector(params["normal"], "normal")
      [origin, width, height, normal]
    end

    def validate_circle_params(params)
      unless params.is_a?(Hash)
        raise BridgeError.new("invalid_argument", "create_circle params must be an object")
      end
      unknown_keys = params.keys - CIRCLE_PARAM_KEYS
      unless unknown_keys.empty?
        raise BridgeError.new(
          "invalid_argument",
          "create_circle params contain unsupported keys: #{unknown_keys.sort.join(', ')}"
        )
      end
      center = numeric_triplet(params["center"], "center")
      normal = unit_normal_vector(params["normal"], "normal")
      radius = validate_positive_length(params["radius"], "radius", "radius must be positive")
      segments = validate_curve_segments(params["segments"], "segments")
      [center, normal, radius, segments]
    end

    def validate_arc_params(params)
      unless params.is_a?(Hash)
        raise BridgeError.new("invalid_argument", "create_arc params must be an object")
      end
      unknown_keys = params.keys - ARC_PARAM_KEYS
      unless unknown_keys.empty?
        raise BridgeError.new(
          "invalid_argument",
          "create_arc params contain unsupported keys: #{unknown_keys.sort.join(', ')}"
        )
      end
      center = numeric_triplet(params["center"], "center")
      normal = unit_normal_vector(params["normal"], "normal")
      radius = validate_positive_length(params["radius"], "radius", "radius must be positive")
      start_degrees = finite_number(params["start_degrees"], "start_degrees")
      end_degrees = finite_number(params["end_degrees"], "end_degrees")
      sweep = (end_degrees - start_degrees) % 360.0
      if sweep == 0.0
        raise BridgeError.new("invalid_argument", "arc sweep must be non-zero")
      end
      segments = validate_curve_segments(params["segments"], "segments")
      [center, normal, radius, start_degrees, end_degrees, segments]
    end

    def validate_polygon_params(params)
      unless params.is_a?(Hash)
        raise BridgeError.new("invalid_argument", "create_polygon params must be an object")
      end
      unknown_keys = params.keys - POLYGON_PARAM_KEYS
      unless unknown_keys.empty?
        raise BridgeError.new(
          "invalid_argument",
          "create_polygon params contain unsupported keys: #{unknown_keys.sort.join(', ')}"
        )
      end
      center = numeric_triplet(params["center"], "center")
      normal = unit_normal_vector(params["normal"], "normal")
      radius = validate_positive_length(params["radius"], "radius", "radius must be positive")
      sides = begin
        Integer(params["sides"])
      rescue ArgumentError, TypeError
        raise BridgeError.new("invalid_argument", "sides must be an integer")
      end
      unless sides.between?(3, MAX_CURVE_SEGMENTS)
        raise BridgeError.new("invalid_argument", "sides must contain 3..360 sides")
      end
      [center, normal, radius, sides]
    end

    def preflight_create_polyline(model, params)
      validate_polyline_params(params)
      true
    end

    def preflight_create_rectangle(model, params)
      validate_rectangle_params(params)
      true
    end

    def preflight_create_circle(model, params)
      validate_circle_params(params)
      true
    end

    def preflight_create_arc(model, params)
      validate_arc_params(params)
      true
    end

    def preflight_create_polygon(model, params)
      validate_polygon_params(params)
      true
    end

    def planar_polygon_normal(points)
      nx = ny = nz = 0.0
      points.each_with_index do |point, index|
        nxt = points[(index + 1) % points.length]
        nx += (point[1] - nxt[1]) * (point[2] + nxt[2])
        ny += (point[2] - nxt[2]) * (point[0] + nxt[0])
        nz += (point[0] - nxt[0]) * (point[1] + nxt[1])
      end
      [nx, ny, nz]
    end

    def planar_closed_chain(points)
      return [false, nil] if points.length < 4
      nx, ny, nz = planar_polygon_normal(points)
      magnitude = Math.sqrt(nx * nx + ny * ny + nz * nz)
      return [false, nil] if magnitude == 0.0
      base = points[0]
      span = points.map do |point|
        Math.sqrt((point[0] - base[0])**2 + (point[1] - base[1])**2 + (point[2] - base[2])**2)
      end.max
      tolerance = [span * 1e-9, SEMANTIC_QUANTUM].max
      planar = points.all? do |point|
        ((point[0] - base[0]) * nx + (point[1] - base[1]) * ny + (point[2] - base[2]) * nz).abs <= tolerance * magnitude
      end
      planar ? [true, magnitude / 2.0] : [false, nil]
    end

    def execute_create_polyline(model, params)
      points, closed = validate_polyline_params(params)
      chain = points.dup
      chain << points.first if closed && points.first != points.last
      expected_length = chain.each_cons(2).sum do |pair|
        a, b = pair
        Math.sqrt((a[0] - b[0])**2 + (a[1] - b[1])**2 + (a[2] - b[2])**2)
      end
      planar, face_area = closed ? planar_closed_chain(chain) : [false, nil]
      group = model.active_entities.add_group
      unless group && group.valid? && group.is_a?(Sketchup::Group)
        raise BridgeError.new("geometry_execution_failed", "SketchUp did not create the polyline group")
      end
      edges = []
      begin
        chain.each_cons(2) do |pair|
          edge = group.entities.add_line(
            Geom::Point3d.new(pair[0][0], pair[0][1], pair[0][2]),
            Geom::Point3d.new(pair[1][0], pair[1][1], pair[1][2])
          )
          raise BridgeError.new("invalid_geometry", "SketchUp did not create the polyline edge") unless edge
          edges << edge
        end
        if planar
          face = group.entities.add_face(edges)
          raise BridgeError.new("invalid_geometry", "SketchUp did not cap the planar chain") unless face
        end
      rescue BridgeError
        raise
      rescue StandardError => error
        log("create polyline failed: #{error.class}: #{error.message}")
        raise BridgeError.new("geometry_execution_failed", "SketchUp did not create the polyline")
      end
      vertices = edges.flat_map { |edge| [edge.start, edge.end] }.uniq
      {
        "entity" => group,
        "metadata" => {
          "edge_count" => edges.length,
          "vertex_count" => vertices.length,
          "total_length" => expected_length,
          "closed" => closed,
          "planar" => planar,
          "face_expected" => planar,
          "face_area" => face_area
        }
      }
    end

    def execute_create_rectangle(model, params)
      origin, width, height, normal = validate_rectangle_params(params)
      u, v = orthonormal_basis(normal)
      origin_point = Geom::Point3d.new(origin[0], origin[1], origin[2])
      corners = [
        origin_point,
        origin_point + scaled_vector(u, width),
        origin_point + scaled_vector(u, width) + scaled_vector(v, height),
        origin_point + scaled_vector(v, height)
      ]
      before_edges = model.active_entities.grep(Sketchup::Edge).map(&:persistent_id)
      face = begin
        model.active_entities.add_face(corners)
      rescue ArgumentError, RuntimeError => error
        log("create rectangle failed: #{error.class}: #{error.message}")
        raise BridgeError.new("invalid_geometry", "SketchUp rejected rectangle geometry")
      end
      raise BridgeError.new("invalid_geometry", "SketchUp did not create the rectangle face") unless face
      after_edges = model.active_entities.grep(Sketchup::Edge).map(&:persistent_id)
      new_edge_ids = (after_edges - before_edges).sort
      face_edge_ids = face.edges.map(&:persistent_id).sort
      unless new_edge_ids == face_edge_ids && new_edge_ids.length == 4
        raise BridgeError.new("invalid_geometry", "rectangle merged with existing geometry")
      end
      group = model.active_entities.add_group(face.edges + [face])
      unless group && group.valid? && group.is_a?(Sketchup::Group)
        raise BridgeError.new("geometry_execution_failed", "SketchUp did not group the rectangle")
      end
      {
        "entity" => group,
        "metadata" => {
          "corners" => corners.map { |point| quantized_point(point) },
          "width" => width,
          "height" => height,
          "normal" => [normal.x, normal.y, normal.z].map { |value| quantize_number(value) },
          "rectangle_area" => width * height
        }
      }
    end

    def execute_create_circle(model, params)
      center, normal, radius, segments = validate_circle_params(params)
      center_point = Geom::Point3d.new(center[0], center[1], center[2])
      group = model.active_entities.add_group
      unless group && group.valid? && group.is_a?(Sketchup::Group)
        raise BridgeError.new("geometry_execution_failed", "SketchUp did not create the circle group")
      end
      edges = begin
        group.entities.add_circle(center_point, normal, radius, segments)
      rescue ArgumentError, RuntimeError => error
        log("create circle failed: #{error.class}: #{error.message}")
        raise BridgeError.new("invalid_geometry", "SketchUp rejected circle geometry")
      end
      unless edges.is_a?(Array) && edges.length == segments
        raise BridgeError.new("geometry_execution_failed", "SketchUp did not create the circle edges")
      end
      {
        "entity" => group,
        "metadata" => {
          "center" => center,
          "radius" => radius,
          "segments" => segments,
          "normal" => [normal.x, normal.y, normal.z].map { |value| quantize_number(value) }
        }
      }
    end

    def execute_create_arc(model, params)
      center, normal, radius, start_degrees, end_degrees, segments = validate_arc_params(params)
      u, = orthonormal_basis(normal)
      center_point = Geom::Point3d.new(center[0], center[1], center[2])
      group = model.active_entities.add_group
      unless group && group.valid? && group.is_a?(Sketchup::Group)
        raise BridgeError.new("geometry_execution_failed", "SketchUp did not create the arc group")
      end
      edges = begin
        group.entities.add_arc(
          center_point, u, normal, radius,
          start_degrees * Math::PI / 180.0, end_degrees * Math::PI / 180.0, segments
        )
      rescue ArgumentError, RuntimeError => error
        log("create arc failed: #{error.class}: #{error.message}")
        raise BridgeError.new("invalid_geometry", "SketchUp rejected arc geometry")
      end
      unless edges.is_a?(Array) && edges.length == segments
        raise BridgeError.new("geometry_execution_failed", "SketchUp did not create the arc edges")
      end
      {
        "entity" => group,
        "metadata" => {
          "center" => center,
          "radius" => radius,
          "segments" => segments,
          "start_degrees" => start_degrees,
          "end_degrees" => end_degrees,
          "xaxis" => [u.x, u.y, u.z].map { |value| quantize_number(value) },
          "normal" => [normal.x, normal.y, normal.z].map { |value| quantize_number(value) }
        }
      }
    end

    def execute_create_polygon(model, params)
      center, normal, radius, sides = validate_polygon_params(params)
      u, v = orthonormal_basis(normal)
      center_point = Geom::Point3d.new(center[0], center[1], center[2])
      vertices = sides.times.map do |index|
        angle = 2.0 * Math::PI * index / sides
        center_point + scaled_vector(u, radius * Math.cos(angle)) + scaled_vector(v, radius * Math.sin(angle))
      end
      before_edges = model.active_entities.grep(Sketchup::Edge).map(&:persistent_id)
      face = begin
        model.active_entities.add_face(vertices)
      rescue ArgumentError, RuntimeError => error
        log("create polygon failed: #{error.class}: #{error.message}")
        raise BridgeError.new("invalid_geometry", "SketchUp rejected polygon geometry")
      end
      raise BridgeError.new("invalid_geometry", "SketchUp did not create the polygon face") unless face
      after_edges = model.active_entities.grep(Sketchup::Edge).map(&:persistent_id)
      new_edge_ids = (after_edges - before_edges).sort
      face_edge_ids = face.edges.map(&:persistent_id).sort
      unless new_edge_ids == face_edge_ids && new_edge_ids.length == sides
        raise BridgeError.new("invalid_geometry", "polygon merged with existing geometry")
      end
      group = model.active_entities.add_group(face.edges + [face])
      unless group && group.valid? && group.is_a?(Sketchup::Group)
        raise BridgeError.new("geometry_execution_failed", "SketchUp did not group the polygon")
      end
      {
        "entity" => group,
        "metadata" => {
          "center" => center,
          "radius" => radius,
          "sides" => sides,
          "normal" => [normal.x, normal.y, normal.z].map { |value| quantize_number(value) },
          "polygon_area" => sides * radius * radius * Math.sin(2.0 * Math::PI / sides) / 2.0
        }
      }
    end

    def validate_sweep_profile_params(params)
      unless params.is_a?(Hash)
        raise BridgeError.new("invalid_argument", "sweep_profile params must be an object")
      end
      unknown_keys = params.keys - SWEEP_PROFILE_PARAM_KEYS
      unless unknown_keys.empty?
        raise BridgeError.new(
          "invalid_argument",
          "sweep_profile params contain unsupported keys: #{unknown_keys.sort.join(', ')}"
        )
      end
      unless params.key?("face_pid")
        raise BridgeError.new("invalid_argument", "sweep_profile face_pid is required")
      end
      face_pid = bounded_integer(params["face_pid"], minimum: 1, maximum: (2**63) - 1, name: "face_pid")
      raw_path = params["path_pids"]
      unless raw_path.is_a?(Array) && raw_path.length.between?(1, MAX_SWEEP_PATH_EDGES)
        raise BridgeError.new(
          "invalid_argument",
          "sweep_profile path must contain 1..64 connected edges"
        )
      end
      path_pids = raw_path.each_with_index.map do |value, index|
        bounded_integer(value, minimum: 1, maximum: (2**63) - 1, name: "path_pids[#{index}]")
      end
      if path_pids.uniq.length != path_pids.length || path_pids.include?(face_pid)
        raise BridgeError.new("invalid_argument", "sweep_profile path must not contain duplicates")
      end
      [face_pid, path_pids]
    end

    def sweep_path_entities(model, face_pid, path_pids)
      face = require_active_entity(model, face_pid)
      unless face.is_a?(Sketchup::Face)
        raise BridgeError.new("unsupported_object_type", "sweep_profile requires an isolated profile face")
      end
      path = path_pids.map { |value| require_active_entity(model, value) }
      unless path.all? { |entity| entity.is_a?(Sketchup::Edge) }
        raise BridgeError.new(
          "invalid_argument",
          "sweep_profile path must contain 1..64 connected edges"
        )
      end
      allowed_ids = ([face] + face.edges + path).map(&:persistent_id).sort
      face_connected_ids, face_connected_unresolved = connected_persistent_ids(face)
      unless face_connected_unresolved.zero? && (face_connected_ids - allowed_ids).empty?
        raise BridgeError.new(
          "unsupported_object_type",
          "sweep_profile profile must connect only its path"
        )
      end
      edges_closed = face.edges.all? do |edge|
        edge_ids, edge_unresolved = connected_persistent_ids(edge)
        edge_unresolved.zero? && (edge_ids - allowed_ids).empty?
      end
      unless edges_closed
        raise BridgeError.new(
          "invalid_geometry",
          "sweep_profile inputs must connect only each other"
        )
      end
      chain_ok = path.all? do |edge|
        neighbor_ids = ([edge.start, edge.end].flat_map do |vertex|
          vertex.edges.map(&:persistent_id)
        end | edge.faces.map(&:persistent_id)).uniq
        (neighbor_ids - allowed_ids).empty? && !neighbor_ids.empty?
      end
      unless chain_ok
        raise BridgeError.new(
          "invalid_geometry",
          "sweep_profile path must connect only the profile"
        )
      end
      [face, path]
    end

    def preflight_sweep_profile(model, params)
      face_pid, path_pids = validate_sweep_profile_params(params)
      sweep_path_entities(model, face_pid, path_pids)
      true
    end

    def execute_sweep_profile(model, params)
      face_pid, path_pids = validate_sweep_profile_params(params)
      face, path = sweep_path_entities(model, face_pid, path_pids)
      face_edges = face.edges
      input_entities = ([face] + face_edges + path).uniq
      input_pids = input_entities.map(&:persistent_id).sort
      input_fingerprints = input_entities.each_with_object({}) do |entity, result|
        state = semantic_entity_state(model, entity)
        result[entity.persistent_id.to_s] = {
          "identity" => state["identity_fingerprint"],
          "geometry" => state["geometry_fingerprint"],
          "reparent" => grouping_reparent_fingerprint(entity, state)
        }
      end
      edge_lengths = {}
      (face_edges + path).each { |edge| edge_lengths[edge.persistent_id.to_s] = quantize_number(edge.length) }
      face_area = quantize_number(face.area)
      input_bounds = aggregate_semantic_bounds(
        input_entities.map { |entity| semantic_entity_state(model, entity) }
      )
      before_ids = model.active_entities.map(&:persistent_id)
      swept = begin
        face.followme(path)
      rescue StandardError => error
        log("sweep profile failed: #{error.class}: #{error.message}")
        raise BridgeError.new("sweep_failed", "SketchUp did not sweep the profile")
      end
      unless swept
        raise BridgeError.new("sweep_failed", "SketchUp did not sweep the profile")
      end
      after_ids = model.active_entities.map(&:persistent_id)
      gone_ids = (before_ids - after_ids).sort
      seed_ids = (after_ids - before_ids)
      if seed_ids.empty?
        raise BridgeError.new("sweep_failed", "SketchUp sweep produced no geometry")
      end
      closure = seed_ids.flat_map do |persistent_id|
        entity = model.find_entity_by_persistent_id(persistent_id)
        next [] unless entity
        ids, _unresolved = connected_persistent_ids(entity)
        ids
      end.uniq
      if closure.length > MAX_OBJECTS
        raise BridgeError.new("semantic_state_too_large", "Swept shell exceeds entity limit")
      end
      closure_entities = closure.map { |persistent_id| model.find_entity_by_persistent_id(persistent_id) }
      unless closure_entities.all?
        raise BridgeError.new("sweep_failed", "Swept shell changed during grouping")
      end
      foreign = (closure & before_ids) - input_pids
      unless foreign.empty?
        raise BridgeError.new("invalid_geometry", "sweep_profile shell touched outside geometry")
      end
      group = model.active_entities.add_group(closure_entities)
      unless group && group.valid? && group.is_a?(Sketchup::Group)
        raise BridgeError.new("sweep_failed", "SketchUp did not group the swept shell")
      end
      {
        "entity" => group,
        "metadata" => {
          "input_persistent_ids" => input_pids,
          "face_pid" => face_pid,
          "input_fingerprints" => input_fingerprints,
          "edge_lengths" => edge_lengths,
          "face_area" => face_area,
          "input_bounds_min" => input_bounds["min"],
          "input_bounds_max" => input_bounds["max"],
          "consumed_persistent_ids" => gone_ids,
          "reparented_persistent_ids" => (closure & before_ids).sort,
          "sweep_definition_guid" => group.definition.guid.to_s
        }
      }
    end

    def handle_create_edge(params)
      model = require_model
      start_point = point3d(params["start"], "start")
      end_point = point3d(params["end"], "end")
      if start_point.distance(end_point).zero?
        raise BridgeError.new("invalid_geometry", "Edge endpoints must be distinct")
      end

      with_operation(model, "CDT: Create Edge") do
        edge = model.active_entities.add_line(start_point, end_point)
        raise BridgeError.new("invalid_geometry", "SketchUp did not create an edge") unless edge
        serialize_entity(edge)
      end
    end

    def handle_create_face(params)
      model = require_model
      raw_points = params["points"]
      unless raw_points.is_a?(Array) && raw_points.length.between?(3, MAX_FACE_POINTS)
        raise BridgeError.new("invalid_argument", "points must contain 3..#{MAX_FACE_POINTS} vertices")
      end
      points = raw_points.each_with_index.map { |value, index| point3d(value, "points[#{index}]") }

      with_operation(model, "CDT: Create Face") do
        face = begin
          model.active_entities.add_face(points)
        rescue ArgumentError
          raise BridgeError.new("invalid_geometry", "SketchUp rejected face geometry")
        end
        raise BridgeError.new("invalid_geometry", "SketchUp did not create a face") unless face
        serialize_entity(face)
      end
    end

    def execute_create_face(model, params)
      unknown_create_face_keys = params.keys - CREATE_FACE_PARAM_KEYS
      unless unknown_create_face_keys.empty?
        raise BridgeError.new(
          "invalid_argument",
          "create_face params contain unsupported keys: #{unknown_create_face_keys.sort.join(', ')}"
        )
      end

      raw_points = params["points"]
      unless raw_points.is_a?(Array) && raw_points.length.between?(3, MAX_FACE_POINTS)
        raise BridgeError.new(
          "invalid_argument",
          "points must contain 3..#{MAX_FACE_POINTS} vertices"
        )
      end
      points = raw_points.each_with_index.map do |value, index|
        point3d(value, "points[#{index}]")
      end

      face = begin
        model.active_entities.add_face(points)
      rescue ArgumentError
        raise BridgeError.new("invalid_geometry", "SketchUp rejected face geometry")
      end
      raise BridgeError.new("invalid_geometry", "SketchUp did not create a face") unless face
      face
    end

    def execute_extrude_face_to_group(model, params)
      unknown_extrude_face_keys = params.keys - EXTRUDE_FACE_PARAM_KEYS
      unless unknown_extrude_face_keys.empty?
        raise BridgeError.new(
          "invalid_argument",
          "extrude_face_to_group params contain unsupported keys: #{unknown_extrude_face_keys.sort.join(', ')}"
        )
      end

      face = require_active_entity(model, params["persistent_id"])
      unless face.is_a?(Sketchup::Face)
        raise BridgeError.new(
          "unsupported_object_type",
          "extrude_face_to_group requires a Face persistent_id"
        )
      end

      distance = finite_number(params["distance"], "distance")
      if distance.zero?
        raise BridgeError.new("invalid_argument", "distance must be non-zero")
      end

      group_name = params["group_name"]
      if group_name && (!group_name.is_a?(String) || group_name.length > 128)
        raise BridgeError.new(
          "invalid_argument",
          "group_name must be a string up to 128 characters"
        )
      end

      unless isolated_face_for_extrusion?(face)
        raise BridgeError.new(
          "non_isolated_face",
          "extrude_face_to_group requires an isolated face"
        )
      end

      source_persistent_id = face.persistent_id
      face.pushpull(distance, false)
      current = model.find_entity_by_persistent_id(source_persistent_id)
      unless current && current.valid? && current.is_a?(Sketchup::Face)
        raise BridgeError.new(
          "geometry_execution_failed",
          "Source face did not survive extrusion"
        )
      end

      connected_after = current.all_connected
      unless connected_after.length.between?(1, MAX_OBJECTS)
        raise BridgeError.new(
          "semantic_state_too_large",
          "Extruded connected geometry exceeds entity limit"
        )
      end
      unless connected_after.all? do |entity|
               entity.respond_to?(:parent) &&
                 entity.parent == model.active_entities.parent
             end
        raise BridgeError.new(
          "context_mismatch",
          "Extruded geometry escaped the active edit context"
        )
      end

      group = model.active_entities.add_group(connected_after)
      group.name = group_name if group_name && !group_name.empty?
      group
    end

    def isolated_face_for_extrusion?(face)
      expected_ids = ([face] + face.edges).map(&:persistent_id).sort
      actual_ids = face.all_connected.map(&:persistent_id).sort
      expected_ids == actual_ids
    end

    def execute_create_box(model, params)
      unknown_create_box_keys = params.keys - CREATE_BOX_PARAM_KEYS
      unless unknown_create_box_keys.empty?
        raise BridgeError.new(
          "invalid_argument",
          "create_box params contain unsupported keys: #{unknown_create_box_keys.sort.join(', ')}"
        )
      end

      name = bounded_name(params["name"], "name")
      origin = point3d(params["origin"] || [0, 0, 0], "origin")
      dimensions = numeric_triplet(params["dimensions"], "dimensions")
      unless dimensions.all?(&:positive?)
        raise BridgeError.new("invalid_geometry", "dimensions must be positive")
      end
      if model.definitions.any? { |definition| definition.name == name }
        raise BridgeError.new("already_exists", "Component definition already exists")
      end

      definition = model.definitions.add(name)
      entities = definition.entities
      width, depth, height = dimensions
      face = entities.add_face(
        [0, 0, 0],
        [width, 0, 0],
        [width, depth, 0],
        [0, depth, 0]
      )
      raise BridgeError.new("invalid_geometry", "SketchUp did not create component base face") unless face
      face.pushpull(-height)

      transform = Geom::Transformation.translation(origin)
      model.active_entities.add_instance(definition, transform)
    end
  end
end
