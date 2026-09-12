# cdt_sketchup/queries/entity.rb — entity and definition read queries
# Wing: code | Topic: sketchup_bridge | Updated: 2026-09-12

module CDTSketchUp
  class BridgeServer
    private

    def handle_document_info(_params)
      model = require_model
      active_path = model.active_path || []
      {
        "title" => model.title.to_s,
        "path" => model.path.to_s,
        "modified" => model.modified?,
        "active_context" => active_path.map { |entity| entity.persistent_id },
        "active_entity_count" => model.active_entities.length,
        "coordinate_unit" => "sketchup_internal_inch",
        "length_unit_code" => model.options["UnitsOptions"]["LengthUnit"]
      }
    end

    def handle_object_list(params)
      model = require_model
      limit = bounded_integer(params["limit"], default: 100, minimum: 1, maximum: MAX_OBJECTS, name: "limit")
      type_filter = params["type"]
      if type_filter && (!type_filter.is_a?(String) || type_filter.length > 64)
        raise BridgeError.new("invalid_argument", "type must be a bounded string")
      end

      entities = model.active_entities.to_a
      if type_filter
        entities = entities.select { |entity| entity.typename.casecmp?(type_filter) }
      end
      selected = entities.first(limit)
      {
        "objects" => selected.map { |entity| serialize_entity(entity) },
        "returned" => selected.length,
        "total_in_active_context" => entities.length,
        "truncated" => entities.length > selected.length
      }
    end

    def handle_object_get(params)
      model = require_model
      entity = require_entity_by_pid(model, params["persistent_id"])
      serialize_entity(entity)
    end

    def handle_get_entity_state(params)
      started_at = monotonic_now
      model = require_model
      unit_info = resolve_public_unit(model, params["unit"] || "in")
      coordinate_space = validate_coordinate_space(params["coordinate_space"] || "active_context")
      entity = require_entity_by_pid(model, params["persistent_id"])
      state = semantic_entity_state(model, entity)
      snapshot = semantic_active_entity_snapshot(model)
      model_fingerprint = semantic_model_fingerprint(model, active_snapshot: snapshot)
      query_context = receipt_context(model, model_fingerprint: model_fingerprint)
      build_query_receipt(
        model,
        command: "get_entity_state",
        state: state,
        started_at: started_at,
        unit_info: unit_info,
        coordinate_space: coordinate_space,
        context: query_context
      )
    end

    def validate_definition_info_params(params)
      unless params.is_a?(Hash)
        raise BridgeError.new("invalid_argument", "definition_info params must be an object")
      end
      unknown_definition_keys = params.keys - DEFINITION_INFO_PARAM_KEYS
      unless unknown_definition_keys.empty?
        raise BridgeError.new(
          "invalid_argument",
          "definition_info params contain unsupported keys: #{unknown_definition_keys.sort.join(', ')}"
        )
      end
      guid = params["definition_guid"]
      unless guid.is_a?(String) && !guid.strip.empty?
        raise BridgeError.new("invalid_argument", "definition_guid must be a non-empty string")
      end
      guid.strip
    end

    def handle_material_info(params)
      started_at = monotonic_now
      model = require_model
      unit_info = resolve_public_unit(model, params["unit"] || "in")
      unless params.is_a?(Hash)
        raise BridgeError.new("invalid_argument", "material_info params must be an object")
      end
      unknown_keys = params.keys - MATERIAL_INFO_PARAM_KEYS
      unless unknown_keys.empty?
        raise BridgeError.new(
          "invalid_argument",
          "material_info params contain unsupported keys: #{unknown_keys.sort.join(', ')}"
        )
      end
      material = require_material(model, params["material"])
      state = material_semantic_state(material)
      snapshot = semantic_active_entity_snapshot(model)
      model_fingerprint = semantic_model_fingerprint(model, active_snapshot: snapshot)
      query_context = receipt_context(model, model_fingerprint: model_fingerprint)
      build_query_receipt(
        model,
        command: "material_info",
        state: state,
        started_at: started_at,
        unit_info: unit_info,
        coordinate_space: "active_context",
        context: query_context
      )
    end

    def handle_definition_info(params)
      started_at = monotonic_now
      model = require_model
      unit_info = resolve_public_unit(model, params["unit"] || "in")
      guid = validate_definition_info_params(params)
      definition = find_definition_by_guid(model, guid)
      state = semantic_definition_state(model, definition)
      snapshot = semantic_active_entity_snapshot(model)
      model_fingerprint = semantic_model_fingerprint(model, active_snapshot: snapshot)
      query_context = receipt_context(model, model_fingerprint: model_fingerprint)
      build_query_receipt(
        model,
        command: "definition_info",
        state: state,
        started_at: started_at,
        unit_info: unit_info,
        coordinate_space: "active_context",
        context: query_context
      )
    end
  end
end
