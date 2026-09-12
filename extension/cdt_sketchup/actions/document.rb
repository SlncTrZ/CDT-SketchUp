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
