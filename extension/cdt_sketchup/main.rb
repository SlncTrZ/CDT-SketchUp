# CDT-SketchUp Live Bridge — Main-thread-safe typed bridge to SketchUp.
# Wing: code | Topic: sketchup_semantic_loop | Updated: 2026-09-11 19:52

require "sketchup.rb"
require "socket"
require "json"
require "digest"
require "securerandom"
require "fileutils"

module CDTSketchUp
  LOOPBACK = "127.0.0.1"
  DEFAULT_PORT = 9876
  PROTOCOL_VERSION = 1
  MAX_FRAME_BYTES = 256 * 1024
  READ_CHUNK_BYTES = 16 * 1024
  MAX_CLIENTS = 8
  MAX_ACCEPTS_PER_TICK = 4
  CLIENT_IDLE_SECONDS = 5.0
  POLL_SECONDS = 0.05
  MAX_OBJECTS = 500
  MAX_FACE_POINTS = 512
  MAX_ARRAY_COPIES = 100
  MAX_ARRAY_PROJECTED_ENTITIES = 5000
  MAX_CURVE_SEGMENTS = 360
  MAX_POLYLINE_POINTS = 512
  MAX_SWEEP_PATH_EDGES = 64
  MAX_TOPOLOGY_RESULTS = 500
  MAX_ASSET_BYTES = 67108864
  MAX_TEXTURE_BYTES = 16777216
  MAX_INTEGRITY_SCAN = 5000
  MODEL_FILES_ROOTNAME = "models".freeze
  MODEL_SAVE_AS_PARAM_KEYS = %w[file overwrite].freeze
  MODEL_OPEN_PARAM_KEYS = %w[file if_model_guid].freeze
    MODEL_EXPORT_PARAM_KEYS = %w[file format overwrite width height].freeze
    MODEL_EXPORT_FORMATS = %w[dae kmz png jpg].freeze
    RASTER_EXPORT_FORMATS = %w[png jpg].freeze
  TEXTURE_MANIFEST_FILENAME = "textures.json".freeze
  TEXTURE_EXTENSIONS = %w[.png .jpg .jpeg .bmp].freeze
  ASSET_MANIFEST_FILENAME = "assets.json".freeze
  DEBUG_MODE = false

  class BridgeError < StandardError
    attr_reader :kind

    def initialize(kind, message)
      super(message)
      @kind = kind
    end
  end

  class BridgeServer
    COMMANDS = {
      "ping" => :handle_ping,
      "document_info" => :handle_document_info,
      "object_list" => :handle_object_list,
      "object_get" => :handle_object_get,
      "execute_geometry" => :handle_execute_geometry,
      "get_entity_state" => :handle_get_entity_state,
      "definition_info" => :handle_definition_info,
      "measure_distance" => :handle_measure_distance,
      "query_topology" => :handle_query_topology,
      "query_overlap" => :handle_query_overlap,
      "camera_get" => :handle_camera_get,
      "scene_list" => :handle_scene_list,
      "asset_list" => :handle_asset_list,
      "texture_list" => :handle_texture_list,
      "material_info" => :handle_material_info,
      "model_save" => :handle_model_save,
      "model_save_as" => :handle_model_save_as,
      "model_open" => :handle_model_open,
      "model_export" => :handle_model_export,
      "model_list" => :handle_model_list,
      "integrity_report" => :handle_integrity_report,
      "create_edge" => :handle_create_edge,
      "create_face" => :handle_create_face,
      "selection_by_ids" => :handle_selection_by_ids,
      "selection_clear" => :handle_selection_clear,
      "object_delete" => :handle_object_delete,
      "push_pull_face" => :handle_push_pull_face,
      "component_create_box" => :handle_component_create_box,
      "tag_create" => :handle_tag_create,
      "material_create" => :handle_material_create
    }.freeze

    GEOMETRY_ACTIONS = {
      "create_box" => :execute_create_box,
      "create_face" => :execute_create_face,
      "extrude_face_to_group" => :execute_extrude_face_to_group,
      "transform_entity" => :execute_transform_entity,
      "boolean_operation" => :execute_boolean_operation,
      "delete_entity" => :execute_delete_entity,
      "group_entities" => :execute_group_entities,
      "create_component" => :execute_create_component,
      "copy_entity" => :execute_copy_entity,
      "linear_array" => :execute_linear_array,
      "radial_array" => :execute_radial_array,
      "place_instance" => :execute_place_instance,
      "make_unique" => :execute_make_unique,
      "tag_assign" => :execute_tag_assign,
      "material_assign" => :execute_material_assign,
      "create_polyline" => :execute_create_polyline,
      "create_rectangle" => :execute_create_rectangle,
      "create_circle" => :execute_create_circle,
      "create_arc" => :execute_create_arc,
      "create_polygon" => :execute_create_polygon,
      "sweep_profile" => :execute_sweep_profile,
      "place_asset" => :execute_place_asset,
      "material_apply_texture" => :execute_material_apply_texture,
      "camera_set" => :execute_camera_set,
      "scene_create" => :execute_scene_create,
      "repair_reverse_face" => :execute_repair_reverse_face,
      "repair_erase_degenerate" => :execute_repair_erase_degenerate
    }.freeze

    RECEIPT_SCHEMA_VERSION = 1
    PUBLIC_LENGTH_UNITS = %w[mm cm m in ft model].freeze
    PUBLIC_COORDINATE_SPACES = %w[active_context].freeze
    IF_CONTEXT_KEYS = %w[id revision].freeze
    LENGTH_TO_INCH = {
      "mm" => (1.0 / 25.4),
      "cm" => (1.0 / 2.54),
      "m" => (1.0 / 0.0254),
      "in" => 1.0,
      "ft" => 12.0,
      "yd" => 36.0
    }.freeze
    SEMANTIC_QUANTUM = 1e-6
    MAX_FINGERPRINT_EDGES = 20_000
    MAX_MODEL_FINGERPRINT_ENTITIES = MAX_OBJECTS
    SEMANTIC_EXPECT_KEYS = %w[
      active_entity_delta
      deleted
      type
      child_persistent_ids
      count
      definition_guid
      definition_name
      material
      camera_eye
      camera_target
      camera_fov
      scene_name
      edge_count
      vertex_count
      bounds_min
      bounds_max
      bounds_size
      vertex_count
      face_count
      area
      normal
      manifold
      volume
      transformation
      tag
      tolerance
    ].freeze
    CREATE_BOX_PARAM_KEYS = %w[name dimensions origin].freeze
    CREATE_FACE_PARAM_KEYS = %w[points].freeze
    EXTRUDE_FACE_PARAM_KEYS = %w[persistent_id distance group_name].freeze
    TRANSFORM_ENTITY_PARAM_KEYS = %w[persistent_id matrix].freeze
    BOOLEAN_OPERATION_PARAM_KEYS = %w[tool_pid target_pid operation_type].freeze
    DELETE_ENTITY_PARAM_KEYS = %w[persistent_id].freeze
    GROUP_ENTITIES_PARAM_KEYS = %w[persistent_ids name].freeze
    CREATE_COMPONENT_PARAM_KEYS = %w[persistent_ids name].freeze
    COPY_ENTITY_PARAM_KEYS = %w[persistent_id].freeze
    LINEAR_ARRAY_PARAM_KEYS = %w[persistent_id vector count].freeze
    RADIAL_ARRAY_PARAM_KEYS = %w[persistent_id axis_origin axis degrees count].freeze
    TAG_ASSIGN_PARAM_KEYS = %w[persistent_id tag].freeze
    MATERIAL_ASSIGN_PARAM_KEYS = %w[persistent_id material side].freeze
    POLYLINE_PARAM_KEYS = %w[points closed].freeze
    RECTANGLE_PARAM_KEYS = %w[origin width height normal].freeze
    CIRCLE_PARAM_KEYS = %w[center normal radius segments].freeze
    ARC_PARAM_KEYS = %w[center normal radius start_degrees end_degrees segments].freeze
    POLYGON_PARAM_KEYS = %w[center normal radius sides].freeze
    SWEEP_PROFILE_PARAM_KEYS = %w[face_pid path_pids].freeze
    PLACE_ASSET_PARAM_KEYS = %w[asset_key matrix].freeze
    MATERIAL_TEXTURE_PARAM_KEYS = %w[material texture_key width height].freeze
    MATERIAL_INFO_PARAM_KEYS = %w[material unit].freeze
    REVERSE_FACE_PARAM_KEYS = %w[persistent_id].freeze
    ERASE_DEGENERATE_PARAM_KEYS = %w[persistent_id].freeze
    CAMERA_SET_PARAM_KEYS = %w[eye target up fov].freeze
    SCENE_CREATE_PARAM_KEYS = %w[name].freeze
    MEASURE_DISTANCE_PARAM_KEYS = %w[first_pid second_pid unit].freeze
    QUERY_TOPOLOGY_PARAM_KEYS = %w[persistent_id unit].freeze
    QUERY_OVERLAP_PARAM_KEYS = %w[first_pid second_pid unit].freeze
    PLACE_INSTANCE_PARAM_KEYS = %w[definition_guid matrix].freeze
    MAKE_UNIQUE_PARAM_KEYS = %w[persistent_id].freeze
    DEFINITION_INFO_PARAM_KEYS = %w[definition_guid unit].freeze
    BOOLEAN_OPERATION_TYPES = %w[union difference intersect].freeze
    MIN_TRANSFORM_DETERMINANT = 1e-12

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

    def read_client(socket, state)
      chunk = socket.read_nonblock(READ_CHUNK_BYTES, exception: false)
      return if chunk == :wait_readable

      if chunk.nil?
        close_client(socket)
        return
      end

      state[:input] << chunk
      if state[:input].bytesize > MAX_FRAME_BYTES
        queue_error(state, nil, "frame_too_large", "Bridge request exceeds maximum size")
        return
      end

      newline_index = state[:input].index("\n")
      return unless newline_index

      frame = state[:input].byteslice(0, newline_index)
      trailing = state[:input].byteslice(newline_index + 1, state[:input].bytesize) || "".b
      if trailing.bytesize.positive?
        queue_error(state, nil, "invalid_request", "Only one request is allowed per connection")
        return
      end

      response = process_frame(frame)
      queue_response(state, response)
    rescue IO::WaitReadable
      nil
    rescue EOFError, IOError, SystemCallError
      close_client(socket)
    end

    def flush_client(socket, state)
      if state[:output].empty?
        close_client(socket)
        return
      end

      written = socket.write_nonblock(state[:output], exception: false)
      return if written == :wait_writable

      state[:output] = state[:output].byteslice(written, state[:output].bytesize) || "".b
      close_client(socket) if state[:output].empty?
    rescue IO::WaitWritable
      nil
    rescue IOError, SystemCallError
      close_client(socket)
    end

    def queue_response(state, payload)
      encoded = JSON.generate(payload).encode(Encoding::UTF_8) + "\n"
      if encoded.bytesize > MAX_FRAME_BYTES
        encoded = JSON.generate(
          response_error(payload["request_id"], "response_too_large", "Bridge response exceeds maximum size")
        ) + "\n"
      end
      state[:output] = encoded.b
      state[:processed] = true
    end

    def queue_error(state, request_id, kind, message)
      queue_response(state, response_error(request_id, kind, message))
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

    def handle_document_info(_params)
      model = require_model
      active_path = model.active_path || []
      {
        "title" => model.title.to_s,
        "path" => model.path.to_s,
        "modified" => model.modified?,
        "active_context" => active_path.map { |entity| entity.persistent_id },
        "active_entity_count" => model.active_entities.length,
        "coordinate_unit" => "sketchup_internal_inch",
        "length_unit_code" => model.options["UnitsOptions"]["LengthUnit"]
      }
    end

    def handle_object_list(params)
      model = require_model
      limit = bounded_integer(params["limit"], default: 100, minimum: 1, maximum: MAX_OBJECTS, name: "limit")
      type_filter = params["type"]
      if type_filter && (!type_filter.is_a?(String) || type_filter.length > 64)
        raise BridgeError.new("invalid_argument", "type must be a bounded string")
      end

      entities = model.active_entities.to_a
      if type_filter
        entities = entities.select { |entity| entity.typename.casecmp?(type_filter) }
      end
      selected = entities.first(limit)
      {
        "objects" => selected.map { |entity| serialize_entity(entity) },
        "returned" => selected.length,
        "total_in_active_context" => entities.length,
        "truncated" => entities.length > selected.length
      }
    end

    def handle_object_get(params)
      model = require_model
      entity = require_entity_by_pid(model, params["persistent_id"])
      serialize_entity(entity)
    end

    def handle_get_entity_state(params)
      started_at = monotonic_now
      model = require_model
      unit_info = resolve_public_unit(model, params["unit"] || "in")
      coordinate_space = validate_coordinate_space(params["coordinate_space"] || "active_context")
      entity = require_entity_by_pid(model, params["persistent_id"])
      state = semantic_entity_state(model, entity)
      snapshot = semantic_active_entity_snapshot(model)
      model_fingerprint = semantic_model_fingerprint(model, active_snapshot: snapshot)
      query_context = receipt_context(model, model_fingerprint: model_fingerprint)
      build_query_receipt(
        model,
        command: "get_entity_state",
        state: state,
        started_at: started_at,
        unit_info: unit_info,
        coordinate_space: coordinate_space,
        context: query_context
      )
    end

    def handle_execute_geometry(params)
      started_at = monotonic_now
      receipt_id = SecureRandom.uuid
      model = require_model
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
        validate_semantic_expectation_schema(expect)
        validate_action_expectation(action, action_params, expect)

        outcome = send(action_handler, model, action_params)
        after_count = model.active_entities.length
        state, action_metadata = semantic_action_outcome(model, outcome)
        validation = validate_semantic_expectation(
          state,
          expect,
          before_count: before_count,
          after_count: after_count
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
            "message" => "DEBUG-TEMP #{error.class}: #{error.message}",
            "retryable" => false
          }
        )
      ensure
        model.abort_operation if operation_open
      end
    end

    def build_operation_receipt(
      model,
      receipt_id:,
      started_at:,
      action:,
      state:,
      affected:,
      validation:,
      before_count:,
      before_fingerprint:,
      after_count:,
      after_fingerprint:,
      unit_info:,
      coordinate_space:,
      context_before:,
      context:
    )
      before_model = receipt_model_state(before_count, before_fingerprint)
      after_model = receipt_model_state(after_count, after_fingerprint)
      public_unit = unit_info["public_unit"]
      resolved_unit = unit_info["resolved_unit"]
      public_state = semantic_state_in_unit(state, resolved_unit)
      public_validation = validation_in_unit(validation, resolved_unit)
      result = {
        "receipt_schema_version" => RECEIPT_SCHEMA_VERSION,
        "receipt_kind" => "operation",
        "receipt_id" => receipt_id,
        "command" => "execute_geometry",
        "action" => action,
        "unit" => public_unit,
        "resolved_unit" => resolved_unit,
        "native_length_unit" => "in",
        "coordinate_space" => coordinate_space,
        "committed" => true,
        "commit_verified" => true,
        "context_before" => context_before,
        "context" => context,
        "affected" => affected,
        "affected_verified" => true,
        "entity_states" => [public_state],
        "model" => {
          "before" => before_model,
          "after" => after_model,
          "after_rollback" => nil
        },
        "validation" => public_validation,
        "rollback" => nil,
        "error" => nil,
        "duration_ms" => receipt_duration_ms(started_at),
        "limits" => receipt_limits
      }

      # Contract 0.9 compatibility aliases; receipt fields above are authoritative.
      result["rolled_back"] = false
      result["rollback_verified"] = false
      result["persistent_id"] = public_state["persistent_id"]
      result["state"] = public_state
      result["before"] = before_model
      result["after"] = after_model
      result
    end

    def build_query_receipt(model, command:, state:, started_at:, unit_info:, coordinate_space:, context:)
      public_unit = unit_info["public_unit"]
      resolved_unit = unit_info["resolved_unit"]
      public_state = semantic_state_in_unit(state, resolved_unit)
      result = {
        "receipt_schema_version" => RECEIPT_SCHEMA_VERSION,
        "receipt_kind" => "query",
        "receipt_id" => SecureRandom.uuid,
        "command" => command,
        "unit" => public_unit,
        "resolved_unit" => resolved_unit,
        "native_length_unit" => "in",
        "coordinate_space" => coordinate_space,
        "context" => context,
        "entity_fingerprint" => public_state["semantic_fingerprint"],
        "entity_states" => [public_state],
        "result" => public_state,
        "duration_ms" => receipt_duration_ms(started_at),
        "limits" => receipt_limits
      }

      # Preserve the existing flat semantic-state shape during receipt migration.
      public_state.each { |key, value| result[key] = value unless result.key?(key) }
      result
    end

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

    def build_rollback_result(
      model,
      receipt_id:,
      started_at:,
      action:,
      aborted:,
      before_count:,
      before_fingerprint:,
      before_snapshot:,
      unit_info:,
      coordinate_space:,
      validation: nil,
      error: nil
    )
      rolled_back_count = model.active_entities.length
      rolled_back_snapshot, rollback_snapshot_error = safe_semantic_active_entity_snapshot(model)
      rolled_back_fingerprint, rollback_fingerprint_error = if rolled_back_snapshot
                                                              safe_semantic_model_fingerprint(
                                                                model,
                                                                active_snapshot: rolled_back_snapshot
                                                              )
                                                            else
                                                              safe_semantic_model_fingerprint(model)
                                                            end
      rollback_verified = (
        !!aborted &&
        !before_fingerprint.nil? &&
        !rolled_back_fingerprint.nil? &&
        rolled_back_count == before_count &&
        rolled_back_fingerprint == before_fingerprint
      )
      affected = if before_snapshot && rolled_back_snapshot
                   semantic_affected_entities(model, before_snapshot, rolled_back_snapshot)
                 end
      affected ||= empty_affected_entities if rollback_verified

      before_model = receipt_model_state(before_count, before_fingerprint)
      rollback_model = receipt_model_state(rolled_back_count, rolled_back_fingerprint)
      rollback_detail = {
        "attempted" => true,
        "rolled_back" => !!aborted,
        "verified" => rollback_verified,
        "snapshot_error" => rollback_snapshot_error,
        "fingerprint_error" => rollback_fingerprint_error
      }
      public_unit = unit_info["public_unit"]
      resolved_unit = unit_info["resolved_unit"]
      public_validation = validation && validation_in_unit(validation, resolved_unit)
      result = {
        "receipt_schema_version" => RECEIPT_SCHEMA_VERSION,
        "receipt_kind" => "operation",
        "receipt_id" => receipt_id,
        "command" => "execute_geometry",
        "action" => action,
        "unit" => public_unit,
        "resolved_unit" => resolved_unit,
        "native_length_unit" => "in",
        "coordinate_space" => coordinate_space,
        "committed" => false,
        "commit_verified" => false,
        "context" => receipt_context(model, model_fingerprint: rolled_back_fingerprint || before_fingerprint),
        "affected" => affected,
        "affected_verified" => rollback_verified,
        "entity_states" => [],
        "model" => {
          "before" => before_model,
          "after" => nil,
          "after_rollback" => rollback_model
        },
        "validation" => public_validation,
        "rollback" => rollback_detail,
        "error" => error,
        "duration_ms" => receipt_duration_ms(started_at),
        "limits" => receipt_limits,
        # Contract 0.9 compatibility aliases.
        "rolled_back" => !!aborted,
        "rollback_verified" => rollback_verified,
        "before" => before_model,
        "after_rollback" => rollback_model
      }
      result["rollback_fingerprint_error"] = rollback_fingerprint_error if rollback_fingerprint_error
      result
    end

    def resolve_public_unit(model, value)
      unit = value.to_s
      unless PUBLIC_LENGTH_UNITS.include?(unit)
        raise BridgeError.new(
          "invalid_argument",
          "unit must be one of: #{PUBLIC_LENGTH_UNITS.join(', ')}"
        )
      end

      resolved = unit == "model" ? model_length_unit(model) : unit
      factor = LENGTH_TO_INCH[resolved]
      unless factor
        raise BridgeError.new("unsupported_model_unit", "SketchUp model length unit is not supported")
      end
      {
        "public_unit" => unit,
        "resolved_unit" => resolved,
        "to_internal" => factor
      }
    end

    def model_length_unit(model)
      code = model.options["UnitsOptions"]["LengthUnit"]
      unit_map = {
        Length::Inches => "in",
        Length::Feet => "ft",
        Length::Millimeter => "mm",
        Length::Centimeter => "cm",
        Length::Meter => "m"
      }
      unit_map[Length::Yard] = "yd" if defined?(Length::Yard)
      unit_map[code] || raise(
        BridgeError.new("unsupported_model_unit", "SketchUp model length unit is not supported")
      )
    end

    def validate_coordinate_space(value)
      coordinate_space = value.to_s
      unless PUBLIC_COORDINATE_SPACES.include?(coordinate_space)
        raise BridgeError.new("invalid_argument", "coordinate_space must be active_context")
      end
      coordinate_space
    end

    def normalize_geometry_request_units(action, raw_params, raw_expect, unit_info)
      unless raw_params.is_a?(Hash)
        raise BridgeError.new("invalid_argument", "params must be an object")
      end
      unless raw_expect.is_a?(Hash) && !raw_expect.empty?
        raise BridgeError.new("invalid_argument", "expect must be a non-empty validation object")
      end

      params = deep_copy_json(raw_params)
      expect = deep_copy_json(raw_expect)
      unit = unit_info["resolved_unit"]

      case action
      when "create_box"
        params["dimensions"] = length_triplet_to_internal(params["dimensions"], "dimensions", unit)
        if params.key?("origin")
          params["origin"] = length_triplet_to_internal(params["origin"], "origin", unit)
        end
      when "create_face"
        points = params["points"]
        if points.is_a?(Array)
          params["points"] = points.each_with_index.map do |point, index|
            length_triplet_to_internal(point, "points[#{index}]", unit)
          end
        end
      when "extrude_face_to_group"
        params["distance"] = length_to_internal_inches(params["distance"], "distance", unit)
      when "transform_entity"
        params["matrix"] = transformation_to_internal(params["matrix"], "matrix", unit)
      when "place_instance"
        params["matrix"] = transformation_to_internal(params["matrix"], "matrix", unit)
      when "place_asset"
        params["matrix"] = transformation_to_internal(params["matrix"], "matrix", unit)
      when "camera_set"
        params["eye"] = length_triplet_to_internal(params["eye"], "eye", unit)
        params["target"] = length_triplet_to_internal(params["target"], "target", unit)
      when "material_apply_texture"
        params["width"] = length_to_internal_inches(params["width"], "width", unit)
        params["height"] = length_to_internal_inches(params["height"], "height", unit)
      when "linear_array"
        params["vector"] = length_triplet_to_internal(params["vector"], "vector", unit)
      when "radial_array"
        params["axis_origin"] = length_triplet_to_internal(params["axis_origin"], "axis_origin", unit)
      when "create_polyline"
        points = params["points"]
        if points.is_a?(Array)
          params["points"] = points.each_with_index.map do |point, index|
            length_triplet_to_internal(point, "points[#{index}]", unit)
          end
        end
      when "create_rectangle"
        params["origin"] = length_triplet_to_internal(params["origin"], "origin", unit)
        params["width"] = length_to_internal_inches(params["width"], "width", unit)
        params["height"] = length_to_internal_inches(params["height"], "height", unit)
      when "create_circle", "create_arc", "create_polygon"
        params["center"] = length_triplet_to_internal(params["center"], "center", unit)
        params["radius"] = length_to_internal_inches(params["radius"], "radius", unit)
      end

      normalize_expectation_units!(expect, unit)
      [params, expect]
    end

    def normalize_expectation_units!(expect, unit)
      %w[bounds_min bounds_max bounds_size camera_eye camera_target].each do |field|
        next unless expect.key?(field)
        expect[field] = length_triplet_to_internal(expect[field], "expect.#{field}", unit)
      end
      if expect.key?("area")
        expect["area"] = area_to_internal(expect["area"], "expect.area", unit)
      end
      if expect.key?("volume")
        expect["volume"] = volume_to_internal(expect["volume"], "expect.volume", unit)
      end
      if expect.key?("transformation")
        expect["transformation"] = transformation_to_internal(
          expect["transformation"],
          "expect.transformation",
          unit
        )
      end
      if expect.key?("tolerance")
        expect["tolerance"] = length_to_internal_inches(
          expect["tolerance"],
          "expect.tolerance",
          unit
        )
      end
      expect
    end

    def length_triplet_to_internal(value, name, unit)
      numeric_triplet(value, name).map.with_index do |item, index|
        length_to_internal_inches(item, "#{name}[#{index}]", unit)
      end
    end

    def transformation_to_internal(value, name, unit)
      matrix = numeric_array(value, 16, name)
      converted = matrix.dup
      converted[12] = length_to_internal_inches(matrix[12], "#{name}[12]", unit)
      converted[13] = length_to_internal_inches(matrix[13], "#{name}[13]", unit)
      converted[14] = length_to_internal_inches(matrix[14], "#{name}[14]", unit)
      converted
    end

    def length_to_internal_inches(value, name, unit)
      number = finite_number(value, name)
      factor = LENGTH_TO_INCH[unit]
      raise BridgeError.new("invalid_argument", "Unsupported length unit") unless factor
      converted = number * factor
      unless converted.finite?
        raise BridgeError.new("invalid_argument", "#{name} exceeds supported numeric range")
      end
      converted
    end

    def area_to_internal(value, name, unit)
      factor = LENGTH_TO_INCH[unit]
      number = finite_number(value, name)
      converted = number * factor * factor
      raise BridgeError.new("invalid_argument", "#{name} exceeds supported numeric range") unless converted.finite?
      converted
    end

    def volume_to_internal(value, name, unit)
      factor = LENGTH_TO_INCH[unit]
      number = finite_number(value, name)
      converted = number * factor * factor * factor
      raise BridgeError.new("invalid_argument", "#{name} exceeds supported numeric range") unless converted.finite?
      converted
    end

    def semantic_state_in_unit(state, unit)
      converted = deep_copy_json(state)
      if converted["bounds"]
        %w[min max center size].each do |field|
          value = converted["bounds"][field]
          converted["bounds"][field] = convert_triplet_from_internal(value, unit) if value
        end
      end
      if converted["surface"] && !converted["surface"]["area"].nil?
        converted["surface"]["area"] = convert_area_from_internal(converted["surface"]["area"], unit)
      end
      converted["area"] = convert_area_from_internal(converted["area"], unit) unless converted["area"].nil?
      converted["volume"] = convert_volume_from_internal(converted["volume"], unit) unless converted["volume"].nil?
      converted["texture_width"] = convert_length_from_internal(converted["texture_width"], unit) unless converted["texture_width"].nil?
      converted["texture_height"] = convert_length_from_internal(converted["texture_height"], unit) unless converted["texture_height"].nil?
      %w[camera_eye camera_target].each do |field|
        value = converted[field]
        converted[field] = convert_triplet_from_internal(value, unit) if value.is_a?(Array)
      end
      if converted["transformation"].is_a?(Array) && converted["transformation"].length == 16
        converted_transformation = converted["transformation"].dup
        converted_transformation[12] = convert_length_from_internal(converted_transformation[12], unit)
        converted_transformation[13] = convert_length_from_internal(converted_transformation[13], unit)
        converted_transformation[14] = convert_length_from_internal(converted_transformation[14], unit)
        converted["transformation"] = converted_transformation
      end
      converted
    end

    def validation_in_unit(validation, unit)
      converted = deep_copy_json(validation)
      checks = converted["checks"]
      return converted unless checks.is_a?(Array)

      checks.each do |check|
        field = check["field"].to_s
        case field
        when "bounds_min", "bounds_max", "bounds_size", "action.composition_bounds_min", "action.composition_bounds_max", "camera_eye", "camera_target"
          check["expected"] = convert_triplet_from_internal(check["expected"], unit) if check["expected"]
          check["actual"] = convert_triplet_from_internal(check["actual"], unit) if check["actual"]
        when "area"
          check["expected"] = convert_area_from_internal(check["expected"], unit) unless check["expected"].nil?
          check["actual"] = convert_area_from_internal(check["actual"], unit) unless check["actual"].nil?
        when "volume"
          check["expected"] = convert_volume_from_internal(check["expected"], unit) unless check["expected"].nil?
          check["actual"] = convert_volume_from_internal(check["actual"], unit) unless check["actual"].nil?
        when "transformation", "action.transformation"
          check["expected"] = transformation_from_internal(check["expected"], unit) if check["expected"].is_a?(Array)
          check["actual"] = transformation_from_internal(check["actual"], unit) if check["actual"].is_a?(Array)
        when "action.volume_relation"
          check["actual"] = convert_volume_from_internal(check["actual"], unit) unless check["actual"].nil?
        end
      end
      converted
    end

    def transformation_from_internal(value, unit)
      converted = value.dup
      converted[12] = convert_length_from_internal(converted[12], unit)
      converted[13] = convert_length_from_internal(converted[13], unit)
      converted[14] = convert_length_from_internal(converted[14], unit)
      converted
    end

    def convert_triplet_from_internal(value, unit)
      value.map { |item| convert_length_from_internal(item, unit) }
    end

    def convert_length_from_internal(value, unit)
      factor = LENGTH_TO_INCH[unit]
      quantize_public_number(value.to_f / factor)
    end

    def convert_area_from_internal(value, unit)
      factor = LENGTH_TO_INCH[unit]
      quantize_public_number(value.to_f / (factor * factor))
    end

    def convert_volume_from_internal(value, unit)
      factor = LENGTH_TO_INCH[unit]
      quantize_public_number(value.to_f / (factor * factor * factor))
    end

    def quantize_public_number(value)
      return 0.0 if value.abs < 1e-12
      value.round(9)
    end

    def deep_copy_json(value)
      JSON.parse(JSON.generate(value))
    end

    def model_session_identity(model)
      payload = {
        "process_id" => Process.pid,
        "process_session_id" => @process_session_id,
        "model_guid" => model.guid.to_s
      }
      Digest::SHA256.hexdigest(JSON.generate(payload))
    end

    def edit_context_identity(model)
      active_path = model.active_path || []
      path = active_path.map do |entity|
        definition_guid = if entity.respond_to?(:definition) && entity.definition.respond_to?(:guid)
                            entity.definition.guid.to_s
                          end
        {
          "persistent_id" => entity.persistent_id,
          "type" => entity.typename,
          "definition_guid" => definition_guid
        }
      end
      payload = {
        "model_session_id" => model_session_identity(model),
        "active_path" => path
      }
      Digest::SHA256.hexdigest(JSON.generate(payload))
    end

    def context_revision(context_id, model_fingerprint)
      Digest::SHA256.hexdigest(
        JSON.generate(
          {
            "context_id" => context_id,
            "model_fingerprint" => model_fingerprint
          }
        )
      )
    end

    def receipt_context(model, model_fingerprint:)
      active_path = model.active_path || []
      context_id = edit_context_identity(model)
      {
        "id" => context_id,
        "revision" => context_revision(context_id, model_fingerprint),
        "identity_status" => "verified",
        "model_session_id" => model_session_identity(model),
        "model_guid" => model.guid.to_s,
        "active_path" => active_path.map { |entity| entity.persistent_id }
      }
    end

    def validate_write_preconditions(model, action, action_params, if_context, if_match, current_context)
      validate_if_context(if_context, current_context) if if_context
      validate_if_match(model, action, action_params, if_match) if if_match
      true
    end

    def validate_if_context(value, current_context)
      unless value.is_a?(Hash)
        raise BridgeError.new("invalid_argument", "if_context must be an object")
      end
      unknown = value.keys - IF_CONTEXT_KEYS
      unless unknown.empty?
        raise BridgeError.new(
          "invalid_argument",
          "if_context contains unsupported keys: #{unknown.sort.join(', ')}"
        )
      end
      unless value.keys.sort == IF_CONTEXT_KEYS.sort &&
             value["id"].is_a?(String) && value["revision"].is_a?(String)
        raise BridgeError.new("invalid_argument", "if_context requires string id and revision")
      end
      if value["id"] != current_context["id"] ||
         value["revision"] != current_context["revision"]
        raise BridgeError.new("context_mismatch", "Active model/edit context changed since the receipt")
      end
      true
    end

    def precondition_target_pid(action, action_params)
      case action
      when "transform_entity", "delete_entity", "extrude_face_to_group", "make_unique", "copy_entity", "linear_array", "radial_array", "tag_assign", "material_assign", "repair_reverse_face", "repair_erase_degenerate"
        action_params["persistent_id"]
      when "boolean_operation"
        action_params["target_pid"]
      else
        nil
      end
    end

    def validate_if_match(model, action, action_params, if_match)
      return validate_group_if_match_set(model, action_params, if_match) if action == "group_entities"
      return validate_component_if_match_set(model, action_params, if_match) if action == "create_component"
      return validate_camera_if_match(model, if_match) if action == "camera_set"
      return validate_sweep_if_match_set(model, action_params, if_match) if action == "sweep_profile"
      return validate_place_definition_if_match(model, action_params, if_match) if action == "place_instance"

      unless if_match.is_a?(String) && if_match.match?(/\A[a-f0-9]{64}\z/)
        raise BridgeError.new("invalid_argument", "if_match must be a 64-character lowercase SHA-256 hex string")
      end
      persistent_id = precondition_target_pid(action, action_params)
      unless persistent_id
        raise BridgeError.new("invalid_argument", "if_match is not supported for this action")
      end
      entity = require_active_entity(model, persistent_id)
      state = semantic_entity_state(model, entity)
      unless state["semantic_fingerprint"] == if_match
        raise BridgeError.new("stale_entity_state", "Target entity state changed since the receipt")
      end
      true
    end

    def validate_group_if_match_set(model, action_params, if_match)
      unless if_match.is_a?(Hash)
        raise BridgeError.new(
          "invalid_argument",
          "if_match for group_entities must be an object keyed by persistent ID"
        )
      end
      persistent_ids, = validate_group_entities_params(action_params)
      expected_keys = persistent_ids.map(&:to_s).sort
      actual_keys = if_match.keys.map(&:to_s).sort
      unless actual_keys == expected_keys
        raise BridgeError.new(
          "invalid_argument",
          "if_match for group_entities must cover the exact persistent ID set"
        )
      end

      persistent_ids.each do |persistent_id|
        fingerprint = if_match[persistent_id.to_s] || if_match[persistent_id]
        unless fingerprint.is_a?(String) && fingerprint.match?(/\A[a-f0-9]{64}\z/)
          raise BridgeError.new(
            "invalid_argument",
            "if_match values must be 64-character lowercase SHA-256 hex strings"
          )
        end
        entity = require_active_entity(model, persistent_id)
        state = semantic_entity_state(model, entity)
        unless state["semantic_fingerprint"] == fingerprint
          raise BridgeError.new(
            "stale_entity_state",
            "One or more group_entities targets changed since the receipt"
          )
        end
      end
      true
    end

    def validate_create_component_params(params)
      unless params.is_a?(Hash)
        raise BridgeError.new("invalid_argument", "create_component params must be an object")
      end
      unknown_component_keys = params.keys - CREATE_COMPONENT_PARAM_KEYS
      unless unknown_component_keys.empty?
        raise BridgeError.new(
          "invalid_argument",
          "create_component params contain unsupported keys: #{unknown_component_keys.sort.join(', ')}"
        )
      end
      raw_ids = params["persistent_ids"]
      unless raw_ids.is_a?(Array) && raw_ids.length.between?(1, MAX_OBJECTS)
        raise BridgeError.new(
          "invalid_argument",
          "persistent_ids must contain 1..#{MAX_OBJECTS} ids"
        )
      end
      persistent_ids = raw_ids.each_with_index.map do |value, index|
        bounded_integer(
          value,
          minimum: 1,
          maximum: (2**63) - 1,
          name: "persistent_ids[#{index}]"
        )
      end
      if persistent_ids.uniq.length != persistent_ids.length
        raise BridgeError.new("invalid_argument", "persistent_ids must not contain duplicates")
      end

      name = params["name"]
      if name && (!name.is_a?(String) || name.length > 128)
        raise BridgeError.new("invalid_argument", "name must be a string up to 128 characters")
      end
      [persistent_ids, name]
    end

    def validate_place_instance_params(params)
      unless params.is_a?(Hash)
        raise BridgeError.new("invalid_argument", "place_instance params must be an object")
      end
      unknown_place_keys = params.keys - PLACE_INSTANCE_PARAM_KEYS
      unless unknown_place_keys.empty?
        raise BridgeError.new(
          "invalid_argument",
          "place_instance params contain unsupported keys: #{unknown_place_keys.sort.join(', ')}"
        )
      end
      guid = params["definition_guid"]
      unless guid.is_a?(String) && !guid.strip.empty?
        raise BridgeError.new("invalid_argument", "definition_guid must be a non-empty string")
      end
      matrix = params["matrix"]
      unless matrix.is_a?(Array) && matrix.length == 16
        raise BridgeError.new("invalid_argument", "matrix must contain exactly 16 numbers")
      end
      [guid.strip, matrix]
    end

    def validate_make_unique_params(params)
      unless params.is_a?(Hash)
        raise BridgeError.new("invalid_argument", "make_unique params must be an object")
      end
      unknown_unique_keys = params.keys - MAKE_UNIQUE_PARAM_KEYS
      unless unknown_unique_keys.empty?
        raise BridgeError.new(
          "invalid_argument",
          "make_unique params contain unsupported keys: #{unknown_unique_keys.sort.join(', ')}"
        )
      end
      unless params.key?("persistent_id")
        raise BridgeError.new("invalid_argument", "make_unique persistent_id is required")
      end
      bounded_integer(params["persistent_id"], minimum: 1, maximum: (2**63) - 1, name: "persistent_id")
    end

    def validate_definition_info_params(params)
      unless params.is_a?(Hash)
        raise BridgeError.new("invalid_argument", "definition_info params must be an object")
      end
      unknown_definition_keys = params.keys - DEFINITION_INFO_PARAM_KEYS
      unless unknown_definition_keys.empty?
        raise BridgeError.new(
          "invalid_argument",
          "definition_info params contain unsupported keys: #{unknown_definition_keys.sort.join(', ')}"
        )
      end
      guid = params["definition_guid"]
      unless guid.is_a?(String) && !guid.strip.empty?
        raise BridgeError.new("invalid_argument", "definition_guid must be a non-empty string")
      end
      guid.strip
    end

    def preflight_create_component(model, params)
      persistent_ids, = validate_create_component_params(params)
      entities = persistent_ids.map { |value| require_active_entity(model, value) }
      unless entities.all? { |entity| groupable_entity?(entity) }
        raise BridgeError.new(
          "unsupported_object_type",
          "create_component supports only edges, faces, groups, and component instances"
        )
      end
      if entities.any? { |entity| entity.respond_to?(:locked?) && entity.locked? }
        raise BridgeError.new("locked_object", "create_component targets must be unlocked")
      end
      complete_groupable_connected_geometry?(entities)
      true
    end

    def preflight_place_instance(model, params)
      guid, matrix = validate_place_instance_params(params)
      definition = find_definition_by_guid(model, guid)
      if definition.image?
        raise BridgeError.new(
          "unsupported_object_type",
          "place_instance definitions must be component definitions"
        )
      end
      transformation_from_matrix(matrix)
      true
    end

    def preflight_make_unique(model, params)
      persistent_id = validate_make_unique_params(params)
      entity = require_active_entity(model, persistent_id)
      unless entity.is_a?(Sketchup::ComponentInstance)
        raise BridgeError.new("unsupported_object_type", "make_unique targets only component instances")
      end
      if entity.respond_to?(:locked?) && entity.locked?
        raise BridgeError.new("locked_object", "make_unique target must be unlocked")
      end
      true
    end

    def validate_component_if_match_set(model, action_params, if_match)
      unless if_match.is_a?(Hash)
        raise BridgeError.new(
          "invalid_argument",
          "if_match for create_component must be an object keyed by persistent ID"
        )
      end
      persistent_ids, = validate_create_component_params(action_params)
      expected_keys = persistent_ids.map(&:to_s).sort
      actual_keys = if_match.keys.map(&:to_s).sort
      unless actual_keys == expected_keys
        raise BridgeError.new(
          "invalid_argument",
          "if_match for create_component must cover the exact persistent ID set"
        )
      end

      persistent_ids.each do |persistent_id|
        fingerprint = if_match[persistent_id.to_s] || if_match[persistent_id]
        unless fingerprint.is_a?(String) && fingerprint.match?(/\A[a-f0-9]{64}\z/)
          raise BridgeError.new(
            "invalid_argument",
            "if_match values must be 64-character lowercase SHA-256 hex strings"
          )
        end
        entity = require_active_entity(model, persistent_id)
        state = semantic_entity_state(model, entity)
        unless state["semantic_fingerprint"] == fingerprint
          raise BridgeError.new(
            "stale_entity_state",
            "One or more create_component targets changed since the receipt"
          )
        end
      end
      true
    end

    def validate_place_definition_if_match(model, action_params, if_match)
      unless if_match.is_a?(String) && if_match.match?(/\A[a-f0-9]{64}\z/)
        raise BridgeError.new(
          "invalid_argument",
          "if_match for place_instance must be a 64-character lowercase SHA-256 hex string"
        )
      end
      guid, = validate_place_instance_params(action_params)
      definition = find_definition_by_guid(model, guid)
      current = semantic_definition_geometry_fingerprint(definition)
      unless current == if_match
        raise BridgeError.new("stale_entity_state", "Component definition changed since the receipt")
      end
      true
    end

    def execute_create_component(model, params)
      persistent_ids, name = validate_create_component_params(params)
      entities = persistent_ids.map { |value| require_active_entity(model, value) }
      input_states = entities.map do |entity|
        [entity, semantic_entity_state(model, entity)]
      end
      input_fingerprints = input_states.each_with_object({}) do |(entity, state), result|
        result[entity.persistent_id.to_s] = {
          "identity" => state["identity_fingerprint"],
          "geometry" => state["geometry_fingerprint"],
          "reparent" => grouping_reparent_fingerprint(entity, state)
        }
      end
      input_bounds = aggregate_semantic_bounds(input_states.map { |_entity, state| state })

      group = begin
        model.active_entities.add_group(entities)
      rescue ArgumentError, RuntimeError => error
        log("create component failed: #{error.class}: #{error.message}")
        raise BridgeError.new("component_failed", "SketchUp did not group the requested entities")
      end
      unless group && group.valid? && group.is_a?(Sketchup::Group)
        raise BridgeError.new("component_failed", "SketchUp did not produce a group")
      end
      instance = begin
        group.to_component
      rescue StandardError => error
        log("create component failed: #{error.class}: #{error.message}")
        raise BridgeError.new("component_failed", "SketchUp did not convert the group to a component")
      end
      unless instance && instance.valid? && instance.is_a?(Sketchup::ComponentInstance)
        raise BridgeError.new("component_failed", "SketchUp did not produce a component instance")
      end
      instance.name = name if name && !name.empty?

      {
        "entity" => instance,
        "metadata" => {
          "input_persistent_ids" => persistent_ids.sort,
          "input_fingerprints" => input_fingerprints,
          "input_bounds_min" => input_bounds["min"],
          "input_bounds_max" => input_bounds["max"],
          "component_definition_guid" => instance.definition.guid.to_s
        }
      }
    end

    def execute_place_instance(model, params)
      guid, matrix_values = validate_place_instance_params(params)
      definition = find_definition_by_guid(model, guid)
      if definition.image?
        raise BridgeError.new(
          "unsupported_object_type",
          "place_instance definitions must be component definitions"
        )
      end
      before_geometry = semantic_definition_geometry_fingerprint(definition)
      transform = transformation_from_matrix(matrix_values)
      requested = transform.to_a.map { |value| quantize_number(value) }
      instance = begin
        model.active_entities.add_instance(definition, transform)
      rescue ArgumentError, RuntimeError => error
        log("place instance failed: #{error.class}: #{error.message}")
        raise BridgeError.new("component_failed", "SketchUp did not place the component instance")
      end
      unless instance && instance.valid? && instance.is_a?(Sketchup::ComponentInstance)
        raise BridgeError.new("component_failed", "SketchUp did not produce a component instance")
      end

      {
        "entity" => instance,
        "metadata" => {
          "component_definition_guid" => definition.guid.to_s,
          "definition_geometry_before" => before_geometry,
          "requested_transformation" => requested
        }
      }
    end

    def execute_make_unique(model, params)
      persistent_id = validate_make_unique_params(params)
      entity = require_active_entity(model, persistent_id)
      unless entity.is_a?(Sketchup::ComponentInstance)
        raise BridgeError.new("unsupported_object_type", "make_unique targets only component instances")
      end
      before_guid = entity.definition.guid.to_s
      before_geometry = semantic_definition_geometry_fingerprint(entity.definition)
      begin
        entity.make_unique
      rescue StandardError => error
        log("make unique failed: #{error.class}: #{error.message}")
        raise BridgeError.new("component_failed", "SketchUp did not make the instance unique")
      end
      unless entity.valid? && entity.is_a?(Sketchup::ComponentInstance)
        raise BridgeError.new("component_failed", "SketchUp did not keep a valid component instance")
      end

      {
        "entity" => entity,
        "metadata" => {
          "target_persistent_id" => persistent_id,
          "component_definition_guid_before" => before_guid,
          "component_definition_guid_after" => entity.definition.guid.to_s,
          "definition_geometry_before" => before_geometry
        }
      }
    end

    def connected_entities(entity)
      if entity.is_a?(Sketchup::Face) || entity.is_a?(Sketchup::Edge)
        entity.all_connected
      elsif entity.is_a?(Sketchup::Group)
        entity.entities.to_a
      elsif entity.is_a?(Sketchup::ComponentInstance)
        entity.definition.entities.to_a
      else
        []
      end
    end

    def connected_persistent_ids(entity)
      resolved = []
      unresolved = 0
      connected_entities(entity).each do |item|
        pid = begin
          item.respond_to?(:persistent_id) ? item.persistent_id : nil
        rescue StandardError
          nil
        end
        if pid.is_a?(Integer) && pid.positive?
          resolved << pid
        else
          unresolved += 1
        end
      end
      [resolved.sort, unresolved]
    end

    def query_pid_pair(params, keys)
      unless params.is_a?(Hash)
        raise BridgeError.new("invalid_argument", "query params must be an object")
      end
      keys.map do |key|
        unless params.key?(key)
          raise BridgeError.new("invalid_argument", "#{key} is required")
        end
        bounded_integer(params[key], minimum: 1, maximum: (2**63) - 1, name: key)
      end
    end

    def handle_measure_distance(params)
      started_at = monotonic_now
      model = require_model
      unit_info = resolve_public_unit(model, params["unit"] || "in")
      first_pid, second_pid = query_pid_pair(params, %w[first_pid second_pid])
      first = require_entity_by_pid(model, first_pid)
      second = require_entity_by_pid(model, second_pid)
      first_center = point_to_triplet(first.bounds.center)
      second_center = point_to_triplet(second.bounds.center)
      center_distance = Math.sqrt(
        (first_center[0] - second_center[0])**2 +
        (first_center[1] - second_center[1])**2 +
        (first_center[2] - second_center[2])**2
      )
      first_box = box_triplet(first.bounds)
      second_box = box_triplet(second.bounds)
      axis_gaps = 3.times.map do |index|
        [first_box[0][index] - second_box[1][index], second_box[0][index] - first_box[1][index], 0.0].max
      end
      bounds_gap = Math.sqrt(axis_gaps[0]**2 + axis_gaps[1]**2 + axis_gaps[2]**2)
      resolved = unit_info["resolved_unit"]
      state = {
        "query" => "measure_distance",
        "first_pid" => first_pid,
        "second_pid" => second_pid,
        "center_distance" => quantize_public_number(convert_length_from_internal(center_distance, resolved)),
        "bounds_gap" => quantize_public_number(convert_length_from_internal(bounds_gap, resolved)),
        "overlap" => bounds_gap == 0.0,
        "semantic_fingerprint" => Digest::SHA256.hexdigest(
          JSON.generate(
            {
              "query" => "measure_distance",
              "first" => semantic_entity_state(model, first)["semantic_fingerprint"],
              "second" => semantic_entity_state(model, second)["semantic_fingerprint"]
            }
          )
        )
      }
      snapshot = semantic_active_entity_snapshot(model)
      model_fingerprint = semantic_model_fingerprint(model, active_snapshot: snapshot)
      query_context = receipt_context(model, model_fingerprint: model_fingerprint)
      build_query_receipt(
        model,
        command: "measure_distance",
        state: state,
        started_at: started_at,
        unit_info: unit_info,
        coordinate_space: "active_context",
        context: query_context
      )
    end

    def handle_query_topology(params)
      started_at = monotonic_now
      model = require_model
      unit_info = resolve_public_unit(model, params["unit"] || "in")
      persistent_id = query_pid_pair(params, %w[persistent_id]).first
      entity = require_entity_by_pid(model, persistent_id)
      connected_ids, connected_unresolved = connected_persistent_ids(entity)
      if connected_ids.length + connected_unresolved > MAX_TOPOLOGY_RESULTS
        raise BridgeError.new("semantic_state_too_large", "Topology exceeds entity limit")
      end
      counts = semantic_geometry_counts(entity)
      loops = entity.is_a?(Sketchup::Face) ? entity.loops : []
      state = {
        "query" => "query_topology",
        "persistent_id" => persistent_id,
        "type" => entity.typename,
        "connected_count" => connected_ids.length + connected_unresolved,
        "connected_persistent_ids" => connected_ids,
        "connected_unresolved_count" => connected_unresolved,
        "connected_truncated" => false,
        "vertex_count" => counts["vertex_count"],
        "edge_count" => counts["edge_count"],
        "face_count" => counts["face_count"],
        "loop_count" => loops.length,
        "manifold" => semantic_manifold(entity),
        "semantic_fingerprint" => Digest::SHA256.hexdigest(
          JSON.generate(
            {
              "query" => "query_topology",
              "entity" => semantic_entity_state(model, entity)["semantic_fingerprint"],
              "connected" => connected_ids,
              "unresolved" => connected_unresolved
            }
          )
        )
      }
      snapshot = semantic_active_entity_snapshot(model)
      model_fingerprint = semantic_model_fingerprint(model, active_snapshot: snapshot)
      query_context = receipt_context(model, model_fingerprint: model_fingerprint)
      build_query_receipt(
        model,
        command: "query_topology",
        state: state,
        started_at: started_at,
        unit_info: unit_info,
        coordinate_space: "active_context",
        context: query_context
      )
    end

    def handle_query_overlap(params)
      started_at = monotonic_now
      model = require_model
      unit_info = resolve_public_unit(model, params["unit"] || "in")
      first_pid, second_pid = query_pid_pair(params, %w[first_pid second_pid])
      first = require_entity_by_pid(model, first_pid)
      second = require_entity_by_pid(model, second_pid)
      first_box = box_triplet(first.bounds)
      second_box = box_triplet(second.bounds)
      lower = 3.times.map { |index| [first_box[0][index], second_box[0][index]].max }
      upper = 3.times.map { |index| [first_box[1][index], second_box[1][index]].min }
      overlap = 3.times.all? { |index| lower[index] <= upper[index] + SEMANTIC_QUANTUM }
      resolved = unit_info["resolved_unit"]
      overlap_box = if overlap
                      {
                        "min" => convert_triplet_from_internal(lower, resolved),
                        "max" => convert_triplet_from_internal(upper, resolved)
                      }
                    end
      state = {
        "query" => "query_overlap",
        "first_pid" => first_pid,
        "second_pid" => second_pid,
        "overlap" => overlap,
        "overlap_box" => overlap_box,
        "semantic_fingerprint" => Digest::SHA256.hexdigest(
          JSON.generate(
            {
              "query" => "query_overlap",
              "first" => semantic_entity_state(model, first)["semantic_fingerprint"],
              "second" => semantic_entity_state(model, second)["semantic_fingerprint"]
            }
          )
        )
      }
      snapshot = semantic_active_entity_snapshot(model)
      model_fingerprint = semantic_model_fingerprint(model, active_snapshot: snapshot)
      query_context = receipt_context(model, model_fingerprint: model_fingerprint)
      build_query_receipt(
        model,
        command: "query_overlap",
        state: state,
        started_at: started_at,
        unit_info: unit_info,
        coordinate_space: "active_context",
        context: query_context
      )
    end

    def point_to_triplet(point)
      [point.x.to_f, point.y.to_f, point.z.to_f]
    end

    def box_triplet(bounds)
      [[bounds.min.x.to_f, bounds.min.y.to_f, bounds.min.z.to_f],
       [bounds.max.x.to_f, bounds.max.y.to_f, bounds.max.z.to_f]]
    end

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
      unless resolved == root || resolved.start_with?(root + File::SEPARATOR)
        raise BridgeError.new("asset_path_escape", "Asset file escapes the registry root")
      end
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
      unless resolved == root || resolved.start_with?(root + File::SEPARATOR)
        raise BridgeError.new("texture_path_escape", "Texture file escapes the registry root")
      end
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

    def require_material(model, name)
      material_name = bounded_name(name, "material")
      material = model.materials[material_name]
      raise BridgeError.new("material_not_found", "SketchUp material was not found") unless material
      material
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

    def handle_material_info(params)
      started_at = monotonic_now
      model = require_model
      unit_info = resolve_public_unit(model, params["unit"] || "in")
      unless params.is_a?(Hash)
        raise BridgeError.new("invalid_argument", "material_info params must be an object")
      end
      unknown_keys = params.keys - MATERIAL_INFO_PARAM_KEYS
      unless unknown_keys.empty?
        raise BridgeError.new(
          "invalid_argument",
          "material_info params contain unsupported keys: #{unknown_keys.sort.join(', ')}"
        )
      end
      material = require_material(model, params["material"])
      state = material_semantic_state(material)
      snapshot = semantic_active_entity_snapshot(model)
      model_fingerprint = semantic_model_fingerprint(model, active_snapshot: snapshot)
      query_context = receipt_context(model, model_fingerprint: model_fingerprint)
      build_query_receipt(
        model,
        command: "material_info",
        state: state,
        started_at: started_at,
        unit_info: unit_info,
        coordinate_space: "active_context",
        context: query_context
      )
    end

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

    def vector_to_triplet(vector)
      [vector.x.to_f, vector.y.to_f, vector.z.to_f]
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

    def query_camera_receipt(model, command, state, started_at, unit_info)
      snapshot = semantic_active_entity_snapshot(model)
      model_fingerprint = semantic_model_fingerprint(model, active_snapshot: snapshot)
      query_context = receipt_context(model, model_fingerprint: model_fingerprint)
      build_query_receipt(
        model,
        command: command,
        state: state,
        started_at: started_at,
        unit_info: unit_info,
        coordinate_space: "active_context",
        context: query_context
      )
    end

    def handle_camera_get(params)
      started_at = monotonic_now
      model = require_model
      unit_info = resolve_public_unit(model, params["unit"] || "in")
      state = camera_semantic_state(model)
      query_camera_receipt(model, "camera_get", state, started_at, unit_info)
    end

    def handle_scene_list(params)
      started_at = monotonic_now
      model = require_model
      unit_info = resolve_public_unit(model, params["unit"] || "in")
      state = scene_semantic_state(model)
      query_camera_receipt(model, "scene_list", state, started_at, unit_info)
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

    def preflight_camera_set(model, params)
      validate_camera_set_params(params)
      model.active_view.camera
      true
    end

    def preflight_scene_create(model, params)
      name = validate_scene_create_params(params)
      if model.pages.any? { |page| page.name == name }
        raise BridgeError.new("already_exists", "Scene already exists")
      end
      true
    end

    def validate_camera_if_match(model, if_match)
      unless if_match.is_a?(String) && if_match.match?(/\A[a-f0-9]{64}\z/)
        raise BridgeError.new("invalid_argument", "if_match must be a 64-character lowercase SHA-256 hex string")
      end
      current = camera_semantic_state(model)["semantic_fingerprint"]
      unless current == if_match
        raise BridgeError.new("stale_entity_state", "Camera state changed since the receipt")
      end
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

    def model_files_root
      local_app_data = ENV["LOCALAPPDATA"]
      base = if local_app_data && !local_app_data.empty?
               File.join(local_app_data, "CDT-SketchUp")
             else
               File.join(Dir.home, ".cdt-sketchup")
             end
      File.join(base, MODEL_FILES_ROOTNAME)
    end

    def resolve_model_file(file_name, allowed_extensions)
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
      unless resolved == root || resolved.start_with?(root + File::SEPARATOR)
        raise BridgeError.new("model_path_escape", "Model file escapes the models root")
      end
      resolved
    end

    def model_file_state(action, file_name, extra = {})
      payload = { "query" => action, "file" => file_name }.merge(extra)
      {
        "file" => file_name,
        "semantic_fingerprint" => Digest::SHA256.hexdigest(JSON.generate(payload))
      }.merge(extra)
    end

    def file_operation_receipt(model, command, state, checks, started_at)
      snapshot = semantic_active_entity_snapshot(model)
      model_fingerprint = semantic_model_fingerprint(model, active_snapshot: snapshot)
      context = receipt_context(model, model_fingerprint: model_fingerprint)
      build_operation_receipt(
        model,
        receipt_id: SecureRandom.uuid,
        started_at: started_at,
        action: command,
        state: state,
        affected: empty_affected_entities,
        validation: { "passed" => checks.all? { |check| check["passed"] }, "checks" => checks },
        before_count: model.active_entities.length,
        before_fingerprint: model_fingerprint,
        after_count: model.active_entities.length,
        after_fingerprint: model_fingerprint,
        unit_info: { "public_unit" => "none", "resolved_unit" => "in" },
        coordinate_space: "active_context",
        context_before: context,
        context: context
      )
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
      resolved = resolve_model_file(params["file"], %w[skp])
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
      if params.key?("if_model_guid") && !params["if_model_guid"].nil?
        unless params["if_model_guid"].to_s == model.guid.to_s
          raise BridgeError.new("context_mismatch", "Active model changed since the receipt")
        end
      end
      opened = begin
        Sketchup.open_file(resolved)
      rescue StandardError => error
        log("model open failed: #{error.class}: #{error.message}")
        raise BridgeError.new("model_save_failed", "SketchUp did not open the model")
      end
      unless opened
        raise BridgeError.new("model_save_failed", "SketchUp did not open the model")
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
      resolved = resolve_model_file(params["file"], [format])
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

    def validate_repair_pid_params(params, keys, action)
      unless params.is_a?(Hash)
        raise BridgeError.new("invalid_argument", "#{action} params must be an object")
      end
      unknown_keys = params.keys - keys
      unless unknown_keys.empty?
        raise BridgeError.new(
          "invalid_argument",
          "#{action} params contain unsupported keys: #{unknown_keys.sort.join(', ')}"
        )
      end
      unless params.key?("persistent_id")
        raise BridgeError.new("invalid_argument", "#{action} persistent_id is required")
      end
      bounded_integer(params["persistent_id"], minimum: 1, maximum: (2**63) - 1, name: "persistent_id")
    end

    def preflight_repair_reverse_face(model, params)
      persistent_id = validate_repair_pid_params(params, REVERSE_FACE_PARAM_KEYS, "repair_reverse_face")
      entity = require_active_entity(model, persistent_id)
      unless entity.is_a?(Sketchup::Face)
        raise BridgeError.new("unsupported_object_type", "repair_reverse_face targets only faces")
      end
      true
    end

    def preflight_repair_erase_degenerate(model, params)
      persistent_id = validate_repair_pid_params(params, ERASE_DEGENERATE_PARAM_KEYS, "repair_erase_degenerate")
      entity = require_active_entity(model, persistent_id)
      unless entity.is_a?(Sketchup::Edge)
        raise BridgeError.new("unsupported_object_type", "repair_erase_degenerate targets only edges")
      end
      unless entity.length.to_f <= SEMANTIC_QUANTUM
        raise BridgeError.new("invalid_argument", "repair target is not a degenerate edge")
      end
      unless entity.faces.empty?
        raise BridgeError.new("unsupported_object_type", "degenerate edge bounds faces")
      end
      true
    end

    def execute_repair_reverse_face(model, params)
      persistent_id = validate_repair_pid_params(params, REVERSE_FACE_PARAM_KEYS, "repair_reverse_face")
      entity = require_active_entity(model, persistent_id)
      unless entity.is_a?(Sketchup::Face)
        raise BridgeError.new("unsupported_object_type", "repair_reverse_face targets only faces")
      end
      before_normal = vector_to_triplet(entity.normal)
      before_area = quantize_number(entity.area)
      begin
        entity.reverse!
      rescue StandardError => error
        log("reverse face failed: #{error.class}: #{error.message}")
        raise BridgeError.new("repair_failed", "SketchUp did not reverse the face")
      end
      {
        "entity" => entity,
        "metadata" => {
          "target_persistent_id" => persistent_id,
          "before_normal" => before_normal,
          "before_area" => before_area
        }
      }
    end

    def execute_repair_erase_degenerate(model, params)
      persistent_id = validate_repair_pid_params(params, ERASE_DEGENERATE_PARAM_KEYS, "repair_erase_degenerate")
      entity = require_active_entity(model, persistent_id)
      unless entity.is_a?(Sketchup::Edge)
        raise BridgeError.new("unsupported_object_type", "repair_erase_degenerate targets only edges")
      end
      unless entity.length.to_f <= SEMANTIC_QUANTUM
        raise BridgeError.new("invalid_argument", "repair target is not a degenerate edge")
      end
      unless entity.faces.empty?
        raise BridgeError.new("unsupported_object_type", "degenerate edge bounds faces")
      end
      begin
        model.active_entities.erase_entities(entity)
      rescue ArgumentError, RuntimeError => error
        log("erase degenerate failed: #{error.class}: #{error.message}")
        raise BridgeError.new("repair_failed", "SketchUp did not erase the degenerate edge")
      end
      if entity_alive_by_pid?(model, persistent_id)
        raise BridgeError.new("repair_failed", "Degenerate edge persistent ID still resolves")
      end
      {
        "state" => {
          "persistent_id" => persistent_id,
          "type" => "Edge",
          "valid" => false,
          "active_context" => false,
          "deleted" => true
        },
        "metadata" => { "target_persistent_id" => persistent_id }
      }
    end

    def handle_integrity_report(params)
      started_at = monotonic_now
      model = require_model
      unit_info = resolve_public_unit(model, params["unit"] || "in")
      entities = model.active_entities.to_a
      truncated = entities.length > MAX_INTEGRITY_SCAN
      scanned = truncated ? entities.first(MAX_INTEGRITY_SCAN) : entities
      counts = Hash.new(0)
      degenerate = []
      non_manifold = []
      tagged_raw = []
      bad_transforms = []
      default_tags = %w[Layer0 Untagged]
      scanned.each do |entity|
        counts[entity.typename] += 1
        if entity.is_a?(Sketchup::Edge)
          degenerate << entity.persistent_id if entity.length.to_f <= SEMANTIC_QUANTUM
          faces_count = entity.faces.length
          non_manifold << entity.persistent_id if faces_count > 2
        end
        if (entity.is_a?(Sketchup::Edge) || entity.is_a?(Sketchup::Face)) &&
            entity.respond_to?(:layer) && entity.layer &&
            !default_tags.include?(entity.layer.name.to_s)
          tagged_raw << entity.persistent_id
        end
        if (entity.is_a?(Sketchup::Group) || entity.is_a?(Sketchup::ComponentInstance)) &&
            entity.respond_to?(:transformation)
          determinant = transformation_determinant(entity.transformation.to_a)
          bad_transforms << entity.persistent_id if determinant.abs <= MIN_TRANSFORM_DETERMINANT
        end
      end
      used_material_names = []
      scanned.each do |entity|
        next unless entity.respond_to?(:material) && entity.material
        used_material_names << entity.material.name.to_s
        if entity.is_a?(Sketchup::Face) && entity.back_material
          used_material_names << entity.back_material.name.to_s
        end
      end
      definition_walk_truncated = false
      visited_definition_entities = 0
      model.definitions.each do |definition|
        next if definition.group? || definition.image?
        definition.entities.each do |entity|
          visited_definition_entities += 1
          if visited_definition_entities > 20000
            definition_walk_truncated = true
            break
          end
          next unless entity.respond_to?(:material) && entity.material
          used_material_names << entity.material.name.to_s
        end
        break if definition_walk_truncated
      end
      used_material_names.uniq!
      unused_definitions = model.definitions.select do |definition|
        !definition.group? && !definition.image? && definition.count_used_instances.zero?
      end.map { |definition| definition.name.to_s }.sort
      unused_materials = model.materials.map { |material| material.name.to_s }.reject do |name|
        used_material_names.include?(name)
      end.sort
      state = {
        "query" => "integrity_report",
        "scanned_entities" => scanned.length,
        "scan_truncated" => truncated || definition_walk_truncated,
        "model_complexity" => {
          "active_entities" => model.active_entities.length,
          "definitions" => model.definitions.length,
          "materials" => model.materials.length,
          "scenes" => model.pages.length
        },
        "entity_counts" => counts,
        "degenerate_edges" => degenerate.sort,
        "non_manifold_edges" => non_manifold.sort,
        "tag_hygiene" => {
          "raw_tagged_off_default_count" => tagged_raw.length,
          "raw_tagged_sample" => tagged_raw.sort.first(50)
        },
        "invalid_transforms" => bad_transforms.sort,
        "unused_definitions" => unused_definitions,
        "unused_materials" => unused_materials,
        "issue_count" => degenerate.length + non_manifold.length + tagged_raw.length +
          bad_transforms.length + unused_definitions.length + unused_materials.length,
        "semantic_fingerprint" => Digest::SHA256.hexdigest(
          JSON.generate(
            {
              "query" => "integrity_report",
              "model" => semantic_model_fingerprint(model),
              "degenerate" => degenerate.sort,
              "non_manifold" => non_manifold.sort
            }
          )
        )
      }
      snapshot = semantic_active_entity_snapshot(model)
      model_fingerprint = semantic_model_fingerprint(model, active_snapshot: snapshot)
      query_context = receipt_context(model, model_fingerprint: model_fingerprint)
      build_query_receipt(
        model,
        command: "integrity_report",
        state: state,
        started_at: started_at,
        unit_info: unit_info,
        coordinate_space: "active_context",
        context: query_context
      )
    end

    def handle_definition_info(params)
      started_at = monotonic_now
      model = require_model
      unit_info = resolve_public_unit(model, params["unit"] || "in")
      guid = validate_definition_info_params(params)
      definition = find_definition_by_guid(model, guid)
      state = semantic_definition_state(model, definition)
      snapshot = semantic_active_entity_snapshot(model)
      model_fingerprint = semantic_model_fingerprint(model, active_snapshot: snapshot)
      query_context = receipt_context(model, model_fingerprint: model_fingerprint)
      build_query_receipt(
        model,
        command: "definition_info",
        state: state,
        started_at: started_at,
        unit_info: unit_info,
        coordinate_space: "active_context",
        context: query_context
      )
    end

    def validate_copy_entity_params(params)
      unless params.is_a?(Hash)
        raise BridgeError.new("invalid_argument", "copy_entity params must be an object")
      end
      unknown_copy_keys = params.keys - COPY_ENTITY_PARAM_KEYS
      unless unknown_copy_keys.empty?
        raise BridgeError.new(
          "invalid_argument",
          "copy_entity params contain unsupported keys: #{unknown_copy_keys.sort.join(', ')}"
        )
      end
      unless params.key?("persistent_id")
        raise BridgeError.new("invalid_argument", "copy_entity persistent_id is required")
      end
      bounded_integer(params["persistent_id"], minimum: 1, maximum: (2**63) - 1, name: "persistent_id")
    end

    def validate_array_count(value)
      count = begin
        Integer(value)
      rescue ArgumentError, TypeError
        raise BridgeError.new("invalid_argument", "array count must contain 1..100 copies")
      end
      unless count.between?(1, MAX_ARRAY_COPIES)
        raise BridgeError.new("invalid_argument", "array count must contain 1..100 copies")
      end
      count
    end

    def validate_linear_array_params(params)
      unless params.is_a?(Hash)
        raise BridgeError.new("invalid_argument", "linear_array params must be an object")
      end
      unknown_linear_keys = params.keys - LINEAR_ARRAY_PARAM_KEYS
      unless unknown_linear_keys.empty?
        raise BridgeError.new(
          "invalid_argument",
          "linear_array params contain unsupported keys: #{unknown_linear_keys.sort.join(', ')}"
        )
      end
      unless params.key?("persistent_id")
        raise BridgeError.new("invalid_argument", "linear_array persistent_id is required")
      end
      persistent_id = bounded_integer(params["persistent_id"], minimum: 1, maximum: (2**63) - 1, name: "persistent_id")
      vector = numeric_triplet(params["vector"], "vector")
      count = validate_array_count(params["count"])
      [persistent_id, vector, count]
    end

    def validate_radial_array_params(params)
      unless params.is_a?(Hash)
        raise BridgeError.new("invalid_argument", "radial_array params must be an object")
      end
      unknown_radial_keys = params.keys - RADIAL_ARRAY_PARAM_KEYS
      unless unknown_radial_keys.empty?
        raise BridgeError.new(
          "invalid_argument",
          "radial_array params contain unsupported keys: #{unknown_radial_keys.sort.join(', ')}"
        )
      end
      unless params.key?("persistent_id")
        raise BridgeError.new("invalid_argument", "radial_array persistent_id is required")
      end
      persistent_id = bounded_integer(params["persistent_id"], minimum: 1, maximum: (2**63) - 1, name: "persistent_id")
      origin = numeric_triplet(params["axis_origin"], "axis_origin")
      axis = numeric_triplet(params["axis"], "axis")
      axis_length = Math.sqrt(axis[0] * axis[0] + axis[1] * axis[1] + axis[2] * axis[2])
      if axis_length == 0.0
        raise BridgeError.new("invalid_argument", "axis must be non-zero")
      end
      degrees = finite_number(params["degrees"], "degrees")
      count = validate_array_count(params["count"])
      [persistent_id, origin, axis, degrees, count]
    end

    def require_copyable_entity(model, value)
      entity = require_active_entity(model, value)
      unless entity.is_a?(Sketchup::Group) || entity.is_a?(Sketchup::ComponentInstance)
        raise BridgeError.new(
          "unsupported_object_type",
          "copy_entity requires a group/component instance"
        )
      end
      if entity.respond_to?(:locked?) && entity.locked?
        raise BridgeError.new("locked_object", "copy_entity target must be unlocked")
      end
      entity
    end

    def duplication_member_count(entity)
      if entity.is_a?(Sketchup::Group)
        entity.entities.length
      elsif entity.is_a?(Sketchup::ComponentInstance)
        entity.definition.entities.length
      else
        0
      end
    end

    def validate_array_complexity!(entity, count, action)
      projected = duplication_member_count(entity) * count
      if projected > MAX_ARRAY_PROJECTED_ENTITIES
        raise BridgeError.new(
          "complexity_budget_exceeded",
          "#{action} projected #{projected} entities exceeding the #{MAX_ARRAY_PROJECTED_ENTITIES} entity budget"
        )
      end
      projected
    end

    def preflight_copy_entity(model, params)
      persistent_id = validate_copy_entity_params(params)
      require_copyable_entity(model, persistent_id)
      true
    end

    def preflight_linear_array(model, params)
      persistent_id, _vector, count = validate_linear_array_params(params)
      entity = require_copyable_entity(model, persistent_id)
      validate_array_complexity!(entity, count, "linear_array")
      true
    end

    def preflight_radial_array(model, params)
      persistent_id, _origin, _axis, _degrees, count = validate_radial_array_params(params)
      entity = require_copyable_entity(model, persistent_id)
      validate_array_complexity!(entity, count, "radial_array")
      true
    end

    def duplicate_object_for_copy(model, entity)
      if entity.is_a?(Sketchup::Group)
        copy = begin
          entity.copy
        rescue StandardError => error
          log("copy entity failed: #{error.class}: #{error.message}")
          raise BridgeError.new("copy_failed", "SketchUp did not copy the group")
        end
        unless copy && copy.valid? && copy.is_a?(Sketchup::Group)
          raise BridgeError.new("copy_failed", "SketchUp did not produce a group copy")
        end
        copy
      elsif entity.is_a?(Sketchup::ComponentInstance)
        copy = begin
          model.active_entities.add_instance(entity.definition, entity.transformation)
        rescue ArgumentError, RuntimeError => error
          log("copy entity failed: #{error.class}: #{error.message}")
          raise BridgeError.new("copy_failed", "SketchUp did not copy the instance")
        end
        unless copy && copy.valid? && copy.is_a?(Sketchup::ComponentInstance)
          raise BridgeError.new("copy_failed", "SketchUp did not produce an instance copy")
        end
        copy
      else
        raise BridgeError.new(
          "unsupported_object_type",
          "copy_entity requires a group/component instance"
        )
      end
    end

    def duplicate_and_place(model, source, transform)
      copy = duplicate_object_for_copy(model, source)
      begin
        copy.transformation = transform
      rescue ArgumentError, RuntimeError => error
        log("place array copy failed: #{error.class}: #{error.message}")
        raise BridgeError.new("copy_failed", "SketchUp did not place the array copy")
      end
      copy
    end

    def execute_copy_entity(model, params)
      persistent_id = validate_copy_entity_params(params)
      source = require_copyable_entity(model, persistent_id)
      source_state = semantic_entity_state(model, source)
      copy = duplicate_object_for_copy(model, source)
      {
        "entity" => copy,
        "metadata" => {
          "source_persistent_id" => persistent_id,
          "source_transformation" => source_state["transformation"],
          "source_definition_guid" => source_state.dig("definition", "guid"),
          "source_geometry_fingerprint" => source_state["geometry_fingerprint"]
        }
      }
    end

    def execute_linear_array(model, params)
      persistent_id, vector, count = validate_linear_array_params(params)
      source = require_copyable_entity(model, persistent_id)
      validate_array_complexity!(source, count, "linear_array")
      source_transform = source.transformation
      requested = (1..count).map do |step|
        offset = Geom::Vector3d.new(vector[0] * step, vector[1] * step, vector[2] * step)
        (Geom::Transformation.translation(offset) * source_transform).to_a.map do |value|
          quantize_number(value)
        end
      end
      execute_object_array(model, source, persistent_id, count, requested)
    end

    def execute_radial_array(model, params)
      persistent_id, origin, axis, degrees, count = validate_radial_array_params(params)
      source = require_copyable_entity(model, persistent_id)
      validate_array_complexity!(source, count, "radial_array")
      source_transform = source.transformation
      center = Geom::Point3d.new(origin[0], origin[1], origin[2])
      direction = Geom::Vector3d.new(axis[0], axis[1], axis[2])
      requested = (1..count).map do |step|
        rotation = Geom::Transformation.rotation(center, direction, degrees * step * Math::PI / 180.0)
        (rotation * source_transform).to_a.map { |value| quantize_number(value) }
      end
      execute_object_array(model, source, persistent_id, count, requested)
    end

    def execute_object_array(model, source, persistent_id, count, requested)
      source_state = semantic_entity_state(model, source)
      copies = requested.map do |matrix|
        duplicate_and_place(model, source, Geom::Transformation.new(matrix))
      end
      {
        "state" => semantic_entity_state(model, copies.first),
        "metadata" => {
          "source_persistent_id" => persistent_id,
          "count" => count,
          "copy_persistent_ids" => copies.map(&:persistent_id),
          "requested_transformations" => requested,
          "source_definition_guid" => source_state.dig("definition", "guid"),
          "source_geometry_fingerprint" => source_state["geometry_fingerprint"]
        }
      }
    end

    def unit_normal_vector(value, name)
      triplet = numeric_triplet(value, name)
      vector = Geom::Vector3d.new(triplet[0], triplet[1], triplet[2])
      if vector.length == 0.0
        raise BridgeError.new("invalid_argument", "normal must be non-zero")
      end
      vector.normalize
    end

    def orthonormal_basis(normal)
      helper = normal.z.abs < 0.9 ? Geom::Vector3d.new(0, 0, 1) : Geom::Vector3d.new(0, 1, 0)
      u = (helper * normal).normalize
      v = (normal * u).normalize
      [u, v]
    end

    def scaled_vector(vector, factor)
      Geom::Vector3d.new(vector.x * factor, vector.y * factor, vector.z * factor)
    end

    def validate_curve_segments(value, name)
      segments = begin
        Integer(value)
      rescue ArgumentError, TypeError
        raise BridgeError.new("invalid_argument", "#{name} must be an integer")
      end
      unless segments.between?(3, MAX_CURVE_SEGMENTS)
        raise BridgeError.new("invalid_argument", "#{name} must contain 3..#{MAX_CURVE_SEGMENTS} segments")
      end
      segments
    end

    def validate_positive_length(value, name, message)
      number = finite_number(value, name)
      unless number.positive?
        raise BridgeError.new("invalid_argument", message)
      end
      number
    end

    def validate_polyline_params(params)
      unless params.is_a?(Hash)
        raise BridgeError.new("invalid_argument", "create_polyline params must be an object")
      end
      unknown_keys = params.keys - POLYLINE_PARAM_KEYS
      unless unknown_keys.empty?
        raise BridgeError.new(
          "invalid_argument",
          "create_polyline params contain unsupported keys: #{unknown_keys.sort.join(', ')}"
        )
      end
      raw_points = params["points"]
      unless raw_points.is_a?(Array) && raw_points.length.between?(2, MAX_POLYLINE_POINTS)
        raise BridgeError.new(
          "invalid_argument",
          "points must contain 2..#{MAX_POLYLINE_POINTS} points"
        )
      end
      points = raw_points.each_with_index.map do |point, index|
        numeric_triplet(point, "points[#{index}]")
      end
      points.each_cons(2).each_with_index do |pair, index|
        if pair[0] == pair[1]
          raise BridgeError.new(
            "invalid_geometry",
            "polyline points must be pairwise distinct"
          )
        end
      end
      closed = params["closed"]
      unless closed == true || closed == false
        raise BridgeError.new("invalid_argument", "closed must be boolean")
      end
      [points, closed]
    end

    def validate_rectangle_params(params)
      unless params.is_a?(Hash)
        raise BridgeError.new("invalid_argument", "create_rectangle params must be an object")
      end
      unknown_keys = params.keys - RECTANGLE_PARAM_KEYS
      unless unknown_keys.empty?
        raise BridgeError.new(
          "invalid_argument",
          "create_rectangle params contain unsupported keys: #{unknown_keys.sort.join(', ')}"
        )
      end
      origin = numeric_triplet(params["origin"], "origin")
      width = validate_positive_length(params["width"], "width", "width must be positive")
      height = validate_positive_length(params["height"], "height", "height must be positive")
      normal = unit_normal_vector(params["normal"], "normal")
      [origin, width, height, normal]
    end

    def validate_circle_params(params)
      unless params.is_a?(Hash)
        raise BridgeError.new("invalid_argument", "create_circle params must be an object")
      end
      unknown_keys = params.keys - CIRCLE_PARAM_KEYS
      unless unknown_keys.empty?
        raise BridgeError.new(
          "invalid_argument",
          "create_circle params contain unsupported keys: #{unknown_keys.sort.join(', ')}"
        )
      end
      center = numeric_triplet(params["center"], "center")
      normal = unit_normal_vector(params["normal"], "normal")
      radius = validate_positive_length(params["radius"], "radius", "radius must be positive")
      segments = validate_curve_segments(params["segments"], "segments")
      [center, normal, radius, segments]
    end

    def validate_arc_params(params)
      unless params.is_a?(Hash)
        raise BridgeError.new("invalid_argument", "create_arc params must be an object")
      end
      unknown_keys = params.keys - ARC_PARAM_KEYS
      unless unknown_keys.empty?
        raise BridgeError.new(
          "invalid_argument",
          "create_arc params contain unsupported keys: #{unknown_keys.sort.join(', ')}"
        )
      end
      center = numeric_triplet(params["center"], "center")
      normal = unit_normal_vector(params["normal"], "normal")
      radius = validate_positive_length(params["radius"], "radius", "radius must be positive")
      start_degrees = finite_number(params["start_degrees"], "start_degrees")
      end_degrees = finite_number(params["end_degrees"], "end_degrees")
      sweep = (end_degrees - start_degrees) % 360.0
      if sweep == 0.0
        raise BridgeError.new("invalid_argument", "arc sweep must be non-zero")
      end
      segments = validate_curve_segments(params["segments"], "segments")
      [center, normal, radius, start_degrees, end_degrees, segments]
    end

    def validate_polygon_params(params)
      unless params.is_a?(Hash)
        raise BridgeError.new("invalid_argument", "create_polygon params must be an object")
      end
      unknown_keys = params.keys - POLYGON_PARAM_KEYS
      unless unknown_keys.empty?
        raise BridgeError.new(
          "invalid_argument",
          "create_polygon params contain unsupported keys: #{unknown_keys.sort.join(', ')}"
        )
      end
      center = numeric_triplet(params["center"], "center")
      normal = unit_normal_vector(params["normal"], "normal")
      radius = validate_positive_length(params["radius"], "radius", "radius must be positive")
      sides = begin
        Integer(params["sides"])
      rescue ArgumentError, TypeError
        raise BridgeError.new("invalid_argument", "sides must be an integer")
      end
      unless sides.between?(3, MAX_CURVE_SEGMENTS)
        raise BridgeError.new("invalid_argument", "sides must contain 3..360 sides")
      end
      [center, normal, radius, sides]
    end

    def preflight_create_polyline(model, params)
      validate_polyline_params(params)
      true
    end

    def preflight_create_rectangle(model, params)
      validate_rectangle_params(params)
      true
    end

    def preflight_create_circle(model, params)
      validate_circle_params(params)
      true
    end

    def preflight_create_arc(model, params)
      validate_arc_params(params)
      true
    end

    def preflight_create_polygon(model, params)
      validate_polygon_params(params)
      true
    end

    def planar_polygon_normal(points)
      nx = ny = nz = 0.0
      points.each_with_index do |point, index|
        nxt = points[(index + 1) % points.length]
        nx += (point[1] - nxt[1]) * (point[2] + nxt[2])
        ny += (point[2] - nxt[2]) * (point[0] + nxt[0])
        nz += (point[0] - nxt[0]) * (point[1] + nxt[1])
      end
      [nx, ny, nz]
    end

    def planar_closed_chain(points)
      return [false, nil] if points.length < 4
      nx, ny, nz = planar_polygon_normal(points)
      magnitude = Math.sqrt(nx * nx + ny * ny + nz * nz)
      return [false, nil] if magnitude == 0.0
      base = points[0]
      span = points.map do |point|
        Math.sqrt((point[0] - base[0])**2 + (point[1] - base[1])**2 + (point[2] - base[2])**2)
      end.max
      tolerance = [span * 1e-9, SEMANTIC_QUANTUM].max
      planar = points.all? do |point|
        ((point[0] - base[0]) * nx + (point[1] - base[1]) * ny + (point[2] - base[2]) * nz).abs <= tolerance * magnitude
      end
      planar ? [true, magnitude / 2.0] : [false, nil]
    end

    def execute_create_polyline(model, params)
      points, closed = validate_polyline_params(params)
      chain = points.dup
      chain << points.first if closed && points.first != points.last
      expected_length = chain.each_cons(2).sum do |pair|
        a, b = pair
        Math.sqrt((a[0] - b[0])**2 + (a[1] - b[1])**2 + (a[2] - b[2])**2)
      end
      planar, face_area = closed ? planar_closed_chain(chain) : [false, nil]
      group = model.active_entities.add_group
      unless group && group.valid? && group.is_a?(Sketchup::Group)
        raise BridgeError.new("geometry_execution_failed", "SketchUp did not create the polyline group")
      end
      edges = []
      begin
        chain.each_cons(2) do |pair|
          edge = group.entities.add_line(
            Geom::Point3d.new(pair[0][0], pair[0][1], pair[0][2]),
            Geom::Point3d.new(pair[1][0], pair[1][1], pair[1][2])
          )
          raise BridgeError.new("invalid_geometry", "SketchUp did not create the polyline edge") unless edge
          edges << edge
        end
        if planar
          face = group.entities.add_face(edges)
          raise BridgeError.new("invalid_geometry", "SketchUp did not cap the planar chain") unless face
        end
      rescue BridgeError
        raise
      rescue StandardError => error
        log("create polyline failed: #{error.class}: #{error.message}")
        raise BridgeError.new("geometry_execution_failed", "SketchUp did not create the polyline")
      end
      vertices = edges.flat_map { |edge| [edge.start, edge.end] }.uniq
      {
        "entity" => group,
        "metadata" => {
          "edge_count" => edges.length,
          "vertex_count" => vertices.length,
          "total_length" => expected_length,
          "closed" => closed,
          "planar" => planar,
          "face_expected" => planar,
          "face_area" => face_area
        }
      }
    end

    def execute_create_rectangle(model, params)
      origin, width, height, normal = validate_rectangle_params(params)
      u, v = orthonormal_basis(normal)
      origin_point = Geom::Point3d.new(origin[0], origin[1], origin[2])
      corners = [
        origin_point,
        origin_point + scaled_vector(u, width),
        origin_point + scaled_vector(u, width) + scaled_vector(v, height),
        origin_point + scaled_vector(v, height)
      ]
      before_edges = model.active_entities.grep(Sketchup::Edge).map(&:persistent_id)
      face = begin
        model.active_entities.add_face(corners)
      rescue ArgumentError, RuntimeError => error
        log("create rectangle failed: #{error.class}: #{error.message}")
        raise BridgeError.new("invalid_geometry", "SketchUp rejected rectangle geometry")
      end
      raise BridgeError.new("invalid_geometry", "SketchUp did not create the rectangle face") unless face
      after_edges = model.active_entities.grep(Sketchup::Edge).map(&:persistent_id)
      new_edge_ids = (after_edges - before_edges).sort
      face_edge_ids = face.edges.map(&:persistent_id).sort
      unless new_edge_ids == face_edge_ids && new_edge_ids.length == 4
        raise BridgeError.new("invalid_geometry", "rectangle merged with existing geometry")
      end
      group = model.active_entities.add_group(face.edges + [face])
      unless group && group.valid? && group.is_a?(Sketchup::Group)
        raise BridgeError.new("geometry_execution_failed", "SketchUp did not group the rectangle")
      end
      {
        "entity" => group,
        "metadata" => {
          "corners" => corners.map { |point| quantized_point(point) },
          "width" => width,
          "height" => height,
          "normal" => [normal.x, normal.y, normal.z].map { |value| quantize_number(value) },
          "rectangle_area" => width * height
        }
      }
    end

    def execute_create_circle(model, params)
      center, normal, radius, segments = validate_circle_params(params)
      center_point = Geom::Point3d.new(center[0], center[1], center[2])
      group = model.active_entities.add_group
      unless group && group.valid? && group.is_a?(Sketchup::Group)
        raise BridgeError.new("geometry_execution_failed", "SketchUp did not create the circle group")
      end
      edges = begin
        group.entities.add_circle(center_point, normal, radius, segments)
      rescue ArgumentError, RuntimeError => error
        log("create circle failed: #{error.class}: #{error.message}")
        raise BridgeError.new("invalid_geometry", "SketchUp rejected circle geometry")
      end
      unless edges.is_a?(Array) && edges.length == segments
        raise BridgeError.new("geometry_execution_failed", "SketchUp did not create the circle edges")
      end
      {
        "entity" => group,
        "metadata" => {
          "center" => center,
          "radius" => radius,
          "segments" => segments,
          "normal" => [normal.x, normal.y, normal.z].map { |value| quantize_number(value) }
        }
      }
    end

    def execute_create_arc(model, params)
      center, normal, radius, start_degrees, end_degrees, segments = validate_arc_params(params)
      u, = orthonormal_basis(normal)
      center_point = Geom::Point3d.new(center[0], center[1], center[2])
      group = model.active_entities.add_group
      unless group && group.valid? && group.is_a?(Sketchup::Group)
        raise BridgeError.new("geometry_execution_failed", "SketchUp did not create the arc group")
      end
      edges = begin
        group.entities.add_arc(
          center_point, u, normal, radius,
          start_degrees * Math::PI / 180.0, end_degrees * Math::PI / 180.0, segments
        )
      rescue ArgumentError, RuntimeError => error
        log("create arc failed: #{error.class}: #{error.message}")
        raise BridgeError.new("invalid_geometry", "SketchUp rejected arc geometry")
      end
      unless edges.is_a?(Array) && edges.length == segments
        raise BridgeError.new("geometry_execution_failed", "SketchUp did not create the arc edges")
      end
      {
        "entity" => group,
        "metadata" => {
          "center" => center,
          "radius" => radius,
          "segments" => segments,
          "start_degrees" => start_degrees,
          "end_degrees" => end_degrees,
          "xaxis" => [u.x, u.y, u.z].map { |value| quantize_number(value) },
          "normal" => [normal.x, normal.y, normal.z].map { |value| quantize_number(value) }
        }
      }
    end

    def execute_create_polygon(model, params)
      center, normal, radius, sides = validate_polygon_params(params)
      u, v = orthonormal_basis(normal)
      center_point = Geom::Point3d.new(center[0], center[1], center[2])
      vertices = sides.times.map do |index|
        angle = 2.0 * Math::PI * index / sides
        center_point + scaled_vector(u, radius * Math.cos(angle)) + scaled_vector(v, radius * Math.sin(angle))
      end
      before_edges = model.active_entities.grep(Sketchup::Edge).map(&:persistent_id)
      face = begin
        model.active_entities.add_face(vertices)
      rescue ArgumentError, RuntimeError => error
        log("create polygon failed: #{error.class}: #{error.message}")
        raise BridgeError.new("invalid_geometry", "SketchUp rejected polygon geometry")
      end
      raise BridgeError.new("invalid_geometry", "SketchUp did not create the polygon face") unless face
      after_edges = model.active_entities.grep(Sketchup::Edge).map(&:persistent_id)
      new_edge_ids = (after_edges - before_edges).sort
      face_edge_ids = face.edges.map(&:persistent_id).sort
      unless new_edge_ids == face_edge_ids && new_edge_ids.length == sides
        raise BridgeError.new("invalid_geometry", "polygon merged with existing geometry")
      end
      group = model.active_entities.add_group(face.edges + [face])
      unless group && group.valid? && group.is_a?(Sketchup::Group)
        raise BridgeError.new("geometry_execution_failed", "SketchUp did not group the polygon")
      end
      {
        "entity" => group,
        "metadata" => {
          "center" => center,
          "radius" => radius,
          "sides" => sides,
          "normal" => [normal.x, normal.y, normal.z].map { |value| quantize_number(value) },
          "polygon_area" => sides * radius * radius * Math.sin(2.0 * Math::PI / sides) / 2.0
        }
      }
    end

    def validate_sweep_profile_params(params)
      unless params.is_a?(Hash)
        raise BridgeError.new("invalid_argument", "sweep_profile params must be an object")
      end
      unknown_keys = params.keys - SWEEP_PROFILE_PARAM_KEYS
      unless unknown_keys.empty?
        raise BridgeError.new(
          "invalid_argument",
          "sweep_profile params contain unsupported keys: #{unknown_keys.sort.join(', ')}"
        )
      end
      unless params.key?("face_pid")
        raise BridgeError.new("invalid_argument", "sweep_profile face_pid is required")
      end
      face_pid = bounded_integer(params["face_pid"], minimum: 1, maximum: (2**63) - 1, name: "face_pid")
      raw_path = params["path_pids"]
      unless raw_path.is_a?(Array) && raw_path.length.between?(1, MAX_SWEEP_PATH_EDGES)
        raise BridgeError.new(
          "invalid_argument",
          "sweep_profile path must contain 1..64 connected edges"
        )
      end
      path_pids = raw_path.each_with_index.map do |value, index|
        bounded_integer(value, minimum: 1, maximum: (2**63) - 1, name: "path_pids[#{index}]")
      end
      if path_pids.uniq.length != path_pids.length || path_pids.include?(face_pid)
        raise BridgeError.new("invalid_argument", "sweep_profile path must not contain duplicates")
      end
      [face_pid, path_pids]
    end

    def sweep_path_entities(model, face_pid, path_pids)
      face = require_active_entity(model, face_pid)
      unless face.is_a?(Sketchup::Face)
        raise BridgeError.new("unsupported_object_type", "sweep_profile requires an isolated profile face")
      end
      path = path_pids.map { |value| require_active_entity(model, value) }
      unless path.all? { |entity| entity.is_a?(Sketchup::Edge) }
        raise BridgeError.new(
          "invalid_argument",
          "sweep_profile path must contain 1..64 connected edges"
        )
      end
      allowed_ids = ([face] + face.edges + path).map(&:persistent_id).sort
      face_connected_ids, face_connected_unresolved = connected_persistent_ids(face)
      unless face_connected_unresolved.zero? && (face_connected_ids - allowed_ids).empty?
        raise BridgeError.new(
          "unsupported_object_type",
          "sweep_profile profile must connect only its path"
        )
      end
      edges_closed = face.edges.all? do |edge|
        edge_ids, edge_unresolved = connected_persistent_ids(edge)
        edge_unresolved.zero? && (edge_ids - allowed_ids).empty?
      end
      unless edges_closed
        raise BridgeError.new(
          "invalid_geometry",
          "sweep_profile inputs must connect only each other"
        )
      end
      chain_ok = path.all? do |edge|
        neighbor_ids = ([edge.start, edge.end].flat_map do |vertex|
          vertex.edges.map(&:persistent_id)
        end | edge.faces.map(&:persistent_id)).uniq
        (neighbor_ids - allowed_ids).empty? && !neighbor_ids.empty?
      end
      unless chain_ok
        raise BridgeError.new(
          "invalid_geometry",
          "sweep_profile path must connect only the profile"
        )
      end
      [face, path]
    end

    def preflight_sweep_profile(model, params)
      face_pid, path_pids = validate_sweep_profile_params(params)
      sweep_path_entities(model, face_pid, path_pids)
      true
    end

    def validate_sweep_if_match_set(model, action_params, if_match)
      unless if_match.is_a?(Hash)
        raise BridgeError.new(
          "invalid_argument",
          "if_match for sweep_profile must be an object keyed by persistent ID"
        )
      end
      face_pid, path_pids = validate_sweep_profile_params(action_params)
      expected_keys = ([face_pid] + path_pids).map(&:to_s).sort
      actual_keys = if_match.keys.map(&:to_s).sort
      unless actual_keys == expected_keys
        raise BridgeError.new(
          "invalid_argument",
          "if_match for sweep_profile must cover the exact face and path set"
        )
      end
      ([face_pid] + path_pids).each do |persistent_id|
        fingerprint = if_match[persistent_id.to_s] || if_match[persistent_id]
        unless fingerprint.is_a?(String) && fingerprint.match?(/\A[a-f0-9]{64}\z/)
          raise BridgeError.new(
            "invalid_argument",
            "if_match values must be 64-character lowercase SHA-256 hex strings"
          )
        end
        entity = require_active_entity(model, persistent_id)
        state = semantic_entity_state(model, entity)
        unless state["semantic_fingerprint"] == fingerprint
          raise BridgeError.new(
            "stale_entity_state",
            "One or more sweep_profile inputs changed since the receipt"
          )
        end
      end
      true
    end

    def execute_sweep_profile(model, params)
      face_pid, path_pids = validate_sweep_profile_params(params)
      face, path = sweep_path_entities(model, face_pid, path_pids)
      face_edges = face.edges
      input_entities = ([face] + face_edges + path).uniq
      input_pids = input_entities.map(&:persistent_id).sort
      input_fingerprints = input_entities.each_with_object({}) do |entity, result|
        state = semantic_entity_state(model, entity)
        result[entity.persistent_id.to_s] = {
          "identity" => state["identity_fingerprint"],
          "geometry" => state["geometry_fingerprint"],
          "reparent" => grouping_reparent_fingerprint(entity, state)
        }
      end
      edge_lengths = {}
      (face_edges + path).each { |edge| edge_lengths[edge.persistent_id.to_s] = quantize_number(edge.length) }
      face_area = quantize_number(face.area)
      input_bounds = aggregate_semantic_bounds(
        input_entities.map { |entity| semantic_entity_state(model, entity) }
      )
      before_ids = model.active_entities.map(&:persistent_id)
      swept = begin
        face.followme(path)
      rescue StandardError => error
        log("sweep profile failed: #{error.class}: #{error.message}")
        raise BridgeError.new("sweep_failed", "SketchUp did not sweep the profile")
      end
      unless swept
        raise BridgeError.new("sweep_failed", "SketchUp did not sweep the profile")
      end
      after_ids = model.active_entities.map(&:persistent_id)
      gone_ids = (before_ids - after_ids).sort
      seed_ids = (after_ids - before_ids)
      if seed_ids.empty?
        raise BridgeError.new("sweep_failed", "SketchUp sweep produced no geometry")
      end
      closure = seed_ids.flat_map do |persistent_id|
        entity = model.find_entity_by_persistent_id(persistent_id)
        next [] unless entity
        ids, _unresolved = connected_persistent_ids(entity)
        ids
      end.uniq
      if closure.length > MAX_OBJECTS
        raise BridgeError.new("semantic_state_too_large", "Swept shell exceeds entity limit")
      end
      closure_entities = closure.map { |persistent_id| model.find_entity_by_persistent_id(persistent_id) }
      unless closure_entities.all?
        raise BridgeError.new("sweep_failed", "Swept shell changed during grouping")
      end
      foreign = (closure & before_ids) - input_pids
      unless foreign.empty?
        raise BridgeError.new("invalid_geometry", "sweep_profile shell touched outside geometry")
      end
      group = model.active_entities.add_group(closure_entities)
      unless group && group.valid? && group.is_a?(Sketchup::Group)
        raise BridgeError.new("sweep_failed", "SketchUp did not group the swept shell")
      end
      {
        "entity" => group,
        "metadata" => {
          "input_persistent_ids" => input_pids,
          "face_pid" => face_pid,
          "input_fingerprints" => input_fingerprints,
          "edge_lengths" => edge_lengths,
          "face_area" => face_area,
          "input_bounds_min" => input_bounds["min"],
          "input_bounds_max" => input_bounds["max"],
          "consumed_persistent_ids" => gone_ids,
          "reparented_persistent_ids" => (closure & before_ids).sort,
          "sweep_definition_guid" => group.definition.guid.to_s
        }
      }
    end

    def receipt_model_state(active_entity_count, model_fingerprint)
      {
        "active_entity_count" => active_entity_count,
        "model_fingerprint" => model_fingerprint
      }
    end

    def receipt_limits
      {
        "bridge_frame_bytes" => MAX_FRAME_BYTES,
        "max_model_entities_for_fingerprint" => MAX_MODEL_FINGERPRINT_ENTITIES,
        "max_fingerprint_edges" => MAX_FINGERPRINT_EDGES,
        "max_face_points" => MAX_FACE_POINTS
      }
    end

    def receipt_duration_ms(started_at)
      ((monotonic_now - started_at) * 1000.0).round(3)
    end

    def safe_semantic_model_fingerprint(model, active_snapshot: nil)
      [semantic_model_fingerprint(model, active_snapshot: active_snapshot), nil]
    rescue BridgeError => error
      [
        nil,
        {
          "kind" => error.kind,
          "message" => error.message
        }
      ]
    rescue StandardError => error
      log("semantic model fingerprint failed: #{error.class}: #{error.message}")
      [
        nil,
        {
          "kind" => "semantic_fingerprint_failed",
          "message" => "Semantic model fingerprint failed"
        }
      ]
    end

    def handle_create_edge(params)
      model = require_model
      start_point = point3d(params["start"], "start")
      end_point = point3d(params["end"], "end")
      if start_point.distance(end_point).zero?
        raise BridgeError.new("invalid_geometry", "Edge endpoints must be distinct")
      end

      with_operation(model, "CDT: Create Edge") do
        edge = model.active_entities.add_line(start_point, end_point)
        raise BridgeError.new("invalid_geometry", "SketchUp did not create an edge") unless edge
        serialize_entity(edge)
      end
    end

    def handle_create_face(params)
      model = require_model
      raw_points = params["points"]
      unless raw_points.is_a?(Array) && raw_points.length.between?(3, MAX_FACE_POINTS)
        raise BridgeError.new("invalid_argument", "points must contain 3..#{MAX_FACE_POINTS} vertices")
      end
      points = raw_points.each_with_index.map { |value, index| point3d(value, "points[#{index}]") }

      with_operation(model, "CDT: Create Face") do
        face = begin
          model.active_entities.add_face(points)
        rescue ArgumentError
          raise BridgeError.new("invalid_geometry", "SketchUp rejected face geometry")
        end
        raise BridgeError.new("invalid_geometry", "SketchUp did not create a face") unless face
        serialize_entity(face)
      end
    end

    def handle_selection_by_ids(params)
      model = require_model
      raw_ids = params["persistent_ids"]
      unless raw_ids.is_a?(Array) && raw_ids.length.between?(1, MAX_OBJECTS)
        raise BridgeError.new("invalid_argument", "persistent_ids must contain 1..#{MAX_OBJECTS} ids")
      end

      replace = params.key?("replace") ? params["replace"] : true
      unless replace == true || replace == false
        raise BridgeError.new("invalid_argument", "replace must be boolean")
      end

      entities = raw_ids.map { |value| require_active_entity(model, value) }
      selection = model.selection
      selection.clear if replace
      entities.each { |entity| selection.add(entity) }
      {
        "selected_count" => selection.length,
        "selected" => selection.map { |entity| serialize_entity(entity) }
      }
    end

    def handle_selection_clear(_params)
      model = require_model
      selection = model.selection
      previous_count = selection.length
      selection.clear
      {
        "cleared" => previous_count,
        "selected_count" => selection.length
      }
    end

    def handle_object_delete(params)
      model = require_model
      entity = require_active_entity(model, params["persistent_id"])
      persistent_id = entity.persistent_id

      with_operation(model, "CDT: Delete Object") do
        entity.erase!
        {
          "deleted" => true,
          "persistent_id" => persistent_id
        }
      end
    end

    def handle_object_move(params)
      model = require_model
      entity = require_transformable_entity(model, params["persistent_id"])
      vector = vector3d(params["vector"], "vector")

      with_operation(model, "CDT: Move Object") do
        entity.transform!(Geom::Transformation.translation(vector))
        serialize_entity(entity)
      end
    end

    def handle_object_rotate(params)
      model = require_model
      entity = require_transformable_entity(model, params["persistent_id"])
      origin = point3d(params["axis_origin"], "axis_origin")
      axis = vector3d(params["axis"], "axis")
      if axis.length.zero?
        raise BridgeError.new("invalid_argument", "axis must be non-zero")
      end
      degrees = finite_number(params["degrees"], "degrees")
      radians = degrees * Math::PI / 180.0

      with_operation(model, "CDT: Rotate Object") do
        transform = Geom::Transformation.rotation(origin, axis, radians)
        entity.transform!(transform)
        serialize_entity(entity)
      end
    end

    def handle_object_scale(params)
      model = require_model
      entity = require_transformable_entity(model, params["persistent_id"])
      factors = numeric_triplet(params["factors"], "factors")
      if factors.any?(&:zero?)
        raise BridgeError.new("invalid_argument", "scale factors must be non-zero")
      end
      origin = if params.key?("origin")
                 point3d(params["origin"], "origin")
               else
                 entity.bounds.center
               end

      with_operation(model, "CDT: Scale Object") do
        transform = Geom::Transformation.scaling(origin, factors[0], factors[1], factors[2])
        entity.transform!(transform)
        serialize_entity(entity)
      end
    end

    def handle_push_pull_face(params)
      model = require_model
      face = require_active_entity(model, params["persistent_id"])
      unless face.is_a?(Sketchup::Face)
        raise BridgeError.new("unsupported_object_type", "push_pull_face requires a Face")
      end
      distance = finite_number(params["distance"], "distance")
      if distance.zero?
        raise BridgeError.new("invalid_argument", "distance must be non-zero")
      end
      persistent_id = face.persistent_id

      with_operation(model, "CDT: Push Pull Face") do
        face.pushpull(distance, false)
        current = model.find_entity_by_persistent_id(persistent_id)
        {
          "source_persistent_id" => persistent_id,
          "distance" => distance,
          "source_valid" => !!(current && current.valid?)
        }
      end
    end

    def handle_component_create_box(params)
      model = require_model
      with_operation(model, "CDT: Create Box Component") do
        serialize_entity(execute_create_box(model, params))
      end
    end

    def preflight_geometry_action(model, action, action_params)
      preflight_delete_entity(model, action_params) if action == "delete_entity"
      preflight_group_entities(model, action_params) if action == "group_entities"
      preflight_create_component(model, action_params) if action == "create_component"
      preflight_copy_entity(model, action_params) if action == "copy_entity"
      preflight_linear_array(model, action_params) if action == "linear_array"
      preflight_radial_array(model, action_params) if action == "radial_array"
      preflight_tag_assign(model, action_params) if action == "tag_assign"
      preflight_material_assign(model, action_params) if action == "material_assign"
      preflight_create_polyline(model, action_params) if action == "create_polyline"
      preflight_create_rectangle(model, action_params) if action == "create_rectangle"
      preflight_create_circle(model, action_params) if action == "create_circle"
      preflight_create_arc(model, action_params) if action == "create_arc"
      preflight_create_polygon(model, action_params) if action == "create_polygon"
      preflight_place_asset(model, action_params) if action == "place_asset"
      preflight_repair_reverse_face(model, action_params) if action == "repair_reverse_face"
      preflight_repair_erase_degenerate(model, action_params) if action == "repair_erase_degenerate"
      preflight_camera_set(model, action_params) if action == "camera_set"
      preflight_scene_create(model, action_params) if action == "scene_create"
      preflight_material_apply_texture(model, action_params) if action == "material_apply_texture"
      preflight_sweep_profile(model, action_params) if action == "sweep_profile"
      preflight_place_instance(model, action_params) if action == "place_instance"
      preflight_make_unique(model, action_params) if action == "make_unique"
      true
    end

    def preflight_delete_entity(model, params)
      validate_delete_entity_params(params)
      require_deletable_entity(model, params["persistent_id"])
      true
    end

    def validate_delete_entity_params(params)
      unless params.is_a?(Hash)
        raise BridgeError.new("invalid_argument", "delete_entity params must be an object")
      end
      unknown_delete_keys = params.keys - DELETE_ENTITY_PARAM_KEYS
      unless unknown_delete_keys.empty?
        raise BridgeError.new(
          "invalid_argument",
          "delete_entity params contain unsupported keys: #{unknown_delete_keys.sort.join(', ')}"
        )
      end
      unless params.key?("persistent_id")
        raise BridgeError.new("invalid_argument", "delete_entity persistent_id is required")
      end
      true
    end

    def preflight_group_entities(model, params)
      persistent_ids, = validate_group_entities_params(params)
      entities = persistent_ids.map { |value| require_active_entity(model, value) }
      unless entities.all? { |entity| groupable_entity?(entity) }
        raise BridgeError.new(
          "unsupported_object_type",
          "group_entities supports only edges, faces, groups, and component instances"
        )
      end
      if entities.any? { |entity| entity.respond_to?(:locked?) && entity.locked? }
        raise BridgeError.new("locked_object", "group_entities targets must be unlocked")
      end
      unless complete_groupable_connected_geometry?(entities)
        raise BridgeError.new(
          "partial_connected_geometry",
          "Raw edge/face targets must include each complete connected geometry set"
        )
      end
      true
    end

    def validate_group_entities_params(params)
      unless params.is_a?(Hash)
        raise BridgeError.new("invalid_argument", "group_entities params must be an object")
      end
      unknown_group_keys = params.keys - GROUP_ENTITIES_PARAM_KEYS
      unless unknown_group_keys.empty?
        raise BridgeError.new(
          "invalid_argument",
          "group_entities params contain unsupported keys: #{unknown_group_keys.sort.join(', ')}"
        )
      end
      raw_ids = params["persistent_ids"]
      unless raw_ids.is_a?(Array) && raw_ids.length.between?(1, MAX_OBJECTS)
        raise BridgeError.new(
          "invalid_argument",
          "persistent_ids must contain 1..#{MAX_OBJECTS} ids"
        )
      end
      persistent_ids = raw_ids.each_with_index.map do |value, index|
        bounded_integer(
          value,
          minimum: 1,
          maximum: (2**63) - 1,
          name: "persistent_ids[#{index}]"
        )
      end
      if persistent_ids.uniq.length != persistent_ids.length
        raise BridgeError.new("invalid_argument", "persistent_ids must not contain duplicates")
      end

      name = params["name"]
      if name && (!name.is_a?(String) || name.length > 128)
        raise BridgeError.new("invalid_argument", "name must be a string up to 128 characters")
      end
      [persistent_ids, name]
    end

    def groupable_entity?(entity)
      entity.is_a?(Sketchup::Edge) ||
        entity.is_a?(Sketchup::Face) ||
        entity.is_a?(Sketchup::Group) ||
        entity.is_a?(Sketchup::ComponentInstance)
    end

    def complete_groupable_connected_geometry?(entities)
      raw_entities = entities.select do |entity|
        entity.is_a?(Sketchup::Edge) || entity.is_a?(Sketchup::Face)
      end
      return true if raw_entities.empty?

      selected_ids = raw_entities.map(&:persistent_id).sort
      raw_entities.all? do |entity|
        connected = entity.all_connected
        if connected.length > MAX_OBJECTS
          raise BridgeError.new(
            "semantic_state_too_large",
            "Connected raw geometry exceeds entity limit"
          )
        end
        connected_ids = connected.select do |item|
          item.is_a?(Sketchup::Edge) || item.is_a?(Sketchup::Face)
        end.map(&:persistent_id).sort
        (connected_ids - selected_ids).empty?
      end
    end

    def execute_create_face(model, params)
      unknown_create_face_keys = params.keys - CREATE_FACE_PARAM_KEYS
      unless unknown_create_face_keys.empty?
        raise BridgeError.new(
          "invalid_argument",
          "create_face params contain unsupported keys: #{unknown_create_face_keys.sort.join(', ')}"
        )
      end

      raw_points = params["points"]
      unless raw_points.is_a?(Array) && raw_points.length.between?(3, MAX_FACE_POINTS)
        raise BridgeError.new(
          "invalid_argument",
          "points must contain 3..#{MAX_FACE_POINTS} vertices"
        )
      end
      points = raw_points.each_with_index.map do |value, index|
        point3d(value, "points[#{index}]")
      end

      face = begin
        model.active_entities.add_face(points)
      rescue ArgumentError
        raise BridgeError.new("invalid_geometry", "SketchUp rejected face geometry")
      end
      raise BridgeError.new("invalid_geometry", "SketchUp did not create a face") unless face
      face
    end

    def execute_extrude_face_to_group(model, params)
      unknown_extrude_face_keys = params.keys - EXTRUDE_FACE_PARAM_KEYS
      unless unknown_extrude_face_keys.empty?
        raise BridgeError.new(
          "invalid_argument",
          "extrude_face_to_group params contain unsupported keys: #{unknown_extrude_face_keys.sort.join(', ')}"
        )
      end

      face = require_active_entity(model, params["persistent_id"])
      unless face.is_a?(Sketchup::Face)
        raise BridgeError.new(
          "unsupported_object_type",
          "extrude_face_to_group requires a Face persistent_id"
        )
      end

      distance = finite_number(params["distance"], "distance")
      if distance.zero?
        raise BridgeError.new("invalid_argument", "distance must be non-zero")
      end

      group_name = params["group_name"]
      if group_name && (!group_name.is_a?(String) || group_name.length > 128)
        raise BridgeError.new(
          "invalid_argument",
          "group_name must be a string up to 128 characters"
        )
      end

      unless isolated_face_for_extrusion?(face)
        raise BridgeError.new(
          "non_isolated_face",
          "extrude_face_to_group requires an isolated face"
        )
      end

      source_persistent_id = face.persistent_id
      face.pushpull(distance, false)
      current = model.find_entity_by_persistent_id(source_persistent_id)
      unless current && current.valid? && current.is_a?(Sketchup::Face)
        raise BridgeError.new(
          "geometry_execution_failed",
          "Source face did not survive extrusion"
        )
      end

      connected_after = current.all_connected
      unless connected_after.length.between?(1, MAX_OBJECTS)
        raise BridgeError.new(
          "semantic_state_too_large",
          "Extruded connected geometry exceeds entity limit"
        )
      end
      unless connected_after.all? do |entity|
               entity.respond_to?(:parent) &&
                 entity.parent == model.active_entities.parent
             end
        raise BridgeError.new(
          "context_mismatch",
          "Extruded geometry escaped the active edit context"
        )
      end

      group = model.active_entities.add_group(connected_after)
      group.name = group_name if group_name && !group_name.empty?
      group
    end

    def isolated_face_for_extrusion?(face)
      expected_ids = ([face] + face.edges).map(&:persistent_id).sort
      actual_ids = face.all_connected.map(&:persistent_id).sort
      expected_ids == actual_ids
    end

    def execute_transform_entity(model, params)
      unknown_transform_keys = params.keys - TRANSFORM_ENTITY_PARAM_KEYS
      unless unknown_transform_keys.empty?
        raise BridgeError.new(
          "invalid_argument",
          "transform_entity params contain unsupported keys: #{unknown_transform_keys.sort.join(', ')}"
        )
      end

      entity = require_transformable_entity(model, params["persistent_id"])
      before_state = semantic_entity_state(model, entity)
      transformation = transformation_from_matrix(params["matrix"])
      requested_transformation = transformation.to_a.map { |value| quantize_number(value) }

      entity.transformation = transformation
      {
        "entity" => entity,
        "metadata" => {
          "target_persistent_id" => before_state["persistent_id"],
          "before_identity_fingerprint" => before_state["identity_fingerprint"],
          "before_geometry_fingerprint" => before_state["geometry_fingerprint"],
          "requested_transformation" => requested_transformation
        }
      }
    end

    def execute_boolean_operation(model, params)
      unknown_boolean_keys = params.keys - BOOLEAN_OPERATION_PARAM_KEYS
      unless unknown_boolean_keys.empty?
        raise BridgeError.new(
          "invalid_argument",
          "boolean_operation params contain unsupported keys: #{unknown_boolean_keys.sort.join(', ')}"
        )
      end

      operation_type = params["operation_type"]
      unless BOOLEAN_OPERATION_TYPES.include?(operation_type)
        raise BridgeError.new(
          "invalid_argument",
          "operation_type must be union, difference, or intersect"
        )
      end

      tool = require_boolean_solid(model, params["tool_pid"], "tool_pid")
      target = require_boolean_solid(model, params["target_pid"], "target_pid")
      if tool.persistent_id == target.persistent_id
        raise BridgeError.new("invalid_argument", "tool_pid and target_pid must be different")
      end

      tool_state = semantic_entity_state(model, tool)
      target_state = semantic_entity_state(model, target)
      result = begin
        case operation_type
        when "union"
          target.union(tool)
        when "difference"
          # SketchUp's parameter semantics subtract the receiver from the argument.
          # Contract difference is target - tool, therefore receiver must be tool.
          tool.subtract(target)
        when "intersect"
          target.intersect(tool)
        end
      rescue StandardError => error
        log("boolean operation failed: #{error.class}: #{error.message}")
        raise BridgeError.new("boolean_failed", "SketchUp boolean operation failed")
      end

      unless result && result.valid? && result.is_a?(Sketchup::Group)
        raise BridgeError.new("boolean_failed", "SketchUp did not produce a boolean result group")
      end
      unless result.respond_to?(:parent) && result.parent == model.active_entities.parent
        raise BridgeError.new("context_mismatch", "Boolean result escaped the active edit context")
      end
      unless semantic_manifold(result) == true
        raise BridgeError.new("invalid_geometry", "Boolean result is not a manifold solid")
      end

      {
        "entity" => result,
        "metadata" => {
          "operation_type" => operation_type,
          "tool_persistent_id" => tool_state["persistent_id"],
          "target_persistent_id" => target_state["persistent_id"],
          "tool_volume" => tool_state["volume"],
          "target_volume" => target_state["volume"]
        }
      }
    end

    def execute_delete_entity(model, params)
      validate_delete_entity_params(params)
      entity = require_deletable_entity(model, params["persistent_id"])
      before_state = semantic_entity_state(model, entity)
      persistent_id = before_state["persistent_id"]

      begin
        model.active_entities.erase_entities(entity)
      rescue ArgumentError, RuntimeError => error
        log("delete entity failed: #{error.class}: #{error.message}")
        raise BridgeError.new("delete_failed", "SketchUp did not delete the target entity")
      end

      if entity_alive_by_pid?(model, persistent_id)
        raise BridgeError.new("delete_failed", "Deleted target persistent ID still resolves")
      end

      {
        "state" => {
          "persistent_id" => persistent_id,
          "type" => before_state["type"],
          "valid" => false,
          "active_context" => false,
          "deleted" => true
        },
        "metadata" => {
          "target_persistent_id" => persistent_id,
          "target_type" => before_state["type"],
          "before_state" => before_state
        }
      }
    end

    def execute_group_entities(model, params)
      persistent_ids, name = validate_group_entities_params(params)
      entities = persistent_ids.map { |value| require_active_entity(model, value) }
      input_states = entities.map do |entity|
        [entity, semantic_entity_state(model, entity)]
      end
      input_fingerprints = input_states.each_with_object({}) do |(entity, state), result|
        result[entity.persistent_id.to_s] = {
          "identity" => state["identity_fingerprint"],
          "geometry" => state["geometry_fingerprint"],
          "reparent" => grouping_reparent_fingerprint(entity, state)
        }
      end
      input_bounds = aggregate_semantic_bounds(input_states.map { |_entity, state| state })

      group = begin
        model.active_entities.add_group(entities)
      rescue ArgumentError, RuntimeError => error
        log("group entities failed: #{error.class}: #{error.message}")
        raise BridgeError.new("group_failed", "SketchUp did not group the requested entities")
      end
      unless group && group.valid? && group.is_a?(Sketchup::Group)
        raise BridgeError.new("group_failed", "SketchUp did not produce a group")
      end
      group.name = name if name && !name.empty?

      {
        "entity" => group,
        "metadata" => {
          "input_persistent_ids" => persistent_ids.sort,
          "input_fingerprints" => input_fingerprints,
          "input_bounds_min" => input_bounds["min"],
          "input_bounds_max" => input_bounds["max"],
          "group_definition_guid" => group.definition.guid.to_s
        }
      }
    end

    def grouping_reparent_fingerprint(entity, state)
      payload = {
        "persistent_id" => entity.persistent_id,
        "type" => entity.typename
      }
      if entity.is_a?(Sketchup::Edge)
        payload["length"] = quantize_number(entity.length)
        payload["face_persistent_ids"] = entity.faces.map(&:persistent_id).sort
      elsif entity.is_a?(Sketchup::Face)
        payload["area"] = quantize_number(entity.area)
        payload["edge_persistent_ids"] = entity.edges.map(&:persistent_id).sort
      else
        payload["identity_fingerprint"] = state["identity_fingerprint"]
        payload["geometry_fingerprint"] = state["geometry_fingerprint"]
      end
      Digest::SHA256.hexdigest(JSON.generate(payload))
    end

    def aggregate_semantic_bounds(states)
      mins = states.map { |state| state.dig("bounds", "min") }
      maxs = states.map { |state| state.dig("bounds", "max") }
      unless mins.all? { |value| value.is_a?(Array) && value.length == 3 } &&
             maxs.all? { |value| value.is_a?(Array) && value.length == 3 }
        raise BridgeError.new("semantic_state_invalid", "Grouping inputs must expose bounded geometry")
      end
      {
        "min" => 3.times.map { |index| mins.map { |value| value[index] }.min },
        "max" => 3.times.map { |index| maxs.map { |value| value[index] }.max }
      }
    end

    def require_boolean_solid(model, value, name)
      entity = require_active_entity(model, value)
      unless entity.is_a?(Sketchup::Group) || entity.is_a?(Sketchup::ComponentInstance)
        raise BridgeError.new(
          "unsupported_object_type",
          "#{name} must reference a group/component instance"
        )
      end
      if entity.respond_to?(:locked?) && entity.locked?
        raise BridgeError.new("locked_object", "Boolean operands must be unlocked")
      end
      unless semantic_manifold(entity) == true
        raise BridgeError.new("non_manifold_operand", "Boolean operands must be manifold solids")
      end
      entity
    end

    def transformation_from_matrix(value)
      unless value.is_a?(Array) && value.length == 16
        raise BridgeError.new("invalid_argument", "matrix must contain exactly 16 numbers")
      end
      matrix = value.map.with_index do |item, index|
        finite_number(item, "matrix[#{index}]")
      end
      unless matrix[3].abs <= SEMANTIC_QUANTUM &&
             matrix[7].abs <= SEMANTIC_QUANTUM &&
             matrix[11].abs <= SEMANTIC_QUANTUM &&
             (matrix[15] - 1.0).abs <= SEMANTIC_QUANTUM
        raise BridgeError.new("invalid_argument", "matrix must be an affine 4x4 transformation")
      end
      determinant = transformation_determinant(matrix)
      if determinant.abs <= MIN_TRANSFORM_DETERMINANT
        raise BridgeError.new("non_invertible_transform", "matrix must be invertible")
      end
      Geom::Transformation.new(matrix)
    rescue ArgumentError
      raise BridgeError.new("invalid_argument", "matrix is not a valid SketchUp transformation")
    end

    def transformation_determinant(matrix)
      a = matrix[0]
      b = matrix[4]
      c = matrix[8]
      d = matrix[1]
      e = matrix[5]
      f = matrix[9]
      g = matrix[2]
      h = matrix[6]
      i = matrix[10]
      a * (e * i - f * h) -
        b * (d * i - f * g) +
        c * (d * h - e * g)
    end

    def execute_create_box(model, params)
      unknown_create_box_keys = params.keys - CREATE_BOX_PARAM_KEYS
      unless unknown_create_box_keys.empty?
        raise BridgeError.new(
          "invalid_argument",
          "create_box params contain unsupported keys: #{unknown_create_box_keys.sort.join(', ')}"
        )
      end

      name = bounded_name(params["name"], "name")
      origin = point3d(params["origin"] || [0, 0, 0], "origin")
      dimensions = numeric_triplet(params["dimensions"], "dimensions")
      unless dimensions.all?(&:positive?)
        raise BridgeError.new("invalid_geometry", "dimensions must be positive")
      end
      if model.definitions.any? { |definition| definition.name == name }
        raise BridgeError.new("already_exists", "Component definition already exists")
      end

      definition = model.definitions.add(name)
      entities = definition.entities
      width, depth, height = dimensions
      face = entities.add_face(
        [0, 0, 0],
        [width, 0, 0],
        [width, depth, 0],
        [0, depth, 0]
      )
      raise BridgeError.new("invalid_geometry", "SketchUp did not create component base face") unless face
      face.pushpull(-height)

      transform = Geom::Transformation.translation(origin)
      model.active_entities.add_instance(definition, transform)
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

    def require_taggable_entity(model, value)
      entity = require_active_entity(model, value)
      unless entity.is_a?(Sketchup::Group) || entity.is_a?(Sketchup::ComponentInstance)
        raise BridgeError.new("unsupported_object_type", "Tags are assigned only to groups/components")
      end
      if entity.respond_to?(:locked?) && entity.locked?
        raise BridgeError.new("locked_object", "Tag assignment target must be unlocked")
      end
      entity
    end

    def require_material_target(model, value, side)
      entity = require_active_entity(model, value)
      unless entity.is_a?(Sketchup::Face) || (side == "both" && entity.respond_to?(:material=))
        raise BridgeError.new("unsupported_object_type", "Material side semantics require a Face")
      end
      if entity.respond_to?(:locked?) && entity.locked?
        raise BridgeError.new("locked_object", "Material assignment target must be unlocked")
      end
      entity
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

    def require_model
      model = Sketchup.active_model
      raise BridgeError.new("live_model_unavailable", "No active SketchUp model") unless model
      model
    end

    def require_entity_by_pid(model, value)
      persistent_id = bounded_integer(
        value,
        minimum: 1,
        maximum: (2**63) - 1,
        name: "persistent_id"
      )
      entity = begin
        model.find_entity_by_persistent_id(persistent_id)
      rescue ArgumentError, RangeError, TypeError
        raise BridgeError.new(
          "invalid_argument",
          "persistent_id is outside the SketchUp supported range"
        )
      end
      unless entity && entity.respond_to?(:valid?) && entity.valid?
        raise BridgeError.new("object_not_found", "SketchUp entity was not found")
      end
      entity
    end

    def require_active_entity(model, value)
      entity = require_entity_by_pid(model, value)
      unless entity.respond_to?(:parent) && entity.parent == model.active_entities.parent
        raise BridgeError.new("inactive_edit_context", "Entity is outside the active edit context")
      end
      entity
    end

    def require_transformable_entity(model, value)
      entity = require_active_entity(model, value)
      unless entity.is_a?(Sketchup::Group) || entity.is_a?(Sketchup::ComponentInstance)
        raise BridgeError.new("unsupported_object_type", "Transform requires a group/component instance")
      end
      entity
    end

    def require_deletable_entity(model, value)
      entity = require_active_entity(model, value)
      unless entity.is_a?(Sketchup::Group) || entity.is_a?(Sketchup::ComponentInstance)
        raise BridgeError.new(
          "unsupported_object_type",
          "delete_entity requires a group/component instance"
        )
      end
      if entity.respond_to?(:locked?) && entity.locked?
        raise BridgeError.new("locked_object", "Delete target must be unlocked")
      end
      entity
    end

    def numeric_triplet(value, name)
      unless value.is_a?(Array) && value.length == 3
        raise BridgeError.new("invalid_argument", "#{name} must be [x, y, z]")
      end
      value.map.with_index do |item, index|
        finite_number(item, "#{name}[#{index}]")
      end
    end

    def vector3d(value, name)
      Geom::Vector3d.new(numeric_triplet(value, name))
    end

    def finite_number(value, name)
      number = Float(value)
      raise BridgeError.new("invalid_argument", "#{name} must be finite") unless number.finite?
      number
    rescue ArgumentError, TypeError
      raise BridgeError.new("invalid_argument", "#{name} must be numeric")
    end

    def bounded_name(value, name)
      unless value.is_a?(String)
        raise BridgeError.new("invalid_argument", "#{name} must be a string")
      end
      normalized = value.strip
      unless normalized.length.between?(1, 128)
        raise BridgeError.new("invalid_argument", "#{name} must contain 1..128 characters")
      end
      normalized
    end

    def rgb_triplet(value)
      unless value.is_a?(Array) && value.length == 3
        raise BridgeError.new("invalid_argument", "color must be [r, g, b]")
      end
      value.map do |item|
        integer = Integer(item)
        unless integer.between?(0, 255)
          raise BridgeError.new("invalid_argument", "RGB channels must be 0..255")
        end
        integer
      rescue ArgumentError, TypeError
        raise BridgeError.new("invalid_argument", "RGB channels must be integers")
      end
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

    def semantic_model_fingerprint(model, active_snapshot: nil)
      snapshot = active_snapshot || semantic_active_entity_snapshot(model)
      active_entities = snapshot.map do |persistent_id, state|
        [persistent_id, state["type"], state["semantic_fingerprint"]]
      end.sort

      definitions = model.definitions.map do |definition|
        [
          definition.guid.to_s,
          definition.name.to_s,
          definition.entities.length
        ]
      end.sort

      payload = {
        "active_entities" => active_entities,
        "definitions" => definitions,
        "materials" => model.materials.map { |material| material.name.to_s }.sort,
        "scenes" => model.pages.map { |page| page.name.to_s }.sort
      }
      Digest::SHA256.hexdigest(JSON.generate(payload))
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

    def find_definition_by_guid(model, guid)
      definition = model.definitions.find { |candidate| candidate.guid.to_s == guid }
      unless definition
        raise BridgeError.new("definition_not_found", "Component definition was not found")
      end
      definition
    end

    def semantic_action_outcome(model, outcome)
      if outcome.is_a?(Hash) && outcome.key?("state")
        state = outcome["state"]
        metadata = outcome["metadata"] || {}
        unless state.is_a?(Hash)
          raise BridgeError.new("semantic_state_invalid", "Action state must be an object")
        end
        return [state, metadata]
      end
      if outcome.is_a?(Hash) && outcome.key?("entity")
        entity = outcome["entity"]
        metadata = outcome["metadata"] || {}
        return [semantic_entity_state(model, entity), metadata]
      end
      [semantic_entity_state(model, outcome), {}]
    end

    def validate_action_expectation(action, action_params, expect)
      case action
      when "transform_entity"
        unless Integer(expect["active_entity_delta"]) == 0
          raise BridgeError.new(
            "invalid_argument",
            "transform_entity requires expect.active_entity_delta = 0"
          )
        end
        unless expect.key?("transformation")
          raise BridgeError.new(
            "invalid_argument",
            "transform_entity requires expect.transformation"
          )
        end

        requested = transformation_from_matrix(action_params["matrix"]).to_a
        expected = numeric_array(expect["transformation"], 16, "expect.transformation")
        tolerance = expect.key?("tolerance") ? finite_number(expect["tolerance"], "expect.tolerance") : SEMANTIC_QUANTUM
        matches = requested.zip(expected).all? do |requested_item, expected_item|
          (requested_item - expected_item).abs <= tolerance
        end
        unless matches
          raise BridgeError.new(
            "invalid_argument",
            "expect.transformation must match the requested absolute matrix"
          )
        end
      when "boolean_operation"
        unless Integer(expect["active_entity_delta"]) == -1
          raise BridgeError.new(
            "invalid_argument",
            "boolean_operation requires expect.active_entity_delta = -1"
          )
        end
        unless expect["type"] == "Group"
          raise BridgeError.new(
            "invalid_argument",
            "boolean_operation requires expect.type = Group"
          )
        end
        unless expect["manifold"] == true
          raise BridgeError.new(
            "invalid_argument",
            "boolean_operation requires expect.manifold = true"
          )
        end
      when "delete_entity"
        unless Integer(expect["active_entity_delta"]) == -1
          raise BridgeError.new(
            "invalid_argument",
            "delete_entity requires expect.active_entity_delta = -1"
          )
        end
        unless expect["deleted"] == true
          raise BridgeError.new(
            "invalid_argument",
            "delete_entity requires expect.deleted = true"
          )
        end
        unsupported_delete_expect = expect.keys - %w[active_entity_delta deleted type tolerance]
        unless unsupported_delete_expect.empty?
          raise BridgeError.new(
            "invalid_argument",
            "delete_entity expect contains unsupported keys: #{unsupported_delete_expect.sort.join(', ')}"
          )
        end
        if expect.key?("type") && !%w[Group ComponentInstance].include?(expect["type"].to_s)
          raise BridgeError.new(
            "invalid_argument",
            "delete_entity expect.type must be Group or ComponentInstance"
          )
        end
      when "group_entities"
        persistent_ids, = validate_group_entities_params(action_params)
        unless Integer(expect["active_entity_delta"]) == 1 - persistent_ids.length
          raise BridgeError.new(
            "invalid_argument",
            "group_entities requires expect.active_entity_delta = 1 - input count"
          )
        end
        unless expect["type"] == "Group"
          raise BridgeError.new(
            "invalid_argument",
            "group_entities requires expect.type = Group"
          )
        end
        unless expect.key?("child_persistent_ids")
          raise BridgeError.new(
            "invalid_argument",
            "group_entities requires expect.child_persistent_ids"
          )
        end
        unsupported_group_expect = expect.keys - %w[active_entity_delta type child_persistent_ids tolerance]
        unless unsupported_group_expect.empty?
          raise BridgeError.new(
            "invalid_argument",
            "group_entities expect contains unsupported keys: #{unsupported_group_expect.sort.join(', ')}"
          )
        end
      when "create_component"
        persistent_ids, = validate_create_component_params(action_params)
        unless Integer(expect["active_entity_delta"]) == 1 - persistent_ids.length
          raise BridgeError.new(
            "invalid_argument",
            "create_component requires expect.active_entity_delta = 1 - input count"
          )
        end
        unless expect["type"] == "ComponentInstance"
          raise BridgeError.new(
            "invalid_argument",
            "create_component requires expect.type = ComponentInstance"
          )
        end
        unless expect.key?("child_persistent_ids")
          raise BridgeError.new(
            "invalid_argument",
            "create_component requires expect.child_persistent_ids"
          )
        end
        unsupported_component_expect = expect.keys - %w[active_entity_delta type child_persistent_ids tolerance]
        unless unsupported_component_expect.empty?
          raise BridgeError.new(
            "invalid_argument",
            "create_component expect contains unsupported keys: #{unsupported_component_expect.sort.join(', ')}"
          )
        end
      when "place_instance"
        unless Integer(expect["active_entity_delta"]) == 1
          raise BridgeError.new(
            "invalid_argument",
            "place_instance requires expect.active_entity_delta = 1"
          )
        end
        unless expect["type"] == "ComponentInstance"
          raise BridgeError.new(
            "invalid_argument",
            "place_instance requires expect.type = ComponentInstance"
          )
        end
        unless expect["definition_guid"].to_s == action_params["definition_guid"].to_s.strip
          raise BridgeError.new(
            "invalid_argument",
            "place_instance requires expect.definition_guid"
          )
        end
        unless expect.key?("transformation")
          raise BridgeError.new(
            "invalid_argument",
            "place_instance requires expect.transformation"
          )
        end
        unsupported_place_expect = expect.keys - %w[active_entity_delta type definition_guid transformation tolerance]
        unless unsupported_place_expect.empty?
          raise BridgeError.new(
            "invalid_argument",
            "place_instance expect contains unsupported keys: #{unsupported_place_expect.sort.join(', ')}"
          )
        end
      when "make_unique"
        unless Integer(expect["active_entity_delta"]) == 0
          raise BridgeError.new(
            "invalid_argument",
            "make_unique requires expect.active_entity_delta = 0"
          )
        end
        unless expect["type"] == "ComponentInstance"
          raise BridgeError.new(
            "invalid_argument",
            "make_unique requires expect.type = ComponentInstance"
          )
        end
        unsupported_unique_expect = expect.keys - %w[active_entity_delta type tolerance]
        unless unsupported_unique_expect.empty?
          raise BridgeError.new(
            "invalid_argument",
            "make_unique expect contains unsupported keys: #{unsupported_unique_expect.sort.join(', ')}"
          )
        end
      when "copy_entity"
        unless Integer(expect["active_entity_delta"]) == 1
          raise BridgeError.new(
            "invalid_argument",
            "copy_entity requires expect.active_entity_delta = 1"
          )
        end
        unless expect.key?("type")
          raise BridgeError.new(
            "invalid_argument",
            "copy_entity requires expect.type"
          )
        end
        unsupported_copy_expect = expect.keys - %w[active_entity_delta type tolerance]
        unless unsupported_copy_expect.empty?
          raise BridgeError.new(
            "invalid_argument",
            "copy_entity expect contains unsupported keys: #{unsupported_copy_expect.sort.join(', ')}"
          )
        end
      when "linear_array"
        linear_count = validate_linear_array_params(action_params)[2]
        unless Integer(expect["active_entity_delta"]) == linear_count
          raise BridgeError.new(
            "invalid_argument",
            "linear_array requires expect.active_entity_delta = count"
          )
        end
        unless Integer(expect["count"]) == linear_count
          raise BridgeError.new(
            "invalid_argument",
            "linear_array requires expect.count"
          )
        end
        unless expect.key?("type")
          raise BridgeError.new(
            "invalid_argument",
            "linear_array requires expect.type"
          )
        end
        unsupported_linear_expect = expect.keys - %w[active_entity_delta type count tolerance]
        unless unsupported_linear_expect.empty?
          raise BridgeError.new(
            "invalid_argument",
            "linear_array expect contains unsupported keys: #{unsupported_linear_expect.sort.join(', ')}"
          )
        end
      when "radial_array"
        radial_count = validate_radial_array_params(action_params)[4]
        unless Integer(expect["active_entity_delta"]) == radial_count
          raise BridgeError.new(
            "invalid_argument",
            "radial_array requires expect.active_entity_delta = count"
          )
        end
        unless Integer(expect["count"]) == radial_count
          raise BridgeError.new(
            "invalid_argument",
            "radial_array requires expect.count"
          )
        end
        unless expect.key?("type")
          raise BridgeError.new(
            "invalid_argument",
            "radial_array requires expect.type"
          )
        end
        unsupported_radial_expect = expect.keys - %w[active_entity_delta type count tolerance]
        unless unsupported_radial_expect.empty?
          raise BridgeError.new(
            "invalid_argument",
            "radial_array expect contains unsupported keys: #{unsupported_radial_expect.sort.join(', ')}"
          )
        end
      when "tag_assign"
        unless Integer(expect["active_entity_delta"]) == 0
          raise BridgeError.new(
            "invalid_argument",
            "tag_assign requires expect.active_entity_delta = 0"
          )
        end
        unless expect.key?("tag")
          raise BridgeError.new(
            "invalid_argument",
            "tag_assign requires expect.tag"
          )
        end
        unsupported_tag_expect = expect.keys - %w[active_entity_delta type tag tolerance]
        unless unsupported_tag_expect.empty?
          raise BridgeError.new(
            "invalid_argument",
            "tag_assign expect contains unsupported keys: #{unsupported_tag_expect.sort.join(', ')}"
          )
        end
      when "material_assign"
        unless Integer(expect["active_entity_delta"]) == 0
          raise BridgeError.new(
            "invalid_argument",
            "material_assign requires expect.active_entity_delta = 0"
          )
        end
        unless expect.key?("material")
          raise BridgeError.new(
            "invalid_argument",
            "material_assign requires expect.material"
          )
        end
        unsupported_material_expect = expect.keys - %w[active_entity_delta type material tolerance]
        unless unsupported_material_expect.empty?
          raise BridgeError.new(
            "invalid_argument",
            "material_assign expect contains unsupported keys: #{unsupported_material_expect.sort.join(', ')}"
          )
        end
      when "create_polyline"
        unless Integer(expect["active_entity_delta"]) == 1
          raise BridgeError.new(
            "invalid_argument",
            "create_polyline requires expect.active_entity_delta = 1"
          )
        end
        unless expect["type"] == "Group"
          raise BridgeError.new(
            "invalid_argument",
            "create_polyline requires expect.type = Group"
          )
        end
        unsupported_polyline_expect = expect.keys - %w[active_entity_delta type edge_count vertex_count tolerance]
        unless unsupported_polyline_expect.empty?
          raise BridgeError.new(
            "invalid_argument",
            "create_polyline expect contains unsupported keys: #{unsupported_polyline_expect.sort.join(', ')}"
          )
        end
      when "create_rectangle"
        unless Integer(expect["active_entity_delta"]) == 1
          raise BridgeError.new(
            "invalid_argument",
            "create_rectangle requires expect.active_entity_delta = 1"
          )
        end
        unless expect["type"] == "Group"
          raise BridgeError.new(
            "invalid_argument",
            "create_rectangle requires expect.type = Group"
          )
        end
        unless expect.key?("edge_count")
          raise BridgeError.new(
            "invalid_argument",
            "create_rectangle requires expect.edge_count"
          )
        end
        unsupported_rectangle_expect = expect.keys - %w[active_entity_delta type edge_count vertex_count tolerance]
        unless unsupported_rectangle_expect.empty?
          raise BridgeError.new(
            "invalid_argument",
            "create_rectangle expect contains unsupported keys: #{unsupported_rectangle_expect.sort.join(', ')}"
          )
        end
      when "create_circle"
        unless Integer(expect["active_entity_delta"]) == 1
          raise BridgeError.new(
            "invalid_argument",
            "create_circle requires expect.active_entity_delta = 1"
          )
        end
        unless expect["type"] == "Group"
          raise BridgeError.new(
            "invalid_argument",
            "create_circle requires expect.type = Group"
          )
        end
        unless expect.key?("edge_count")
          raise BridgeError.new(
            "invalid_argument",
            "create_circle requires expect.edge_count"
          )
        end
        unsupported_circle_expect = expect.keys - %w[active_entity_delta type edge_count vertex_count tolerance]
        unless unsupported_circle_expect.empty?
          raise BridgeError.new(
            "invalid_argument",
            "create_circle expect contains unsupported keys: #{unsupported_circle_expect.sort.join(', ')}"
          )
        end
      when "create_arc"
        unless Integer(expect["active_entity_delta"]) == 1
          raise BridgeError.new(
            "invalid_argument",
            "create_arc requires expect.active_entity_delta = 1"
          )
        end
        unless expect["type"] == "Group"
          raise BridgeError.new(
            "invalid_argument",
            "create_arc requires expect.type = Group"
          )
        end
        unless expect.key?("edge_count")
          raise BridgeError.new(
            "invalid_argument",
            "create_arc requires expect.edge_count"
          )
        end
        unsupported_arc_expect = expect.keys - %w[active_entity_delta type edge_count vertex_count tolerance]
        unless unsupported_arc_expect.empty?
          raise BridgeError.new(
            "invalid_argument",
            "create_arc expect contains unsupported keys: #{unsupported_arc_expect.sort.join(', ')}"
          )
        end
      when "create_polygon"
        unless Integer(expect["active_entity_delta"]) == 1
          raise BridgeError.new(
            "invalid_argument",
            "create_polygon requires expect.active_entity_delta = 1"
          )
        end
        unless expect["type"] == "Group"
          raise BridgeError.new(
            "invalid_argument",
            "create_polygon requires expect.type = Group"
          )
        end
        unless expect.key?("edge_count")
          raise BridgeError.new(
            "invalid_argument",
            "create_polygon requires expect.edge_count"
          )
        end
        unsupported_polygon_expect = expect.keys - %w[active_entity_delta type edge_count vertex_count tolerance]
        unless unsupported_polygon_expect.empty?
          raise BridgeError.new(
            "invalid_argument",
            "create_polygon expect contains unsupported keys: #{unsupported_polygon_expect.sort.join(', ')}"
          )
        end
      when "sweep_profile"
        face_pid, path_pids = validate_sweep_profile_params(action_params)
        profile = Sketchup.active_model.find_entity_by_persistent_id(face_pid)
        profile_edge_count = profile.is_a?(Sketchup::Face) ? profile.edges.length : 0
        unless Integer(expect["active_entity_delta"]) == 1 - (1 + profile_edge_count + path_pids.length)
          raise BridgeError.new(
            "invalid_argument",
            "sweep_profile requires expect.active_entity_delta = 1 - input count"
          )
        end
        unless expect["type"] == "Group"
          raise BridgeError.new(
            "invalid_argument",
            "sweep_profile requires expect.type = Group"
          )
        end
        unless expect["manifold"] == true
          raise BridgeError.new(
            "invalid_argument",
            "sweep_profile requires expect.manifold"
          )
        end
        unsupported_sweep_expect = expect.keys - %w[active_entity_delta type manifold tolerance]
        unless unsupported_sweep_expect.empty?
          raise BridgeError.new(
            "invalid_argument",
            "sweep_profile expect contains unsupported keys: #{unsupported_sweep_expect.sort.join(', ')}"
          )
        end
      when "place_asset"
        unless Integer(expect["active_entity_delta"]) == 1
          raise BridgeError.new(
            "invalid_argument",
            "place_asset requires expect.active_entity_delta = 1"
          )
        end
        unless expect["type"] == "ComponentInstance"
          raise BridgeError.new(
            "invalid_argument",
            "place_asset requires expect.type = ComponentInstance"
          )
        end
        unsupported_asset_expect = expect.keys - %w[active_entity_delta type definition_name transformation tolerance]
        unless unsupported_asset_expect.empty?
          raise BridgeError.new(
            "invalid_argument",
            "place_asset expect contains unsupported keys: #{unsupported_asset_expect.sort.join(', ')}"
          )
        end
      when "camera_set"
        unless Integer(expect["active_entity_delta"]) == 0
          raise BridgeError.new(
            "invalid_argument",
            "camera_set requires expect.active_entity_delta = 0"
          )
        end
        unless expect.key?("camera_fov")
          raise BridgeError.new(
            "invalid_argument",
            "camera_set requires expect.camera_fov"
          )
        end
        unsupported_camera_expect = expect.keys - %w[active_entity_delta camera_eye camera_target camera_fov tolerance]
        unless unsupported_camera_expect.empty?
          raise BridgeError.new(
            "invalid_argument",
            "camera_set expect contains unsupported keys: #{unsupported_camera_expect.sort.join(', ')}"
          )
        end
      when "scene_create"
        unless Integer(expect["active_entity_delta"]) == 0
          raise BridgeError.new(
            "invalid_argument",
            "scene_create requires expect.active_entity_delta = 0"
          )
        end
        unless expect.key?("scene_name")
          raise BridgeError.new(
            "invalid_argument",
            "scene_create requires expect.scene_name"
          )
        end
        unsupported_scene_expect = expect.keys - %w[active_entity_delta scene_name tolerance]
        unless unsupported_scene_expect.empty?
          raise BridgeError.new(
            "invalid_argument",
            "scene_create expect contains unsupported keys: #{unsupported_scene_expect.sort.join(', ')}"
          )
        end
      when "material_apply_texture"
        unless Integer(expect["active_entity_delta"]) == 0
          raise BridgeError.new(
            "invalid_argument",
            "material_apply_texture requires expect.active_entity_delta = 0"
          )
        end
        unless expect.key?("material")
          raise BridgeError.new(
            "invalid_argument",
            "material_apply_texture requires expect.material"
          )
        end
        unsupported_texture_expect = expect.keys - %w[active_entity_delta material tolerance]
        unless unsupported_texture_expect.empty?
          raise BridgeError.new(
            "invalid_argument",
            "material_apply_texture expect contains unsupported keys: #{unsupported_texture_expect.sort.join(', ')}"
          )
        end
      when "repair_reverse_face"
        unless Integer(expect["active_entity_delta"]) == 0
          raise BridgeError.new(
            "invalid_argument",
            "repair_reverse_face requires expect.active_entity_delta = 0"
          )
        end
        unless expect["type"] == "Face"
          raise BridgeError.new(
            "invalid_argument",
            "repair_reverse_face requires expect.type = Face"
          )
        end
        unsupported_reverse_expect = expect.keys - %w[active_entity_delta type tolerance]
        unless unsupported_reverse_expect.empty?
          raise BridgeError.new(
            "invalid_argument",
            "repair_reverse_face expect contains unsupported keys: #{unsupported_reverse_expect.sort.join(', ')}"
          )
        end
      when "repair_erase_degenerate"
        unless Integer(expect["active_entity_delta"]) == -1
          raise BridgeError.new(
            "invalid_argument",
            "repair_erase_degenerate requires expect.active_entity_delta = -1"
          )
        end
        unless expect["deleted"] == true
          raise BridgeError.new(
            "invalid_argument",
            "repair_erase_degenerate requires expect.deleted = true"
          )
        end
        unsupported_erase_expect = expect.keys - %w[active_entity_delta deleted type tolerance]
        unless unsupported_erase_expect.empty?
          raise BridgeError.new(
            "invalid_argument",
            "repair_erase_degenerate expect contains unsupported keys: #{unsupported_erase_expect.sort.join(', ')}"
          )
        end
      end
      true
    rescue ArgumentError, TypeError
      raise BridgeError.new("invalid_argument", "expect.active_entity_delta must be an integer")
    end

    def curve_vertices_on_radius?(vertices, center, radius, transform = nil)
      tolerance = [radius.abs * 1e-9, SEMANTIC_QUANTUM].max
      vertices.all? do |vertex|
        point = transform ? vertex.position.transform(transform) : vertex.position
        distance = Math.sqrt(
          (point.x - center[0])**2 + (point.y - center[1])**2 + (point.z - center[2])**2
        )
        (distance - radius).abs <= tolerance
      end
    end

    def angular_difference_degrees(left, right)
      ((left - right + 540.0) % 360.0) - 180.0
    end

    def group_member_entities(model, state)
      group = model.find_entity_by_persistent_id(state["persistent_id"])
      return [] unless group.is_a?(Sketchup::Group) && group.valid?

      group.entities.to_a
    end

    def global_member_corners(group, vertices)
      transform = group.transformation
      vertices.map { |vertex| quantized_point(vertex.position.transform(transform)) }.sort
    end

    def validate_action_semantic_invariants(action, state, metadata)
      case action
      when "transform_entity"
        return [
          semantic_check(
            "action.persistent_id",
            metadata["target_persistent_id"],
            state["persistent_id"]
          ),
          semantic_check(
            "action.identity_fingerprint",
            metadata["before_identity_fingerprint"],
            state["identity_fingerprint"]
          ),
          semantic_check(
            "action.geometry_fingerprint",
            metadata["before_geometry_fingerprint"],
            state["geometry_fingerprint"]
          ),
          validate_numeric_array_expectation(
            "action.transformation",
            metadata["requested_transformation"],
            state["transformation"],
            SEMANTIC_QUANTUM
          )
        ]
      when "boolean_operation"
        tool_alive = entity_alive_by_pid?(Sketchup.active_model, metadata["tool_persistent_id"])
        target_alive = entity_alive_by_pid?(Sketchup.active_model, metadata["target_persistent_id"])
        return [
          semantic_check("action.tool_consumed", false, tool_alive),
          semantic_check("action.target_consumed", false, target_alive),
          semantic_check(
            "action.result_is_new",
            true,
            ![metadata["tool_persistent_id"], metadata["target_persistent_id"]].include?(state["persistent_id"])
          ),
          validate_boolean_volume_invariant(state, metadata)
        ]
      when "delete_entity"
        target_alive = entity_alive_by_pid?(Sketchup.active_model, metadata["target_persistent_id"])
        return [
          semantic_check("action.target_consumed", false, target_alive),
          semantic_check("action.deleted", true, state["deleted"]),
          semantic_check(
            "action.persistent_id",
            metadata["target_persistent_id"],
            state["persistent_id"]
          ),
          semantic_check("action.type", metadata["target_type"], state["type"])
        ]
      when "group_entities"
        model = Sketchup.active_model
        input_ids = metadata["input_persistent_ids"] || []
        input_entities = input_ids.map do |persistent_id|
          model.find_entity_by_persistent_id(persistent_id)
        end
        input_alive = input_entities.all? do |entity|
          entity && entity.respond_to?(:valid?) && entity.valid?
        end
        expected_definition_guid = metadata["group_definition_guid"]
        parent_definition_ok = input_alive && input_entities.all? do |entity|
          parent = entity.respond_to?(:parent) ? entity.parent : nil
          parent.respond_to?(:guid) && parent.guid.to_s == expected_definition_guid
        end
        child_ids = if state.dig("hierarchy", "child_persistent_ids").is_a?(Array)
                      state.dig("hierarchy", "child_persistent_ids").sort
                    else
                      []
                    end
        semantics_ok = input_alive && input_entities.all? do |entity|
          before = metadata.fetch("input_fingerprints", {})[entity.persistent_id.to_s]
          next false unless before
          current = semantic_entity_state(model, entity)
          before["identity"] == current["identity_fingerprint"] &&
            before["reparent"] == grouping_reparent_fingerprint(entity, current)
        end
        bounds_min_check = validate_numeric_triplet_expectation(
          "action.composition_bounds_min",
          metadata["input_bounds_min"],
          state.dig("bounds", "min"),
          SEMANTIC_QUANTUM
        )
        bounds_max_check = validate_numeric_triplet_expectation(
          "action.composition_bounds_max",
          metadata["input_bounds_max"],
          state.dig("bounds", "max"),
          SEMANTIC_QUANTUM
        )
        return [
          semantic_check("action.input_pids_alive", true, input_alive),
          semantic_check("action.input_parent_definition", true, parent_definition_ok),
          semantic_check("action.group_children_exact", input_ids.sort, child_ids),
          semantic_check("action.input_semantics_preserved", true, semantics_ok),
          bounds_min_check,
          bounds_max_check,
          semantic_check(
            "action.result_is_new",
            true,
            !input_ids.include?(state["persistent_id"])
          )
        ]
      when "create_component"
        model = Sketchup.active_model
        input_ids = metadata["input_persistent_ids"] || []
        input_entities = input_ids.map do |persistent_id|
          model.find_entity_by_persistent_id(persistent_id)
        end
        input_alive = input_entities.all? do |entity|
          entity && entity.respond_to?(:valid?) && entity.valid?
        end
        expected_definition_guid = metadata["component_definition_guid"]
        parent_definition_ok = input_alive && input_entities.all? do |entity|
          parent = entity.respond_to?(:parent) ? entity.parent : nil
          parent.respond_to?(:guid) && parent.guid.to_s == expected_definition_guid
        end
        child_ids = if state.dig("hierarchy", "child_persistent_ids").is_a?(Array)
                      state.dig("hierarchy", "child_persistent_ids").sort
                    else
                      []
                    end
        semantics_ok = input_alive && input_entities.all? do |entity|
          before = metadata.fetch("input_fingerprints", {})[entity.persistent_id.to_s]
          next false unless before
          current = semantic_entity_state(model, entity)
          before["identity"] == current["identity_fingerprint"] &&
            before["reparent"] == grouping_reparent_fingerprint(entity, current)
        end
        bounds_min_check = validate_numeric_triplet_expectation(
          "action.composition_bounds_min",
          metadata["input_bounds_min"],
          state.dig("bounds", "min"),
          SEMANTIC_QUANTUM
        )
        bounds_max_check = validate_numeric_triplet_expectation(
          "action.composition_bounds_max",
          metadata["input_bounds_max"],
          state.dig("bounds", "max"),
          SEMANTIC_QUANTUM
        )
        return [
          semantic_check("action.input_pids_alive", true, input_alive),
          semantic_check("action.input_parent_definition", true, parent_definition_ok),
          semantic_check("action.component_children_exact", input_ids.sort, child_ids),
          semantic_check("action.input_semantics_preserved", true, semantics_ok),
          bounds_min_check,
          bounds_max_check,
          semantic_check(
            "action.component_definition_guid",
            expected_definition_guid,
            state.dig("definition", "guid")
          ),
          semantic_check(
            "action.result_is_new",
            true,
            !input_ids.include?(state["persistent_id"])
          )
        ]
      when "place_instance"
        model = Sketchup.active_model
        expected_definition_guid = metadata["component_definition_guid"]
        current_definition = semantic_definition_geometry_fingerprint(
          find_definition_by_guid(model, expected_definition_guid)
        )
        return [
          semantic_check(
            "action.definition_guid",
            expected_definition_guid,
            state.dig("definition", "guid")
          ),
          semantic_check(
            "action.definition_geometry_preserved",
            metadata["definition_geometry_before"],
            current_definition
          ),
          semantic_check(
            "action.definition_geometry_matches_state",
            metadata["definition_geometry_before"],
            state.dig("definition", "geometry_fingerprint")
          ),
          validate_numeric_array_expectation(
            "action.transformation",
            metadata["requested_transformation"],
            state["transformation"],
            SEMANTIC_QUANTUM
          )
        ]
      when "make_unique"
        model = Sketchup.active_model
        entity = model.find_entity_by_persistent_id(metadata["target_persistent_id"])
        current_guid = entity.respond_to?(:definition) ? entity.definition.guid.to_s : nil
        current_geometry = entity.respond_to?(:definition) ? semantic_definition_geometry_fingerprint(entity.definition) : nil
        return [
          semantic_check(
            "action.persistent_id",
            metadata["target_persistent_id"],
            state["persistent_id"]
          ),
          semantic_check(
            "action.definition_guid_changed",
            true,
            metadata["component_definition_guid_before"] != current_guid
          ),
          semantic_check(
            "action.definition_guid_matches_state",
            current_guid,
            state.dig("definition", "guid")
          ),
          semantic_check(
            "action.definition_geometry_preserved",
            metadata["definition_geometry_before"],
            current_geometry
          )
        ]
      when "copy_entity"
        model = Sketchup.active_model
        source_alive = entity_alive_by_pid?(model, metadata["source_persistent_id"])
        shares = if state["type"] == "ComponentInstance"
                   !metadata["source_definition_guid"].nil? &&
                     state.dig("definition", "guid") == metadata["source_definition_guid"]
                 else
                   state["geometry_fingerprint"] == metadata["source_geometry_fingerprint"]
                 end
        return [
          semantic_check(
            "action.copy_is_new",
            true,
            state["persistent_id"] != metadata["source_persistent_id"]
          ),
          semantic_check("action.source_alive", true, source_alive),
          semantic_check(
            "action.copy_transform_same",
            metadata["source_transformation"],
            state["transformation"]
          ),
          semantic_check("action.copy_shares_source", true, shares)
        ]
      when "linear_array", "radial_array"
        model = Sketchup.active_model
        copy_ids = metadata["copy_persistent_ids"] || []
        requested = metadata["requested_transformations"] || []
        copies = copy_ids.map { |persistent_id| model.find_entity_by_persistent_id(persistent_id) }
        copies_alive = copies.all? { |entity| entity && entity.respond_to?(:valid?) && entity.valid? }
        transforms_ok = copies_alive && copies.each_with_index.all? do |entity, index|
          current = semantic_entity_state(model, entity)
          current["transformation"] == requested[index]
        end
        shares_ok = copies_alive && copies.all? do |entity|
          current = semantic_entity_state(model, entity)
          if current["type"] == "ComponentInstance"
            !metadata["source_definition_guid"].nil? &&
              current.dig("definition", "guid") == metadata["source_definition_guid"]
          else
            current["geometry_fingerprint"] == metadata["source_geometry_fingerprint"]
          end
        end
        return [
          semantic_check("action.array_count_exact", metadata["count"], copy_ids.length),
          semantic_check("action.copies_alive", true, copies_alive),
          semantic_check("action.array_transforms_exact", true, transforms_ok),
          semantic_check("action.array_shares_source", true, shares_ok),
          semantic_check(
            "action.result_is_new",
            true,
            !copy_ids.include?(metadata["source_persistent_id"])
          )
        ]
      when "tag_assign"
        return [
          semantic_check(
            "action.assign_same_pid",
            metadata["target_persistent_id"],
            state["persistent_id"]
          ),
          semantic_check(
            "action.tag_applied",
            metadata["requested_tag"],
            state["tag"]
          ),
          semantic_check(
            "action.geometry_preserved",
            metadata["before_geometry_fingerprint"],
            state["geometry_fingerprint"]
          ),
          semantic_check(
            "action.transform_unchanged",
            metadata["before_transformation"],
            state["transformation"]
          )
        ]
      when "material_assign"
        applied = if metadata["requested_side"] == "back"
                    state["back_material"]
                  else
                    state["material"]
                  end
        return [
          semantic_check(
            "action.assign_same_pid",
            metadata["target_persistent_id"],
            state["persistent_id"]
          ),
          semantic_check(
            "action.material_applied",
            metadata["requested_material"],
            applied
          ),
          semantic_check(
            "action.geometry_preserved",
            metadata["before_geometry_fingerprint"],
            state["geometry_fingerprint"]
          ),
          semantic_check(
            "action.transform_unchanged",
            metadata["before_transformation"],
            state["transformation"]
          )
        ]
      when "create_polyline"
        model = Sketchup.active_model
        members = group_member_entities(model, state)
        edges = members.grep(Sketchup::Edge)
        actual_length = edges.sum(&:length)
        length_tolerance = [metadata["total_length"].abs * 1e-9, SEMANTIC_QUANTUM].max
        faces = members.grep(Sketchup::Face)
        face_ok = if metadata["face_expected"]
                    faces.length == 1 &&
                      (faces.first.area - metadata["face_area"]).abs <=
                        [metadata["face_area"].abs * 1e-9, SEMANTIC_QUANTUM].max
                  else
                    faces.empty?
                  end
        return [
          semantic_check(
            "action.total_length_exact",
            true,
            (actual_length - metadata["total_length"]).abs <= length_tolerance
          ),
          semantic_check("action.face_exact", true, face_ok),
          semantic_check(
            "action.result_is_new",
            true,
            state["type"] == "Group"
          )
        ]
      when "create_rectangle"
        model = Sketchup.active_model
        members = group_member_entities(model, state)
        group = model.find_entity_by_persistent_id(state["persistent_id"])
        face = members.grep(Sketchup::Face).first
        face_corners = face ? global_member_corners(group, face.vertices) : []
        corners_ok = face && face_corners == metadata["corners"].sort
        area_tolerance = [metadata["rectangle_area"].abs * 1e-9, SEMANTIC_QUANTUM].max
        face_area = face ? face.area : nil
        return [
          semantic_check("action.face_single", true, members.grep(Sketchup::Face).length == 1),
          semantic_check("action.corners_exact", true, corners_ok),
          semantic_check(
            "action.rectangle_area_exact",
            true,
            !face_area.nil? && (face_area - metadata["rectangle_area"]).abs <= area_tolerance
          )
        ]
      when "create_circle"
        model = Sketchup.active_model
        members = group_member_entities(model, state)
        group = model.find_entity_by_persistent_id(state["persistent_id"])
        vertices = members.grep(Sketchup::Edge).flat_map { |edge| [edge.start, edge.end] }.uniq
        transform = group.is_a?(Sketchup::Group) ? group.transformation : nil
        return [
          semantic_check(
            "action.radius_exact",
            true,
            curve_vertices_on_radius?(vertices, metadata["center"], metadata["radius"], transform)
          )
        ]
      when "create_arc"
        model = Sketchup.active_model
        members = group_member_entities(model, state)
        group = model.find_entity_by_persistent_id(state["persistent_id"])
        vertices = members.grep(Sketchup::Edge).flat_map { |edge| [edge.start, edge.end] }.uniq
        center = metadata["center"]
        group_transform = group.is_a?(Sketchup::Group) ? group.transformation : nil
        global_points = vertices.map do |vertex|
          point = group_transform ? vertex.position.transform(group_transform) : vertex.position
          [point.x, point.y, point.z]
        end
        xaxis = Geom::Vector3d.new(metadata["xaxis"][0], metadata["xaxis"][1], metadata["xaxis"][2])
        normal = Geom::Vector3d.new(metadata["normal"][0], metadata["normal"][1], metadata["normal"][2])
        v_axis = (normal * xaxis).normalize
        angles = global_points.map do |point|
          direction = Geom::Vector3d.new(
            point[0] - center[0],
            point[1] - center[1],
            point[2] - center[2]
          )
          Math.atan2(direction.dot(v_axis), direction.dot(xaxis)) * 180.0 / Math::PI
        end
        endpoints_ok = [metadata["start_degrees"], metadata["end_degrees"]].all? do |target|
          angles.any? { |angle| angular_difference_degrees(angle, target).abs <= 1e-6 }
        end
        return [
          semantic_check(
            "action.radius_exact",
            true,
            curve_vertices_on_radius?(vertices, center, metadata["radius"], group_transform)
          ),
          semantic_check("action.arc_endpoints_exact", true, endpoints_ok)
        ]
      when "create_polygon"
        model = Sketchup.active_model
        members = group_member_entities(model, state)
        group = model.find_entity_by_persistent_id(state["persistent_id"])
        face = members.grep(Sketchup::Face).first
        vertices = face ? face.vertices : []
        transform = group.is_a?(Sketchup::Group) ? group.transformation : nil
        area_tolerance = [metadata["polygon_area"].abs * 1e-9, SEMANTIC_QUANTUM].max
        face_area = face ? face.area : nil
        return [
          semantic_check("action.face_single", true, members.grep(Sketchup::Face).length == 1),
          semantic_check(
            "action.radius_exact",
            true,
            curve_vertices_on_radius?(vertices, metadata["center"], metadata["radius"], transform)
          ),
          semantic_check(
            "action.polygon_area_exact",
            true,
            !face_area.nil? && (face_area - metadata["polygon_area"]).abs <= area_tolerance
          )
        ]
      when "sweep_profile"
        model = Sketchup.active_model
        input_ids = metadata["input_persistent_ids"] || []
        consumed_ids = metadata["consumed_persistent_ids"] || []
        reparented_ids = metadata["reparented_persistent_ids"] || []
        edge_lengths = metadata["edge_lengths"] || {}
        face_entity = model.find_entity_by_persistent_id(metadata["face_pid"])
        face_ok = if face_entity && face_entity.respond_to?(:valid?) && face_entity.valid?
                    parent = face_entity.respond_to?(:parent) ? face_entity.parent : nil
                    parent.respond_to?(:guid) &&
                      parent.guid.to_s == metadata["sweep_definition_guid"] &&
                      (quantize_number(face_entity.area) - metadata["face_area"]).abs <=
                        [metadata["face_area"].abs * 1e-9, SEMANTIC_QUANTUM].max
                  else
                    consumed_ids.include?(metadata["face_pid"])
                  end
        no_collateral = (consumed_ids - input_ids).empty?
        reparented_ok = reparented_ids.all? do |persistent_id|
          entity = model.find_entity_by_persistent_id(persistent_id)
          next false unless entity && entity.respond_to?(:valid?) && entity.valid?
          parent = entity.respond_to?(:parent) ? entity.parent : nil
          parent.respond_to?(:guid) && parent.guid.to_s == metadata["sweep_definition_guid"]
        end
        lengths_ok = reparented_ids.all? do |persistent_id|
          entity = model.find_entity_by_persistent_id(persistent_id)
          next true unless entity.is_a?(Sketchup::Edge)
          expected = edge_lengths[persistent_id.to_s]
          !expected.nil? && (quantize_number(entity.length) - expected).abs <=
            [expected.abs * 1e-9, SEMANTIC_QUANTUM].max
        end
        child_ids = if state.dig("hierarchy", "child_persistent_ids").is_a?(Array)
                      state.dig("hierarchy", "child_persistent_ids").sort
                    else
                      []
                    end
        children_cover_reparented = (reparented_ids - child_ids).empty?
        volume = state["volume"]
        return [
          semantic_check("action.profile_accounted", true, face_ok),
          semantic_check("action.no_collateral_consumed", true, no_collateral),
          semantic_check("action.inputs_reparented", true, reparented_ok),
          semantic_check("action.sweep_children_cover_inputs", true, children_cover_reparented),
          semantic_check("action.lengths_preserved", true, lengths_ok),
          semantic_check("action.sweep_manifold", true, state["manifold"] == true),
          semantic_check("action.sweep_volume_positive", true, !volume.nil? && volume > 0),
          semantic_check(
            "action.result_is_new",
            true,
            !input_ids.include?(state["persistent_id"])
          )
        ]
      when "place_asset"
        return [
          validate_numeric_array_expectation(
            "action.asset_transform_exact",
            metadata["requested_transformation"],
            state["transformation"],
            SEMANTIC_QUANTUM
          )
        ]
      when "camera_set"
        tolerance = SEMANTIC_QUANTUM
        eye_ok = validate_numeric_triplet_expectation(
          "action.camera_eye", metadata["requested_eye"], state["camera_eye"], tolerance
        )["passed"]
        target_ok = validate_numeric_triplet_expectation(
          "action.camera_target", metadata["requested_target"], state["camera_target"], tolerance
        )["passed"]
        return [
          semantic_check("action.camera_eye_exact", true, eye_ok),
          semantic_check("action.camera_target_exact", true, target_ok),
          semantic_check("action.camera_up_orthogonal", true, metadata["up_orthogonal"]),
          semantic_check(
            "action.camera_fov_exact",
            true,
            (state["camera_fov"] - metadata["requested_fov"]).abs <= 1e-9
          )
        ]
      when "scene_create"
        return [
          semantic_check(
            "action.scene_created",
            metadata["requested_name"],
            state["scene_name"]
          ),
          semantic_check(
            "action.scene_count_incremented",
            metadata["before_count"] + 1,
            state["scene_count"]
          )
        ]
      when "material_apply_texture"
        width_ok = state["texture_width"] == metadata["requested_width"] &&
          state["texture_height"] == metadata["requested_height"]
        return [
          semantic_check(
            "action.texture_dims_exact",
            true,
            width_ok
          ),
          semantic_check(
            "action.texture_material_same",
            metadata["material"],
            state["material"]
          )
        ]
      when "repair_reverse_face"
        before = metadata["before_normal"]
        after = state["normal"]
        flipped = !before.nil? && !after.nil? &&
          (before[0] + after[0]).abs <= SEMANTIC_QUANTUM &&
          (before[1] + after[1]).abs <= SEMANTIC_QUANTUM &&
          (before[2] + after[2]).abs <= SEMANTIC_QUANTUM
        return [
          semantic_check(
            "action.face_reversed",
            true,
            flipped
          ),
          semantic_check(
            "action.repair_same_pid",
            metadata["target_persistent_id"],
            state["persistent_id"]
          ),
          semantic_check(
            "action.repair_area_same",
            metadata["before_area"],
            state["area"]
          )
        ]
      when "repair_erase_degenerate"
        target_alive = entity_alive_by_pid?(Sketchup.active_model, metadata["target_persistent_id"])
        return [
          semantic_check("action.degenerate_erased", false, target_alive),
          semantic_check("action.deleted", true, state["deleted"]),
          semantic_check(
            "action.repair_same_pid",
            metadata["target_persistent_id"],
            state["persistent_id"]
          )
        ]
      end
      []
    end

    def validate_action_affected_invariants(action, state, metadata, affected)
      case action
      when "group_entities", "create_component"
        input_ids = (metadata["input_persistent_ids"] || []).sort
        return [
          semantic_check("affected.created", [state["persistent_id"]], affected["created"]),
          semantic_check("affected.modified", input_ids, affected["modified"]),
          semantic_check("affected.deleted", [], affected["deleted"])
        ]
      when "make_unique"
        return [
          semantic_check("affected.created", [], affected["created"]),
          semantic_check("affected.modified", [state["persistent_id"]], affected["modified"]),
          semantic_check("affected.deleted", [], affected["deleted"])
        ]
      when "copy_entity"
        return [
          semantic_check("affected.created", [state["persistent_id"]], affected["created"]),
          semantic_check("affected.modified", [], affected["modified"]),
          semantic_check("affected.deleted", [], affected["deleted"])
        ]
      when "linear_array", "radial_array"
        copy_ids = (metadata["copy_persistent_ids"] || []).sort
        return [
          semantic_check("affected.created", copy_ids, affected["created"]),
          semantic_check("affected.modified", [], affected["modified"]),
          semantic_check("affected.deleted", [], affected["deleted"])
        ]
      when "tag_assign", "material_assign"
        return [
          semantic_check("affected.created", [], affected["created"]),
          semantic_check("affected.modified", [state["persistent_id"]], affected["modified"]),
          semantic_check("affected.deleted", [], affected["deleted"])
        ]
      when "create_polyline", "create_circle", "create_arc", "create_rectangle", "create_polygon"
        return [
          semantic_check("affected.created", [state["persistent_id"]], affected["created"]),
          semantic_check("affected.modified", [], affected["modified"]),
          semantic_check("affected.deleted", [], affected["deleted"])
        ]
      when "sweep_profile"
        consumed_ids = ((metadata["consumed_persistent_ids"] || []).sort)
        reparented_ids = ((metadata["reparented_persistent_ids"] || []).sort)
        return [
          semantic_check("affected.created", [state["persistent_id"]], affected["created"]),
          semantic_check("affected.modified", reparented_ids, affected["modified"]),
          semantic_check("affected.deleted", consumed_ids, affected["deleted"])
        ]
      when "place_asset", "place_instance"
        return [
          semantic_check("affected.created", [state["persistent_id"]], affected["created"]),
          semantic_check("affected.modified", [], affected["modified"]),
          semantic_check("affected.deleted", [], affected["deleted"])
        ]
      when "material_apply_texture"
        return [
          semantic_check("affected.created", [], affected["created"]),
          semantic_check("affected.modified", [], affected["modified"]),
          semantic_check("affected.deleted", [], affected["deleted"])
        ]
      when "camera_set", "scene_create"
        return [
          semantic_check("affected.created", [], affected["created"]),
          semantic_check("affected.modified", [], affected["modified"]),
          semantic_check("affected.deleted", [], affected["deleted"])
        ]
      when "repair_reverse_face"
        return [
          semantic_check("affected.created", [], affected["created"]),
          semantic_check("affected.modified", [state["persistent_id"]], affected["modified"]),
          semantic_check("affected.deleted", [], affected["deleted"])
        ]
      when "repair_erase_degenerate"
        return [
          semantic_check("affected.created", [], affected["created"]),
          semantic_check("affected.modified", [], affected["modified"]),
          semantic_check("affected.deleted", [state["persistent_id"]], affected["deleted"])
        ]
      end
      []
    end

    def semantic_affected_entities(model, before_snapshot, after_snapshot)
      before_ids = before_snapshot.keys
      after_ids = after_snapshot.keys
      created = after_ids - before_ids
      deleted = []
      modified = []

      (before_ids - after_ids).each do |persistent_id|
        if entity_alive_by_pid?(model, persistent_id)
          modified << persistent_id
        else
          deleted << persistent_id
        end
      end

      (before_ids & after_ids).each do |persistent_id|
        before_state = before_snapshot[persistent_id]
        after_state = after_snapshot[persistent_id]
        modified << persistent_id if before_state != after_state
      end

      {
        "created" => created.sort,
        "modified" => modified.uniq.sort,
        "deleted" => deleted.sort
      }
    end

    def empty_affected_entities
      {
        "created" => [],
        "modified" => [],
        "deleted" => []
      }
    end

    def entity_alive_by_pid?(model, persistent_id)
      entity = model.find_entity_by_persistent_id(persistent_id)
      !!(entity && entity.respond_to?(:valid?) && entity.valid?)
    end

    def validate_boolean_volume_invariant(state, metadata)
      actual = state["volume"]
      tool_volume = metadata["tool_volume"]
      target_volume = metadata["target_volume"]
      passed = false
      if actual && tool_volume && target_volume && actual.positive?
        passed = case metadata["operation_type"]
                 when "union"
                   actual >= [tool_volume, target_volume].max - SEMANTIC_QUANTUM &&
                     actual <= tool_volume + target_volume + SEMANTIC_QUANTUM
                 when "difference"
                   actual <= target_volume + SEMANTIC_QUANTUM
                 when "intersect"
                   actual <= [tool_volume, target_volume].min + SEMANTIC_QUANTUM
                 else
                   false
                 end
      end
      {
        "field" => "action.volume_relation",
        "expected" => metadata["operation_type"],
        "actual" => actual,
        "passed" => !!passed
      }
    end

    def validate_semantic_expectation_schema(expect)
      unknown_expect_keys = expect.keys - SEMANTIC_EXPECT_KEYS
      unless unknown_expect_keys.empty?
        raise BridgeError.new(
          "invalid_argument",
          "expect contains unsupported keys: #{unknown_expect_keys.sort.join(', ')}"
        )
      end

      unless expect.key?("active_entity_delta")
        raise BridgeError.new(
          "invalid_argument",
          "expect.active_entity_delta is required"
        )
      end

      validation_keys = expect.keys - ["tolerance", "active_entity_delta"]
      if validation_keys.empty?
        raise BridgeError.new(
          "invalid_argument",
          "expect must contain at least one entity semantic validation field"
        )
      end
      true
    end

    def validate_semantic_expectation(state, expect, before_count:, after_count:)
      tolerance = expect.key?("tolerance") ? finite_number(expect["tolerance"], "expect.tolerance") : 1e-6
      if tolerance.negative?
        raise BridgeError.new("invalid_argument", "expect.tolerance must be non-negative")
      end
      area_tolerance = [tolerance * tolerance, SEMANTIC_QUANTUM].max
      volume_tolerance = [tolerance * tolerance * tolerance, SEMANTIC_QUANTUM].max
      checks = []

      checks << semantic_check(
        "active_entity_delta",
        Integer(expect["active_entity_delta"]),
        after_count - before_count
      )

      if expect.key?("deleted")
        unless expect["deleted"] == true || expect["deleted"] == false
          raise BridgeError.new("invalid_argument", "expect.deleted must be boolean")
        end
        checks << semantic_check("deleted", expect["deleted"], state["deleted"])
      end
      if expect.key?("type")
        checks << semantic_check("type", expect["type"].to_s, state["type"])
      end
      if expect.key?("child_persistent_ids")
        expected_children = normalize_expected_pid_set(
          expect["child_persistent_ids"],
          "expect.child_persistent_ids"
        )
        actual_children = state.dig("hierarchy", "child_persistent_ids")
        checks << semantic_check(
          "child_persistent_ids",
          expected_children,
          actual_children.is_a?(Array) ? actual_children.sort : actual_children
        )
      end
      if expect.key?("bounds_min")
        checks << validate_numeric_triplet_expectation(
          "bounds_min",
          expect["bounds_min"],
          state.dig("bounds", "min"),
          tolerance
        )
      end
      if expect.key?("bounds_max")
        checks << validate_numeric_triplet_expectation(
          "bounds_max",
          expect["bounds_max"],
          state.dig("bounds", "max"),
          tolerance
        )
      end
      if expect.key?("bounds_size")
        checks << validate_numeric_triplet_expectation(
          "bounds_size",
          expect["bounds_size"],
          state.dig("bounds", "size"),
          tolerance
        )
      end
      if expect.key?("vertex_count")
        checks << semantic_check("vertex_count", Integer(expect["vertex_count"]), state["vertex_count"])
      end
      if expect.key?("face_count")
        checks << semantic_check("face_count", Integer(expect["face_count"]), state["face_count"])
      end
      if expect.key?("edge_count")
        checks << semantic_check("edge_count", Integer(expect["edge_count"]), state["edge_count"])
      end
      if expect.key?("vertex_count")
        checks << semantic_check("vertex_count", Integer(expect["vertex_count"]), state["vertex_count"])
      end
      if expect.key?("area")
        checks << validate_numeric_expectation(
          "area",
          expect["area"],
          state["area"],
          area_tolerance
        )
      end
      if expect.key?("normal")
        checks << validate_numeric_triplet_expectation(
          "normal",
          expect["normal"],
          state["normal"],
          tolerance
        )
      end
      if expect.key?("manifold")
        unless expect["manifold"] == true || expect["manifold"] == false
          raise BridgeError.new("invalid_argument", "expect.manifold must be boolean")
        end
        checks << semantic_check("manifold", expect["manifold"], state["manifold"])
      end
      if expect.key?("volume")
        checks << validate_numeric_expectation(
          "volume",
          expect["volume"],
          state["volume"],
          volume_tolerance
        )
      end
      if expect.key?("transformation")
        checks << validate_transformation_expectation(
          "transformation",
          expect["transformation"],
          state["transformation"],
          tolerance
        )
      end
      if expect.key?("tag")
        checks << semantic_check("tag", expect["tag"].to_s, state["tag"])
      end
      if expect.key?("material")
        checks << semantic_check("material", expect["material"].to_s, state["material"])
      end
      if expect.key?("camera_eye")
        checks << validate_numeric_triplet_expectation(
          "camera_eye",
          expect["camera_eye"],
          state["camera_eye"],
          tolerance
        )
      end
      if expect.key?("camera_target")
        checks << validate_numeric_triplet_expectation(
          "camera_target",
          expect["camera_target"],
          state["camera_target"],
          tolerance
        )
      end
      if expect.key?("camera_fov")
        checks << validate_numeric_expectation(
          "camera_fov",
          expect["camera_fov"],
          state["camera_fov"],
          SEMANTIC_QUANTUM
        )
      end
      if expect.key?("scene_name")
        checks << semantic_check("scene_name", expect["scene_name"].to_s, state["scene_name"])
      end
      if expect.key?("definition_guid")
        checks << semantic_check(
          "definition_guid",
          expect["definition_guid"].to_s,
          state.dig("definition", "guid")
        )
      end
      if expect.key?("definition_name")
        checks << semantic_check(
          "definition_name",
          expect["definition_name"].to_s,
          state.dig("hierarchy", "definition_name")
        )
      end

      {
        "passed" => checks.all? { |check| check["passed"] },
        "checks" => checks
      }
    rescue ArgumentError, TypeError
      raise BridgeError.new("invalid_argument", "semantic validation contains invalid integer")
    end

    def normalize_expected_pid_set(value, name)
      unless value.is_a?(Array) && value.length.between?(1, MAX_OBJECTS)
        raise BridgeError.new(
          "invalid_argument",
          "#{name} must contain 1..#{MAX_OBJECTS} persistent IDs"
        )
      end
      persistent_ids = value.each_with_index.map do |item, index|
        bounded_integer(
          item,
          minimum: 1,
          maximum: (2**63) - 1,
          name: "#{name}[#{index}]"
        )
      end
      if persistent_ids.uniq.length != persistent_ids.length
        raise BridgeError.new("invalid_argument", "#{name} must not contain duplicates")
      end
      persistent_ids.sort
    end

    def numeric_array(value, length, name)
      unless value.is_a?(Array) && value.length == length
        raise BridgeError.new("invalid_argument", "#{name} must contain exactly #{length} numbers")
      end
      value.map.with_index do |item, index|
        finite_number(item, "#{name}[#{index}]")
      end
    end

    def validate_transformation_expectation(field, expected_value, actual_value, length_tolerance)
      expected = numeric_array(expected_value, 16, "expect.#{field}")
      passed = actual_value.is_a?(Array) && actual_value.length == 16
      if passed
        passed = expected.zip(actual_value).each_with_index.all? do |(expected_item, actual_item), index|
          tolerance = [12, 13, 14].include?(index) ? length_tolerance : SEMANTIC_QUANTUM
          (expected_item - actual_item).abs <= tolerance
        end
      end
      {
        "field" => field,
        "expected" => expected,
        "actual" => actual_value,
        "passed" => !!passed
      }
    end

    def validate_numeric_array_expectation(field, expected_value, actual_value, tolerance)
      expected = numeric_array(expected_value, 16, "expect.#{field}")
      passed = actual_value.is_a?(Array) &&
        actual_value.length == 16 &&
        expected.zip(actual_value).all? do |expected_item, actual_item|
          (expected_item - actual_item).abs <= tolerance
        end
      {
        "field" => field,
        "expected" => expected,
        "actual" => actual_value,
        "passed" => !!passed
      }
    end

    def validate_numeric_expectation(field, expected_value, actual_value, tolerance)
      expected = finite_number(expected_value, "expect.#{field}")
      passed = !actual_value.nil? && (expected - actual_value).abs <= tolerance
      {
        "field" => field,
        "expected" => expected,
        "actual" => actual_value,
        "passed" => !!passed
      }
    end

    def validate_numeric_triplet_expectation(field, expected_value, actual_value, tolerance)
      expected = numeric_triplet(expected_value, "expect.#{field}")
      passed = actual_value && expected.zip(actual_value).all? do |expected_item, actual_item|
        (expected_item - actual_item).abs <= tolerance
      end
      {
        "field" => field,
        "expected" => expected,
        "actual" => actual_value,
        "passed" => !!passed
      }
    end

    def semantic_check(field, expected, actual)
      {
        "field" => field,
        "expected" => expected,
        "actual" => actual,
        "passed" => expected == actual
      }
    end

    def quantize_number(value)
      (value.to_f / SEMANTIC_QUANTUM).round * SEMANTIC_QUANTUM
    end

    def quantized_point(point)
      [
        quantize_number(point.x),
        quantize_number(point.y),
        quantize_number(point.z)
      ]
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

    def point3d(value, name)
      unless value.is_a?(Array) && value.length == 3
        raise BridgeError.new("invalid_argument", "#{name} must be [x, y, z]")
      end
      numbers = value.map do |item|
        number = Float(item)
        unless number.finite?
          raise BridgeError.new("invalid_argument", "#{name} coordinates must be finite")
        end
        number
      rescue ArgumentError, TypeError
        raise BridgeError.new("invalid_argument", "#{name} coordinates must be numeric")
      end
      Geom::Point3d.new(numbers)
    end

    def point_to_array(point)
      [point.x.to_f, point.y.to_f, point.z.to_f]
    end

    def vector_to_array(vector)
      [vector.x.to_f, vector.y.to_f, vector.z.to_f]
    end

    def bounded_integer(value, default: nil, minimum:, maximum:, name:)
      value = default if value.nil? && !default.nil?
      integer = Integer(value)
      unless integer.between?(minimum, maximum)
        raise BridgeError.new("invalid_argument", "#{name} must be #{minimum}..#{maximum}")
      end
      integer
    rescue ArgumentError, TypeError
      raise BridgeError.new("invalid_argument", "#{name} must be an integer")
    end

    def response_error(request_id, kind, message)
      {
        "protocol" => PROTOCOL_VERSION,
        "request_id" => request_id,
        "ok" => false,
        "error" => {
          "kind" => kind,
          "message" => message
        }
      }
    end

    def secure_compare(left, right)
      return false unless left.is_a?(String) && right.is_a?(String)
      return false unless left.bytesize == right.bytesize

      mismatch = 0
      left.bytes.zip(right.bytes) { |a, b| mismatch |= (a ^ b) }
      mismatch.zero?
    end

    def load_or_create_token
      path = token_path
      if File.file?(path)
        token = File.read(path, encoding: "UTF-8").strip
        return token if token.length >= 32
      end

      FileUtils.mkdir_p(File.dirname(path))
      token = SecureRandom.hex(32)
      temp_path = "#{path}.tmp-#{Process.pid}"
      File.open(temp_path, File::WRONLY | File::CREAT | File::TRUNC, 0o600) do |file|
        file.write(token)
        file.write("\n")
      end
      begin
        File.chmod(0o600, temp_path)
      rescue SystemCallError, NotImplementedError
        nil
      end
      File.rename(temp_path, path)
      token
    ensure
      begin
        File.delete(temp_path) if defined?(temp_path) && temp_path && File.exist?(temp_path)
      rescue SystemCallError
        nil
      end
    end

    def token_path
      configured = ENV["CDT_SKETCHUP_BRIDGE_TOKEN_FILE"]
      return File.expand_path(configured) if configured && !configured.empty?

      local_app_data = ENV["LOCALAPPDATA"]
      if local_app_data && !local_app_data.empty?
        File.join(local_app_data, "CDT-SketchUp", "bridge.token")
      else
        File.join(Dir.home, ".cdt-sketchup", "bridge.token")
      end
    end

    def monotonic_now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def close_client(socket)
      @clients.delete(socket)
      socket.close unless socket.closed?
    rescue IOError, SystemCallError
      nil
    end

    def log(message)
      puts("[CDT-SketchUp] #{message}") if DEBUG_MODE
    end
  end

  unless file_loaded?(__FILE__)
    @bridge_server = BridgeServer.new

    menu = UI.menu("Extensions").add_submenu("CDT-SketchUp")
    menu.add_item("Start Bridge") { @bridge_server.start }
    menu.add_item("Stop Bridge") { @bridge_server.stop }
    menu.add_item("Bridge Status") do
      UI.messagebox(@bridge_server.running? ? "CDT-SketchUp bridge is running." : "CDT-SketchUp bridge is stopped.")
    end

    @bridge_server.start
    file_loaded(__FILE__)
  end
end
