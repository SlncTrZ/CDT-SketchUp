# cdt_sketchup/actions/camera.rb — strict camera control
# Wing: code | Topic: sketchup_bridge | Updated: 2026-09-12

module CDTSketchUp
  class BridgeServer
    private

    def handle_camera_get(params)
      started_at = monotonic_now
      model = require_model
      unit_info = resolve_public_unit(model, params["unit"] || "in")
      state = camera_semantic_state(model)
      query_camera_receipt(model, "camera_get", state, started_at, unit_info)
    end

    def validate_camera_set_params(params)
      unless params.is_a?(Hash)
        raise BridgeError.new("invalid_argument", "camera_set params must be an object")
      end
      unknown_keys = params.keys - CAMERA_SET_PARAM_KEYS
      unless unknown_keys.empty?
        raise BridgeError.new(
          "invalid_argument",
          "camera_set params contain unsupported keys: #{unknown_keys.sort.join(', ')}"
        )
      end
      eye = numeric_triplet(params["eye"], "eye")
      target = numeric_triplet(params["target"], "target")
      if eye == target
        raise BridgeError.new("invalid_argument", "eye and target must differ")
      end
      up_raw = numeric_triplet(params["up"], "up")
      up = Geom::Vector3d.new(up_raw[0], up_raw[1], up_raw[2])
      if up.length == 0.0
        raise BridgeError.new("invalid_argument", "up must be non-zero")
      end
      fov = finite_number(params["fov"], "fov")
      unless fov.positive? && fov < 180.0
        raise BridgeError.new("invalid_argument", "fov must be within 0..180 exclusive")
      end
      [eye, target, up_raw, fov]
    end

    def preflight_camera_set(model, params)
      validate_camera_set_params(params)
      model.active_view.camera
      true
    end

    def execute_camera_set(model, params)
      eye, target, up_raw, fov = validate_camera_set_params(params)
      camera = model.active_view.camera
      before = camera_semantic_state(model)
      begin
        camera.set(
          Geom::Point3d.new(eye[0], eye[1], eye[2]),
          Geom::Point3d.new(target[0], target[1], target[2]),
          Geom::Vector3d.new(up_raw[0], up_raw[1], up_raw[2])
        )
        camera.fov = fov
      rescue StandardError => error
        log("camera set failed: #{error.class}: #{error.message}")
        raise BridgeError.new("camera_failed", "SketchUp did not set the camera")
      end
      after = camera_semantic_state(model)
      actual_up = Geom::Vector3d.new(after["camera_up"][0], after["camera_up"][1], after["camera_up"][2])
      requested_up = Geom::Vector3d.new(up_raw[0], up_raw[1], up_raw[2])
      view_direction = Geom::Vector3d.new(
        after["camera_target"][0] - after["camera_eye"][0],
        after["camera_target"][1] - after["camera_eye"][1],
        after["camera_target"][2] - after["camera_eye"][2]
      )
      up_orthogonal = (actual_up.normalize.dot(view_direction.normalize).abs <= 1e-9) &&
        (actual_up.dot(requested_up) > 0)
      {
        "state" => after,
        "metadata" => {
          "requested_eye" => eye,
          "requested_target" => target,
          "requested_fov" => fov,
          "up_orthogonal" => up_orthogonal,
          "before_fingerprint" => before["semantic_fingerprint"],
          "before_camera" => {
            "eye" => before["camera_eye"],
            "target" => before["camera_target"],
            "up" => before["camera_up"],
            "fov" => before["camera_fov"]
          }
        }
      }
    end
  end
end
