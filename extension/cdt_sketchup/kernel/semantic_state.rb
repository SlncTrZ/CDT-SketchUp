# cdt_sketchup/kernel/semantic_state.rb — semantic state extraction and fingerprints
# Wing: code | Topic: sketchup_bridge | Updated: 2026-09-12

module CDTSketchUp
  class BridgeServer
    private

    def material_semantic_state(material)
      texture = begin
        material.texture
      rescue StandardError
        nil
      end
      color = material.color
      texture_width = texture ? quantize_number(texture.width.to_f) : nil
      texture_height = texture ? quantize_number(texture.height.to_f) : nil
      payload = {
        "material" => material.name.to_s,
        "color" => color ? [color.red, color.green, color.blue] : nil,
        "texture_filename" => texture ? File.basename(texture.filename.to_s) : nil,
        "texture_width" => texture_width,
        "texture_height" => texture_height
      }
      payload.merge(
        "texture_image_width" => texture ? texture.image_width : nil,
        "texture_image_height" => texture ? texture.image_height : nil,
        "semantic_fingerprint" => Digest::SHA256.hexdigest(JSON.generate(payload))
      )
    end

    def camera_semantic_state(model)
      camera = model.active_view.camera
      eye = point_to_triplet(camera.eye)
      target = point_to_triplet(camera.target)
      up = vector_to_triplet(camera.up)
      fov = camera.fov.to_f
      perspective = camera.respond_to?(:perspective?) ? !!camera.perspective? : nil
      payload = {
        "eye" => eye,
        "target" => target,
        "up" => up,
        "fov" => fov,
        "perspective" => perspective
      }
      payload.merge(
        "camera_eye" => eye,
        "camera_target" => target,
        "camera_up" => up,
        "camera_fov" => fov,
        "camera_perspective" => perspective,
        "semantic_fingerprint" => Digest::SHA256.hexdigest(JSON.generate(payload))
      )
    end

    def scene_semantic_state(model)
      names = model.pages.map { |page| page.name.to_s }.sort
      payload = {
        "scene_count" => names.length,
        "scene_names" => names
      }
      payload.merge(
        "semantic_fingerprint" => Digest::SHA256.hexdigest(JSON.generate(payload))
      )
    end

    def semantic_active_entity_snapshot(model)
      active = model.active_entities.to_a
      if active.length > MAX_MODEL_FINGERPRINT_ENTITIES
        raise BridgeError.new(
          "semantic_state_too_large",
          "Active context exceeds model fingerprint entity limit"
        )
      end

      active.each_with_object({}) do |entity, snapshot|
        state = semantic_entity_state(model, entity)
        snapshot[state["persistent_id"]] = {
          "type" => state["type"],
          "semantic_fingerprint" => state["semantic_fingerprint"]
        }
      end
    end

    def safe_semantic_active_entity_snapshot(model)
      [semantic_active_entity_snapshot(model), nil]
    rescue BridgeError => error
      [nil, { "kind" => error.kind, "message" => error.message }]
    rescue StandardError => error
      log("semantic active snapshot failed: #{error.class}: #{error.message}")
      [
        nil,
        {
          "kind" => "semantic_snapshot_failed",
          "message" => "Semantic active-entity snapshot failed"
        }
      ]
    end

    def semantic_entity_state(model, entity)
      counts = semantic_geometry_counts(entity)
      bounds = semantic_bounds(entity)
      surface = semantic_surface_state(entity)
      geometry_fingerprint = semantic_geometry_fingerprint(entity)
      manifold = semantic_manifold(entity)
      volume = semantic_volume(entity, manifold)
      tag = entity.respond_to?(:layer) && entity.layer ? entity.layer.name.to_s : nil
      material = if entity.respond_to?(:material) && entity.material
                   entity.material.name.to_s
                 end
      back_material = if entity.is_a?(Sketchup::Face) && entity.back_material
                        entity.back_material.name.to_s
                      end
      transformation = if entity.respond_to?(:transformation)
                         entity.transformation.to_a.map { |value| quantize_number(value) }
                       end
      definition_guid = if entity.respond_to?(:definition) && entity.definition.respond_to?(:guid)
                          entity.definition.guid.to_s
                        end
      definition_summary = if entity.is_a?(Sketchup::ComponentInstance) && entity.definition.respond_to?(:guid)
                             {
                               "guid" => entity.definition.guid.to_s,
                               "name" => entity.definition.name.to_s,
                               "geometry_fingerprint" => semantic_definition_geometry_fingerprint(entity.definition)
                             }
                           end
      hierarchy = semantic_hierarchy(entity)

      identity_payload = {
        "persistent_id" => entity.persistent_id,
        "type" => entity.typename,
        "definition_guid" => definition_guid
      }
      semantic_payload = {
        "type" => entity.typename,
        "bounds" => bounds,
        "geometry" => counts,
        "geometry_fingerprint" => geometry_fingerprint,
        "surface" => surface,
        "tag" => tag,
        "material" => material,
        "back_material" => back_material,
        "manifold" => manifold,
        "volume" => volume,
        "transformation" => transformation,
        "hierarchy" => hierarchy
      }

      {
        "persistent_id" => entity.persistent_id,
        "type" => entity.typename,
        "valid" => entity.valid?,
        "deleted" => false,
        "active_context" => (
          entity.respond_to?(:parent) &&
          entity.parent == model.active_entities.parent
        ),
        "bounds" => bounds,
        "geometry" => counts,
        "vertex_count" => counts["vertex_count"],
        "edge_count" => counts["edge_count"],
        "face_count" => counts["face_count"],
        "surface" => surface,
        "area" => surface && surface["area"],
        "normal" => surface && surface["normal"],
        "tag" => tag,
        "material" => material,
        "back_material" => back_material,
        "manifold" => manifold,
        "volume" => volume,
        "transformation" => transformation,
        "hierarchy" => hierarchy,
        "definition" => definition_summary,
        "identity_fingerprint" => Digest::SHA256.hexdigest(JSON.generate(identity_payload)),
        "geometry_fingerprint" => geometry_fingerprint,
        "semantic_fingerprint" => Digest::SHA256.hexdigest(JSON.generate(semantic_payload))
      }
    end

    def semantic_bounds(entity)
      unless entity.respond_to?(:bounds)
        return nil
      end
      bounds = entity.bounds
      {
        "min" => quantized_point(bounds.min),
        "max" => quantized_point(bounds.max),
        "center" => quantized_point(bounds.center),
        "size" => [
          quantize_number(bounds.width),
          quantize_number(bounds.height),
          quantize_number(bounds.depth)
        ]
      }
    end

    def semantic_surface_state(entity)
      return nil unless entity.is_a?(Sketchup::Face)

      {
        "area" => quantize_number(entity.area),
        "normal" => quantized_point(entity.normal)
      }
    end

    def semantic_volume(entity, manifold)
      return nil unless manifold == true && entity.respond_to?(:volume)

      value = entity.volume.to_f
      return nil unless value.finite?

      quantize_number(value)
    rescue StandardError
      nil
    end

    def semantic_geometry_counts(entity)
      if entity.is_a?(Sketchup::Edge)
        return {
          "vertex_count" => 2,
          "edge_count" => 1,
          "face_count" => entity.faces.length
        }
      end
      if entity.is_a?(Sketchup::Face)
        return {
          "vertex_count" => entity.vertices.length,
          "edge_count" => entity.edges.length,
          "face_count" => 1
        }
      end

      entities = semantic_definition_entities(entity)
      unless entities
        return {
          "vertex_count" => 0,
          "edge_count" => 0,
          "face_count" => 0
        }
      end
      edges = entities.grep(Sketchup::Edge)
      vertices = edges.flat_map { |edge| [edge.start, edge.end] }.uniq
      {
        "vertex_count" => vertices.length,
        "edge_count" => edges.length,
        "face_count" => entities.grep(Sketchup::Face).length
      }
    end

    def semantic_definition_entities(entity)
      if entity.is_a?(Sketchup::Group)
        entity.entities.to_a
      elsif entity.is_a?(Sketchup::ComponentInstance)
        entity.definition.entities.to_a
      end
    end

    def semantic_geometry_fingerprint(entity)
      if entity.is_a?(Sketchup::Edge)
        endpoints = [
          quantized_point(entity.start.position),
          quantized_point(entity.end.position)
        ].sort
        return Digest::SHA256.hexdigest(JSON.generate({ "edges" => [endpoints] }))
      end
      if entity.is_a?(Sketchup::Face)
        vertices = entity.vertices.map { |vertex| quantized_point(vertex.position) }.sort
        normal = quantized_point(entity.normal)
        return Digest::SHA256.hexdigest(
          JSON.generate(
            {
              "vertices" => vertices,
              "normal" => normal
            }
          )
        )
      end

      entities = semantic_definition_entities(entity)
      return Digest::SHA256.hexdigest(JSON.generate({ "geometry" => [] })) unless entities

      canonical_entities_geometry_fingerprint(entities)
    end

    def canonical_entities_geometry_fingerprint(entities)
      edges = entities.grep(Sketchup::Edge)
      if edges.length > MAX_FINGERPRINT_EDGES
        raise BridgeError.new("semantic_state_too_large", "Entity exceeds fingerprint edge limit")
      end
      canonical_edges = edges.map do |edge|
        [
          quantized_point(edge.start.position),
          quantized_point(edge.end.position)
        ].sort
      end.sort
      faces = entities.grep(Sketchup::Face).map do |face|
        [
          face.vertices.map { |vertex| quantized_point(vertex.position) }.sort,
          quantized_point(face.normal)
        ]
      end.sort
      Digest::SHA256.hexdigest(
        JSON.generate(
          {
            "edges" => canonical_edges,
            "faces" => faces
          }
        )
      )
    end

    def semantic_manifold(entity)
      definition = entity.respond_to?(:definition) ? entity.definition : nil
      if definition && definition.respond_to?(:manifold?)
        return definition.manifold?
      end
      return entity.manifold? if entity.respond_to?(:manifold?)
      nil
    end

    def semantic_hierarchy(entity)
      parent = entity.respond_to?(:parent) ? entity.parent : nil
      definition = entity.respond_to?(:definition) ? entity.definition : nil
      child_entities = semantic_definition_entities(entity)
      child_count = child_entities ? child_entities.length : 0
      child_ids = if child_entities && child_count <= MAX_OBJECTS
                    child_entities.map(&:persistent_id).sort
                  elsif child_entities
                    nil
                  else
                    []
                  end
      face_edges = entity.is_a?(Sketchup::Face) ? entity.edges : nil
      face_edge_ids = if face_edges && face_edges.length <= MAX_OBJECTS
                        face_edges.map(&:persistent_id).sort
                      elsif face_edges
                        nil
                      end
      {
        "parent_type" => parent ? parent.class.name.to_s : nil,
        "parent_definition_guid" => parent.respond_to?(:guid) ? parent.guid.to_s : nil,
        "child_count" => child_count,
        "child_persistent_ids" => child_ids,
        "child_persistent_ids_truncated" => child_count > MAX_OBJECTS,
        "edge_persistent_ids" => face_edge_ids,
        "definition_name" => definition ? definition.name.to_s : nil,
        "definition_guid" => definition && definition.respond_to?(:guid) ? definition.guid.to_s : nil
      }
    end

    def semantic_definition_geometry_fingerprint(definition)
      entities = definition.entities.to_a
      return Digest::SHA256.hexdigest(JSON.generate({ "geometry" => [] })) if entities.empty?

      canonical_entities_geometry_fingerprint(entities)
    end

    def semantic_definition_state(model, definition)
      members = definition.entities.to_a
      edges = members.grep(Sketchup::Edge)
      vertices = edges.flat_map { |edge| [edge.start, edge.end] }.uniq
      faces = members.grep(Sketchup::Face)
      instances = definition.instances
      if instances.length > MAX_OBJECTS
        raise BridgeError.new(
          "semantic_state_too_large",
          "Definition exceeds instance limit"
        )
      end
      bounds = begin
        definition_bounds(definition)
      rescue StandardError
        nil
      end
      geometry_fingerprint = semantic_definition_geometry_fingerprint(definition)
      semantic_payload = {
        "guid" => definition.guid.to_s,
        "name" => definition.name.to_s,
        "geometry_fingerprint" => geometry_fingerprint
      }
      {
        "guid" => definition.guid.to_s,
        "name" => definition.name.to_s,
        "group_definition" => definition.group?,
        "image_definition" => definition.image?,
        "instance_count" => instances.length,
        "instance_persistent_ids" => instances.map(&:persistent_id).sort,
        "bounds" => bounds,
        "geometry" => {
          "vertex_count" => vertices.length,
          "edge_count" => edges.length,
          "face_count" => faces.length
        },
        "geometry_fingerprint" => geometry_fingerprint,
        "active_context" => false,
        "semantic_fingerprint" => Digest::SHA256.hexdigest(JSON.generate(semantic_payload))
      }
    end

    def definition_bounds(definition)
      return nil unless definition.respond_to?(:bounds)

      bounds = definition.bounds
      {
        "min" => quantized_point(bounds.min),
        "max" => quantized_point(bounds.max),
        "center" => quantized_point(bounds.center),
        "size" => [
          quantize_number(bounds.width),
          quantize_number(bounds.height),
          quantize_number(bounds.depth)
        ]
      }
    end

    def serialize_entity(entity)
      result = {
        "persistent_id" => entity.persistent_id,
        "type" => entity.typename,
        "valid" => entity.valid?
      }
      result["name"] = entity.name.to_s if entity.respond_to?(:name)
      result["hidden"] = entity.hidden? if entity.respond_to?(:hidden?)
      if entity.respond_to?(:layer) && entity.layer
        result["tag"] = entity.layer.name.to_s
      end

      if entity.is_a?(Sketchup::Edge)
        result["start"] = point_to_array(entity.start.position)
        result["end"] = point_to_array(entity.end.position)
        result["length"] = entity.length.to_f
      elsif entity.is_a?(Sketchup::Face)
        result["area"] = entity.area.to_f
        result["normal"] = vector_to_array(entity.normal)
      elsif entity.is_a?(Sketchup::Group)
        result["entity_count"] = entity.entities.length
      elsif entity.is_a?(Sketchup::ComponentInstance)
        result["definition_name"] = entity.definition.name.to_s
      end
      result
    end
  end
end
