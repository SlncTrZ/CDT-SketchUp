# cdt_sketchup/kernel/transaction.rb — AI_Step transaction and non-undoable compensation
# Wing: code | Topic: sketchup_bridge | Updated: 2026-09-12

module CDTSketchUp
  class BridgeServer
    private

    def compensate_non_undoable_action(model, action, metadata)
      case action
      when "scene_create"
        name = metadata["actual_name"]
        return if name.nil? || name.empty?
        page = model.pages.to_a.find { |candidate| candidate.name == name }
        return unless page
        model.pages.erase(page)
        if model.pages.any? { |candidate| candidate.name == name }
          raise BridgeError.new("scene_failed", "Aborted scene was not removed")
        end
      when "camera_set"
        before = metadata["before_camera"]
        return unless before
        camera = model.active_view.camera
        camera.set(
          Geom::Point3d.new(before["eye"][0], before["eye"][1], before["eye"][2]),
          Geom::Point3d.new(before["target"][0], before["target"][1], before["target"][2]),
          Geom::Vector3d.new(before["up"][0], before["up"][1], before["up"][2])
        )
        camera.fov = before["fov"]
        restored = camera_semantic_state(model)
        unless restored["semantic_fingerprint"] == metadata["before_fingerprint"]
          raise BridgeError.new("camera_failed", "Aborted camera was not restored")
        end
      end
      true
    end

    def with_operation(model, _name)
      started = model.start_operation("AI_Step", true)
      unless started
        raise BridgeError.new(
          "transaction_start_failed",
          "SketchUp did not start AI_Step transaction"
        )
      end
      operation_open = true
      begin
        result = yield
        committed = model.commit_operation
        unless committed
          raise BridgeError.new(
            "transaction_commit_failed",
            "SketchUp did not commit AI_Step transaction"
          )
        end
        operation_open = false
        result
      rescue StandardError
        model.abort_operation if operation_open
        raise
      end
    end
  end
end
