# cdt_sketchup/actions/document.rb — rooted document lifecycle
# Wing: code | Topic: sketchup_bridge | Updated: 2026-09-12

module CDTSketchUp
  class BridgeServer
    private

    def model_files_root
      local_app_data = ENV["LOCALAPPDATA"]
      base = if local_app_data && !local_app_data.empty?
               File.join(local_app_data, "CDT-SketchUp")
             else
               File.join(Dir.home, ".cdt-sketchup")
             end
      File.join(base, MODEL_FILES_ROOTNAME)
    end

    def resolve_model_file(file_name, allowed_extensions, allow_missing: false)
      unless file_name.is_a?(String) && !file_name.strip.empty?
        raise BridgeError.new("invalid_argument", "file must be a non-empty file name")
      end
      cleaned = file_name.strip
      if File.basename(cleaned) != cleaned
        raise BridgeError.new("model_path_escape", "Model file must be a plain file name")
      end
      extension = File.extname(cleaned).downcase.delete_prefix(".")
      unless allowed_extensions.include?(extension)
        raise BridgeError.new("model_path_escape", "Model file extension is not allowed")
      end
      root = File.expand_path(model_files_root)
      FileUtils.mkdir_p(root)
      resolved = File.expand_path(File.join(root, cleaned))
      canonical_contained_path(root, resolved, "model_path_escape", allow_missing: allow_missing)
    end

    def model_file_state(action, file_name, extra = {})
      payload = { "query" => action, "file" => file_name }.merge(extra)
      {
        "file" => file_name,
        "semantic_fingerprint" => Digest::SHA256.hexdigest(JSON.generate(payload))
      }.merge(extra)
    end

    def handle_model_list(params)
      started_at = monotonic_now
      model = require_model
      unit_info = resolve_public_unit(model, params["unit"] || "in")
      root = model_files_root
      models = if Dir.exist?(root)
                 Dir.children(root).select { |name| name.downcase.end_with?(".skp") }.sort.map do |name|
                   { "file" => name, "size_bytes" => File.size(File.join(root, name)) }
                 end
               else
                 []
               end
      state = {
        "query" => "model_list",
        "models_root" => MODEL_FILES_ROOTNAME,
        "model_count" => models.length,
        "models" => models,
        "semantic_fingerprint" => Digest::SHA256.hexdigest(
          JSON.generate({ "query" => "model_list", "models" => models })
        )
      }
      snapshot = semantic_active_entity_snapshot(model)
      model_fingerprint = semantic_model_fingerprint(model, active_snapshot: snapshot)
      query_context = receipt_context(model, model_fingerprint: model_fingerprint)
      build_query_receipt(
        model,
        command: "model_list",
        state: state,
        started_at: started_at,
        unit_info: unit_info,
        coordinate_space: "active_context",
        context: query_context
      )
    end

    def handle_model_save(params)
      started_at = monotonic_now
      model = require_model
      path = model.path.to_s
      if path.empty?
        raise BridgeError.new("model_save_failed", "Model has no path; use model_save_as")
      end
      saved = begin
        model.save(path)
      rescue StandardError => error
        log("model save failed: #{error.class}: #{error.message}")
        raise BridgeError.new("model_save_failed", "SketchUp did not save the model")
      end
      unless saved && File.file?(path) && File.size(path).positive?
        raise BridgeError.new("model_save_failed", "SketchUp did not save the model")
      end
      state = model_file_state(
        "model_save", File.basename(path),
        "saved" => true, "size_bytes" => File.size(path), "model_guid" => model.guid.to_s
      )
      file_operation_receipt(
        model, "model_save", state,
        [semantic_check("action.file_saved", true, true)],
        started_at
      )
    end

    def handle_model_save_as(params)
      started_at = monotonic_now
      model = require_model
      unless params.is_a?(Hash)
        raise BridgeError.new("invalid_argument", "model_save_as params must be an object")
      end
      unknown_keys = params.keys - MODEL_SAVE_AS_PARAM_KEYS
      unless unknown_keys.empty?
        raise BridgeError.new(
          "invalid_argument",
          "model_save_as params contain unsupported keys: #{unknown_keys.sort.join(', ')}"
        )
      end
      resolved = resolve_model_file(params["file"], %w[skp], allow_missing: true)
      overwrite = params["overwrite"]
      overwrite = false if overwrite.nil?
      unless overwrite == true || overwrite == false
        raise BridgeError.new("invalid_argument", "overwrite must be boolean")
      end
      if File.file?(resolved) && !overwrite
        raise BridgeError.new("model_already_exists", "Model file exists without overwrite")
      end
      saved = begin
        model.save(resolved)
      rescue StandardError => error
        log("model save_as failed: #{error.class}: #{error.message}")
        raise BridgeError.new("model_save_failed", "SketchUp did not save the model")
      end
      unless saved && File.file?(resolved) && File.size(resolved).positive?
        raise BridgeError.new("model_save_failed", "SketchUp did not save the model")
      end
      state = model_file_state(
        "model_save_as", File.basename(resolved),
        "saved" => true, "size_bytes" => File.size(resolved), "model_guid" => model.guid.to_s
      )
      file_operation_receipt(
        model, "model_save_as", state,
        [semantic_check("action.file_saved", true, true)],
        started_at
      )
    end

    def handle_model_open(params)
      started_at = monotonic_now
      model = require_model
      unless params.is_a?(Hash)
        raise BridgeError.new("invalid_argument", "model_open params must be an object")
      end
      unknown_keys = params.keys - MODEL_OPEN_PARAM_KEYS
      unless unknown_keys.empty?
        raise BridgeError.new(
          "invalid_argument",
          "model_open params contain unsupported keys: #{unknown_keys.sort.join(', ')}"
        )
      end
      resolved = resolve_model_file(params["file"], %w[skp])
      unless File.file?(resolved)
        raise BridgeError.new("model_not_found", "Model file was not found")
      end
      unless model.respond_to?(:modified?)
        raise BridgeError.new("model_open_failed", "SketchUp cannot verify whether the active model is saved")
      end
      if model.modified?
        raise BridgeError.new("unsaved_model_changes", "Active model has unsaved changes; save before model_open")
      end
      if params.key?("if_model_guid") && !params["if_model_guid"].nil?
        unless params["if_model_guid"].to_s == model.guid.to_s
          raise BridgeError.new("context_mismatch", "Active model changed since the receipt")
        end
      end
      opened = begin
        Sketchup.open_file(resolved)
      rescue StandardError => error
        log("model open failed: #{error.class}: #{error.message}")
        raise BridgeError.new("model_open_failed", "SketchUp did not open the model")
      end
      unless opened
        raise BridgeError.new("model_open_failed", "SketchUp did not open the model")
      end
      fresh = require_model
      state = model_file_state(
        "model_open", File.basename(resolved),
        "opened" => true, "model_guid" => fresh.guid.to_s
      )
      file_operation_receipt(
        fresh, "model_open", state,
        [semantic_check("action.file_opened", true, true)],
        started_at
      )
    end


    def artifact_seal_root
      File.join(File.dirname(model_files_root), ARTIFACT_SEAL_ROOTNAME)
    end

    def artifact_sha256(path)
      Digest::SHA256.file(path).hexdigest
    rescue StandardError => error
      log("artifact hash failed: #{error.class}: #{error.message}")
      raise BridgeError.new("artifact_hash_failed", "Artifact bytes could not be hashed")
    end

    def artifact_source_file(params, keys)
      unless params.is_a?(Hash)
        raise BridgeError.new("invalid_argument", "artifact params must be an object")
      end
      unknown_keys = params.keys - keys
      unless unknown_keys.empty?
        raise BridgeError.new(
          "invalid_argument",
          "artifact params contain unsupported keys: #{unknown_keys.sort.join(', ')}"
        )
      end
      resolved = resolve_model_file(params["file"], %w[skp])
      unless File.file?(resolved)
        raise BridgeError.new("model_not_found", "Artifact source model was not found")
      end
      if File.size(resolved) > MAX_ARTIFACT_BYTES
        raise BridgeError.new("artifact_too_large", "Artifact exceeds the hashing/seal size budget")
      end
      resolved
    end

    def same_canonical_file?(first, second)
      File.realpath(first) == File.realpath(second)
    rescue StandardError
      false
    end

    def artifact_manifest_payload(sha256, size_bytes, model_guid)
      {
        "schema_version" => 1,
        "sha256" => sha256,
        "size_bytes" => size_bytes,
        "accepted_file" => "#{sha256}.skp",
        "model_guid" => model_guid.to_s,
        "sketchup_version" => Sketchup.version.to_s
      }
    end

    def artifact_manifest_state(root, sha256)
      manifest_path = File.join(root, "#{sha256}.json")
      unless File.file?(manifest_path)
        raise BridgeError.new("artifact_seal_not_found", "Artifact seal manifest was not found")
      end
      begin
        manifest = JSON.parse(File.read(manifest_path, encoding: "UTF-8"))
      rescue StandardError
        raise BridgeError.new("artifact_seal_corrupt", "Artifact seal manifest is unreadable")
      end
      unless manifest.is_a?(Hash) && manifest["sha256"] == sha256 &&
             manifest["accepted_file"] == "#{sha256}.skp"
        raise BridgeError.new("artifact_seal_corrupt", "Artifact seal manifest identity is invalid")
      end
      [manifest, manifest_path]
    end

    def handle_artifact_seal(params)
      started_at = monotonic_now
      model = require_model
      source = artifact_source_file(params, ARTIFACT_SEAL_PARAM_KEYS)
      if model.path.to_s.empty? || !same_canonical_file?(model.path.to_s, source)
        raise BridgeError.new("artifact_source_mismatch", "Artifact seal requires the active rooted model file")
      end
      if model.respond_to?(:modified?) && model.modified?
        raise BridgeError.new("unsaved_model_changes", "Save the active model before sealing the artifact")
      end

      size_bytes = File.size(source)
      sha256 = artifact_sha256(source)
      root = File.expand_path(artifact_seal_root)
      FileUtils.mkdir_p(root)
      accepted = canonical_contained_path(
        root, File.join(root, "#{sha256}.skp"), "artifact_path_escape", allow_missing: true
      )
      manifest_path = canonical_contained_path(
        root, File.join(root, "#{sha256}.json"), "artifact_path_escape", allow_missing: true
      )
      temp_copy = File.join(root, ".#{sha256}.#{Process.pid}.skp.tmp")
      temp_manifest = File.join(root, ".#{sha256}.#{Process.pid}.json.tmp")
      begin
        FileUtils.cp(source, temp_copy)
        copied_sha256 = artifact_sha256(temp_copy)
        source_after_sha256 = artifact_sha256(source)
        unless copied_sha256 == sha256 && source_after_sha256 == sha256 && File.size(source) == size_bytes
          raise BridgeError.new("artifact_changed_during_seal", "Artifact bytes changed while the seal was created")
        end

        if File.file?(accepted)
          unless artifact_sha256(accepted) == sha256
            raise BridgeError.new("artifact_seal_corrupt", "Existing content-addressed artifact is corrupt")
          end
          File.delete(temp_copy)
        else
          File.rename(temp_copy, accepted)
        end

        manifest = artifact_manifest_payload(sha256, size_bytes, model.guid)
        encoded = JSON.generate(manifest)
        if File.file?(manifest_path)
          existing, = artifact_manifest_state(root, sha256)
          unless existing == manifest
            raise BridgeError.new("artifact_seal_conflict", "Existing artifact seal metadata does not match")
          end
        else
          File.open(temp_manifest, File::WRONLY | File::CREAT | File::TRUNC, 0o600) do |file|
            file.write(encoded)
            file.flush
            begin
              file.fsync
            rescue SystemCallError, NotImplementedError
              nil
            end
          end
          File.rename(temp_manifest, manifest_path)
        end
      ensure
        begin
          File.delete(temp_copy) if File.file?(temp_copy)
          File.delete(temp_manifest) if File.file?(temp_manifest)
        rescue SystemCallError
          nil
        end
      end

      verified = artifact_sha256(accepted) == sha256
      state = model_file_state(
        "artifact_seal", File.basename(source),
        "sealed" => verified,
        "sha256" => sha256,
        "size_bytes" => size_bytes,
        "accepted_file" => File.join(ARTIFACT_SEAL_ROOTNAME, "#{sha256}.skp"),
        "manifest_file" => File.join(ARTIFACT_SEAL_ROOTNAME, "#{sha256}.json"),
        "model_guid" => model.guid.to_s
      )
      file_operation_receipt(
        model,
        "artifact_seal",
        state,
        [semantic_check("action.artifact_sealed", true, verified)],
        started_at
      )
    end

    def handle_artifact_verify(params)
      started_at = monotonic_now
      model = require_model
      source = artifact_source_file(params, ARTIFACT_VERIFY_PARAM_KEYS)
      sha256 = params["sha256"]
      unless sha256.is_a?(String) && sha256.match?(/\A[a-f0-9]{64}\z/)
        raise BridgeError.new("invalid_argument", "sha256 must be a lowercase 64-character SHA-256 hex string")
      end
      root = File.expand_path(artifact_seal_root)
      manifest, = artifact_manifest_state(root, sha256)
      accepted = canonical_contained_path(
        root, File.join(root, manifest["accepted_file"]), "artifact_path_escape"
      )
      unless File.file?(accepted) && artifact_sha256(accepted) == sha256 && File.size(accepted) == manifest["size_bytes"]
        raise BridgeError.new("artifact_seal_corrupt", "Content-addressed artifact no longer matches its manifest")
      end

      if !model.path.to_s.empty? && same_canonical_file?(model.path.to_s, source) &&
         model.respond_to?(:modified?) && model.modified?
        raise BridgeError.new("artifact_stale", "Active model has unsaved changes after the artifact seal")
      end
      current_sha256 = artifact_sha256(source)
      unless current_sha256 == sha256
        raise BridgeError.new("artifact_stale", "Rooted source artifact no longer matches the accepted seal")
      end
      if !model.path.to_s.empty? && same_canonical_file?(model.path.to_s, source) &&
         manifest["model_guid"].to_s != model.guid.to_s
        raise BridgeError.new("artifact_stale", "Active model identity no longer matches the accepted seal")
      end

      unit_info = resolve_public_unit(model, "in")
      state = {
        "query" => "artifact_verify",
        "file" => File.basename(source),
        "sha256" => sha256,
        "size_bytes" => File.size(source),
        "accepted_file" => File.join(ARTIFACT_SEAL_ROOTNAME, manifest["accepted_file"]),
        "verified" => true,
        "source_matches_seal" => true,
        "semantic_fingerprint" => Digest::SHA256.hexdigest(
          JSON.generate({ "query" => "artifact_verify", "file" => File.basename(source), "sha256" => sha256 })
        )
      }
      snapshot = semantic_active_entity_snapshot(model)
      model_fingerprint = semantic_model_fingerprint(model, active_snapshot: snapshot)
      build_query_receipt(
        model,
        command: "artifact_verify",
        state: state,
        started_at: started_at,
        unit_info: unit_info,
        coordinate_space: "active_context",
        context: receipt_context(model, model_fingerprint: model_fingerprint)
      )
    end

    def handle_model_export(params)
      started_at = monotonic_now
      model = require_model
      unless params.is_a?(Hash)
        raise BridgeError.new("invalid_argument", "model_export params must be an object")
      end
      unknown_keys = params.keys - MODEL_EXPORT_PARAM_KEYS
      unless unknown_keys.empty?
        raise BridgeError.new(
          "invalid_argument",
          "model_export params contain unsupported keys: #{unknown_keys.sort.join(', ')}"
        )
      end
      format = params["format"].to_s.downcase
      unless MODEL_EXPORT_FORMATS.include?(format)
        raise BridgeError.new("model_export_failed", "Export format is not supported")
      end
      resolved = resolve_model_file(params["file"], [format], allow_missing: true)
      unless File.basename(resolved).downcase.end_with?(".#{format}")
        raise BridgeError.new("model_export_failed", "Export file must match the format")
      end
      overwrite = params["overwrite"]
      overwrite = false if overwrite.nil?
      unless overwrite == true || overwrite == false
        raise BridgeError.new("invalid_argument", "overwrite must be boolean")
      end
      if File.file?(resolved) && !overwrite
        raise BridgeError.new("model_already_exists", "Export file exists without overwrite")
      end
      exported = if RASTER_EXPORT_FORMATS.include?(format)
                   width = params.key?("width") ? params["width"] : 1024
                   height = params.key?("height") ? params["height"] : 768
                   width = bounded_integer(width, minimum: 64, maximum: 8192, name: "width")
                   height = bounded_integer(height, minimum: 64, maximum: 8192, name: "height")
                   begin
                     model.active_view.write_image(
                       filename: resolved, width: width, height: height, antialias: true
                     )
                   rescue StandardError => error
                     log("model raster export failed: #{error.class}: #{error.message}")
                     raise BridgeError.new("model_export_failed", "SketchUp did not export the image")
                   end
                 else
                   begin
                     model.export(resolved)
                   rescue StandardError => error
                     log("model export failed: #{error.class}: #{error.message}")
                     raise BridgeError.new("model_export_failed", "SketchUp did not export the model")
                   end
                 end
      unless exported && File.file?(resolved) && File.size(resolved).positive?
        raise BridgeError.new("model_export_failed", "SketchUp did not export the model")
      end
      state = model_file_state(
        "model_export", File.basename(resolved),
        "exported" => true, "format" => format,
        "size_bytes" => File.size(resolved), "model_guid" => model.guid.to_s
      )
      file_operation_receipt(
        model, "model_export", state,
        [semantic_check("action.file_exported", true, true)],
        started_at
      )
    end
  end
end
