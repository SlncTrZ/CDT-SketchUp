# cdt_sketchup/kernel/context.rb — edit-context identity and stale-write guards
# Wing: code | Topic: sketchup_bridge | Updated: 2026-09-12

module CDTSketchUp
  class BridgeServer
    private

    def model_session_identity(model)
      payload = {
        "process_id" => Process.pid,
        "process_session_id" => @process_session_id,
        "model_guid" => model.guid.to_s
      }
      Digest::SHA256.hexdigest(JSON.generate(payload))
    end

    def edit_context_identity(model)
      active_path = model.active_path || []
      path = active_path.map do |entity|
        definition_guid = if entity.respond_to?(:definition) && entity.definition.respond_to?(:guid)
                            entity.definition.guid.to_s
                          end
        {
          "persistent_id" => entity.persistent_id,
          "type" => entity.typename,
          "definition_guid" => definition_guid
        }
      end
      payload = {
        "model_session_id" => model_session_identity(model),
        "active_path" => path
      }
      Digest::SHA256.hexdigest(JSON.generate(payload))
    end

    def context_revision(context_id, model_fingerprint)
      Digest::SHA256.hexdigest(
        JSON.generate(
          {
            "context_id" => context_id,
            "model_fingerprint" => model_fingerprint
          }
        )
      )
    end

    def receipt_context(model, model_fingerprint:)
      active_path = model.active_path || []
      context_id = edit_context_identity(model)
      {
        "id" => context_id,
        "revision" => context_revision(context_id, model_fingerprint),
        "identity_status" => "verified",
        "model_session_id" => model_session_identity(model),
        "model_guid" => model.guid.to_s,
        "active_path" => active_path.map { |entity| entity.persistent_id }
      }
    end

    def validate_write_preconditions(model, action, action_params, if_context, if_match, current_context)
      validate_if_context(if_context, current_context) if if_context
      validate_if_match(model, action, action_params, if_match) if if_match
      true
    end

    def validate_if_context(value, current_context)
      unless value.is_a?(Hash)
        raise BridgeError.new("invalid_argument", "if_context must be an object")
      end
      unknown = value.keys - IF_CONTEXT_KEYS
      unless unknown.empty?
        raise BridgeError.new(
          "invalid_argument",
          "if_context contains unsupported keys: #{unknown.sort.join(', ')}"
        )
      end
      unless value.keys.sort == IF_CONTEXT_KEYS.sort &&
             value["id"].is_a?(String) && value["revision"].is_a?(String)
        raise BridgeError.new("invalid_argument", "if_context requires string id and revision")
      end
      if value["id"] != current_context["id"] ||
         value["revision"] != current_context["revision"]
        raise BridgeError.new("context_mismatch", "Active model/edit context changed since the receipt")
      end
      true
    end

    def precondition_target_pid(action, action_params)
      case action
      when "transform_entity", "delete_entity", "extrude_face_to_group", "make_unique", "copy_entity", "linear_array", "radial_array", "tag_assign", "material_assign", "repair_reverse_face", "repair_erase_degenerate"
        action_params["persistent_id"]
      when "boolean_operation"
        action_params["target_pid"]
      else
        nil
      end
    end

    def validate_if_match(model, action, action_params, if_match)
      return validate_group_if_match_set(model, action_params, if_match) if action == "group_entities"
      return validate_component_if_match_set(model, action_params, if_match) if action == "create_component"
      return validate_camera_if_match(model, if_match) if action == "camera_set"
      return validate_sweep_if_match_set(model, action_params, if_match) if action == "sweep_profile"
      return validate_place_definition_if_match(model, action_params, if_match) if action == "place_instance"

      unless if_match.is_a?(String) && if_match.match?(/\A[a-f0-9]{64}\z/)
        raise BridgeError.new("invalid_argument", "if_match must be a 64-character lowercase SHA-256 hex string")
      end
      persistent_id = precondition_target_pid(action, action_params)
      unless persistent_id
        raise BridgeError.new("invalid_argument", "if_match is not supported for this action")
      end
      entity = require_active_entity(model, persistent_id)
      state = semantic_entity_state(model, entity)
      unless state["semantic_fingerprint"] == if_match
        raise BridgeError.new("stale_entity_state", "Target entity state changed since the receipt")
      end
      true
    end

    def validate_group_if_match_set(model, action_params, if_match)
      unless if_match.is_a?(Hash)
        raise BridgeError.new(
          "invalid_argument",
          "if_match for group_entities must be an object keyed by persistent ID"
        )
      end
      persistent_ids, = validate_group_entities_params(action_params)
      expected_keys = persistent_ids.map(&:to_s).sort
      actual_keys = if_match.keys.map(&:to_s).sort
      unless actual_keys == expected_keys
        raise BridgeError.new(
          "invalid_argument",
          "if_match for group_entities must cover the exact persistent ID set"
        )
      end

      persistent_ids.each do |persistent_id|
        fingerprint = if_match[persistent_id.to_s] || if_match[persistent_id]
        unless fingerprint.is_a?(String) && fingerprint.match?(/\A[a-f0-9]{64}\z/)
          raise BridgeError.new(
            "invalid_argument",
            "if_match values must be 64-character lowercase SHA-256 hex strings"
          )
        end
        entity = require_active_entity(model, persistent_id)
        state = semantic_entity_state(model, entity)
        unless state["semantic_fingerprint"] == fingerprint
          raise BridgeError.new(
            "stale_entity_state",
            "One or more group_entities targets changed since the receipt"
          )
        end
      end
      true
    end

    def validate_component_if_match_set(model, action_params, if_match)
      unless if_match.is_a?(Hash)
        raise BridgeError.new(
          "invalid_argument",
          "if_match for create_component must be an object keyed by persistent ID"
        )
      end
      persistent_ids, = validate_create_component_params(action_params)
      expected_keys = persistent_ids.map(&:to_s).sort
      actual_keys = if_match.keys.map(&:to_s).sort
      unless actual_keys == expected_keys
        raise BridgeError.new(
          "invalid_argument",
          "if_match for create_component must cover the exact persistent ID set"
        )
      end

      persistent_ids.each do |persistent_id|
        fingerprint = if_match[persistent_id.to_s] || if_match[persistent_id]
        unless fingerprint.is_a?(String) && fingerprint.match?(/\A[a-f0-9]{64}\z/)
          raise BridgeError.new(
            "invalid_argument",
            "if_match values must be 64-character lowercase SHA-256 hex strings"
          )
        end
        entity = require_active_entity(model, persistent_id)
        state = semantic_entity_state(model, entity)
        unless state["semantic_fingerprint"] == fingerprint
          raise BridgeError.new(
            "stale_entity_state",
            "One or more create_component targets changed since the receipt"
          )
        end
      end
      true
    end

    def validate_place_definition_if_match(model, action_params, if_match)
      unless if_match.is_a?(String) && if_match.match?(/\A[a-f0-9]{64}\z/)
        raise BridgeError.new(
          "invalid_argument",
          "if_match for place_instance must be a 64-character lowercase SHA-256 hex string"
        )
      end
      guid, = validate_place_instance_params(action_params)
      definition = find_definition_by_guid(model, guid)
      current = semantic_definition_geometry_fingerprint(definition)
      unless current == if_match
        raise BridgeError.new("stale_entity_state", "Component definition changed since the receipt")
      end
      true
    end

    def validate_camera_if_match(model, if_match)
      unless if_match.is_a?(String) && if_match.match?(/\A[a-f0-9]{64}\z/)
        raise BridgeError.new("invalid_argument", "if_match must be a 64-character lowercase SHA-256 hex string")
      end
      current = camera_semantic_state(model)["semantic_fingerprint"]
      unless current == if_match
        raise BridgeError.new("stale_entity_state", "Camera state changed since the receipt")
      end
      true
    end

    def validate_sweep_if_match_set(model, action_params, if_match)
      unless if_match.is_a?(Hash)
        raise BridgeError.new(
          "invalid_argument",
          "if_match for sweep_profile must be an object keyed by persistent ID"
        )
      end
      face_pid, path_pids = validate_sweep_profile_params(action_params)
      expected_keys = ([face_pid] + path_pids).map(&:to_s).sort
      actual_keys = if_match.keys.map(&:to_s).sort
      unless actual_keys == expected_keys
        raise BridgeError.new(
          "invalid_argument",
          "if_match for sweep_profile must cover the exact face and path set"
        )
      end
      ([face_pid] + path_pids).each do |persistent_id|
        fingerprint = if_match[persistent_id.to_s] || if_match[persistent_id]
        unless fingerprint.is_a?(String) && fingerprint.match?(/\A[a-f0-9]{64}\z/)
          raise BridgeError.new(
            "invalid_argument",
            "if_match values must be 64-character lowercase SHA-256 hex strings"
          )
        end
        entity = require_active_entity(model, persistent_id)
        state = semantic_entity_state(model, entity)
        unless state["semantic_fingerprint"] == fingerprint
          raise BridgeError.new(
            "stale_entity_state",
            "One or more sweep_profile inputs changed since the receipt"
          )
        end
      end
      true
    end
  end
end
