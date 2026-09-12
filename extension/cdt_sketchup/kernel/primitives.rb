# cdt_sketchup/kernel/primitives.rb — validation and conversion primitives
# Wing: code | Topic: sketchup_bridge | Updated: 2026-09-12

module CDTSketchUp
  class BridgeServer
    private

    def deep_copy_json(value)
      JSON.parse(JSON.generate(value))
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

    def point_to_triplet(point)
      [point.x.to_f, point.y.to_f, point.z.to_f]
    end

    def box_triplet(bounds)
      [[bounds.min.x.to_f, bounds.min.y.to_f, bounds.min.z.to_f],
       [bounds.max.x.to_f, bounds.max.y.to_f, bounds.max.z.to_f]]
    end

    def vector_to_triplet(vector)
      [vector.x.to_f, vector.y.to_f, vector.z.to_f]
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

    def monotonic_now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def log(message)
      puts("[CDT-SketchUp] #{message}") if DEBUG_MODE
    end
  end
end
