# cdt_sketchup/kernel/receipts.rb — operation/query receipt builders
# Wing: code | Topic: sketchup_bridge | Updated: 2026-09-12

module CDTSketchUp
  class BridgeServer
    private

    RECEIPT_SCHEMA_VERSION = 1

    def build_operation_receipt(
      model,
      receipt_id:,
      started_at:,
      action:,
      state:,
      affected:,
      validation:,
      before_count:,
      before_fingerprint:,
      after_count:,
      after_fingerprint:,
      unit_info:,
      coordinate_space:,
      context_before:,
      context:
    )
      before_model = receipt_model_state(before_count, before_fingerprint)
      after_model = receipt_model_state(after_count, after_fingerprint)
      public_unit = unit_info["public_unit"]
      resolved_unit = unit_info["resolved_unit"]
      public_state = semantic_state_in_unit(state, resolved_unit)
      public_validation = validation_in_unit(validation, resolved_unit)
      result = {
        "receipt_schema_version" => RECEIPT_SCHEMA_VERSION,
        "receipt_kind" => "operation",
        "receipt_id" => receipt_id,
        "command" => "execute_geometry",
        "action" => action,
        "unit" => public_unit,
        "resolved_unit" => resolved_unit,
        "native_length_unit" => "in",
        "coordinate_space" => coordinate_space,
        "committed" => true,
        "commit_verified" => true,
        "context_before" => context_before,
        "context" => context,
        "affected" => affected,
        "affected_verified" => true,
        "entity_states" => [public_state],
        "model" => {
          "before" => before_model,
          "after" => after_model,
          "after_rollback" => nil
        },
        "validation" => public_validation,
        "rollback" => nil,
        "error" => nil,
        "duration_ms" => receipt_duration_ms(started_at),
        "limits" => receipt_limits
      }

      # Contract 0.9 compatibility aliases; receipt fields above are authoritative.
      result["rolled_back"] = false
      result["rollback_verified"] = false
      result["persistent_id"] = public_state["persistent_id"]
      result["state"] = public_state
      result["before"] = before_model
      result["after"] = after_model
      result
    end

    def build_query_receipt(model, command:, state:, started_at:, unit_info:, coordinate_space:, context:)
      public_unit = unit_info["public_unit"]
      resolved_unit = unit_info["resolved_unit"]
      public_state = semantic_state_in_unit(state, resolved_unit)
      result = {
        "receipt_schema_version" => RECEIPT_SCHEMA_VERSION,
        "receipt_kind" => "query",
        "receipt_id" => SecureRandom.uuid,
        "command" => command,
        "unit" => public_unit,
        "resolved_unit" => resolved_unit,
        "native_length_unit" => "in",
        "coordinate_space" => coordinate_space,
        "context" => context,
        "entity_fingerprint" => public_state["semantic_fingerprint"],
        "entity_states" => [public_state],
        "result" => public_state,
        "duration_ms" => receipt_duration_ms(started_at),
        "limits" => receipt_limits
      }

      # Preserve the existing flat semantic-state shape during receipt migration.
      public_state.each { |key, value| result[key] = value unless result.key?(key) }
      result
    end

    def build_rollback_result(
      model,
      receipt_id:,
      started_at:,
      action:,
      aborted:,
      before_count:,
      before_fingerprint:,
      before_snapshot:,
      unit_info:,
      coordinate_space:,
      validation: nil,
      error: nil
    )
      rolled_back_count = model.active_entities.length
      rolled_back_snapshot, rollback_snapshot_error = safe_semantic_active_entity_snapshot(model)
      rolled_back_fingerprint, rollback_fingerprint_error = if rolled_back_snapshot
                                                              safe_semantic_model_fingerprint(
                                                                model,
                                                                active_snapshot: rolled_back_snapshot
                                                              )
                                                            else
                                                              safe_semantic_model_fingerprint(model)
                                                            end
      rollback_verified = (
        !!aborted &&
        !before_fingerprint.nil? &&
        !rolled_back_fingerprint.nil? &&
        rolled_back_count == before_count &&
        rolled_back_fingerprint == before_fingerprint
      )
      affected = if before_snapshot && rolled_back_snapshot
                   semantic_affected_entities(model, before_snapshot, rolled_back_snapshot)
                 end
      affected ||= empty_affected_entities if rollback_verified

      before_model = receipt_model_state(before_count, before_fingerprint)
      rollback_model = receipt_model_state(rolled_back_count, rolled_back_fingerprint)
      rollback_detail = {
        "attempted" => true,
        "rolled_back" => !!aborted,
        "verified" => rollback_verified,
        "snapshot_error" => rollback_snapshot_error,
        "fingerprint_error" => rollback_fingerprint_error
      }
      public_unit = unit_info["public_unit"]
      resolved_unit = unit_info["resolved_unit"]
      public_validation = validation && validation_in_unit(validation, resolved_unit)
      result = {
        "receipt_schema_version" => RECEIPT_SCHEMA_VERSION,
        "receipt_kind" => "operation",
        "receipt_id" => receipt_id,
        "command" => "execute_geometry",
        "action" => action,
        "unit" => public_unit,
        "resolved_unit" => resolved_unit,
        "native_length_unit" => "in",
        "coordinate_space" => coordinate_space,
        "committed" => false,
        "commit_verified" => false,
        "context" => receipt_context(model, model_fingerprint: rolled_back_fingerprint || before_fingerprint),
        "affected" => affected,
        "affected_verified" => rollback_verified,
        "entity_states" => [],
        "model" => {
          "before" => before_model,
          "after" => nil,
          "after_rollback" => rollback_model
        },
        "validation" => public_validation,
        "rollback" => rollback_detail,
        "error" => error,
        "duration_ms" => receipt_duration_ms(started_at),
        "limits" => receipt_limits,
        # Contract 0.9 compatibility aliases.
        "rolled_back" => !!aborted,
        "rollback_verified" => rollback_verified,
        "before" => before_model,
        "after_rollback" => rollback_model
      }
      result["rollback_fingerprint_error"] = rollback_fingerprint_error if rollback_fingerprint_error
      result
    end

    def query_camera_receipt(model, command, state, started_at, unit_info)
      snapshot = semantic_active_entity_snapshot(model)
      model_fingerprint = semantic_model_fingerprint(model, active_snapshot: snapshot)
      query_context = receipt_context(model, model_fingerprint: model_fingerprint)
      build_query_receipt(
        model,
        command: command,
        state: state,
        started_at: started_at,
        unit_info: unit_info,
        coordinate_space: "active_context",
        context: query_context
      )
    end

    def file_operation_receipt(model, command, state, checks, started_at)
      snapshot = semantic_active_entity_snapshot(model)
      model_fingerprint = semantic_model_fingerprint(model, active_snapshot: snapshot)
      context = receipt_context(model, model_fingerprint: model_fingerprint)
      verified = checks.all? { |check| check["passed"] }
      {
        "receipt_schema_version" => RECEIPT_SCHEMA_VERSION,
        "receipt_kind" => "external_side_effect",
        "receipt_id" => SecureRandom.uuid,
        "command" => command,
        "action" => command,
        "transactional" => false,
        "rollback_supported" => false,
        "rollback_verified" => false,
        "side_effect_completed" => verified,
        "side_effect_verified" => verified,
        "context" => context,
        "result" => state,
        "entity_states" => [state],
        "validation" => { "passed" => verified, "checks" => checks },
        "error" => nil,
        "duration_ms" => receipt_duration_ms(started_at),
        "limits" => receipt_limits
      }
    end

    def receipt_model_state(active_entity_count, model_fingerprint)
      {
        "active_entity_count" => active_entity_count,
        "model_fingerprint" => model_fingerprint
      }
    end

    def receipt_limits
      {
        "bridge_frame_bytes" => MAX_FRAME_BYTES,
        "max_model_entities_for_fingerprint" => MAX_MODEL_FINGERPRINT_ENTITIES,
        "max_fingerprint_edges" => MAX_FINGERPRINT_EDGES,
        "max_face_points" => MAX_FACE_POINTS
      }
    end

    def receipt_duration_ms(started_at)
      ((monotonic_now - started_at) * 1000.0).round(3)
    end
  end
end
