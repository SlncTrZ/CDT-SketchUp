# cdt_sketchup/queries/topology.rb — connectivity queries
# Wing: code | Topic: sketchup_bridge | Updated: 2026-09-12

module CDTSketchUp
  class BridgeServer
    private

    def handle_query_topology(params)
      started_at = monotonic_now
      model = require_model
      unit_info = resolve_public_unit(model, params["unit"] || "in")
      persistent_id = query_pid_pair(params, %w[persistent_id]).first
      entity = require_entity_by_pid(model, persistent_id)
      connected_ids, connected_unresolved = connected_persistent_ids(entity)
      if connected_ids.length + connected_unresolved > MAX_TOPOLOGY_RESULTS
        raise BridgeError.new("semantic_state_too_large", "Topology exceeds entity limit")
      end
      counts = semantic_geometry_counts(entity)
      loops = entity.is_a?(Sketchup::Face) ? entity.loops : []
      state = {
        "query" => "query_topology",
        "persistent_id" => persistent_id,
        "type" => entity.typename,
        "connected_count" => connected_ids.length + connected_unresolved,
        "connected_persistent_ids" => connected_ids,
        "connected_unresolved_count" => connected_unresolved,
        "connected_truncated" => false,
        "vertex_count" => counts["vertex_count"],
        "edge_count" => counts["edge_count"],
        "face_count" => counts["face_count"],
        "loop_count" => loops.length,
        "manifold" => semantic_manifold(entity),
        "semantic_fingerprint" => Digest::SHA256.hexdigest(
          JSON.generate(
            {
              "query" => "query_topology",
              "entity" => semantic_entity_state(model, entity)["semantic_fingerprint"],
              "connected" => connected_ids,
              "unresolved" => connected_unresolved
            }
          )
        )
      }
      snapshot = semantic_active_entity_snapshot(model)
      model_fingerprint = semantic_model_fingerprint(model, active_snapshot: snapshot)
      query_context = receipt_context(model, model_fingerprint: model_fingerprint)
      build_query_receipt(
        model,
        command: "query_topology",
        state: state,
        started_at: started_at,
        unit_info: unit_info,
        coordinate_space: "active_context",
        context: query_context
      )
    end
  end
end
