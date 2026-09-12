# cdt_sketchup/actions/asset.rb — allowlisted asset registry and placement
# Wing: code | Topic: sketchup_bridge | Updated: 2026-09-12

module CDTSketchUp
  class BridgeServer
    private

    def asset_registry_root
      local_app_data = ENV["LOCALAPPDATA"]
      base = if local_app_data && !local_app_data.empty?
               File.join(local_app_data, "CDT-SketchUp")
             else
               File.join(Dir.home, ".cdt-sketchup")
             end
      File.join(base, "assets")
    end

    def asset_registry_manifest
      manifest_path = File.join(asset_registry_root, ASSET_MANIFEST_FILENAME)
      return [{}, nil] unless File.file?(manifest_path)

      begin
        manifest = JSON.parse(File.read(manifest_path, encoding: "UTF-8"))
      rescue StandardError
        raise BridgeError.new("asset_not_found", "Asset registry manifest is unreadable")
      end
      unless manifest.is_a?(Hash)
        raise BridgeError.new("asset_not_found", "Asset registry manifest is unreadable")
      end
      [manifest, manifest_path]
    end

    def asset_registry_entries
      manifest, = asset_registry_manifest
      entries = []
      manifest.each do |key, value|
        next unless value.is_a?(Hash) && value["file"].is_a?(String)

        begin
          resolved = resolve_asset_file(key, value["file"])
        rescue BridgeError
          next
        end
        entries << {
          "asset_key" => key.to_s,
          "name" => value["name"].to_s,
          "file" => value["file"].to_s,
          "size_bytes" => File.size(resolved)
        }
      end
      entries.sort_by { |entry| entry["asset_key"] }
    end

    def resolve_asset_file(asset_key, file_name)
      unless file_name.is_a?(String) && !file_name.strip.empty?
        raise BridgeError.new("asset_not_found", "Component asset was not found")
      end
      if File.basename(file_name) != file_name.strip
        raise BridgeError.new("asset_path_escape", "Asset file must be a plain file name")
      end
      unless file_name.strip.downcase.end_with?(".skp")
        raise BridgeError.new("asset_path_escape", "Asset file must use the .skp extension")
      end
      root = File.expand_path(asset_registry_root)
      resolved = File.expand_path(File.join(root, file_name.strip))
      resolved = canonical_contained_path(root, resolved, "asset_path_escape")
      manifest, = asset_registry_manifest
      bound = manifest[asset_key] || manifest[asset_key.to_s]
      unless bound.is_a?(Hash) && bound["file"].to_s == file_name.strip
        raise BridgeError.new("asset_not_found", "Component asset was not found")
      end
      unless File.file?(resolved)
        raise BridgeError.new("asset_not_found", "Component asset was not found")
      end
      if File.size(resolved) > MAX_ASSET_BYTES
        raise BridgeError.new("asset_too_large", "Component asset exceeds the size budget")
      end
      resolved
    end

    def handle_asset_list(params)
      started_at = monotonic_now
      model = require_model
      unit_info = resolve_public_unit(model, params["unit"] || "in")
      entries = asset_registry_entries
      state = {
        "query" => "asset_list",
        "asset_root" => "assets",
        "asset_count" => entries.length,
        "assets" => entries,
        "semantic_fingerprint" => Digest::SHA256.hexdigest(
          JSON.generate({ "query" => "asset_list", "assets" => entries })
        )
      }
      snapshot = semantic_active_entity_snapshot(model)
      model_fingerprint = semantic_model_fingerprint(model, active_snapshot: snapshot)
      query_context = receipt_context(model, model_fingerprint: model_fingerprint)
      build_query_receipt(
        model,
        command: "asset_list",
        state: state,
        started_at: started_at,
        unit_info: unit_info,
        coordinate_space: "active_context",
        context: query_context
      )
    end

    def validate_place_asset_params(params)
      unless params.is_a?(Hash)
        raise BridgeError.new("invalid_argument", "place_asset params must be an object")
      end
      unknown_keys = params.keys - PLACE_ASSET_PARAM_KEYS
      unless unknown_keys.empty?
        raise BridgeError.new(
          "invalid_argument",
          "place_asset params contain unsupported keys: #{unknown_keys.sort.join(', ')}"
        )
      end
      asset_key = params["asset_key"]
      unless asset_key.is_a?(String) && !asset_key.strip.empty?
        raise BridgeError.new("invalid_argument", "asset_key must be a non-empty string")
      end
      matrix = params["matrix"]
      unless matrix.is_a?(Array) && matrix.length == 16
        raise BridgeError.new("invalid_argument", "matrix must contain exactly 16 numbers")
      end
      [asset_key.strip, matrix]
    end

    def preflight_place_asset(model, params)
      asset_key, matrix = validate_place_asset_params(params)
      manifest, = asset_registry_manifest
      entry = manifest[asset_key] || manifest[asset_key.to_s]
      unless entry.is_a?(Hash) && entry["file"].is_a?(String)
        raise BridgeError.new("asset_not_found", "Component asset was not found")
      end
      resolve_asset_file(asset_key, entry["file"])
      transformation_from_matrix(matrix)
      true
    end

    def execute_place_asset(model, params)
      asset_key, matrix_values = validate_place_asset_params(params)
      manifest, = asset_registry_manifest
      entry = manifest[asset_key] || manifest[asset_key.to_s]
      unless entry.is_a?(Hash) && entry["file"].is_a?(String)
        raise BridgeError.new("asset_not_found", "Component asset was not found")
      end
      asset_path = resolve_asset_file(asset_key, entry["file"])
      transform = transformation_from_matrix(matrix_values)
      requested = transform.to_a.map { |value| quantize_number(value) }
      before_guids = model.definitions.map { |definition| definition.guid.to_s }
      definition = begin
        model.definitions.load(asset_path)
      rescue StandardError => error
        log("place asset failed: #{error.class}: #{error.message}")
        raise BridgeError.new("asset_not_found", "Component asset could not be loaded")
      end
      unless definition && definition.valid?
        raise BridgeError.new("asset_not_found", "Component asset could not be loaded")
      end
      instance = begin
        model.active_entities.add_instance(definition, transform)
      rescue ArgumentError, RuntimeError => error
        log("place asset failed: #{error.class}: #{error.message}")
        raise BridgeError.new("component_failed", "SketchUp did not place the asset instance")
      end
      unless instance && instance.valid? && instance.is_a?(Sketchup::ComponentInstance)
        raise BridgeError.new("component_failed", "SketchUp did not produce an asset instance")
      end
      {
        "entity" => instance,
        "metadata" => {
          "asset_key" => asset_key,
          "asset_name" => entry["name"].to_s,
          "definition_reused" => before_guids.include?(definition.guid.to_s),
          "requested_transformation" => requested
        }
      }
    end

    def texture_registry_manifest
      manifest_path = File.join(asset_registry_root, TEXTURE_MANIFEST_FILENAME)
      return [{}, nil] unless File.file?(manifest_path)

      begin
        manifest = JSON.parse(File.read(manifest_path, encoding: "UTF-8"))
      rescue StandardError
        raise BridgeError.new("texture_not_found", "Texture registry manifest is unreadable")
      end
      unless manifest.is_a?(Hash)
        raise BridgeError.new("texture_not_found", "Texture registry manifest is unreadable")
      end
      [manifest, manifest_path]
    end

    def texture_registry_entries
      manifest, = texture_registry_manifest
      entries = []
      manifest.each do |key, value|
        next unless value.is_a?(Hash) && value["file"].is_a?(String)

        begin
          resolved = resolve_texture_file(key, value["file"])
        rescue BridgeError
          next
        end
        entries << {
          "texture_key" => key.to_s,
          "name" => value["name"].to_s,
          "file" => value["file"].to_s,
          "size_bytes" => File.size(resolved)
        }
      end
      entries.sort_by { |entry| entry["texture_key"] }
    end

    def resolve_texture_file(texture_key, file_name)
      unless file_name.is_a?(String) && !file_name.strip.empty?
        raise BridgeError.new("texture_not_found", "Texture asset was not found")
      end
      if File.basename(file_name) != file_name.strip
        raise BridgeError.new("texture_path_escape", "Texture file must be a plain file name")
      end
      unless TEXTURE_EXTENSIONS.include?(File.extname(file_name.strip).downcase)
        raise BridgeError.new("texture_path_escape", "Texture file must use a raster image extension")
      end
      root = File.expand_path(asset_registry_root)
      resolved = File.expand_path(File.join(root, file_name.strip))
      resolved = canonical_contained_path(root, resolved, "texture_path_escape")
      manifest, = texture_registry_manifest
      bound = manifest[texture_key] || manifest[texture_key.to_s]
      unless bound.is_a?(Hash) && bound["file"].to_s == file_name.strip
        raise BridgeError.new("texture_not_found", "Texture asset was not found")
      end
      unless File.file?(resolved)
        raise BridgeError.new("texture_not_found", "Texture asset was not found")
      end
      if File.size(resolved) > MAX_TEXTURE_BYTES
        raise BridgeError.new("texture_too_large", "Texture asset exceeds the size budget")
      end
      resolved
    end

    def handle_texture_list(params)
      started_at = monotonic_now
      model = require_model
      unit_info = resolve_public_unit(model, params["unit"] || "in")
      entries = texture_registry_entries
      state = {
        "query" => "texture_list",
        "asset_root" => "assets",
        "texture_count" => entries.length,
        "textures" => entries,
        "semantic_fingerprint" => Digest::SHA256.hexdigest(
          JSON.generate({ "query" => "texture_list", "textures" => entries })
        )
      }
      snapshot = semantic_active_entity_snapshot(model)
      model_fingerprint = semantic_model_fingerprint(model, active_snapshot: snapshot)
      query_context = receipt_context(model, model_fingerprint: model_fingerprint)
      build_query_receipt(
        model,
        command: "texture_list",
        state: state,
        started_at: started_at,
        unit_info: unit_info,
        coordinate_space: "active_context",
        context: query_context
      )
    end
  end
end
