# cdt_sketchup/bridge/server.rb — loopback server lifecycle and command dispatch
# Wing: code | Topic: sketchup_bridge | Updated: 2026-09-12

module CDTSketchUp
  class BridgeServer
    public

  LOOPBACK = "127.0.0.1"
  DEFAULT_PORT = 9876
  PROTOCOL_VERSION = 1
  MAX_FRAME_BYTES = 256 * 1024
  READ_CHUNK_BYTES = 16 * 1024
  MAX_CLIENTS = 8
  MAX_ACCEPTS_PER_TICK = 4
  CLIENT_IDLE_SECONDS = 5.0
  POLL_SECONDS = 0.05

    def initialize(port: DEFAULT_PORT)
      @port = Integer(port)
      raise ArgumentError, "bridge port must be 1..65535" unless @port.between?(1, 65_535)

      @server = nil
      @timer_id = nil
      @clients = {}
      @token = nil
      @process_session_id = SecureRandom.hex(16)
    end

    def running?
      !@server.nil?
    end

    def start
      return true if running?

      @token = load_or_create_token
      @server = TCPServer.new(LOOPBACK, @port)
      @server.listen(MAX_CLIENTS)
      @timer_id = UI.start_timer(POLL_SECONDS, true) { tick }
      log("bridge listening on #{LOOPBACK}:#{@port}")
      true
    rescue StandardError => error
      log("bridge start failed: #{error.class}: #{error.message}")
      stop
      false
    end

    def stop
      UI.stop_timer(@timer_id) if @timer_id
      @timer_id = nil

      @clients.keys.each { |socket| close_client(socket) }
      @clients.clear

      begin
        @server.close if @server
      rescue IOError, SystemCallError
        nil
      ensure
        @server = nil
      end
      true
    end

    private

    def tick
      return unless @server

      accept_clients
      now = monotonic_now
      @clients.keys.each do |socket|
        state = @clients[socket]
        if now - state[:opened_at] > CLIENT_IDLE_SECONDS
          close_client(socket)
          next
        end
        service_client(socket, state)
      end
    rescue StandardError => error
      log("bridge tick error: #{error.class}: #{error.message}")
    end

    def accept_clients
      MAX_ACCEPTS_PER_TICK.times do
        socket = @server.accept_nonblock(exception: false)
        break if socket == :wait_readable

        @clients[socket] = {
          input: +"".b,
          output: +"".b,
          opened_at: monotonic_now,
          processed: false
        }
      end
    rescue IO::WaitReadable
      nil
    rescue StandardError => error
      log("bridge accept error: #{error.class}: #{error.message}")
    end

    def service_client(socket, state)
      unless state[:processed]
        read_client(socket, state)
      end
      flush_client(socket, state) if state[:processed]
    end

    def process_frame(frame)
      payload = JSON.parse(frame.force_encoding(Encoding::UTF_8))
      request_id = payload["request_id"]

      validate_envelope(payload)
      unless secure_compare(payload["token"], @token)
        return response_error(request_id, "unauthorized", "Invalid bridge credential")
      end

      handler = COMMANDS[payload["command"]]
      return response_error(request_id, "unsupported_command", "Command is not supported") unless handler

      result = send(handler, payload["params"])
      {
        "protocol" => PROTOCOL_VERSION,
        "request_id" => request_id,
        "ok" => true,
        "result" => result
      }
    rescue JSON::ParserError, EncodingError
      response_error(nil, "invalid_request", "Request is not valid UTF-8 JSON")
    rescue BridgeError => error
      response_error(request_id, error.kind, error.message)
    rescue StandardError => error
      log("command failed: #{error.class}: #{error.message}")
      response_error(request_id, "internal_error", "SketchUp command failed")
    end

    def validate_envelope(payload)
      raise BridgeError.new("invalid_request", "Request must be an object") unless payload.is_a?(Hash)
      raise BridgeError.new("protocol_mismatch", "Unsupported bridge protocol") unless payload["protocol"] == PROTOCOL_VERSION

      request_id = payload["request_id"]
      unless request_id.is_a?(String) && request_id.length.between?(1, 128)
        raise BridgeError.new("invalid_request", "request_id must be a bounded string")
      end

      command = payload["command"]
      unless command.is_a?(String) && command.match?(/\A[a-z][a-z0-9_]*\z/)
        raise BridgeError.new("invalid_request", "command must be a simple identifier")
      end

      raise BridgeError.new("invalid_request", "params must be an object") unless payload["params"].is_a?(Hash)
      raise BridgeError.new("unauthorized", "Bridge credential is required") unless payload["token"].is_a?(String)
    end

    def handle_ping(_params)
      model = Sketchup.active_model
      {
        "live_model" => !model.nil?,
        "sketchup_version" => Sketchup.version.to_s,
        "ruby_version" => RUBY_VERSION,
        "bridge_protocol" => PROTOCOL_VERSION
      }
    end

    def run_targeted_geometry_in_context(model, params)
      original_path = (model.active_path || []).dup
      original_path_ids = original_path.map(&:persistent_id)
      caller_snapshot = semantic_active_entity_snapshot(model)
      caller_fingerprint = semantic_model_fingerprint(model, active_snapshot: caller_snapshot)
      caller_context_before = receipt_context(model, model_fingerprint: caller_fingerprint)
      validate_if_context(params["if_context"], caller_context_before) if params["if_context"]

      target_path, target_path_ids = resolve_target_edit_context(model, params["target_context"])
      inner_params = params.dup
      inner_params.delete("target_context")
      # if_context guards the caller context at dispatch time. The recursive strict
      # execution captures and validates its own target-context pre-state.
      inner_params.delete("if_context")

      result = nil
      execution_error = nil
      restoration = nil
      begin
        activate_target_edit_context(model, target_path, target_path_ids) unless target_path_ids == original_path_ids
        result = handle_execute_geometry(inner_params)
      rescue BridgeError => error
        execution_error = error
      rescue StandardError => error
        log("targeted geometry execution failed: #{error.class}: #{error.message}")
        execution_error = BridgeError.new(
          "geometry_execution_failed",
          "Targeted SketchUp geometry execution failed"
        )
      ensure
        restoration = restore_active_path(model, original_path)
      end

      if execution_error
        unless restoration["verified"]
          raise BridgeError.new(
            "context_restore_failed",
            "Targeted execution failed and the caller edit context could not be restored"
          )
        end
        raise execution_error
      end
      unless result.is_a?(Hash)
        raise BridgeError.new("geometry_execution_failed", "Targeted execution produced an invalid receipt")
      end

      caller_context_after = nil
      if restoration["verified"]
        restored_snapshot = semantic_active_entity_snapshot(model)
        restored_fingerprint = semantic_model_fingerprint(model, active_snapshot: restored_snapshot)
        caller_context_after = receipt_context(model, model_fingerprint: restored_fingerprint)
      end
      result["context_targeting"] = {
        "target_instance_path" => target_path_ids,
        "coordinate_space" => "active_context",
        "edit_semantics" => "shared_definition",
        "instance_specific_edit" => "make_unique_first",
        "caller_context_before" => caller_context_before,
        "execution_context_before" => result["context_before"],
        "execution_context_after" => result["context"],
        "restoration" => restoration,
        "caller_context_after" => caller_context_after
      }
      result
    end

    def handle_execute_geometry(params)
      started_at = monotonic_now
      receipt_id = SecureRandom.uuid
      model = require_model
      if params.key?("target_context") && !params["target_context"].nil?
        return run_targeted_geometry_in_context(model, params)
      end
      action = params["action"]
      unit_info = resolve_public_unit(model, params["unit"] || "in")
      coordinate_space = validate_coordinate_space(params["coordinate_space"] || "active_context")
      action_params, expect = normalize_geometry_request_units(
        action,
        params["params"],
        params["expect"],
        unit_info
      )
      pre_snapshot = semantic_active_entity_snapshot(model)
      pre_fingerprint = semantic_model_fingerprint(model, active_snapshot: pre_snapshot)
      pre_context = receipt_context(model, model_fingerprint: pre_fingerprint)
      validate_if_context(params["if_context"], pre_context) if params["if_context"]
      preflight_geometry_action(model, action, action_params)
      validate_if_match(model, action, action_params, params["if_match"]) if params["if_match"]
      started = model.start_operation("AI_Step", true)
      unless started
        raise BridgeError.new("transaction_start_failed", "SketchUp did not start AI_Step transaction")
      end
      operation_open = true
      before_count = model.active_entities.length
      before_fingerprint = nil
      before_snapshot = nil

      begin
        before_snapshot = pre_snapshot
        before_fingerprint = pre_fingerprint
        action_handler = GEOMETRY_ACTIONS[action]
        unless action_handler
          raise BridgeError.new("unsupported_geometry_action", "Geometry action is not supported")
        end
        validate_semantic_expectation_schema(
          expect,
          require_active_entity_delta: action != "delete_topology_entity" && action != "push_pull_topology_face"
        )
        validate_action_expectation(action, action_params, expect)

        outcome = send(action_handler, model, action_params)
        after_count = model.active_entities.length
        state, action_metadata = semantic_action_outcome(model, outcome)
        validation = validate_semantic_expectation(
          state,
          expect,
          before_count: before_count,
          after_count: after_count,
          check_active_entity_delta: action != "delete_topology_entity" && action != "push_pull_topology_face"
        )
        action_checks = validate_action_semantic_invariants(
          action,
          state,
          action_metadata
        )
        validation["checks"].concat(action_checks)
        validation["passed"] &&= action_checks.all? { |check| check["passed"] }

        after_snapshot = semantic_active_entity_snapshot(model)
        affected = semantic_affected_entities(model, before_snapshot, after_snapshot)
        affected_checks = validate_action_affected_invariants(
          action,
          state,
          action_metadata,
          affected
        )
        validation["checks"].concat(affected_checks)
        validation["passed"] &&= affected_checks.all? { |check| check["passed"] }

        unless validation["passed"]
          aborted = model.abort_operation
          operation_open = false
          compensate_non_undoable_action(model, action, action_metadata)
          return build_rollback_result(
            model,
            receipt_id: receipt_id,
            started_at: started_at,
            action: action,
            aborted: aborted,
            before_count: before_count,
            before_fingerprint: before_fingerprint,
            before_snapshot: before_snapshot,
            validation: validation,
            unit_info: unit_info,
            coordinate_space: coordinate_space
          )
        end

        after_fingerprint = semantic_model_fingerprint(model, active_snapshot: after_snapshot)
        committed = model.commit_operation
        unless committed
          raise BridgeError.new(
            "transaction_commit_failed",
            "SketchUp did not commit AI_Step transaction"
          )
        end
        operation_open = false
        build_operation_receipt(
          model,
          receipt_id: receipt_id,
          started_at: started_at,
          action: action,
          state: state,
          affected: affected,
          validation: validation,
          before_count: before_count,
          before_fingerprint: before_fingerprint,
          after_count: after_count,
          after_fingerprint: after_fingerprint,
          unit_info: unit_info,
          coordinate_space: coordinate_space,
          context_before: pre_context,
          context: receipt_context(model, model_fingerprint: after_fingerprint)
        )
      rescue BridgeError => error
        aborted = operation_open ? model.abort_operation : false
        operation_open = false
        build_rollback_result(
          model,
          receipt_id: receipt_id,
          started_at: started_at,
          action: action,
          aborted: aborted,
          before_count: before_count,
          before_fingerprint: before_fingerprint,
          before_snapshot: before_snapshot,
          unit_info: unit_info,
          coordinate_space: coordinate_space,
          error: {
            "kind" => error.kind,
            "message" => error.message,
            "retryable" => false
          }
        )
      rescue StandardError => error
        aborted = operation_open ? model.abort_operation : false
        operation_open = false
        log("execute_geometry failed: #{error.class}: #{error.message}")
        build_rollback_result(
          model,
          receipt_id: receipt_id,
          started_at: started_at,
          action: action,
          aborted: aborted,
          before_count: before_count,
          before_fingerprint: before_fingerprint,
          before_snapshot: before_snapshot,
          unit_info: unit_info,
          coordinate_space: coordinate_space,
          error: {
            "kind" => "geometry_execution_failed",
            "message" => "SketchUp geometry execution failed",
            "retryable" => false
          }
        )
      ensure
        model.abort_operation if operation_open
      end
    end
  end
end
