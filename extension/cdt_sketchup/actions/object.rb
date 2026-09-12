# cdt_sketchup/actions/object.rb — strict delete/group/compose/duplicate/repair actions
# Wing: code | Topic: sketchup_bridge | Updated: 2026-09-12

module CDTSketchUp
  class BridgeServer
    private

    def validate_create_component_params(params)
      unless params.is_a?(Hash)
        raise BridgeError.new("invalid_argument", "create_component params must be an object")
      end
      unknown_component_keys = params.keys - CREATE_COMPONENT_PARAM_KEYS
      unless unknown_component_keys.empty?
        raise BridgeError.new(
          "invalid_argument",
          "create_component params contain unsupported keys: #{unknown_component_keys.sort.join(', ')}"
        )
      end
      raw_ids = params["persistent_ids"]
      unless raw_ids.is_a?(Array) && raw_ids.length.between?(1, MAX_OBJECTS)
        raise BridgeError.new(
          "invalid_argument",
          "persistent_ids must contain 1..#{MAX_OBJECTS} ids"
        )
      end
      persistent_ids = raw_ids.each_with_index.map do |value, index|
        bounded_integer(
          value,
          minimum: 1,
          maximum: (2**63) - 1,
          name: "persistent_ids[#{index}]"
        )
      end
      if persistent_ids.uniq.length != persistent_ids.length
        raise BridgeError.new("invalid_argument", "persistent_ids must not contain duplicates")
      end

      name = params["name"]
      if name && (!name.is_a?(String) || name.length > 128)
        raise BridgeError.new("invalid_argument", "name must be a string up to 128 characters")
      end
      [persistent_ids, name]
    end

    def preflight_create_component(model, params)
      persistent_ids, = validate_create_component_params(params)
      entities = persistent_ids.map { |value| require_active_entity(model, value) }
      unless entities.all? { |entity| groupable_entity?(entity) }
        raise BridgeError.new(
          "unsupported_object_type",
          "create_component supports only edges, faces, groups, and component instances"
        )
      end
      if entities.any? { |entity| entity.respond_to?(:locked?) && entity.locked? }
        raise BridgeError.new("locked_object", "create_component targets must be unlocked")
      end
      complete_groupable_connected_geometry?(entities)
      true
    end

    def execute_create_component(model, params)
      persistent_ids, name = validate_create_component_params(params)
      entities = persistent_ids.map { |value| require_active_entity(model, value) }
      input_states = entities.map do |entity|
        [entity, semantic_entity_state(model, entity)]
      end
      input_fingerprints = input_states.each_with_object({}) do |(entity, state), result|
        result[entity.persistent_id.to_s] = {
          "identity" => state["identity_fingerprint"],
          "geometry" => state["geometry_fingerprint"],
          "reparent" => grouping_reparent_fingerprint(entity, state)
        }
      end
      input_bounds = aggregate_semantic_bounds(input_states.map { |_entity, state| state })

      group = begin
        model.active_entities.add_group(entities)
      rescue ArgumentError, RuntimeError => error
        log("create component failed: #{error.class}: #{error.message}")
        raise BridgeError.new("component_failed", "SketchUp did not group the requested entities")
      end
      unless group && group.valid? && group.is_a?(Sketchup::Group)
        raise BridgeError.new("component_failed", "SketchUp did not produce a group")
      end
      instance = begin
        group.to_component
      rescue StandardError => error
        log("create component failed: #{error.class}: #{error.message}")
        raise BridgeError.new("component_failed", "SketchUp did not convert the group to a component")
      end
      unless instance && instance.valid? && instance.is_a?(Sketchup::ComponentInstance)
        raise BridgeError.new("component_failed", "SketchUp did not produce a component instance")
      end
      instance.name = name if name && !name.empty?

      {
        "entity" => instance,
        "metadata" => {
          "input_persistent_ids" => persistent_ids.sort,
          "input_fingerprints" => input_fingerprints,
          "input_bounds_min" => input_bounds["min"],
          "input_bounds_max" => input_bounds["max"],
          "component_definition_guid" => instance.definition.guid.to_s
        }
      }
    end

    def validate_repair_pid_params(params, keys, action)
      unless params.is_a?(Hash)
        raise BridgeError.new("invalid_argument", "#{action} params must be an object")
      end
      unknown_keys = params.keys - keys
      unless unknown_keys.empty?
        raise BridgeError.new(
          "invalid_argument",
          "#{action} params contain unsupported keys: #{unknown_keys.sort.join(', ')}"
        )
      end
      unless params.key?("persistent_id")
        raise BridgeError.new("invalid_argument", "#{action} persistent_id is required")
      end
      bounded_integer(params["persistent_id"], minimum: 1, maximum: (2**63) - 1, name: "persistent_id")
    end

    def preflight_repair_reverse_face(model, params)
      persistent_id = validate_repair_pid_params(params, REVERSE_FACE_PARAM_KEYS, "repair_reverse_face")
      entity = require_active_entity(model, persistent_id)
      unless entity.is_a?(Sketchup::Face)
        raise BridgeError.new("unsupported_object_type", "repair_reverse_face targets only faces")
      end
      true
    end

    def preflight_repair_erase_degenerate(model, params)
      persistent_id = validate_repair_pid_params(params, ERASE_DEGENERATE_PARAM_KEYS, "repair_erase_degenerate")
      entity = require_active_entity(model, persistent_id)
      unless entity.is_a?(Sketchup::Edge)
        raise BridgeError.new("unsupported_object_type", "repair_erase_degenerate targets only edges")
      end
      unless entity.length.to_f <= SEMANTIC_QUANTUM
        raise BridgeError.new("invalid_argument", "repair target is not a degenerate edge")
      end
      unless entity.faces.empty?
        raise BridgeError.new("unsupported_object_type", "degenerate edge bounds faces")
      end
      true
    end

    def execute_repair_reverse_face(model, params)
      persistent_id = validate_repair_pid_params(params, REVERSE_FACE_PARAM_KEYS, "repair_reverse_face")
      entity = require_active_entity(model, persistent_id)
      unless entity.is_a?(Sketchup::Face)
        raise BridgeError.new("unsupported_object_type", "repair_reverse_face targets only faces")
      end
      before_normal = vector_to_triplet(entity.normal)
      before_area = quantize_number(entity.area)
      begin
        entity.reverse!
      rescue StandardError => error
        log("reverse face failed: #{error.class}: #{error.message}")
        raise BridgeError.new("repair_failed", "SketchUp did not reverse the face")
      end
      {
        "entity" => entity,
        "metadata" => {
          "target_persistent_id" => persistent_id,
          "before_normal" => before_normal,
          "before_area" => before_area
        }
      }
    end

    def execute_repair_erase_degenerate(model, params)
      persistent_id = validate_repair_pid_params(params, ERASE_DEGENERATE_PARAM_KEYS, "repair_erase_degenerate")
      entity = require_active_entity(model, persistent_id)
      unless entity.is_a?(Sketchup::Edge)
        raise BridgeError.new("unsupported_object_type", "repair_erase_degenerate targets only edges")
      end
      unless entity.length.to_f <= SEMANTIC_QUANTUM
        raise BridgeError.new("invalid_argument", "repair target is not a degenerate edge")
      end
      unless entity.faces.empty?
        raise BridgeError.new("unsupported_object_type", "degenerate edge bounds faces")
      end
      begin
        model.active_entities.erase_entities(entity)
      rescue ArgumentError, RuntimeError => error
        log("erase degenerate failed: #{error.class}: #{error.message}")
        raise BridgeError.new("repair_failed", "SketchUp did not erase the degenerate edge")
      end
      if entity_alive_by_pid?(model, persistent_id)
        raise BridgeError.new("repair_failed", "Degenerate edge persistent ID still resolves")
      end
      {
        "state" => {
          "persistent_id" => persistent_id,
          "type" => "Edge",
          "valid" => false,
          "active_context" => false,
          "deleted" => true
        },
        "metadata" => { "target_persistent_id" => persistent_id }
      }
    end

    def validate_copy_entity_params(params)
      unless params.is_a?(Hash)
        raise BridgeError.new("invalid_argument", "copy_entity params must be an object")
      end
      unknown_copy_keys = params.keys - COPY_ENTITY_PARAM_KEYS
      unless unknown_copy_keys.empty?
        raise BridgeError.new(
          "invalid_argument",
          "copy_entity params contain unsupported keys: #{unknown_copy_keys.sort.join(', ')}"
        )
      end
      unless params.key?("persistent_id")
        raise BridgeError.new("invalid_argument", "copy_entity persistent_id is required")
      end
      bounded_integer(params["persistent_id"], minimum: 1, maximum: (2**63) - 1, name: "persistent_id")
    end

    def validate_array_count(value)
      count = begin
        Integer(value)
      rescue ArgumentError, TypeError
        raise BridgeError.new("invalid_argument", "array count must contain 1..100 copies")
      end
      unless count.between?(1, MAX_ARRAY_COPIES)
        raise BridgeError.new("invalid_argument", "array count must contain 1..100 copies")
      end
      count
    end

    def validate_linear_array_params(params)
      unless params.is_a?(Hash)
        raise BridgeError.new("invalid_argument", "linear_array params must be an object")
      end
      unknown_linear_keys = params.keys - LINEAR_ARRAY_PARAM_KEYS
      unless unknown_linear_keys.empty?
        raise BridgeError.new(
          "invalid_argument",
          "linear_array params contain unsupported keys: #{unknown_linear_keys.sort.join(', ')}"
        )
      end
      unless params.key?("persistent_id")
        raise BridgeError.new("invalid_argument", "linear_array persistent_id is required")
      end
      persistent_id = bounded_integer(params["persistent_id"], minimum: 1, maximum: (2**63) - 1, name: "persistent_id")
      vector = numeric_triplet(params["vector"], "vector")
      count = validate_array_count(params["count"])
      [persistent_id, vector, count]
    end

    def validate_radial_array_params(params)
      unless params.is_a?(Hash)
        raise BridgeError.new("invalid_argument", "radial_array params must be an object")
      end
      unknown_radial_keys = params.keys - RADIAL_ARRAY_PARAM_KEYS
      unless unknown_radial_keys.empty?
        raise BridgeError.new(
          "invalid_argument",
          "radial_array params contain unsupported keys: #{unknown_radial_keys.sort.join(', ')}"
        )
      end
      unless params.key?("persistent_id")
        raise BridgeError.new("invalid_argument", "radial_array persistent_id is required")
      end
      persistent_id = bounded_integer(params["persistent_id"], minimum: 1, maximum: (2**63) - 1, name: "persistent_id")
      origin = numeric_triplet(params["axis_origin"], "axis_origin")
      axis = numeric_triplet(params["axis"], "axis")
      axis_length = Math.sqrt(axis[0] * axis[0] + axis[1] * axis[1] + axis[2] * axis[2])
      if axis_length == 0.0
        raise BridgeError.new("invalid_argument", "axis must be non-zero")
      end
      degrees = finite_number(params["degrees"], "degrees")
      count = validate_array_count(params["count"])
      [persistent_id, origin, axis, degrees, count]
    end

    def duplication_member_count(entity)
      if entity.is_a?(Sketchup::Group)
        entity.entities.length
      elsif entity.is_a?(Sketchup::ComponentInstance)
        entity.definition.entities.length
      else
        0
      end
    end

    def validate_array_complexity!(entity, count, action)
      projected = duplication_member_count(entity) * count
      if projected > MAX_ARRAY_PROJECTED_ENTITIES
        raise BridgeError.new(
          "complexity_budget_exceeded",
          "#{action} projected #{projected} entities exceeding the #{MAX_ARRAY_PROJECTED_ENTITIES} entity budget"
        )
      end
      projected
    end

    def preflight_copy_entity(model, params)
      persistent_id = validate_copy_entity_params(params)
      require_copyable_entity(model, persistent_id)
      true
    end

    def preflight_linear_array(model, params)
      persistent_id, _vector, count = validate_linear_array_params(params)
      entity = require_copyable_entity(model, persistent_id)
      validate_array_complexity!(entity, count, "linear_array")
      true
    end

    def preflight_radial_array(model, params)
      persistent_id, _origin, _axis, _degrees, count = validate_radial_array_params(params)
      entity = require_copyable_entity(model, persistent_id)
      validate_array_complexity!(entity, count, "radial_array")
      true
    end

    def duplicate_object_for_copy(model, entity)
      if entity.is_a?(Sketchup::Group)
        copy = begin
          entity.copy
        rescue StandardError => error
          log("copy entity failed: #{error.class}: #{error.message}")
          raise BridgeError.new("copy_failed", "SketchUp did not copy the group")
        end
        unless copy && copy.valid? && copy.is_a?(Sketchup::Group)
          raise BridgeError.new("copy_failed", "SketchUp did not produce a group copy")
        end
        copy
      elsif entity.is_a?(Sketchup::ComponentInstance)
        copy = begin
          model.active_entities.add_instance(entity.definition, entity.transformation)
        rescue ArgumentError, RuntimeError => error
          log("copy entity failed: #{error.class}: #{error.message}")
          raise BridgeError.new("copy_failed", "SketchUp did not copy the instance")
        end
        unless copy && copy.valid? && copy.is_a?(Sketchup::ComponentInstance)
          raise BridgeError.new("copy_failed", "SketchUp did not produce an instance copy")
        end
        copy
      else
        raise BridgeError.new(
          "unsupported_object_type",
          "copy_entity requires a group/component instance"
        )
      end
    end

    def duplicate_and_place(model, source, transform)
      copy = duplicate_object_for_copy(model, source)
      begin
        copy.transformation = transform
      rescue ArgumentError, RuntimeError => error
        log("place array copy failed: #{error.class}: #{error.message}")
        raise BridgeError.new("copy_failed", "SketchUp did not place the array copy")
      end
      copy
    end

    def execute_copy_entity(model, params)
      persistent_id = validate_copy_entity_params(params)
      source = require_copyable_entity(model, persistent_id)
      source_state = semantic_entity_state(model, source)
      copy = duplicate_object_for_copy(model, source)
      {
        "entity" => copy,
        "metadata" => {
          "source_persistent_id" => persistent_id,
          "source_transformation" => source_state["transformation"],
          "source_definition_guid" => source_state.dig("definition", "guid"),
          "source_geometry_fingerprint" => source_state["geometry_fingerprint"]
        }
      }
    end

    def execute_linear_array(model, params)
      persistent_id, vector, count = validate_linear_array_params(params)
      source = require_copyable_entity(model, persistent_id)
      validate_array_complexity!(source, count, "linear_array")
      source_transform = source.transformation
      requested = (1..count).map do |step|
        offset = Geom::Vector3d.new(vector[0] * step, vector[1] * step, vector[2] * step)
        (Geom::Transformation.translation(offset) * source_transform).to_a.map do |value|
          quantize_number(value)
        end
      end
      execute_object_array(model, source, persistent_id, count, requested)
    end

    def execute_radial_array(model, params)
      persistent_id, origin, axis, degrees, count = validate_radial_array_params(params)
      source = require_copyable_entity(model, persistent_id)
      validate_array_complexity!(source, count, "radial_array")
      source_transform = source.transformation
      center = Geom::Point3d.new(origin[0], origin[1], origin[2])
      direction = Geom::Vector3d.new(axis[0], axis[1], axis[2])
      requested = (1..count).map do |step|
        rotation = Geom::Transformation.rotation(center, direction, degrees * step * Math::PI / 180.0)
        (rotation * source_transform).to_a.map { |value| quantize_number(value) }
      end
      execute_object_array(model, source, persistent_id, count, requested)
    end

    def execute_object_array(model, source, persistent_id, count, requested)
      source_state = semantic_entity_state(model, source)
      copies = requested.map do |matrix|
        duplicate_and_place(model, source, Geom::Transformation.new(matrix))
      end
      {
        "state" => semantic_entity_state(model, copies.first),
        "metadata" => {
          "source_persistent_id" => persistent_id,
          "count" => count,
          "copy_persistent_ids" => copies.map(&:persistent_id),
          "requested_transformations" => requested,
          "source_definition_guid" => source_state.dig("definition", "guid"),
          "source_geometry_fingerprint" => source_state["geometry_fingerprint"]
        }
      }
    end

    def handle_selection_by_ids(params)
      model = require_model
      raw_ids = params["persistent_ids"]
      unless raw_ids.is_a?(Array) && raw_ids.length.between?(1, MAX_OBJECTS)
        raise BridgeError.new("invalid_argument", "persistent_ids must contain 1..#{MAX_OBJECTS} ids")
      end

      replace = params.key?("replace") ? params["replace"] : true
      unless replace == true || replace == false
        raise BridgeError.new("invalid_argument", "replace must be boolean")
      end

      entities = raw_ids.map { |value| require_active_entity(model, value) }
      selection = model.selection
      selection.clear if replace
      entities.each { |entity| selection.add(entity) }
      {
        "selected_count" => selection.length,
        "selected" => selection.map { |entity| serialize_entity(entity) }
      }
    end

    def handle_selection_clear(_params)
      model = require_model
      selection = model.selection
      previous_count = selection.length
      selection.clear
      {
        "cleared" => previous_count,
        "selected_count" => selection.length
      }
    end

    def handle_object_delete(params)
      model = require_model
      entity = require_active_entity(model, params["persistent_id"])
      persistent_id = entity.persistent_id

      with_operation(model, "CDT: Delete Object") do
        entity.erase!
        {
          "deleted" => true,
          "persistent_id" => persistent_id
        }
      end
    end

    def handle_object_move(params)
      model = require_model
      entity = require_transformable_entity(model, params["persistent_id"])
      vector = vector3d(params["vector"], "vector")

      with_operation(model, "CDT: Move Object") do
        entity.transform!(Geom::Transformation.translation(vector))
        serialize_entity(entity)
      end
    end

    def handle_object_rotate(params)
      model = require_model
      entity = require_transformable_entity(model, params["persistent_id"])
      origin = point3d(params["axis_origin"], "axis_origin")
      axis = vector3d(params["axis"], "axis")
      if axis.length.zero?
        raise BridgeError.new("invalid_argument", "axis must be non-zero")
      end
      degrees = finite_number(params["degrees"], "degrees")
      radians = degrees * Math::PI / 180.0

      with_operation(model, "CDT: Rotate Object") do
        transform = Geom::Transformation.rotation(origin, axis, radians)
        entity.transform!(transform)
        serialize_entity(entity)
      end
    end

    def handle_object_scale(params)
      model = require_model
      entity = require_transformable_entity(model, params["persistent_id"])
      factors = numeric_triplet(params["factors"], "factors")
      if factors.any?(&:zero?)
        raise BridgeError.new("invalid_argument", "scale factors must be non-zero")
      end
      origin = if params.key?("origin")
                 point3d(params["origin"], "origin")
               else
                 entity.bounds.center
               end

      with_operation(model, "CDT: Scale Object") do
        transform = Geom::Transformation.scaling(origin, factors[0], factors[1], factors[2])
        entity.transform!(transform)
        serialize_entity(entity)
      end
    end

    def handle_push_pull_face(params)
      model = require_model
      face = require_active_entity(model, params["persistent_id"])
      unless face.is_a?(Sketchup::Face)
        raise BridgeError.new("unsupported_object_type", "push_pull_face requires a Face")
      end
      distance = finite_number(params["distance"], "distance")
      if distance.zero?
        raise BridgeError.new("invalid_argument", "distance must be non-zero")
      end
      persistent_id = face.persistent_id

      with_operation(model, "CDT: Push Pull Face") do
        face.pushpull(distance, false)
        current = model.find_entity_by_persistent_id(persistent_id)
        {
          "source_persistent_id" => persistent_id,
          "distance" => distance,
          "source_valid" => !!(current && current.valid?)
        }
      end
    end

    def preflight_geometry_action(model, action, action_params)
      preflight_delete_entity(model, action_params) if action == "delete_entity"
      preflight_group_entities(model, action_params) if action == "group_entities"
      preflight_create_component(model, action_params) if action == "create_component"
      preflight_copy_entity(model, action_params) if action == "copy_entity"
      preflight_linear_array(model, action_params) if action == "linear_array"
      preflight_radial_array(model, action_params) if action == "radial_array"
      preflight_tag_assign(model, action_params) if action == "tag_assign"
      preflight_material_assign(model, action_params) if action == "material_assign"
      preflight_create_polyline(model, action_params) if action == "create_polyline"
      preflight_create_rectangle(model, action_params) if action == "create_rectangle"
      preflight_create_circle(model, action_params) if action == "create_circle"
      preflight_create_arc(model, action_params) if action == "create_arc"
      preflight_create_polygon(model, action_params) if action == "create_polygon"
      preflight_place_asset(model, action_params) if action == "place_asset"
      preflight_repair_reverse_face(model, action_params) if action == "repair_reverse_face"
      preflight_repair_erase_degenerate(model, action_params) if action == "repair_erase_degenerate"
      preflight_camera_set(model, action_params) if action == "camera_set"
      preflight_scene_create(model, action_params) if action == "scene_create"
      preflight_material_apply_texture(model, action_params) if action == "material_apply_texture"
      preflight_sweep_profile(model, action_params) if action == "sweep_profile"
      preflight_place_instance(model, action_params) if action == "place_instance"
      preflight_make_unique(model, action_params) if action == "make_unique"
      true
    end

    def preflight_delete_entity(model, params)
      validate_delete_entity_params(params)
      require_deletable_entity(model, params["persistent_id"])
      true
    end

    def validate_delete_entity_params(params)
      unless params.is_a?(Hash)
        raise BridgeError.new("invalid_argument", "delete_entity params must be an object")
      end
      unknown_delete_keys = params.keys - DELETE_ENTITY_PARAM_KEYS
      unless unknown_delete_keys.empty?
        raise BridgeError.new(
          "invalid_argument",
          "delete_entity params contain unsupported keys: #{unknown_delete_keys.sort.join(', ')}"
        )
      end
      unless params.key?("persistent_id")
        raise BridgeError.new("invalid_argument", "delete_entity persistent_id is required")
      end
      true
    end

    def preflight_group_entities(model, params)
      persistent_ids, = validate_group_entities_params(params)
      entities = persistent_ids.map { |value| require_active_entity(model, value) }
      unless entities.all? { |entity| groupable_entity?(entity) }
        raise BridgeError.new(
          "unsupported_object_type",
          "group_entities supports only edges, faces, groups, and component instances"
        )
      end
      if entities.any? { |entity| entity.respond_to?(:locked?) && entity.locked? }
        raise BridgeError.new("locked_object", "group_entities targets must be unlocked")
      end
      unless complete_groupable_connected_geometry?(entities)
        raise BridgeError.new(
          "partial_connected_geometry",
          "Raw edge/face targets must include each complete connected geometry set"
        )
      end
      true
    end

    def validate_group_entities_params(params)
      unless params.is_a?(Hash)
        raise BridgeError.new("invalid_argument", "group_entities params must be an object")
      end
      unknown_group_keys = params.keys - GROUP_ENTITIES_PARAM_KEYS
      unless unknown_group_keys.empty?
        raise BridgeError.new(
          "invalid_argument",
          "group_entities params contain unsupported keys: #{unknown_group_keys.sort.join(', ')}"
        )
      end
      raw_ids = params["persistent_ids"]
      unless raw_ids.is_a?(Array) && raw_ids.length.between?(1, MAX_OBJECTS)
        raise BridgeError.new(
          "invalid_argument",
          "persistent_ids must contain 1..#{MAX_OBJECTS} ids"
        )
      end
      persistent_ids = raw_ids.each_with_index.map do |value, index|
        bounded_integer(
          value,
          minimum: 1,
          maximum: (2**63) - 1,
          name: "persistent_ids[#{index}]"
        )
      end
      if persistent_ids.uniq.length != persistent_ids.length
        raise BridgeError.new("invalid_argument", "persistent_ids must not contain duplicates")
      end

      name = params["name"]
      if name && (!name.is_a?(String) || name.length > 128)
        raise BridgeError.new("invalid_argument", "name must be a string up to 128 characters")
      end
      [persistent_ids, name]
    end

    def groupable_entity?(entity)
      entity.is_a?(Sketchup::Edge) ||
        entity.is_a?(Sketchup::Face) ||
        entity.is_a?(Sketchup::Group) ||
        entity.is_a?(Sketchup::ComponentInstance)
    end

    def complete_groupable_connected_geometry?(entities)
      raw_entities = entities.select { |entity| raw_topology_entity?(entity) }
      return true if raw_entities.empty?

      selected_ids = raw_entities.map(&:persistent_id).sort
      checked_ids = {}
      raw_entities.all? do |entity|
        next true if checked_ids[entity.persistent_id]

        closure = bounded_raw_topology_closure(entity)
        closure_ids = closure.map(&:persistent_id).sort
        closure_ids.each { |pid| checked_ids[pid] = true }
        (closure_ids - selected_ids).empty?
      end
    end

    def execute_delete_entity(model, params)
      validate_delete_entity_params(params)
      entity = require_deletable_entity(model, params["persistent_id"])
      before_state = semantic_entity_state(model, entity)
      persistent_id = before_state["persistent_id"]

      begin
        model.active_entities.erase_entities(entity)
      rescue ArgumentError, RuntimeError => error
        log("delete entity failed: #{error.class}: #{error.message}")
        raise BridgeError.new("delete_failed", "SketchUp did not delete the target entity")
      end

      if entity_alive_by_pid?(model, persistent_id)
        raise BridgeError.new("delete_failed", "Deleted target persistent ID still resolves")
      end

      {
        "state" => {
          "persistent_id" => persistent_id,
          "type" => before_state["type"],
          "valid" => false,
          "active_context" => false,
          "deleted" => true
        },
        "metadata" => {
          "target_persistent_id" => persistent_id,
          "target_type" => before_state["type"],
          "before_state" => before_state
        }
      }
    end

    def execute_group_entities(model, params)
      persistent_ids, name = validate_group_entities_params(params)
      entities = persistent_ids.map { |value| require_active_entity(model, value) }
      input_states = entities.map do |entity|
        [entity, semantic_entity_state(model, entity)]
      end
      input_fingerprints = input_states.each_with_object({}) do |(entity, state), result|
        result[entity.persistent_id.to_s] = {
          "identity" => state["identity_fingerprint"],
          "geometry" => state["geometry_fingerprint"],
          "reparent" => grouping_reparent_fingerprint(entity, state)
        }
      end
      input_bounds = aggregate_semantic_bounds(input_states.map { |_entity, state| state })

      group = begin
        model.active_entities.add_group(entities)
      rescue ArgumentError, RuntimeError => error
        log("group entities failed: #{error.class}: #{error.message}")
        raise BridgeError.new("group_failed", "SketchUp did not group the requested entities")
      end
      unless group && group.valid? && group.is_a?(Sketchup::Group)
        raise BridgeError.new("group_failed", "SketchUp did not produce a group")
      end
      group.name = name if name && !name.empty?

      {
        "entity" => group,
        "metadata" => {
          "input_persistent_ids" => persistent_ids.sort,
          "input_fingerprints" => input_fingerprints,
          "input_bounds_min" => input_bounds["min"],
          "input_bounds_max" => input_bounds["max"],
          "group_definition_guid" => group.definition.guid.to_s
        }
      }
    end

    def grouping_reparent_fingerprint(entity, state)
      payload = {
        "persistent_id" => entity.persistent_id,
        "type" => entity.typename
      }
      if entity.is_a?(Sketchup::Edge)
        payload["length"] = quantize_number(entity.length)
        payload["face_persistent_ids"] = entity.faces.map(&:persistent_id).sort
      elsif entity.is_a?(Sketchup::Face)
        payload["area"] = quantize_number(entity.area)
        payload["edge_persistent_ids"] = entity.edges.map(&:persistent_id).sort
      else
        payload["identity_fingerprint"] = state["identity_fingerprint"]
        payload["geometry_fingerprint"] = state["geometry_fingerprint"]
      end
      Digest::SHA256.hexdigest(JSON.generate(payload))
    end

    def aggregate_semantic_bounds(states)
      mins = states.map { |state| state.dig("bounds", "min") }
      maxs = states.map { |state| state.dig("bounds", "max") }
      unless mins.all? { |value| value.is_a?(Array) && value.length == 3 } &&
             maxs.all? { |value| value.is_a?(Array) && value.length == 3 }
        raise BridgeError.new("semantic_state_invalid", "Grouping inputs must expose bounded geometry")
      end
      {
        "min" => 3.times.map { |index| mins.map { |value| value[index] }.min },
        "max" => 3.times.map { |index| maxs.map { |value| value[index] }.max }
      }
    end
  end
end
