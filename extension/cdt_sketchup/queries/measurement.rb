# cdt_sketchup/queries/measurement.rb — measurement and overlap queries
# Wing: code | Topic: sketchup_bridge | Updated: 2026-09-12

module CDTSketchUp
  class BridgeServer
    private

    def handle_measure_distance(params)
      started_at = monotonic_now
      model = require_model
      unit_info = resolve_public_unit(model, params["unit"] || "in")
      first_pid, second_pid = query_pid_pair(params, %w[first_pid second_pid])
      first = require_entity_by_pid(model, first_pid)
      second = require_entity_by_pid(model, second_pid)
      first_center = point_to_triplet(first.bounds.center)
      second_center = point_to_triplet(second.bounds.center)
      center_distance = Math.sqrt(
        (first_center[0] - second_center[0])**2 +
        (first_center[1] - second_center[1])**2 +
        (first_center[2] - second_center[2])**2
      )
      first_box = box_triplet(first.bounds)
      second_box = box_triplet(second.bounds)
      axis_gaps = 3.times.map do |index|
        [first_box[0][index] - second_box[1][index], second_box[0][index] - first_box[1][index], 0.0].max
      end
      bounds_gap = Math.sqrt(axis_gaps[0]**2 + axis_gaps[1]**2 + axis_gaps[2]**2)
      resolved = unit_info["resolved_unit"]
      state = {
        "query" => "measure_distance",
        "first_pid" => first_pid,
        "second_pid" => second_pid,
        "center_distance" => quantize_public_number(convert_length_from_internal(center_distance, resolved)),
        "bounds_gap" => quantize_public_number(convert_length_from_internal(bounds_gap, resolved)),
        "overlap" => bounds_gap == 0.0,
        "semantic_fingerprint" => Digest::SHA256.hexdigest(
          JSON.generate(
            {
              "query" => "measure_distance",
              "first" => semantic_entity_state(model, first)["semantic_fingerprint"],
              "second" => semantic_entity_state(model, second)["semantic_fingerprint"]
            }
          )
        )
      }
      snapshot = semantic_active_entity_snapshot(model)
      model_fingerprint = semantic_model_fingerprint(model, active_snapshot: snapshot)
      query_context = receipt_context(model, model_fingerprint: model_fingerprint)
      build_query_receipt(
        model,
        command: "measure_distance",
        state: state,
        started_at: started_at,
        unit_info: unit_info,
        coordinate_space: "active_context",
        context: query_context
      )
    end

    def handle_query_overlap(params)
      started_at = monotonic_now
      model = require_model
      unit_info = resolve_public_unit(model, params["unit"] || "in")
      first_pid, second_pid = query_pid_pair(params, %w[first_pid second_pid])
      first = require_entity_by_pid(model, first_pid)
      second = require_entity_by_pid(model, second_pid)
      first_box = box_triplet(first.bounds)
      second_box = box_triplet(second.bounds)
      lower = 3.times.map { |index| [first_box[0][index], second_box[0][index]].max }
      upper = 3.times.map { |index| [first_box[1][index], second_box[1][index]].min }
      overlap = 3.times.all? { |index| lower[index] <= upper[index] + SEMANTIC_QUANTUM }
      resolved = unit_info["resolved_unit"]
      overlap_box = if overlap
                      {
                        "min" => convert_triplet_from_internal(lower, resolved),
                        "max" => convert_triplet_from_internal(upper, resolved)
                      }
                    end
      state = {
        "query" => "query_overlap",
        "first_pid" => first_pid,
        "second_pid" => second_pid,
        "overlap" => overlap,
        "overlap_box" => overlap_box,
        "semantic_fingerprint" => Digest::SHA256.hexdigest(
          JSON.generate(
            {
              "query" => "query_overlap",
              "first" => semantic_entity_state(model, first)["semantic_fingerprint"],
              "second" => semantic_entity_state(model, second)["semantic_fingerprint"]
            }
          )
        )
      }
      snapshot = semantic_active_entity_snapshot(model)
      model_fingerprint = semantic_model_fingerprint(model, active_snapshot: snapshot)
      query_context = receipt_context(model, model_fingerprint: model_fingerprint)
      build_query_receipt(
        model,
        command: "query_overlap",
        state: state,
        started_at: started_at,
        unit_info: unit_info,
        coordinate_space: "active_context",
        context: query_context
      )
    end
  end
end
