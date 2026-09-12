# cdt_sketchup/actions/material.rb — strict tag/material/texture actions
# Wing: code | Topic: sketchup_bridge | Updated: 2026-09-12

module CDTSketchUp
  class BridgeServer
    private

    def validate_material_texture_params(params)
      unless params.is_a?(Hash)
        raise BridgeError.new("invalid_argument", "material_apply_texture params must be an object")
      end
      unknown_keys = params.keys - MATERIAL_TEXTURE_PARAM_KEYS
      unless unknown_keys.empty?
        raise BridgeError.new(
          "invalid_argument",
          "material_apply_texture params contain unsupported keys: #{unknown_keys.sort.join(', ')}"
        )
      end
      material_name = bounded_name(params["material"], "material")
      texture_key = params["texture_key"]
      unless texture_key.is_a?(String) && !texture_key.strip.empty?
        raise BridgeError.new("invalid_argument", "texture_key must be a non-empty string")
      end
      width = finite_number(params["width"], "width")
      height = finite_number(params["height"], "height")
      unless width.positive? && height.positive?
        raise BridgeError.new("invalid_argument", "texture dimensions must be positive")
      end
      [material_name, texture_key.strip, width, height]
    end

    def preflight_material_apply_texture(model, params)
      material_name, texture_key, _width, _height = validate_material_texture_params(params)
      require_material(model, material_name)
      manifest, = texture_registry_manifest
      entry = manifest[texture_key] || manifest[texture_key.to_s]
      unless entry.is_a?(Hash) && entry["file"].is_a?(String)
        raise BridgeError.new("texture_not_found", "Texture asset was not found")
      end
      resolve_texture_file(texture_key, entry["file"])
      true
    end

    def execute_material_apply_texture(model, params)
      material_name, texture_key, width, height = validate_material_texture_params(params)
      material = require_material(model, material_name)
      manifest, = texture_registry_manifest
      entry = manifest[texture_key] || manifest[texture_key.to_s]
      unless entry.is_a?(Hash) && entry["file"].is_a?(String)
        raise BridgeError.new("texture_not_found", "Texture asset was not found")
      end
      texture_path = resolve_texture_file(texture_key, entry["file"])
      before = material_semantic_state(material)
      begin
        material.texture = texture_path
        texture = material.texture
        raise BridgeError.new("component_failed", "SketchUp did not attach the texture") unless texture
        texture.size = [width, height]
      rescue BridgeError
        raise
      rescue StandardError => error
        log("material texture failed: #{error.class}: #{error.message}")
        raise BridgeError.new("component_failed", "SketchUp did not apply the texture")
      end
      after = material_semantic_state(material)
      {
        "state" => after,
        "metadata" => {
          "material" => material.name.to_s,
          "texture_key" => texture_key,
          "requested_width" => width,
          "requested_height" => height,
          "before_fingerprint" => before["semantic_fingerprint"]
        }
      }
    end

    def handle_tag_create(params)
      model = require_model
      name = bounded_name(params["name"], "name")
      existing = model.layers[name]
      return { "name" => existing.name.to_s, "created" => false } if existing

      with_operation(model, "CDT: Create Tag") do
        tag = model.layers.add(name)
        {
          "name" => tag.name.to_s,
          "created" => true
        }
      end
    end

    def validate_tag_assign_params(params)
      unless params.is_a?(Hash)
        raise BridgeError.new("invalid_argument", "tag_assign params must be an object")
      end
      unknown_tag_keys = params.keys - TAG_ASSIGN_PARAM_KEYS
      unless unknown_tag_keys.empty?
        raise BridgeError.new(
          "invalid_argument",
          "tag_assign params contain unsupported keys: #{unknown_tag_keys.sort.join(', ')}"
        )
      end
      unless params.key?("persistent_id")
        raise BridgeError.new("invalid_argument", "tag_assign persistent_id is required")
      end
      persistent_id = bounded_integer(params["persistent_id"], minimum: 1, maximum: (2**63) - 1, name: "persistent_id")
      [persistent_id, bounded_name(params["tag"], "tag")]
    end

    def validate_material_assign_params(params)
      unless params.is_a?(Hash)
        raise BridgeError.new("invalid_argument", "material_assign params must be an object")
      end
      unknown_material_keys = params.keys - MATERIAL_ASSIGN_PARAM_KEYS
      unless unknown_material_keys.empty?
        raise BridgeError.new(
          "invalid_argument",
          "material_assign params contain unsupported keys: #{unknown_material_keys.sort.join(', ')}"
        )
      end
      unless params.key?("persistent_id")
        raise BridgeError.new("invalid_argument", "material_assign persistent_id is required")
      end
      persistent_id = bounded_integer(params["persistent_id"], minimum: 1, maximum: (2**63) - 1, name: "persistent_id")
      side = params["side"] || "both"
      unless %w[front back both].include?(side)
        raise BridgeError.new("invalid_argument", "side must be front, back, or both")
      end
      [persistent_id, bounded_name(params["material"], "material"), side]
    end

    def preflight_tag_assign(model, params)
      persistent_id, tag_name = validate_tag_assign_params(params)
      require_taggable_entity(model, persistent_id)
      raise BridgeError.new("tag_not_found", "SketchUp tag was not found") unless model.layers[tag_name]
      true
    end

    def preflight_material_assign(model, params)
      persistent_id, material_name, side = validate_material_assign_params(params)
      require_material_target(model, persistent_id, side)
      raise BridgeError.new("material_not_found", "SketchUp material was not found") unless model.materials[material_name]
      true
    end

    def execute_tag_assign(model, params)
      persistent_id, tag_name = validate_tag_assign_params(params)
      entity = require_taggable_entity(model, persistent_id)
      tag = model.layers[tag_name]
      raise BridgeError.new("tag_not_found", "SketchUp tag was not found") unless tag
      before = semantic_entity_state(model, entity)
      begin
        entity.layer = tag
      rescue StandardError => error
        log("tag assign failed: #{error.class}: #{error.message}")
        raise BridgeError.new("assign_failed", "SketchUp did not assign the tag")
      end
      {
        "entity" => entity,
        "metadata" => {
          "target_persistent_id" => persistent_id,
          "requested_tag" => tag.name.to_s,
          "before_geometry_fingerprint" => before["geometry_fingerprint"],
          "before_transformation" => before["transformation"]
        }
      }
    end

    def execute_material_assign(model, params)
      persistent_id, material_name, side = validate_material_assign_params(params)
      entity = require_material_target(model, persistent_id, side)
      material = model.materials[material_name]
      raise BridgeError.new("material_not_found", "SketchUp material was not found") unless material
      before = semantic_entity_state(model, entity)
      begin
        if entity.is_a?(Sketchup::Face)
          entity.material = material if side == "front" || side == "both"
          entity.back_material = material if side == "back" || side == "both"
        else
          entity.material = material
        end
      rescue StandardError => error
        log("material assign failed: #{error.class}: #{error.message}")
        raise BridgeError.new("assign_failed", "SketchUp did not assign the material")
      end
      {
        "entity" => entity,
        "metadata" => {
          "target_persistent_id" => persistent_id,
          "requested_material" => material.name.to_s,
          "requested_side" => side,
          "before_geometry_fingerprint" => before["geometry_fingerprint"],
          "before_transformation" => before["transformation"]
        }
      }
    end

    def handle_material_create(params)
      model = require_model
      name = bounded_name(params["name"], "name")
      color = params.key?("color") ? rgb_triplet(params["color"]) : nil
      existing = model.materials[name]

      with_operation(model, "CDT: Create Material") do
        material = existing || model.materials.add(name)
        material.color = Sketchup::Color.new(color[0], color[1], color[2]) if color
        {
          "name" => material.name.to_s,
          "created" => existing.nil?,
          "color" => material.color ? [material.color.red, material.color.green, material.color.blue] : nil
        }
      end
    end
  end
end
