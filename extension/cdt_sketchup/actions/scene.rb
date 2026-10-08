# cdt_sketchup/actions/scene.rb — strict scene control
# Wing: code | Topic: sketchup_bridge | Updated: 2026-09-12

module CDTSketchUp
  class BridgeServer
    private

    def handle_scene_list(params)
      started_at = monotonic_now
      model = require_model
      unit_info = resolve_public_unit(model, params["unit"] || "in")
      state = scene_semantic_state(model)
      query_camera_receipt(model, "scene_list", state, started_at, unit_info)
    end

    def validate_scene_create_params(params)
      unless params.is_a?(Hash)
        raise BridgeError.new("invalid_argument", "scene_create params must be an object")
      end
      unknown_keys = params.keys - SCENE_CREATE_PARAM_KEYS
      unless unknown_keys.empty?
        raise BridgeError.new(
          "invalid_argument",
          "scene_create params contain unsupported keys: #{unknown_keys.sort.join(', ')}"
        )
      end
      bounded_name(params["name"], "name")
    end

    def preflight_scene_create(model, params)
      name = validate_scene_create_params(params)
      if model.pages.any? { |page| page.name == name }
        raise BridgeError.new("already_exists", "Scene already exists")
      end
      true
    end

    def execute_scene_create(model, params)
      name = validate_scene_create_params(params)
      if model.pages.any? { |page| page.name == name }
        raise BridgeError.new("already_exists", "Scene already exists")
      end
      before_count = model.pages.length
      page = begin
        model.pages.add(name)
      rescue StandardError => error
        log("scene create failed: #{error.class}: #{error.message}")
        raise BridgeError.new("scene_failed", "SketchUp did not create the scene")
      end
      unless page && page.valid?
        raise BridgeError.new("scene_failed", "SketchUp did not create the scene")
      end
      {
        "state" => {
          "scene_name" => page.name.to_s,
          "scene_count" => model.pages.length,
          "semantic_fingerprint" => Digest::SHA256.hexdigest(
            JSON.generate({ "scene" => page.name.to_s, "count" => model.pages.length })
          )
        },
        "metadata" => {
          "requested_name" => name,
          "actual_name" => page.name.to_s,
          "before_count" => before_count
        }
      }
    end
  end
end
