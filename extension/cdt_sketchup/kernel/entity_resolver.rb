# cdt_sketchup/kernel/entity_resolver.rb — PID resolution and typed entity requirements
# Wing: code | Topic: sketchup_bridge | Updated: 2026-09-12

module CDTSketchUp
  class BridgeServer
    private

    def raw_topology_entity?(entity)
      entity.is_a?(Sketchup::Edge) || entity.is_a?(Sketchup::Face)
    end

    def raw_topology_neighbors(entity)
      neighbors = if entity.is_a?(Sketchup::Face)
                    entity.edges.to_a
                  elsif entity.is_a?(Sketchup::Edge)
                    edge = entity
                    edge.faces.to_a + edge.vertices.flat_map { |vertex| vertex.edges.to_a }
                  else
                    []
                  end
      neighbors.select { |item| raw_topology_entity?(item) }
    end

    def bounded_raw_topology_closure(entity)
      unless raw_topology_entity?(entity)
        raise BridgeError.new("unsupported_object_type", "Topology closure requires an Edge or Face")
      end

      parent = entity.parent
      seed_pid = entity.respond_to?(:persistent_id) ? entity.persistent_id : nil
      unless seed_pid.is_a?(Integer) && seed_pid.positive?
        raise BridgeError.new("topology_unresolvable", "Topology target has no persistent identity")
      end
      queue = [entity]
      queued = { seed_pid => true }
      seen = {}
      until queue.empty?
        current = queue.shift
        next unless current.respond_to?(:valid?) && current.valid?
        next unless current.respond_to?(:parent) && current.parent == parent

        pid = current.respond_to?(:persistent_id) ? current.persistent_id : nil
        unless pid.is_a?(Integer) && pid.positive?
          raise BridgeError.new("topology_unresolvable", "Topology contains an entity without persistent identity")
        end
        next if seen.key?(pid)

        seen[pid] = current
        if seen.length > MAX_TOPOLOGY_RESULTS
          raise BridgeError.new("topology_closure_too_large", "Topology closure exceeds entity limit")
        end
        raw_topology_neighbors(current).each do |neighbor|
          neighbor_pid = neighbor.respond_to?(:persistent_id) ? neighbor.persistent_id : nil
          unless neighbor_pid.is_a?(Integer) && neighbor_pid.positive?
            raise BridgeError.new("topology_unresolvable", "Topology contains an entity without persistent identity")
          end
          next if queued.key?(neighbor_pid)
          if queued.length >= MAX_TOPOLOGY_RESULTS
            raise BridgeError.new("topology_closure_too_large", "Topology closure exceeds entity limit")
          end
          queued[neighbor_pid] = true
          queue << neighbor
        end
      end
      seen.values.sort_by(&:persistent_id)
    end

    def raw_topology_closure_fingerprint(model, entities)
      facts = entities.map do |entity|
        state = semantic_entity_state(model, entity)
        [state["persistent_id"], state["type"], state["semantic_fingerprint"]]
      end
      Digest::SHA256.hexdigest(JSON.generate(facts.sort_by { |fact| fact[0] }))
    end

    def connected_entities(entity)
      if raw_topology_entity?(entity)
        bounded_raw_topology_closure(entity)
      elsif entity.is_a?(Sketchup::Group)
        entity.entities.to_a
      elsif entity.is_a?(Sketchup::ComponentInstance)
        entity.definition.entities.to_a
      else
        []
      end
    end

    def connected_persistent_ids(entity, connected: nil)
      resolved = []
      unresolved = 0
      (connected || connected_entities(entity)).each do |item|
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

    def require_material(model, name)
      material_name = bounded_name(name, "material")
      material = model.materials[material_name]
      raise BridgeError.new("material_not_found", "SketchUp material was not found") unless material
      material
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

    def find_definition_by_guid(model, guid)
      definition = model.definitions.find { |candidate| candidate.guid.to_s == guid }
      unless definition
        raise BridgeError.new("definition_not_found", "Component definition was not found")
      end
      definition
    end

    def entity_alive_by_pid?(model, persistent_id)
      entity = model.find_entity_by_persistent_id(persistent_id)
      !!(entity && entity.respond_to?(:valid?) && entity.valid?)
    end
  end
end
