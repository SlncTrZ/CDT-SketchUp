# cdt_sketchup/kernel/registry.rb — command registries and shared schemas
# Wing: code | Topic: sketchup_bridge | Updated: 2026-09-12

module CDTSketchUp
  class BridgeServer
    private

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
    MODEL_SAVE_AS_PARAM_KEYS = %w[file overwrite].freeze
    MODEL_OPEN_PARAM_KEYS = %w[file if_model_guid].freeze
    MODEL_EXPORT_PARAM_KEYS = %w[file format overwrite width height].freeze
    BOOLEAN_OPERATION_TYPES = %w[union difference intersect].freeze
    MIN_TRANSFORM_DETERMINANT = 1e-12
    MODEL_EXPORT_FORMATS = %w[dae kmz png jpg].freeze
    RASTER_EXPORT_FORMATS = %w[png jpg].freeze
  TEXTURE_MANIFEST_FILENAME = "textures.json".freeze
  TEXTURE_EXTENSIONS = %w[.png .jpg .jpeg .bmp].freeze
  ASSET_MANIFEST_FILENAME = "assets.json".freeze
  end
end
