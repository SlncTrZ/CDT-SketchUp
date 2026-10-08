# cdt_sketchup/actions/transform.rb — strict absolute transforms
# Wing: code | Topic: sketchup_bridge | Updated: 2026-09-12

module CDTSketchUp
  class BridgeServer
    private

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
  end
end
