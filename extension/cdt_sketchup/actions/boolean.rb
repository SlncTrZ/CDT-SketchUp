# cdt_sketchup/actions/boolean.rb — strict manifold booleans
# Wing: code | Topic: sketchup_bridge | Updated: 2026-09-12

module CDTSketchUp
  class BridgeServer
    private

    def execute_boolean_operation(model, params)
      unknown_boolean_keys = params.keys - BOOLEAN_OPERATION_PARAM_KEYS
      unless unknown_boolean_keys.empty?
        raise BridgeError.new(
          "invalid_argument",
          "boolean_operation params contain unsupported keys: #{unknown_boolean_keys.sort.join(', ')}"
        )
      end

      operation_type = params["operation_type"]
      unless BOOLEAN_OPERATION_TYPES.include?(operation_type)
        raise BridgeError.new(
          "invalid_argument",
          "operation_type must be union, difference, or intersect"
        )
      end

      tool = require_boolean_solid(model, params["tool_pid"], "tool_pid")
      target = require_boolean_solid(model, params["target_pid"], "target_pid")
      if tool.persistent_id == target.persistent_id
        raise BridgeError.new("invalid_argument", "tool_pid and target_pid must be different")
      end

      tool_state = semantic_entity_state(model, tool)
      target_state = semantic_entity_state(model, target)
      result = begin
        case operation_type
        when "union"
          target.union(tool)
        when "difference"
          # SketchUp's parameter semantics subtract the receiver from the argument.
          # Contract difference is target - tool, therefore receiver must be tool.
          tool.subtract(target)
        when "intersect"
          target.intersect(tool)
        end
      rescue StandardError => error
        log("boolean operation failed: #{error.class}: #{error.message}")
        raise BridgeError.new("boolean_failed", "SketchUp boolean operation failed")
      end

      unless result && result.valid? && result.is_a?(Sketchup::Group)
        raise BridgeError.new("boolean_failed", "SketchUp did not produce a boolean result group")
      end
      unless result.respond_to?(:parent) && result.parent == model.active_entities.parent
        raise BridgeError.new("context_mismatch", "Boolean result escaped the active edit context")
      end
      unless semantic_manifold(result) == true
        raise BridgeError.new("invalid_geometry", "Boolean result is not a manifold solid")
      end

      {
        "entity" => result,
        "metadata" => {
          "operation_type" => operation_type,
          "tool_persistent_id" => tool_state["persistent_id"],
          "target_persistent_id" => target_state["persistent_id"],
          "tool_volume" => tool_state["volume"],
          "target_volume" => target_state["volume"]
        }
      }
    end

    def validate_boolean_volume_invariant(state, metadata)
      actual = state["volume"]
      tool_volume = metadata["tool_volume"]
      target_volume = metadata["target_volume"]
      passed = false
      if actual && tool_volume && target_volume && actual.positive?
        passed = case metadata["operation_type"]
                 when "union"
                   actual >= [tool_volume, target_volume].max - SEMANTIC_QUANTUM &&
                     actual <= tool_volume + target_volume + SEMANTIC_QUANTUM
                 when "difference"
                   actual <= target_volume + SEMANTIC_QUANTUM
                 when "intersect"
                   actual <= [tool_volume, target_volume].min + SEMANTIC_QUANTUM
                 else
                   false
                 end
      end
      {
        "field" => "action.volume_relation",
        "expected" => metadata["operation_type"],
        "actual" => actual,
        "passed" => !!passed
      }
    end
  end
end
