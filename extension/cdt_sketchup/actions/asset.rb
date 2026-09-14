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
      if manifest.length > MAX_ASSET_REGISTRY_ENTRIES
        raise BridgeError.new("asset_registry_too_large", "Asset registry exceeds the entry budget")
      end
      [manifest, manifest_path]
    end

    def asset_manifest_identity(entry)
      sha256 = entry["sha256"]
      native_version = entry["native_version"]
      unless sha256.is_a?(String) && sha256.match?(/\A[a-f0-9]{64}\z/)
        raise BridgeError.new("asset_identity_unverified", "Component asset SHA-256 metadata is invalid")
      end
      unless native_version.is_a?(String) && !native_version.strip.empty? && native_version.length <= 128
        raise BridgeError.new("asset_identity_unverified", "Component asset native_version metadata is invalid")
      end
      {
        "sha256" => sha256,
        "native_version" => native_version.strip
      }
    end

    def asset_file_sha256(path)
      Digest::SHA256.file(path).hexdigest
    rescue StandardError => error
      log("asset hash failed: #{error.class}: #{error.message}")
      raise BridgeError.new("asset_identity_unverified", "Component asset bytes could not be verified")
    end

    def verified_asset_binding(asset_key, entry, resolved_path: nil)
      unless entry.is_a?(Hash) && entry["file"].is_a?(String)
        raise BridgeError.new("asset_not_found", "Component asset was not found")
      end
      resolved = resolved_path || resolve_asset_file(asset_key, entry["file"])
      identity = asset_manifest_identity(entry)
      observed_sha256 = asset_file_sha256(resolved)
      unless observed_sha256 == identity["sha256"]
        raise BridgeError.new("asset_identity_unverified", "Component asset bytes do not match registry identity")
      end
      identity.merge(
        "asset_key" => asset_key.to_s,
        "path" => resolved,
        "size_bytes" => File.size(resolved)
      )
    end

    def asset_registry_entries
      manifest, = asset_registry_manifest
      entries = []
      hashed_bytes = 0
      manifest.each do |key, value|
        base = {
          "asset_key" => key.to_s,
          "name" => value.is_a?(Hash) ? value["name"].to_s : "",
          "available" => false
        }
        unless value.is_a?(Hash) && value["file"].is_a?(String)
          entries << base.merge("reason" => "asset_identity_unverified")
          next
        end

        begin
          resolved = resolve_asset_file(key, value["file"])
          size_bytes = File.size(resolved)
          if hashed_bytes + size_bytes > MAX_ASSET_REGISTRY_HASH_BYTES
            entries << base.merge("reason" => "asset_registry_hash_budget_exceeded")
            next
          end
          hashed_bytes += size_bytes
          binding = verified_asset_binding(key, value, resolved_path: resolved)
          entries << base.merge(
            "available" => true,
            "file" => value["file"].to_s,
            "size_bytes" => binding["size_bytes"],
            "sha256" => binding["sha256"],
            "native_version" => binding["native_version"]
          )
        rescue BridgeError => error
          safe_file = value["file"].to_s.strip
          failed = base.merge("reason" => error.kind)
          if File.basename(safe_file) == safe_file
            failed["file"] = safe_file
          end
          entries << failed
        end
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
      resolved = canonical_contained_path(root, resolved, "asset_path_escape", allow_missing: true)
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

    def same_asset_file?(first_path, second_path)
      return false if first_path.nil? || second_path.nil?
      first = first_path.to_s
      second = second_path.to_s
      return false if first.empty? || second.empty?

      File.identical?(first, second)
    rescue StandardError
      File.expand_path(first) == File.expand_path(second)
    end

    def loaded_asset_definition(model, asset_path, binding: nil)
      if binding
        expected = expected_definition_asset_identity(binding)
        verified = model.definitions.find do |definition|
          semantic_asset_identity(model, definition) == expected
        end
        return verified if verified
      end

      model.definitions.find do |definition|
        definition.respond_to?(:path) && same_asset_file?(definition.path, asset_path)
      end
    end

    def asset_definition_used?(definition)
      return true unless definition.respond_to?(:count_used_instances)
      count = definition.count_used_instances
      return true unless count.is_a?(Integer)
      count.positive?
    rescue StandardError
      true
    end

    def asset_definition_rebindable?(definition)
      return false unless definition.respond_to?(:instances)
      return false unless definition.instances.empty?
      return false if definition.respond_to?(:live_component?) && definition.live_component?
      !asset_definition_used?(definition)
    rescue StandardError
      false
    end

    def expected_definition_asset_identity(binding)
      {
        "asset_key" => binding["asset_key"],
        "sha256" => binding["sha256"],
        "native_version" => binding["native_version"]
      }
    end

    def asset_definition_identity_matches?(model, definition, binding)
      semantic_asset_identity(model, definition) == expected_definition_asset_identity(binding)
    end

    def bind_asset_definition_identity(model, definition, binding)
      identity = expected_definition_asset_identity(binding)
      record = identity.merge(
        "geometry_fingerprint" => semantic_definition_geometry_fingerprint(definition)
      )
      begin
        model.set_attribute(
          ASSET_ATTRIBUTE_DICTIONARY,
          definition.guid.to_s,
          JSON.generate(record)
        )
      rescue StandardError => error
        log("asset identity binding failed: #{error.class}: #{error.message}")
        raise BridgeError.new("asset_identity_unverified", "Loaded component identity could not be bound")
      end
      unless semantic_asset_identity(model, definition) == identity
        raise BridgeError.new("asset_identity_unverified", "Loaded component identity could not be verified")
      end
      identity
    end

    def preflight_place_asset(model, params)
      asset_key, matrix = validate_place_asset_params(params)
      manifest, = asset_registry_manifest
      entry = manifest[asset_key] || manifest[asset_key.to_s]
      binding = verified_asset_binding(asset_key, entry)
      existing = loaded_asset_definition(model, binding["path"], binding: binding)
      if existing && !asset_definition_identity_matches?(model, existing, binding) &&
         !asset_definition_rebindable?(existing)
        raise BridgeError.new(
          "asset_definition_identity_mismatch",
          "A loaded definition for this asset is already in use but does not match the verified registry identity"
        )
      end
      transformation_from_matrix(matrix)
      true
    end

    def execute_place_asset(model, params)
      asset_key, matrix_values = validate_place_asset_params(params)
      manifest, = asset_registry_manifest
      entry = manifest[asset_key] || manifest[asset_key.to_s]
      binding = verified_asset_binding(asset_key, entry)
      asset_path = binding["path"]
      transform = transformation_from_matrix(matrix_values)
      requested = transform.to_a.map { |value| quantize_number(value) }

      definition = loaded_asset_definition(model, asset_path, binding: binding)
      definition_reused = !definition.nil? && asset_definition_identity_matches?(model, definition, binding)
      unless definition_reused
        if definition && !asset_definition_rebindable?(definition)
          raise BridgeError.new(
            "asset_definition_identity_mismatch",
            "A loaded definition for this asset is already in use but does not match the verified registry identity"
          )
        end

        before_definition_guids = model.definitions.map { |item| item.guid.to_s }
        definition = begin
          model.definitions.load(asset_path)
        rescue StandardError => error
          log("place asset failed: #{error.class}: #{error.message}")
          raise BridgeError.new("asset_not_found", "Component asset could not be loaded")
        end
        unless definition && definition.valid?
          raise BridgeError.new("asset_not_found", "Component asset could not be loaded")
        end

        post_load_sha256 = asset_file_sha256(asset_path)
        unless post_load_sha256 == binding["sha256"]
          raise BridgeError.new(
            "asset_changed_during_load",
            "Component asset bytes changed while SketchUp was loading the definition"
          )
        end

        definition_reused = before_definition_guids.include?(definition.guid.to_s)
        if definition_reused && !asset_definition_identity_matches?(model, definition, binding) &&
           !asset_definition_rebindable?(definition)
          raise BridgeError.new(
            "asset_definition_identity_mismatch",
            "A loaded definition for this asset is already in use but does not match the verified registry identity"
          )
        end
        bind_asset_definition_identity(model, definition, binding)
      end

      unless asset_definition_identity_matches?(model, definition, binding)
        raise BridgeError.new("asset_identity_unverified", "Loaded component identity is not verified")
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
          "asset_identity" => expected_definition_asset_identity(binding),
          "definition_reused" => definition_reused,
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
