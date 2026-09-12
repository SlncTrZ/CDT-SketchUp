# cdt_sketchup/kernel/expectations.rb — expectation schemas and semantic invariants
# Wing: code | Topic: sketchup_bridge | Updated: 2026-09-12

module CDTSketchUp
  class BridgeServer
    private

    def semantic_action_outcome(model, outcome)
      if outcome.is_a?(Hash) && outcome.key?("state")
        state = outcome["state"]
        metadata = outcome["metadata"] || {}
        unless state.is_a?(Hash)
          raise BridgeError.new("semantic_state_invalid", "Action state must be an object")
        end
        return [state, metadata]
      end
      if outcome.is_a?(Hash) && outcome.key?("entity")
        entity = outcome["entity"]
        metadata = outcome["metadata"] || {}
        return [semantic_entity_state(model, entity), metadata]
      end
      [semantic_entity_state(model, outcome), {}]
    end

    def validate_action_expectation(action, action_params, expect)
      case action
      when "transform_entity"
        unless Integer(expect["active_entity_delta"]) == 0
          raise BridgeError.new(
            "invalid_argument",
            "transform_entity requires expect.active_entity_delta = 0"
          )
        end
        unless expect.key?("transformation")
          raise BridgeError.new(
            "invalid_argument",
            "transform_entity requires expect.transformation"
          )
        end

        requested = transformation_from_matrix(action_params["matrix"]).to_a
        expected = numeric_array(expect["transformation"], 16, "expect.transformation")
        tolerance = expect.key?("tolerance") ? finite_number(expect["tolerance"], "expect.tolerance") : SEMANTIC_QUANTUM
        matches = requested.zip(expected).all? do |requested_item, expected_item|
          (requested_item - expected_item).abs <= tolerance
        end
        unless matches
          raise BridgeError.new(
            "invalid_argument",
            "expect.transformation must match the requested absolute matrix"
          )
        end
      when "boolean_operation"
        unless Integer(expect["active_entity_delta"]) == -1
          raise BridgeError.new(
            "invalid_argument",
            "boolean_operation requires expect.active_entity_delta = -1"
          )
        end
        unless expect["type"] == "Group"
          raise BridgeError.new(
            "invalid_argument",
            "boolean_operation requires expect.type = Group"
          )
        end
        unless expect["manifold"] == true
          raise BridgeError.new(
            "invalid_argument",
            "boolean_operation requires expect.manifold = true"
          )
        end
      when "delete_entity"
        unless Integer(expect["active_entity_delta"]) == -1
          raise BridgeError.new(
            "invalid_argument",
            "delete_entity requires expect.active_entity_delta = -1"
          )
        end
        unless expect["deleted"] == true
          raise BridgeError.new(
            "invalid_argument",
            "delete_entity requires expect.deleted = true"
          )
        end
        unsupported_delete_expect = expect.keys - %w[active_entity_delta deleted type tolerance]
        unless unsupported_delete_expect.empty?
          raise BridgeError.new(
            "invalid_argument",
            "delete_entity expect contains unsupported keys: #{unsupported_delete_expect.sort.join(', ')}"
          )
        end
        if expect.key?("type") && !%w[Group ComponentInstance].include?(expect["type"].to_s)
          raise BridgeError.new(
            "invalid_argument",
            "delete_entity expect.type must be Group or ComponentInstance"
          )
        end
      when "delete_topology_entity"
        unless expect["deleted"] == true
          raise BridgeError.new(
            "invalid_argument",
            "delete_topology_entity requires expect.deleted = true"
          )
        end
        unsupported_topology_delete_expect = expect.keys - %w[deleted type tolerance]
        unless unsupported_topology_delete_expect.empty?
          raise BridgeError.new(
            "invalid_argument",
            "delete_topology_entity expect contains unsupported keys: #{unsupported_topology_delete_expect.sort.join(', ')}"
          )
        end
        if expect.key?("type") && !%w[Edge Face].include?(expect["type"].to_s)
          raise BridgeError.new(
            "invalid_argument",
            "delete_topology_entity expect.type must be Edge or Face"
          )
        end
      when "push_pull_topology_face"
        unless expect["type"] == "Face"
          raise BridgeError.new(
            "invalid_argument",
            "push_pull_topology_face requires expect.type = Face"
          )
        end
        unsupported_push_pull_expect = expect.keys - %w[type tolerance]
        unless unsupported_push_pull_expect.empty?
          raise BridgeError.new(
            "invalid_argument",
            "push_pull_topology_face expect contains unsupported keys: #{unsupported_push_pull_expect.sort.join(', ')}"
          )
        end
      when "group_entities"
        persistent_ids, = validate_group_entities_params(action_params)
        unless Integer(expect["active_entity_delta"]) == 1 - persistent_ids.length
          raise BridgeError.new(
            "invalid_argument",
            "group_entities requires expect.active_entity_delta = 1 - input count"
          )
        end
        unless expect["type"] == "Group"
          raise BridgeError.new(
            "invalid_argument",
            "group_entities requires expect.type = Group"
          )
        end
        unless expect.key?("child_persistent_ids")
          raise BridgeError.new(
            "invalid_argument",
            "group_entities requires expect.child_persistent_ids"
          )
        end
        unsupported_group_expect = expect.keys - %w[active_entity_delta type child_persistent_ids tolerance]
        unless unsupported_group_expect.empty?
          raise BridgeError.new(
            "invalid_argument",
            "group_entities expect contains unsupported keys: #{unsupported_group_expect.sort.join(', ')}"
          )
        end
      when "create_component"
        persistent_ids, = validate_create_component_params(action_params)
        unless Integer(expect["active_entity_delta"]) == 1 - persistent_ids.length
          raise BridgeError.new(
            "invalid_argument",
            "create_component requires expect.active_entity_delta = 1 - input count"
          )
        end
        unless expect["type"] == "ComponentInstance"
          raise BridgeError.new(
            "invalid_argument",
            "create_component requires expect.type = ComponentInstance"
          )
        end
        unless expect.key?("child_persistent_ids")
          raise BridgeError.new(
            "invalid_argument",
            "create_component requires expect.child_persistent_ids"
          )
        end
        unsupported_component_expect = expect.keys - %w[active_entity_delta type child_persistent_ids tolerance]
        unless unsupported_component_expect.empty?
          raise BridgeError.new(
            "invalid_argument",
            "create_component expect contains unsupported keys: #{unsupported_component_expect.sort.join(', ')}"
          )
        end
      when "place_instance"
        unless Integer(expect["active_entity_delta"]) == 1
          raise BridgeError.new(
            "invalid_argument",
            "place_instance requires expect.active_entity_delta = 1"
          )
        end
        unless expect["type"] == "ComponentInstance"
          raise BridgeError.new(
            "invalid_argument",
            "place_instance requires expect.type = ComponentInstance"
          )
        end
        unless expect["definition_guid"].to_s == action_params["definition_guid"].to_s.strip
          raise BridgeError.new(
            "invalid_argument",
            "place_instance requires expect.definition_guid"
          )
        end
        unless expect.key?("transformation")
          raise BridgeError.new(
            "invalid_argument",
            "place_instance requires expect.transformation"
          )
        end
        unsupported_place_expect = expect.keys - %w[active_entity_delta type definition_guid transformation tolerance]
        unless unsupported_place_expect.empty?
          raise BridgeError.new(
            "invalid_argument",
            "place_instance expect contains unsupported keys: #{unsupported_place_expect.sort.join(', ')}"
          )
        end
      when "make_unique"
        unless Integer(expect["active_entity_delta"]) == 0
          raise BridgeError.new(
            "invalid_argument",
            "make_unique requires expect.active_entity_delta = 0"
          )
        end
        unless expect["type"] == "ComponentInstance"
          raise BridgeError.new(
            "invalid_argument",
            "make_unique requires expect.type = ComponentInstance"
          )
        end
        unsupported_unique_expect = expect.keys - %w[active_entity_delta type tolerance]
        unless unsupported_unique_expect.empty?
          raise BridgeError.new(
            "invalid_argument",
            "make_unique expect contains unsupported keys: #{unsupported_unique_expect.sort.join(', ')}"
          )
        end
      when "copy_entity"
        unless Integer(expect["active_entity_delta"]) == 1
          raise BridgeError.new(
            "invalid_argument",
            "copy_entity requires expect.active_entity_delta = 1"
          )
        end
        unless expect.key?("type")
          raise BridgeError.new(
            "invalid_argument",
            "copy_entity requires expect.type"
          )
        end
        unsupported_copy_expect = expect.keys - %w[active_entity_delta type tolerance]
        unless unsupported_copy_expect.empty?
          raise BridgeError.new(
            "invalid_argument",
            "copy_entity expect contains unsupported keys: #{unsupported_copy_expect.sort.join(', ')}"
          )
        end
      when "linear_array"
        linear_count = validate_linear_array_params(action_params)[2]
        unless Integer(expect["active_entity_delta"]) == linear_count
          raise BridgeError.new(
            "invalid_argument",
            "linear_array requires expect.active_entity_delta = count"
          )
        end
        unless Integer(expect["count"]) == linear_count
          raise BridgeError.new(
            "invalid_argument",
            "linear_array requires expect.count"
          )
        end
        unless expect.key?("type")
          raise BridgeError.new(
            "invalid_argument",
            "linear_array requires expect.type"
          )
        end
        unsupported_linear_expect = expect.keys - %w[active_entity_delta type count tolerance]
        unless unsupported_linear_expect.empty?
          raise BridgeError.new(
            "invalid_argument",
            "linear_array expect contains unsupported keys: #{unsupported_linear_expect.sort.join(', ')}"
          )
        end
      when "radial_array"
        radial_count = validate_radial_array_params(action_params)[4]
        unless Integer(expect["active_entity_delta"]) == radial_count
          raise BridgeError.new(
            "invalid_argument",
            "radial_array requires expect.active_entity_delta = count"
          )
        end
        unless Integer(expect["count"]) == radial_count
          raise BridgeError.new(
            "invalid_argument",
            "radial_array requires expect.count"
          )
        end
        unless expect.key?("type")
          raise BridgeError.new(
            "invalid_argument",
            "radial_array requires expect.type"
          )
        end
        unsupported_radial_expect = expect.keys - %w[active_entity_delta type count tolerance]
        unless unsupported_radial_expect.empty?
          raise BridgeError.new(
            "invalid_argument",
            "radial_array expect contains unsupported keys: #{unsupported_radial_expect.sort.join(', ')}"
          )
        end
      when "tag_assign"
        unless Integer(expect["active_entity_delta"]) == 0
          raise BridgeError.new(
            "invalid_argument",
            "tag_assign requires expect.active_entity_delta = 0"
          )
        end
        unless expect.key?("tag")
          raise BridgeError.new(
            "invalid_argument",
            "tag_assign requires expect.tag"
          )
        end
        unsupported_tag_expect = expect.keys - %w[active_entity_delta type tag tolerance]
        unless unsupported_tag_expect.empty?
          raise BridgeError.new(
            "invalid_argument",
            "tag_assign expect contains unsupported keys: #{unsupported_tag_expect.sort.join(', ')}"
          )
        end
      when "material_assign"
        unless Integer(expect["active_entity_delta"]) == 0
          raise BridgeError.new(
            "invalid_argument",
            "material_assign requires expect.active_entity_delta = 0"
          )
        end
        unless expect.key?("material")
          raise BridgeError.new(
            "invalid_argument",
            "material_assign requires expect.material"
          )
        end
        unsupported_material_expect = expect.keys - %w[active_entity_delta type material tolerance]
        unless unsupported_material_expect.empty?
          raise BridgeError.new(
            "invalid_argument",
            "material_assign expect contains unsupported keys: #{unsupported_material_expect.sort.join(', ')}"
          )
        end
      when "create_polyline"
        unless Integer(expect["active_entity_delta"]) == 1
          raise BridgeError.new(
            "invalid_argument",
            "create_polyline requires expect.active_entity_delta = 1"
          )
        end
        unless expect["type"] == "Group"
          raise BridgeError.new(
            "invalid_argument",
            "create_polyline requires expect.type = Group"
          )
        end
        unsupported_polyline_expect = expect.keys - %w[active_entity_delta type edge_count vertex_count tolerance]
        unless unsupported_polyline_expect.empty?
          raise BridgeError.new(
            "invalid_argument",
            "create_polyline expect contains unsupported keys: #{unsupported_polyline_expect.sort.join(', ')}"
          )
        end
      when "create_rectangle"
        unless Integer(expect["active_entity_delta"]) == 1
          raise BridgeError.new(
            "invalid_argument",
            "create_rectangle requires expect.active_entity_delta = 1"
          )
        end
        unless expect["type"] == "Group"
          raise BridgeError.new(
            "invalid_argument",
            "create_rectangle requires expect.type = Group"
          )
        end
        unless expect.key?("edge_count")
          raise BridgeError.new(
            "invalid_argument",
            "create_rectangle requires expect.edge_count"
          )
        end
        unsupported_rectangle_expect = expect.keys - %w[active_entity_delta type edge_count vertex_count tolerance]
        unless unsupported_rectangle_expect.empty?
          raise BridgeError.new(
            "invalid_argument",
            "create_rectangle expect contains unsupported keys: #{unsupported_rectangle_expect.sort.join(', ')}"
          )
        end
      when "create_circle"
        unless Integer(expect["active_entity_delta"]) == 1
          raise BridgeError.new(
            "invalid_argument",
            "create_circle requires expect.active_entity_delta = 1"
          )
        end
        unless expect["type"] == "Group"
          raise BridgeError.new(
            "invalid_argument",
            "create_circle requires expect.type = Group"
          )
        end
        unless expect.key?("edge_count")
          raise BridgeError.new(
            "invalid_argument",
            "create_circle requires expect.edge_count"
          )
        end
        unsupported_circle_expect = expect.keys - %w[active_entity_delta type edge_count vertex_count tolerance]
        unless unsupported_circle_expect.empty?
          raise BridgeError.new(
            "invalid_argument",
            "create_circle expect contains unsupported keys: #{unsupported_circle_expect.sort.join(', ')}"
          )
        end
      when "create_arc"
        unless Integer(expect["active_entity_delta"]) == 1
          raise BridgeError.new(
            "invalid_argument",
            "create_arc requires expect.active_entity_delta = 1"
          )
        end
        unless expect["type"] == "Group"
          raise BridgeError.new(
            "invalid_argument",
            "create_arc requires expect.type = Group"
          )
        end
        unless expect.key?("edge_count")
          raise BridgeError.new(
            "invalid_argument",
            "create_arc requires expect.edge_count"
          )
        end
        unsupported_arc_expect = expect.keys - %w[active_entity_delta type edge_count vertex_count tolerance]
        unless unsupported_arc_expect.empty?
          raise BridgeError.new(
            "invalid_argument",
            "create_arc expect contains unsupported keys: #{unsupported_arc_expect.sort.join(', ')}"
          )
        end
      when "create_polygon"
        unless Integer(expect["active_entity_delta"]) == 1
          raise BridgeError.new(
            "invalid_argument",
            "create_polygon requires expect.active_entity_delta = 1"
          )
        end
        unless expect["type"] == "Group"
          raise BridgeError.new(
            "invalid_argument",
            "create_polygon requires expect.type = Group"
          )
        end
        unless expect.key?("edge_count")
          raise BridgeError.new(
            "invalid_argument",
            "create_polygon requires expect.edge_count"
          )
        end
        unsupported_polygon_expect = expect.keys - %w[active_entity_delta type edge_count vertex_count tolerance]
        unless unsupported_polygon_expect.empty?
          raise BridgeError.new(
            "invalid_argument",
            "create_polygon expect contains unsupported keys: #{unsupported_polygon_expect.sort.join(', ')}"
          )
        end
      when "sweep_profile"
        face_pid, path_pids = validate_sweep_profile_params(action_params)
        profile = Sketchup.active_model.find_entity_by_persistent_id(face_pid)
        profile_edge_count = profile.is_a?(Sketchup::Face) ? profile.edges.length : 0
        unless Integer(expect["active_entity_delta"]) == 1 - (1 + profile_edge_count + path_pids.length)
          raise BridgeError.new(
            "invalid_argument",
            "sweep_profile requires expect.active_entity_delta = 1 - input count"
          )
        end
        unless expect["type"] == "Group"
          raise BridgeError.new(
            "invalid_argument",
            "sweep_profile requires expect.type = Group"
          )
        end
        unless expect["manifold"] == true
          raise BridgeError.new(
            "invalid_argument",
            "sweep_profile requires expect.manifold"
          )
        end
        unsupported_sweep_expect = expect.keys - %w[active_entity_delta type manifold tolerance]
        unless unsupported_sweep_expect.empty?
          raise BridgeError.new(
            "invalid_argument",
            "sweep_profile expect contains unsupported keys: #{unsupported_sweep_expect.sort.join(', ')}"
          )
        end
      when "place_asset"
        unless Integer(expect["active_entity_delta"]) == 1
          raise BridgeError.new(
            "invalid_argument",
            "place_asset requires expect.active_entity_delta = 1"
          )
        end
        unless expect["type"] == "ComponentInstance"
          raise BridgeError.new(
            "invalid_argument",
            "place_asset requires expect.type = ComponentInstance"
          )
        end
        unsupported_asset_expect = expect.keys - %w[active_entity_delta type definition_name transformation tolerance]
        unless unsupported_asset_expect.empty?
          raise BridgeError.new(
            "invalid_argument",
            "place_asset expect contains unsupported keys: #{unsupported_asset_expect.sort.join(', ')}"
          )
        end
      when "camera_set"
        unless Integer(expect["active_entity_delta"]) == 0
          raise BridgeError.new(
            "invalid_argument",
            "camera_set requires expect.active_entity_delta = 0"
          )
        end
        unless expect.key?("camera_fov")
          raise BridgeError.new(
            "invalid_argument",
            "camera_set requires expect.camera_fov"
          )
        end
        unsupported_camera_expect = expect.keys - %w[active_entity_delta camera_eye camera_target camera_fov tolerance]
        unless unsupported_camera_expect.empty?
          raise BridgeError.new(
            "invalid_argument",
            "camera_set expect contains unsupported keys: #{unsupported_camera_expect.sort.join(', ')}"
          )
        end
      when "scene_create"
        unless Integer(expect["active_entity_delta"]) == 0
          raise BridgeError.new(
            "invalid_argument",
            "scene_create requires expect.active_entity_delta = 0"
          )
        end
        unless expect.key?("scene_name")
          raise BridgeError.new(
            "invalid_argument",
            "scene_create requires expect.scene_name"
          )
        end
        unsupported_scene_expect = expect.keys - %w[active_entity_delta scene_name tolerance]
        unless unsupported_scene_expect.empty?
          raise BridgeError.new(
            "invalid_argument",
            "scene_create expect contains unsupported keys: #{unsupported_scene_expect.sort.join(', ')}"
          )
        end
      when "material_apply_texture"
        unless Integer(expect["active_entity_delta"]) == 0
          raise BridgeError.new(
            "invalid_argument",
            "material_apply_texture requires expect.active_entity_delta = 0"
          )
        end
        unless expect.key?("material")
          raise BridgeError.new(
            "invalid_argument",
            "material_apply_texture requires expect.material"
          )
        end
        unsupported_texture_expect = expect.keys - %w[active_entity_delta material tolerance]
        unless unsupported_texture_expect.empty?
          raise BridgeError.new(
            "invalid_argument",
            "material_apply_texture expect contains unsupported keys: #{unsupported_texture_expect.sort.join(', ')}"
          )
        end
      when "repair_reverse_face"
        unless Integer(expect["active_entity_delta"]) == 0
          raise BridgeError.new(
            "invalid_argument",
            "repair_reverse_face requires expect.active_entity_delta = 0"
          )
        end
        unless expect["type"] == "Face"
          raise BridgeError.new(
            "invalid_argument",
            "repair_reverse_face requires expect.type = Face"
          )
        end
        unsupported_reverse_expect = expect.keys - %w[active_entity_delta type tolerance]
        unless unsupported_reverse_expect.empty?
          raise BridgeError.new(
            "invalid_argument",
            "repair_reverse_face expect contains unsupported keys: #{unsupported_reverse_expect.sort.join(', ')}"
          )
        end
      when "repair_erase_degenerate"
        unless Integer(expect["active_entity_delta"]) == -1
          raise BridgeError.new(
            "invalid_argument",
            "repair_erase_degenerate requires expect.active_entity_delta = -1"
          )
        end
        unless expect["deleted"] == true
          raise BridgeError.new(
            "invalid_argument",
            "repair_erase_degenerate requires expect.deleted = true"
          )
        end
        unsupported_erase_expect = expect.keys - %w[active_entity_delta deleted type tolerance]
        unless unsupported_erase_expect.empty?
          raise BridgeError.new(
            "invalid_argument",
            "repair_erase_degenerate expect contains unsupported keys: #{unsupported_erase_expect.sort.join(', ')}"
          )
        end
      end
      true
    rescue ArgumentError, TypeError
      raise BridgeError.new("invalid_argument", "expect.active_entity_delta must be an integer")
    end

    def curve_vertices_on_radius?(vertices, center, radius, transform = nil)
      tolerance = [radius.abs * 1e-9, SEMANTIC_QUANTUM].max
      vertices.all? do |vertex|
        point = transform ? vertex.position.transform(transform) : vertex.position
        distance = Math.sqrt(
          (point.x - center[0])**2 + (point.y - center[1])**2 + (point.z - center[2])**2
        )
        (distance - radius).abs <= tolerance
      end
    end

    def angular_difference_degrees(left, right)
      ((left - right + 540.0) % 360.0) - 180.0
    end

    def group_member_entities(model, state)
      group = model.find_entity_by_persistent_id(state["persistent_id"])
      return [] unless group.is_a?(Sketchup::Group) && group.valid?

      group.entities.to_a
    end

    def global_member_corners(group, vertices)
      transform = group.transformation
      vertices.map { |vertex| quantized_point(vertex.position.transform(transform)) }.sort
    end

    def validate_action_semantic_invariants(action, state, metadata)
      case action
      when "transform_entity"
        return [
          semantic_check(
            "action.persistent_id",
            metadata["target_persistent_id"],
            state["persistent_id"]
          ),
          semantic_check(
            "action.identity_fingerprint",
            metadata["before_identity_fingerprint"],
            state["identity_fingerprint"]
          ),
          semantic_check(
            "action.geometry_fingerprint",
            metadata["before_geometry_fingerprint"],
            state["geometry_fingerprint"]
          ),
          validate_numeric_array_expectation(
            "action.transformation",
            metadata["requested_transformation"],
            state["transformation"],
            SEMANTIC_QUANTUM
          )
        ]
      when "boolean_operation"
        tool_alive = entity_alive_by_pid?(Sketchup.active_model, metadata["tool_persistent_id"])
        target_alive = entity_alive_by_pid?(Sketchup.active_model, metadata["target_persistent_id"])
        return [
          semantic_check("action.tool_consumed", false, tool_alive),
          semantic_check("action.target_consumed", false, target_alive),
          semantic_check(
            "action.result_is_new",
            true,
            ![metadata["tool_persistent_id"], metadata["target_persistent_id"]].include?(state["persistent_id"])
          ),
          validate_boolean_volume_invariant(state, metadata)
        ]
      when "delete_entity"
        target_alive = entity_alive_by_pid?(Sketchup.active_model, metadata["target_persistent_id"])
        return [
          semantic_check("action.target_consumed", false, target_alive),
          semantic_check("action.deleted", true, state["deleted"]),
          semantic_check(
            "action.persistent_id",
            metadata["target_persistent_id"],
            state["persistent_id"]
          ),
          semantic_check("action.type", metadata["target_type"], state["type"])
        ]
      when "delete_topology_entity"
        target_alive = entity_alive_by_pid?(Sketchup.active_model, metadata["target_persistent_id"])
        return [
          semantic_check("action.topology_target_consumed", false, target_alive),
          semantic_check("action.deleted", true, state["deleted"]),
          semantic_check("action.persistent_id", metadata["target_persistent_id"], state["persistent_id"]),
          semantic_check("action.type", metadata["target_type"], state["type"])
        ]
      when "push_pull_topology_face"
        source_alive = entity_alive_by_pid?(Sketchup.active_model, metadata["target_persistent_id"])
        return [
          semantic_check("action.push_pull_source_survived", true, source_alive),
          semantic_check("action.persistent_id", metadata["target_persistent_id"], state["persistent_id"]),
          semantic_check("action.type", "Face", state["type"])
        ]
      when "group_entities"
        model = Sketchup.active_model
        input_ids = metadata["input_persistent_ids"] || []
        input_entities = input_ids.map do |persistent_id|
          model.find_entity_by_persistent_id(persistent_id)
        end
        input_alive = input_entities.all? do |entity|
          entity && entity.respond_to?(:valid?) && entity.valid?
        end
        expected_definition_guid = metadata["group_definition_guid"]
        parent_definition_ok = input_alive && input_entities.all? do |entity|
          parent = entity.respond_to?(:parent) ? entity.parent : nil
          parent.respond_to?(:guid) && parent.guid.to_s == expected_definition_guid
        end
        child_ids = if state.dig("hierarchy", "child_persistent_ids").is_a?(Array)
                      state.dig("hierarchy", "child_persistent_ids").sort
                    else
                      []
                    end
        semantics_ok = input_alive && input_entities.all? do |entity|
          before = metadata.fetch("input_fingerprints", {})[entity.persistent_id.to_s]
          next false unless before
          current = semantic_entity_state(model, entity)
          before["identity"] == current["identity_fingerprint"] &&
            before["reparent"] == grouping_reparent_fingerprint(entity, current)
        end
        bounds_min_check = validate_numeric_triplet_expectation(
          "action.composition_bounds_min",
          metadata["input_bounds_min"],
          state.dig("bounds", "min"),
          SEMANTIC_QUANTUM
        )
        bounds_max_check = validate_numeric_triplet_expectation(
          "action.composition_bounds_max",
          metadata["input_bounds_max"],
          state.dig("bounds", "max"),
          SEMANTIC_QUANTUM
        )
        return [
          semantic_check("action.input_pids_alive", true, input_alive),
          semantic_check("action.input_parent_definition", true, parent_definition_ok),
          semantic_check("action.group_children_exact", input_ids.sort, child_ids),
          semantic_check("action.input_semantics_preserved", true, semantics_ok),
          bounds_min_check,
          bounds_max_check,
          semantic_check(
            "action.result_is_new",
            true,
            !input_ids.include?(state["persistent_id"])
          )
        ]
      when "create_component"
        model = Sketchup.active_model
        input_ids = metadata["input_persistent_ids"] || []
        input_entities = input_ids.map do |persistent_id|
          model.find_entity_by_persistent_id(persistent_id)
        end
        input_alive = input_entities.all? do |entity|
          entity && entity.respond_to?(:valid?) && entity.valid?
        end
        expected_definition_guid = metadata["component_definition_guid"]
        parent_definition_ok = input_alive && input_entities.all? do |entity|
          parent = entity.respond_to?(:parent) ? entity.parent : nil
          parent.respond_to?(:guid) && parent.guid.to_s == expected_definition_guid
        end
        child_ids = if state.dig("hierarchy", "child_persistent_ids").is_a?(Array)
                      state.dig("hierarchy", "child_persistent_ids").sort
                    else
                      []
                    end
        semantics_ok = input_alive && input_entities.all? do |entity|
          before = metadata.fetch("input_fingerprints", {})[entity.persistent_id.to_s]
          next false unless before
          current = semantic_entity_state(model, entity)
          before["identity"] == current["identity_fingerprint"] &&
            before["reparent"] == grouping_reparent_fingerprint(entity, current)
        end
        bounds_min_check = validate_numeric_triplet_expectation(
          "action.composition_bounds_min",
          metadata["input_bounds_min"],
          state.dig("bounds", "min"),
          SEMANTIC_QUANTUM
        )
        bounds_max_check = validate_numeric_triplet_expectation(
          "action.composition_bounds_max",
          metadata["input_bounds_max"],
          state.dig("bounds", "max"),
          SEMANTIC_QUANTUM
        )
        return [
          semantic_check("action.input_pids_alive", true, input_alive),
          semantic_check("action.input_parent_definition", true, parent_definition_ok),
          semantic_check("action.component_children_exact", input_ids.sort, child_ids),
          semantic_check("action.input_semantics_preserved", true, semantics_ok),
          bounds_min_check,
          bounds_max_check,
          semantic_check(
            "action.component_definition_guid",
            expected_definition_guid,
            state.dig("definition", "guid")
          ),
          semantic_check(
            "action.result_is_new",
            true,
            !input_ids.include?(state["persistent_id"])
          )
        ]
      when "place_instance"
        model = Sketchup.active_model
        expected_definition_guid = metadata["component_definition_guid"]
        current_definition = semantic_definition_geometry_fingerprint(
          find_definition_by_guid(model, expected_definition_guid)
        )
        return [
          semantic_check(
            "action.definition_guid",
            expected_definition_guid,
            state.dig("definition", "guid")
          ),
          semantic_check(
            "action.definition_geometry_preserved",
            metadata["definition_geometry_before"],
            current_definition
          ),
          semantic_check(
            "action.definition_geometry_matches_state",
            metadata["definition_geometry_before"],
            state.dig("definition", "geometry_fingerprint")
          ),
          validate_numeric_array_expectation(
            "action.transformation",
            metadata["requested_transformation"],
            state["transformation"],
            SEMANTIC_QUANTUM
          )
        ]
      when "make_unique"
        model = Sketchup.active_model
        entity = model.find_entity_by_persistent_id(metadata["target_persistent_id"])
        current_guid = entity.respond_to?(:definition) ? entity.definition.guid.to_s : nil
        current_geometry = entity.respond_to?(:definition) ? semantic_definition_geometry_fingerprint(entity.definition) : nil
        return [
          semantic_check(
            "action.persistent_id",
            metadata["target_persistent_id"],
            state["persistent_id"]
          ),
          semantic_check(
            "action.definition_guid_changed",
            true,
            metadata["component_definition_guid_before"] != current_guid
          ),
          semantic_check(
            "action.definition_guid_matches_state",
            current_guid,
            state.dig("definition", "guid")
          ),
          semantic_check(
            "action.definition_geometry_preserved",
            metadata["definition_geometry_before"],
            current_geometry
          )
        ]
      when "copy_entity"
        model = Sketchup.active_model
        source_alive = entity_alive_by_pid?(model, metadata["source_persistent_id"])
        shares = if state["type"] == "ComponentInstance"
                   !metadata["source_definition_guid"].nil? &&
                     state.dig("definition", "guid") == metadata["source_definition_guid"]
                 else
                   state["geometry_fingerprint"] == metadata["source_geometry_fingerprint"]
                 end
        copy_entity = model.find_entity_by_persistent_id(state["persistent_id"])
        properties_preserved = copy_entity &&
                               copyable_instance_properties(copy_entity) == metadata["source_instance_properties"]
        return [
          semantic_check(
            "action.copy_is_new",
            true,
            state["persistent_id"] != metadata["source_persistent_id"]
          ),
          semantic_check("action.source_alive", true, source_alive),
          semantic_check(
            "action.copy_transform_same",
            metadata["source_transformation"],
            state["transformation"]
          ),
          semantic_check("action.copy_shares_source", true, shares),
          semantic_check("action.copy_properties_preserved", true, properties_preserved)
        ]
      when "linear_array", "radial_array"
        model = Sketchup.active_model
        copy_ids = metadata["copy_persistent_ids"] || []
        requested = metadata["requested_transformations"] || []
        copies = copy_ids.map { |persistent_id| model.find_entity_by_persistent_id(persistent_id) }
        copies_alive = copies.all? { |entity| entity && entity.respond_to?(:valid?) && entity.valid? }
        transforms_ok = copies_alive && copies.each_with_index.all? do |entity, index|
          current = semantic_entity_state(model, entity)
          current["transformation"] == requested[index]
        end
        shares_ok = copies_alive && copies.all? do |entity|
          current = semantic_entity_state(model, entity)
          if current["type"] == "ComponentInstance"
            !metadata["source_definition_guid"].nil? &&
              current.dig("definition", "guid") == metadata["source_definition_guid"]
          else
            current["geometry_fingerprint"] == metadata["source_geometry_fingerprint"]
          end
        end
        properties_ok = copies_alive && copies.all? do |entity|
          copyable_instance_properties(entity) == metadata["source_instance_properties"]
        end
        return [
          semantic_check("action.array_count_exact", metadata["count"], copy_ids.length),
          semantic_check("action.copies_alive", true, copies_alive),
          semantic_check("action.array_transforms_exact", true, transforms_ok),
          semantic_check("action.array_shares_source", true, shares_ok),
          semantic_check("action.array_properties_preserved", true, properties_ok),
          semantic_check(
            "action.result_is_new",
            true,
            !copy_ids.include?(metadata["source_persistent_id"])
          )
        ]
      when "tag_assign"
        return [
          semantic_check(
            "action.assign_same_pid",
            metadata["target_persistent_id"],
            state["persistent_id"]
          ),
          semantic_check(
            "action.tag_applied",
            metadata["requested_tag"],
            state["tag"]
          ),
          semantic_check(
            "action.geometry_preserved",
            metadata["before_geometry_fingerprint"],
            state["geometry_fingerprint"]
          ),
          semantic_check(
            "action.transform_unchanged",
            metadata["before_transformation"],
            state["transformation"]
          )
        ]
      when "material_assign"
        applied = if metadata["requested_side"] == "back"
                    state["back_material"]
                  else
                    state["material"]
                  end
        return [
          semantic_check(
            "action.assign_same_pid",
            metadata["target_persistent_id"],
            state["persistent_id"]
          ),
          semantic_check(
            "action.material_applied",
            metadata["requested_material"],
            applied
          ),
          semantic_check(
            "action.geometry_preserved",
            metadata["before_geometry_fingerprint"],
            state["geometry_fingerprint"]
          ),
          semantic_check(
            "action.transform_unchanged",
            metadata["before_transformation"],
            state["transformation"]
          )
        ]
      when "create_polyline"
        model = Sketchup.active_model
        members = group_member_entities(model, state)
        edges = members.grep(Sketchup::Edge)
        actual_length = edges.sum(&:length)
        length_tolerance = [metadata["total_length"].abs * 1e-9, SEMANTIC_QUANTUM].max
        faces = members.grep(Sketchup::Face)
        face_ok = if metadata["face_expected"]
                    faces.length == 1 &&
                      (faces.first.area - metadata["face_area"]).abs <=
                        [metadata["face_area"].abs * 1e-9, SEMANTIC_QUANTUM].max
                  else
                    faces.empty?
                  end
        return [
          semantic_check(
            "action.total_length_exact",
            true,
            (actual_length - metadata["total_length"]).abs <= length_tolerance
          ),
          semantic_check("action.face_exact", true, face_ok),
          semantic_check(
            "action.result_is_new",
            true,
            state["type"] == "Group"
          )
        ]
      when "create_rectangle"
        model = Sketchup.active_model
        members = group_member_entities(model, state)
        group = model.find_entity_by_persistent_id(state["persistent_id"])
        face = members.grep(Sketchup::Face).first
        face_corners = face ? global_member_corners(group, face.vertices) : []
        corners_ok = face && face_corners == metadata["corners"].sort
        area_tolerance = [metadata["rectangle_area"].abs * 1e-9, SEMANTIC_QUANTUM].max
        face_area = face ? face.area : nil
        return [
          semantic_check("action.face_single", true, members.grep(Sketchup::Face).length == 1),
          semantic_check("action.corners_exact", true, corners_ok),
          semantic_check(
            "action.rectangle_area_exact",
            true,
            !face_area.nil? && (face_area - metadata["rectangle_area"]).abs <= area_tolerance
          )
        ]
      when "create_circle"
        model = Sketchup.active_model
        members = group_member_entities(model, state)
        group = model.find_entity_by_persistent_id(state["persistent_id"])
        vertices = members.grep(Sketchup::Edge).flat_map { |edge| [edge.start, edge.end] }.uniq
        transform = group.is_a?(Sketchup::Group) ? group.transformation : nil
        return [
          semantic_check(
            "action.radius_exact",
            true,
            curve_vertices_on_radius?(vertices, metadata["center"], metadata["radius"], transform)
          )
        ]
      when "create_arc"
        model = Sketchup.active_model
        members = group_member_entities(model, state)
        group = model.find_entity_by_persistent_id(state["persistent_id"])
        vertices = members.grep(Sketchup::Edge).flat_map { |edge| [edge.start, edge.end] }.uniq
        center = metadata["center"]
        group_transform = group.is_a?(Sketchup::Group) ? group.transformation : nil
        global_points = vertices.map do |vertex|
          point = group_transform ? vertex.position.transform(group_transform) : vertex.position
          [point.x, point.y, point.z]
        end
        xaxis = Geom::Vector3d.new(metadata["xaxis"][0], metadata["xaxis"][1], metadata["xaxis"][2])
        normal = Geom::Vector3d.new(metadata["normal"][0], metadata["normal"][1], metadata["normal"][2])
        v_axis = (normal * xaxis).normalize
        angles = global_points.map do |point|
          direction = Geom::Vector3d.new(
            point[0] - center[0],
            point[1] - center[1],
            point[2] - center[2]
          )
          Math.atan2(direction.dot(v_axis), direction.dot(xaxis)) * 180.0 / Math::PI
        end
        endpoints_ok = [metadata["start_degrees"], metadata["end_degrees"]].all? do |target|
          angles.any? { |angle| angular_difference_degrees(angle, target).abs <= 1e-6 }
        end
        return [
          semantic_check(
            "action.radius_exact",
            true,
            curve_vertices_on_radius?(vertices, center, metadata["radius"], group_transform)
          ),
          semantic_check("action.arc_endpoints_exact", true, endpoints_ok)
        ]
      when "create_polygon"
        model = Sketchup.active_model
        members = group_member_entities(model, state)
        group = model.find_entity_by_persistent_id(state["persistent_id"])
        face = members.grep(Sketchup::Face).first
        vertices = face ? face.vertices : []
        transform = group.is_a?(Sketchup::Group) ? group.transformation : nil
        area_tolerance = [metadata["polygon_area"].abs * 1e-9, SEMANTIC_QUANTUM].max
        face_area = face ? face.area : nil
        return [
          semantic_check("action.face_single", true, members.grep(Sketchup::Face).length == 1),
          semantic_check(
            "action.radius_exact",
            true,
            curve_vertices_on_radius?(vertices, metadata["center"], metadata["radius"], transform)
          ),
          semantic_check(
            "action.polygon_area_exact",
            true,
            !face_area.nil? && (face_area - metadata["polygon_area"]).abs <= area_tolerance
          )
        ]
      when "sweep_profile"
        model = Sketchup.active_model
        input_ids = metadata["input_persistent_ids"] || []
        consumed_ids = metadata["consumed_persistent_ids"] || []
        reparented_ids = metadata["reparented_persistent_ids"] || []
        edge_lengths = metadata["edge_lengths"] || {}
        face_entity = model.find_entity_by_persistent_id(metadata["face_pid"])
        face_ok = if face_entity && face_entity.respond_to?(:valid?) && face_entity.valid?
                    parent = face_entity.respond_to?(:parent) ? face_entity.parent : nil
                    parent.respond_to?(:guid) &&
                      parent.guid.to_s == metadata["sweep_definition_guid"] &&
                      (quantize_number(face_entity.area) - metadata["face_area"]).abs <=
                        [metadata["face_area"].abs * 1e-9, SEMANTIC_QUANTUM].max
                  else
                    consumed_ids.include?(metadata["face_pid"])
                  end
        no_collateral = (consumed_ids - input_ids).empty?
        reparented_ok = reparented_ids.all? do |persistent_id|
          entity = model.find_entity_by_persistent_id(persistent_id)
          next false unless entity && entity.respond_to?(:valid?) && entity.valid?
          parent = entity.respond_to?(:parent) ? entity.parent : nil
          parent.respond_to?(:guid) && parent.guid.to_s == metadata["sweep_definition_guid"]
        end
        lengths_ok = reparented_ids.all? do |persistent_id|
          entity = model.find_entity_by_persistent_id(persistent_id)
          next true unless entity.is_a?(Sketchup::Edge)
          expected = edge_lengths[persistent_id.to_s]
          !expected.nil? && (quantize_number(entity.length) - expected).abs <=
            [expected.abs * 1e-9, SEMANTIC_QUANTUM].max
        end
        child_ids = if state.dig("hierarchy", "child_persistent_ids").is_a?(Array)
                      state.dig("hierarchy", "child_persistent_ids").sort
                    else
                      []
                    end
        children_cover_reparented = (reparented_ids - child_ids).empty?
        volume = state["volume"]
        return [
          semantic_check("action.profile_accounted", true, face_ok),
          semantic_check("action.no_collateral_consumed", true, no_collateral),
          semantic_check("action.inputs_reparented", true, reparented_ok),
          semantic_check("action.sweep_children_cover_inputs", true, children_cover_reparented),
          semantic_check("action.lengths_preserved", true, lengths_ok),
          semantic_check("action.sweep_manifold", true, state["manifold"] == true),
          semantic_check("action.sweep_volume_positive", true, !volume.nil? && volume > 0),
          semantic_check(
            "action.result_is_new",
            true,
            !input_ids.include?(state["persistent_id"])
          )
        ]
      when "place_asset"
        return [
          validate_numeric_array_expectation(
            "action.asset_transform_exact",
            metadata["requested_transformation"],
            state["transformation"],
            SEMANTIC_QUANTUM
          )
        ]
      when "camera_set"
        tolerance = SEMANTIC_QUANTUM
        eye_ok = validate_numeric_triplet_expectation(
          "action.camera_eye", metadata["requested_eye"], state["camera_eye"], tolerance
        )["passed"]
        target_ok = validate_numeric_triplet_expectation(
          "action.camera_target", metadata["requested_target"], state["camera_target"], tolerance
        )["passed"]
        return [
          semantic_check("action.camera_eye_exact", true, eye_ok),
          semantic_check("action.camera_target_exact", true, target_ok),
          semantic_check("action.camera_up_orthogonal", true, metadata["up_orthogonal"]),
          semantic_check(
            "action.camera_fov_exact",
            true,
            (state["camera_fov"] - metadata["requested_fov"]).abs <= 1e-9
          )
        ]
      when "scene_create"
        return [
          semantic_check(
            "action.scene_created",
            metadata["requested_name"],
            state["scene_name"]
          ),
          semantic_check(
            "action.scene_count_incremented",
            metadata["before_count"] + 1,
            state["scene_count"]
          )
        ]
      when "material_apply_texture"
        width_ok = state["texture_width"] == metadata["requested_width"] &&
          state["texture_height"] == metadata["requested_height"]
        return [
          semantic_check(
            "action.texture_dims_exact",
            true,
            width_ok
          ),
          semantic_check(
            "action.texture_material_same",
            metadata["material"],
            state["material"]
          )
        ]
      when "repair_reverse_face"
        before = metadata["before_normal"]
        after = state["normal"]
        flipped = !before.nil? && !after.nil? &&
          (before[0] + after[0]).abs <= SEMANTIC_QUANTUM &&
          (before[1] + after[1]).abs <= SEMANTIC_QUANTUM &&
          (before[2] + after[2]).abs <= SEMANTIC_QUANTUM
        return [
          semantic_check(
            "action.face_reversed",
            true,
            flipped
          ),
          semantic_check(
            "action.repair_same_pid",
            metadata["target_persistent_id"],
            state["persistent_id"]
          ),
          semantic_check(
            "action.repair_area_same",
            metadata["before_area"],
            state["area"]
          )
        ]
      when "repair_erase_degenerate"
        target_alive = entity_alive_by_pid?(Sketchup.active_model, metadata["target_persistent_id"])
        return [
          semantic_check("action.degenerate_erased", false, target_alive),
          semantic_check("action.deleted", true, state["deleted"]),
          semantic_check(
            "action.repair_same_pid",
            metadata["target_persistent_id"],
            state["persistent_id"]
          )
        ]
      end
      []
    end

    def validate_action_affected_invariants(action, state, metadata, affected)
      case action
      when "delete_topology_entity"
        closure_ids = (metadata["topology_closure_persistent_ids"] || []).sort
        touched_ids = (affected["modified"] + affected["deleted"]).uniq.sort
        within_closure = (touched_ids - closure_ids).empty?
        return [
          semantic_check("affected.topology_no_created", [], affected["created"]),
          semantic_check("affected.topology_within_closure", true, within_closure),
          semantic_check(
            "affected.topology_target_deleted",
            true,
            affected["deleted"].include?(metadata["target_persistent_id"])
          )
        ]
      when "push_pull_topology_face"
        before_ids = (metadata["before_topology_closure_persistent_ids"] || []).sort
        after_ids = (metadata["after_topology_closure_persistent_ids"] || []).sort
        old_touched = (affected["modified"] + affected["deleted"]).uniq.sort
        old_within_preclosure = (old_touched - before_ids).empty?
        new_within_postclosure = (affected["created"] - after_ids).empty?
        return [
          semantic_check("affected.push_pull_old_within_preclosure", true, old_within_preclosure),
          semantic_check("affected.push_pull_new_within_postclosure", true, new_within_postclosure),
          semantic_check(
            "affected.push_pull_source_not_deleted",
            false,
            affected["deleted"].include?(metadata["target_persistent_id"])
          )
        ]
      when "group_entities", "create_component"
        input_ids = (metadata["input_persistent_ids"] || []).sort
        return [
          semantic_check("affected.created", [state["persistent_id"]], affected["created"]),
          semantic_check("affected.modified", input_ids, affected["modified"]),
          semantic_check("affected.deleted", [], affected["deleted"])
        ]
      when "make_unique"
        return [
          semantic_check("affected.created", [], affected["created"]),
          semantic_check("affected.modified", [state["persistent_id"]], affected["modified"]),
          semantic_check("affected.deleted", [], affected["deleted"])
        ]
      when "copy_entity"
        return [
          semantic_check("affected.created", [state["persistent_id"]], affected["created"]),
          semantic_check("affected.modified", [], affected["modified"]),
          semantic_check("affected.deleted", [], affected["deleted"])
        ]
      when "linear_array", "radial_array"
        copy_ids = (metadata["copy_persistent_ids"] || []).sort
        return [
          semantic_check("affected.created", copy_ids, affected["created"]),
          semantic_check("affected.modified", [], affected["modified"]),
          semantic_check("affected.deleted", [], affected["deleted"])
        ]
      when "tag_assign", "material_assign"
        return [
          semantic_check("affected.created", [], affected["created"]),
          semantic_check("affected.modified", [state["persistent_id"]], affected["modified"]),
          semantic_check("affected.deleted", [], affected["deleted"])
        ]
      when "create_polyline", "create_circle", "create_arc", "create_rectangle", "create_polygon"
        return [
          semantic_check("affected.created", [state["persistent_id"]], affected["created"]),
          semantic_check("affected.modified", [], affected["modified"]),
          semantic_check("affected.deleted", [], affected["deleted"])
        ]
      when "sweep_profile"
        consumed_ids = ((metadata["consumed_persistent_ids"] || []).sort)
        reparented_ids = ((metadata["reparented_persistent_ids"] || []).sort)
        return [
          semantic_check("affected.created", [state["persistent_id"]], affected["created"]),
          semantic_check("affected.modified", reparented_ids, affected["modified"]),
          semantic_check("affected.deleted", consumed_ids, affected["deleted"])
        ]
      when "place_asset", "place_instance"
        return [
          semantic_check("affected.created", [state["persistent_id"]], affected["created"]),
          semantic_check("affected.modified", [], affected["modified"]),
          semantic_check("affected.deleted", [], affected["deleted"])
        ]
      when "material_apply_texture"
        return [
          semantic_check("affected.created", [], affected["created"]),
          semantic_check("affected.modified", [], affected["modified"]),
          semantic_check("affected.deleted", [], affected["deleted"])
        ]
      when "camera_set", "scene_create"
        return [
          semantic_check("affected.created", [], affected["created"]),
          semantic_check("affected.modified", [], affected["modified"]),
          semantic_check("affected.deleted", [], affected["deleted"])
        ]
      when "repair_reverse_face"
        return [
          semantic_check("affected.created", [], affected["created"]),
          semantic_check("affected.modified", [state["persistent_id"]], affected["modified"]),
          semantic_check("affected.deleted", [], affected["deleted"])
        ]
      when "repair_erase_degenerate"
        return [
          semantic_check("affected.created", [], affected["created"]),
          semantic_check("affected.modified", [], affected["modified"]),
          semantic_check("affected.deleted", [state["persistent_id"]], affected["deleted"])
        ]
      end
      []
    end

    def validate_semantic_expectation_schema(expect, require_active_entity_delta: true)
      unknown_expect_keys = expect.keys - SEMANTIC_EXPECT_KEYS
      unless unknown_expect_keys.empty?
        raise BridgeError.new(
          "invalid_argument",
          "expect contains unsupported keys: #{unknown_expect_keys.sort.join(', ')}"
        )
      end

      if require_active_entity_delta && !expect.key?("active_entity_delta")
        raise BridgeError.new(
          "invalid_argument",
          "expect.active_entity_delta is required"
        )
      end

      validation_keys = expect.keys - ["tolerance", "active_entity_delta"]
      if validation_keys.empty?
        raise BridgeError.new(
          "invalid_argument",
          "expect must contain at least one entity semantic validation field"
        )
      end
      true
    end

    def validate_semantic_expectation(
      state,
      expect,
      before_count:,
      after_count:,
      check_active_entity_delta: true
    )
      tolerance = expect.key?("tolerance") ? finite_number(expect["tolerance"], "expect.tolerance") : 1e-6
      if tolerance.negative?
        raise BridgeError.new("invalid_argument", "expect.tolerance must be non-negative")
      end
      area_tolerance = [tolerance * tolerance, SEMANTIC_QUANTUM].max
      volume_tolerance = [tolerance * tolerance * tolerance, SEMANTIC_QUANTUM].max
      checks = []

      if check_active_entity_delta
        checks << semantic_check(
          "active_entity_delta",
          Integer(expect["active_entity_delta"]),
          after_count - before_count
        )
      end

      if expect.key?("deleted")
        unless expect["deleted"] == true || expect["deleted"] == false
          raise BridgeError.new("invalid_argument", "expect.deleted must be boolean")
        end
        checks << semantic_check("deleted", expect["deleted"], state["deleted"])
      end
      if expect.key?("type")
        checks << semantic_check("type", expect["type"].to_s, state["type"])
      end
      if expect.key?("child_persistent_ids")
        expected_children = normalize_expected_pid_set(
          expect["child_persistent_ids"],
          "expect.child_persistent_ids"
        )
        actual_children = state.dig("hierarchy", "child_persistent_ids")
        checks << semantic_check(
          "child_persistent_ids",
          expected_children,
          actual_children.is_a?(Array) ? actual_children.sort : actual_children
        )
      end
      if expect.key?("bounds_min")
        checks << validate_numeric_triplet_expectation(
          "bounds_min",
          expect["bounds_min"],
          state.dig("bounds", "min"),
          tolerance
        )
      end
      if expect.key?("bounds_max")
        checks << validate_numeric_triplet_expectation(
          "bounds_max",
          expect["bounds_max"],
          state.dig("bounds", "max"),
          tolerance
        )
      end
      if expect.key?("bounds_size")
        checks << validate_numeric_triplet_expectation(
          "bounds_size",
          expect["bounds_size"],
          state.dig("bounds", "size"),
          tolerance
        )
      end
      if expect.key?("vertex_count")
        checks << semantic_check("vertex_count", Integer(expect["vertex_count"]), state["vertex_count"])
      end
      if expect.key?("face_count")
        checks << semantic_check("face_count", Integer(expect["face_count"]), state["face_count"])
      end
      if expect.key?("edge_count")
        checks << semantic_check("edge_count", Integer(expect["edge_count"]), state["edge_count"])
      end
      if expect.key?("vertex_count")
        checks << semantic_check("vertex_count", Integer(expect["vertex_count"]), state["vertex_count"])
      end
      if expect.key?("area")
        checks << validate_numeric_expectation(
          "area",
          expect["area"],
          state["area"],
          area_tolerance
        )
      end
      if expect.key?("normal")
        checks << validate_numeric_triplet_expectation(
          "normal",
          expect["normal"],
          state["normal"],
          tolerance
        )
      end
      if expect.key?("manifold")
        unless expect["manifold"] == true || expect["manifold"] == false
          raise BridgeError.new("invalid_argument", "expect.manifold must be boolean")
        end
        checks << semantic_check("manifold", expect["manifold"], state["manifold"])
      end
      if expect.key?("volume")
        checks << validate_numeric_expectation(
          "volume",
          expect["volume"],
          state["volume"],
          volume_tolerance
        )
      end
      if expect.key?("transformation")
        checks << validate_transformation_expectation(
          "transformation",
          expect["transformation"],
          state["transformation"],
          tolerance
        )
      end
      if expect.key?("tag")
        checks << semantic_check("tag", expect["tag"].to_s, state["tag"])
      end
      if expect.key?("material")
        checks << semantic_check("material", expect["material"].to_s, state["material"])
      end
      if expect.key?("camera_eye")
        checks << validate_numeric_triplet_expectation(
          "camera_eye",
          expect["camera_eye"],
          state["camera_eye"],
          tolerance
        )
      end
      if expect.key?("camera_target")
        checks << validate_numeric_triplet_expectation(
          "camera_target",
          expect["camera_target"],
          state["camera_target"],
          tolerance
        )
      end
      if expect.key?("camera_fov")
        checks << validate_numeric_expectation(
          "camera_fov",
          expect["camera_fov"],
          state["camera_fov"],
          SEMANTIC_QUANTUM
        )
      end
      if expect.key?("scene_name")
        checks << semantic_check("scene_name", expect["scene_name"].to_s, state["scene_name"])
      end
      if expect.key?("definition_guid")
        checks << semantic_check(
          "definition_guid",
          expect["definition_guid"].to_s,
          state.dig("definition", "guid")
        )
      end
      if expect.key?("definition_name")
        checks << semantic_check(
          "definition_name",
          expect["definition_name"].to_s,
          state.dig("hierarchy", "definition_name")
        )
      end

      {
        "passed" => checks.all? { |check| check["passed"] },
        "checks" => checks
      }
    rescue ArgumentError, TypeError
      raise BridgeError.new("invalid_argument", "semantic validation contains invalid integer")
    end

    def normalize_expected_pid_set(value, name)
      unless value.is_a?(Array) && value.length.between?(1, MAX_OBJECTS)
        raise BridgeError.new(
          "invalid_argument",
          "#{name} must contain 1..#{MAX_OBJECTS} persistent IDs"
        )
      end
      persistent_ids = value.each_with_index.map do |item, index|
        bounded_integer(
          item,
          minimum: 1,
          maximum: (2**63) - 1,
          name: "#{name}[#{index}]"
        )
      end
      if persistent_ids.uniq.length != persistent_ids.length
        raise BridgeError.new("invalid_argument", "#{name} must not contain duplicates")
      end
      persistent_ids.sort
    end

    def numeric_array(value, length, name)
      unless value.is_a?(Array) && value.length == length
        raise BridgeError.new("invalid_argument", "#{name} must contain exactly #{length} numbers")
      end
      value.map.with_index do |item, index|
        finite_number(item, "#{name}[#{index}]")
      end
    end

    def validate_transformation_expectation(field, expected_value, actual_value, length_tolerance)
      expected = numeric_array(expected_value, 16, "expect.#{field}")
      passed = actual_value.is_a?(Array) && actual_value.length == 16
      if passed
        passed = expected.zip(actual_value).each_with_index.all? do |(expected_item, actual_item), index|
          tolerance = [12, 13, 14].include?(index) ? length_tolerance : SEMANTIC_QUANTUM
          (expected_item - actual_item).abs <= tolerance
        end
      end
      {
        "field" => field,
        "expected" => expected,
        "actual" => actual_value,
        "passed" => !!passed
      }
    end

    def validate_numeric_array_expectation(field, expected_value, actual_value, tolerance)
      expected = numeric_array(expected_value, 16, "expect.#{field}")
      passed = actual_value.is_a?(Array) &&
        actual_value.length == 16 &&
        expected.zip(actual_value).all? do |expected_item, actual_item|
          (expected_item - actual_item).abs <= tolerance
        end
      {
        "field" => field,
        "expected" => expected,
        "actual" => actual_value,
        "passed" => !!passed
      }
    end

    def validate_numeric_expectation(field, expected_value, actual_value, tolerance)
      expected = finite_number(expected_value, "expect.#{field}")
      passed = !actual_value.nil? && (expected - actual_value).abs <= tolerance
      {
        "field" => field,
        "expected" => expected,
        "actual" => actual_value,
        "passed" => !!passed
      }
    end

    def validate_numeric_triplet_expectation(field, expected_value, actual_value, tolerance)
      expected = numeric_triplet(expected_value, "expect.#{field}")
      passed = actual_value && expected.zip(actual_value).all? do |expected_item, actual_item|
        (expected_item - actual_item).abs <= tolerance
      end
      {
        "field" => field,
        "expected" => expected,
        "actual" => actual_value,
        "passed" => !!passed
      }
    end

    def semantic_check(field, expected, actual)
      {
        "field" => field,
        "expected" => expected,
        "actual" => actual,
        "passed" => expected == actual
      }
    end
  end
end
