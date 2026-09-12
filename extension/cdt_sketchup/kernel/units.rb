# cdt_sketchup/kernel/units.rb — public unit contract and native-inch adapter
# Wing: code | Topic: sketchup_bridge | Updated: 2026-09-12

module CDTSketchUp
  class BridgeServer
    private

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
  end
end
