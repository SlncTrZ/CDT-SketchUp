# cdt_sketchup/kernel/fingerprints.rb — model fingerprints and affected-set accounting
# Wing: code | Topic: sketchup_bridge | Updated: 2026-09-12

module CDTSketchUp
  class BridgeServer
    private

    def safe_semantic_model_fingerprint(model, active_snapshot: nil)
      [semantic_model_fingerprint(model, active_snapshot: active_snapshot), nil]
    rescue BridgeError => error
      [
        nil,
        {
          "kind" => error.kind,
          "message" => error.message
        }
      ]
    rescue StandardError => error
      log("semantic model fingerprint failed: #{error.class}: #{error.message}")
      [
        nil,
        {
          "kind" => "semantic_fingerprint_failed",
          "message" => "Semantic model fingerprint failed"
        }
      ]
    end

    def semantic_model_fingerprint(model, active_snapshot: nil)
      snapshot = active_snapshot || semantic_active_entity_snapshot(model)
      active_entities = snapshot.map do |persistent_id, state|
        [persistent_id, state["type"], state["semantic_fingerprint"]]
      end.sort

      definitions = model.definitions.map do |definition|
        [
          definition.guid.to_s,
          definition.name.to_s,
          definition.entities.length
        ]
      end.sort

      payload = {
        "active_entities" => active_entities,
        "definitions" => definitions,
        "materials" => model.materials.map { |material| material.name.to_s }.sort,
        "scenes" => model.pages.map { |page| page.name.to_s }.sort
      }
      Digest::SHA256.hexdigest(JSON.generate(payload))
    end

    def semantic_affected_entities(model, before_snapshot, after_snapshot)
      before_ids = before_snapshot.keys
      after_ids = after_snapshot.keys
      created = after_ids - before_ids
      deleted = []
      modified = []

      (before_ids - after_ids).each do |persistent_id|
        if entity_alive_by_pid?(model, persistent_id)
          modified << persistent_id
        else
          deleted << persistent_id
        end
      end

      (before_ids & after_ids).each do |persistent_id|
        before_state = before_snapshot[persistent_id]
        after_state = after_snapshot[persistent_id]
        modified << persistent_id if before_state != after_state
      end

      {
        "created" => created.sort,
        "modified" => modified.uniq.sort,
        "deleted" => deleted.sort
      }
    end

    def empty_affected_entities
      {
        "created" => [],
        "modified" => [],
        "deleted" => []
      }
    end
  end
end
