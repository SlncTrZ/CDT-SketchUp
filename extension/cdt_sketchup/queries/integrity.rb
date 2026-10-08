# cdt_sketchup/queries/integrity.rb — CAD integrity reports
# Wing: code | Topic: sketchup_bridge | Updated: 2026-09-12

module CDTSketchUp
  class BridgeServer
    private

    def handle_integrity_report(params)
      started_at = monotonic_now
      model = require_model
      unit_info = resolve_public_unit(model, params["unit"] || "in")
      entities = model.active_entities.to_a
      truncated = entities.length > MAX_INTEGRITY_SCAN
      scanned = truncated ? entities.first(MAX_INTEGRITY_SCAN) : entities
      counts = Hash.new(0)
      degenerate = []
      non_manifold = []
      tagged_raw = []
      bad_transforms = []
      default_tags = %w[Layer0 Untagged]
      scanned.each do |entity|
        counts[entity.typename] += 1
        if entity.is_a?(Sketchup::Edge)
          degenerate << entity.persistent_id if entity.length.to_f <= SEMANTIC_QUANTUM
          faces_count = entity.faces.length
          non_manifold << entity.persistent_id if faces_count > 2
        end
        if (entity.is_a?(Sketchup::Edge) || entity.is_a?(Sketchup::Face)) &&
            entity.respond_to?(:layer) && entity.layer &&
            !default_tags.include?(entity.layer.name.to_s)
          tagged_raw << entity.persistent_id
        end
        if (entity.is_a?(Sketchup::Group) || entity.is_a?(Sketchup::ComponentInstance)) &&
            entity.respond_to?(:transformation)
          determinant = transformation_determinant(entity.transformation.to_a)
          bad_transforms << entity.persistent_id if determinant.abs <= MIN_TRANSFORM_DETERMINANT
        end
      end
      used_material_names = []
      scanned.each do |entity|
        next unless entity.respond_to?(:material) && entity.material
        used_material_names << entity.material.name.to_s
        if entity.is_a?(Sketchup::Face) && entity.back_material
          used_material_names << entity.back_material.name.to_s
        end
      end
      definition_walk_truncated = false
      visited_definition_entities = 0
      model.definitions.each do |definition|
        next if definition.group? || definition.image?
        definition.entities.each do |entity|
          visited_definition_entities += 1
          if visited_definition_entities > 20000
            definition_walk_truncated = true
            break
          end
          next unless entity.respond_to?(:material) && entity.material
          used_material_names << entity.material.name.to_s
        end
        break if definition_walk_truncated
      end
      used_material_names.uniq!
      unused_definitions = model.definitions.select do |definition|
        !definition.group? && !definition.image? && definition.count_used_instances.zero?
      end.map { |definition| definition.name.to_s }.sort
      unused_materials = model.materials.map { |material| material.name.to_s }.reject do |name|
        used_material_names.include?(name)
      end.sort
      state = {
        "query" => "integrity_report",
        "scanned_entities" => scanned.length,
        "scan_truncated" => truncated || definition_walk_truncated,
        "model_complexity" => {
          "active_entities" => model.active_entities.length,
          "definitions" => model.definitions.length,
          "materials" => model.materials.length,
          "scenes" => model.pages.length
        },
        "entity_counts" => counts,
        "degenerate_edges" => degenerate.sort,
        "non_manifold_edges" => non_manifold.sort,
        "tag_hygiene" => {
          "raw_tagged_off_default_count" => tagged_raw.length,
          "raw_tagged_sample" => tagged_raw.sort.first(50)
        },
        "invalid_transforms" => bad_transforms.sort,
        "unused_definitions" => unused_definitions,
        "unused_materials" => unused_materials,
        "issue_count" => degenerate.length + non_manifold.length + tagged_raw.length +
          bad_transforms.length + unused_definitions.length + unused_materials.length,
        "semantic_fingerprint" => Digest::SHA256.hexdigest(
          JSON.generate(
            {
              "query" => "integrity_report",
              "model" => semantic_model_fingerprint(model),
              "degenerate" => degenerate.sort,
              "non_manifold" => non_manifold.sort
            }
          )
        )
      }
      snapshot = semantic_active_entity_snapshot(model)
      model_fingerprint = semantic_model_fingerprint(model, active_snapshot: snapshot)
      query_context = receipt_context(model, model_fingerprint: model_fingerprint)
      build_query_receipt(
        model,
        command: "integrity_report",
        state: state,
        started_at: started_at,
        unit_info: unit_info,
        coordinate_space: "active_context",
        context: query_context
      )
    end
  end
end
