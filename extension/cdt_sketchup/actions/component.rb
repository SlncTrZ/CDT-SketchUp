# cdt_sketchup/actions/component.rb — strict definition/instance actions
# Wing: code | Topic: sketchup_bridge | Updated: 2026-09-12

module CDTSketchUp
  class BridgeServer
    private

    def validate_place_instance_params(params)
      unless params.is_a?(Hash)
        raise BridgeError.new("invalid_argument", "place_instance params must be an object")
      end
      unknown_place_keys = params.keys - PLACE_INSTANCE_PARAM_KEYS
      unless unknown_place_keys.empty?
        raise BridgeError.new(
          "invalid_argument",
          "place_instance params contain unsupported keys: #{unknown_place_keys.sort.join(', ')}"
        )
      end
      guid = params["definition_guid"]
      unless guid.is_a?(String) && !guid.strip.empty?
        raise BridgeError.new("invalid_argument", "definition_guid must be a non-empty string")
      end
      matrix = params["matrix"]
      unless matrix.is_a?(Array) && matrix.length == 16
        raise BridgeError.new("invalid_argument", "matrix must contain exactly 16 numbers")
      end
      [guid.strip, matrix]
    end

    def validate_make_unique_params(params)
      unless params.is_a?(Hash)
        raise BridgeError.new("invalid_argument", "make_unique params must be an object")
      end
      unknown_unique_keys = params.keys - MAKE_UNIQUE_PARAM_KEYS
      unless unknown_unique_keys.empty?
        raise BridgeError.new(
          "invalid_argument",
          "make_unique params contain unsupported keys: #{unknown_unique_keys.sort.join(', ')}"
        )
      end
      unless params.key?("persistent_id")
        raise BridgeError.new("invalid_argument", "make_unique persistent_id is required")
      end
      bounded_integer(params["persistent_id"], minimum: 1, maximum: (2**63) - 1, name: "persistent_id")
    end

    def preflight_place_instance(model, params)
      guid, matrix = validate_place_instance_params(params)
      definition = find_definition_by_guid(model, guid)
      if definition.image?
        raise BridgeError.new(
          "unsupported_object_type",
          "place_instance definitions must be component definitions"
        )
      end
      transformation_from_matrix(matrix)
      true
    end

    def preflight_make_unique(model, params)
      persistent_id = validate_make_unique_params(params)
      entity = require_active_entity(model, persistent_id)
      unless entity.is_a?(Sketchup::ComponentInstance)
        raise BridgeError.new("unsupported_object_type", "make_unique targets only component instances")
      end
      if entity.respond_to?(:locked?) && entity.locked?
        raise BridgeError.new("locked_object", "make_unique target must be unlocked")
      end
      true
    end

    def execute_place_instance(model, params)
      guid, matrix_values = validate_place_instance_params(params)
      definition = find_definition_by_guid(model, guid)
      if definition.image?
        raise BridgeError.new(
          "unsupported_object_type",
          "place_instance definitions must be component definitions"
        )
      end
      before_geometry = semantic_definition_geometry_fingerprint(definition)
      transform = transformation_from_matrix(matrix_values)
      requested = transform.to_a.map { |value| quantize_number(value) }
      instance = begin
        model.active_entities.add_instance(definition, transform)
      rescue ArgumentError, RuntimeError => error
        log("place instance failed: #{error.class}: #{error.message}")
        raise BridgeError.new("component_failed", "SketchUp did not place the component instance")
      end
      unless instance && instance.valid? && instance.is_a?(Sketchup::ComponentInstance)
        raise BridgeError.new("component_failed", "SketchUp did not produce a component instance")
      end

      {
        "entity" => instance,
        "metadata" => {
          "component_definition_guid" => definition.guid.to_s,
          "definition_geometry_before" => before_geometry,
          "requested_transformation" => requested
        }
      }
    end

    def execute_make_unique(model, params)
      persistent_id = validate_make_unique_params(params)
      entity = require_active_entity(model, persistent_id)
      unless entity.is_a?(Sketchup::ComponentInstance)
        raise BridgeError.new("unsupported_object_type", "make_unique targets only component instances")
      end
      before_guid = entity.definition.guid.to_s
      before_geometry = semantic_definition_geometry_fingerprint(entity.definition)
      begin
        entity.make_unique
      rescue StandardError => error
        log("make unique failed: #{error.class}: #{error.message}")
        raise BridgeError.new("component_failed", "SketchUp did not make the instance unique")
      end
      unless entity.valid? && entity.is_a?(Sketchup::ComponentInstance)
        raise BridgeError.new("component_failed", "SketchUp did not keep a valid component instance")
      end

      {
        "entity" => entity,
        "metadata" => {
          "target_persistent_id" => persistent_id,
          "component_definition_guid_before" => before_guid,
          "component_definition_guid_after" => entity.definition.guid.to_s,
          "definition_geometry_before" => before_geometry
        }
      }
    end

    def handle_component_create_box(params)
      model = require_model
      with_operation(model, "CDT: Create Box Component") do
        serialize_entity(execute_create_box(model, params))
      end
    end
  end
end
