# cdt_sketchup/kernel/mutation_journal.rb — stable mutation identity and reconciliation
# Wing: code | Topic: sketchup_recovery | Updated: 2026-09-19
#
# Retry safety for strict mutations. A caller keeps one mutation_id across
# transport retries; the journal replays the stored receipt instead of
# mutating twice, and rejects same-id/different-payload reuse. Journal state
# is process memory only: restarts and model switches invalidate it by
# construction (fail-closed via mutation_reconcile, never silent replay).
#
# Canonical hash input covers every logical execute_geometry field except the
# mutation transport metadata itself. Routing/precondition fields such as
# target_context, if_context and if_match are part of operation identity.

module CDTSketchUp
  class BridgeServer
    private

    MUTATION_ID_RE = /\A[0-9a-f]{32}\z/
    MUTATION_HASH_RE = /\A[0-9a-f]{64}\z/
    MAX_JOURNAL_ENTRIES = 128
    MAX_JOURNAL_AGE_SECONDS = 900

    def mutation_utf8_hex(value)
      value.encode(Encoding::UTF_8).unpack1("H*")
    end

    def mutation_canonical_node(node)
      if node.nil?
        ["n"]
      elsif node == true || node == false
        ["b", node ? "1" : "0"]
      elsif node.is_a?(Integer)
        ["i", node.to_s]
      elsif node.is_a?(Float)
        unless node.finite?
          raise ArgumentError, "canonical mutation values must be finite"
        end
        value = node.zero? ? 0.0 : node
        ["f", [value].pack("G").unpack1("H*")]
      elsif node.is_a?(String)
        ["s", mutation_utf8_hex(node)]
      elsif node.is_a?(Array)
        ["a", node.map { |item| mutation_canonical_node(item) }]
      elsif node.is_a?(Hash)
        entries = node.map do |key, value|
          unless key.is_a?(String)
            raise ArgumentError, "canonical mutation object keys must be strings"
          end
          [mutation_utf8_hex(key), mutation_canonical_node(value)]
        end
        entries.sort_by! { |entry| entry[0] }
        ["o", entries]
      else
        raise ArgumentError, "unsupported canonical mutation value: #{node.class}"
      end
    end

    def mutation_canonical_json(node)
      JSON.generate(mutation_canonical_node(node))
    end

    def mutation_canonical_request(action, envelope)
      request = { "action" => action }
      envelope.each do |raw_key, value|
        key = raw_key.to_s
        next if key == "action" || key == "mutation"

        request[key] = value
      end
      request
    end

    def mutation_request_hash(action, envelope)
      Digest::SHA256.hexdigest(
        mutation_canonical_json(mutation_canonical_request(action, envelope)))
    end

    def mutation_journal_prune(now = monotonic_now)
      return if @mutation_journal.nil?

      @mutation_journal.delete_if do |_, entry|
        now - entry["stored_at"] > MAX_JOURNAL_AGE_SECONDS
      end
      while @mutation_journal.length > MAX_JOURNAL_ENTRIES
        @mutation_journal.delete(@mutation_journal.keys.first)
      end
      nil
    end

    def journal_store(id, request_hash, action, status, receipt, model_guid,
                      before_fingerprint, after_fingerprint)
      @mutation_journal = {} if @mutation_journal.nil?
      mutation_journal_prune
      @mutation_journal[id] = {
        "id" => id,
        "request_hash" => request_hash,
        "action" => action,
        "status" => status,
        "receipt" => receipt,
        "model_guid" => model_guid,
        "before_fingerprint" => before_fingerprint,
        "after_fingerprint" => after_fingerprint,
        "stored_at" => monotonic_now
      }
      mutation_journal_prune
      @mutation_journal[id]
    end

    def journal_lookup(id, model_guid)
      return nil if @mutation_journal.nil?

      mutation_journal_prune
      entry = @mutation_journal[id]
      return nil unless entry.is_a?(Hash)
      return nil unless entry["model_guid"] == model_guid

      entry
    end

    def mutation_replay_receipt(entry)
      stored = entry["receipt"]
      return nil unless stored.is_a?(Hash)

      replay = stored.dup
      replay["mutation"] = {
        "id" => entry["id"],
        "request_hash" => entry["request_hash"],
        "replayed" => true
      }
      replay["idempotent"] = true
      replay["journal_status"] = "replayed"
      replay
    end

    def fresh_mutation_info(id, request_hash)
      {
        "id" => id,
        "request_hash" => request_hash,
        "replayed" => false
      }
    end

    def journalize_mutation(envelope, model, status, receipt,
                            before_fp: nil, after_fp: nil)
      raw = envelope["mutation"]
      return receipt if raw.nil?

      before = before_fp
      after = after_fp
      unless receipt.nil?
        before = receipt.dig("model", "before", "model_fingerprint") if before.nil?
        if after.nil?
          after = receipt.dig("model", "after", "model_fingerprint")
          after = receipt.dig("model", "after_rollback", "model_fingerprint") if after.nil?
        end
      end
      journal_store(raw["id"], raw["request_hash"], envelope["action"], status,
                    receipt, model.guid.to_s, before, after)
      unless receipt.nil?
        receipt["mutation"] = fresh_mutation_info(raw["id"], raw["request_hash"])
        receipt["idempotent"] = true
        receipt["journal_status"] = "stored"
      end
      receipt
    end

    def mutation_check(envelope, model)
      raw = envelope["mutation"]
      return nil if raw.nil?

      unless raw.is_a?(Hash)
        raise BridgeError.new("invalid_argument", "mutation must be an object")
      end
      id = raw["id"]
      claimed = raw["request_hash"]
      unless id.is_a?(String) && id.match?(MUTATION_ID_RE)
        raise BridgeError.new("invalid_argument", "mutation.id must be hex32")
      end
      unless claimed.is_a?(String) && claimed.match?(MUTATION_HASH_RE)
        raise BridgeError.new(
          "invalid_argument", "mutation.request_hash must be sha256 hex")
      end
      action = envelope["action"]
      expected = mutation_request_hash(action, envelope)
      unless secure_compare(claimed, expected)
        raise BridgeError.new(
          "mutation_hash_mismatch",
          "mutation.request_hash does not match the canonical request")
      end
      entry = journal_lookup(id, model.guid.to_s)
      return nil if entry.nil?

      unless secure_compare(entry["request_hash"], claimed)
        raise BridgeError.new(
          "mutation_id_reuse",
          "mutation.id was already used for a different request")
      end
      replay = mutation_replay_receipt(entry)
      return replay unless replay.nil?

      raise BridgeError.new(
        "mutation_unknown",
        "mutation was journaled without a stored receipt; reconcile state")
    end

    def resolve_reconcile_entity(model, persistent_id)
      begin
        require_entity_by_pid(model, persistent_id)
      rescue BridgeError
        nil
      end
    end

    def reconcile_entity_proof(model, wanted)
      return true if wanted.nil?
      return false unless wanted.is_a?(Hash)

      proof = true
      wanted.each do |pid_key, wanted_fp|
        pid = nil
        begin
          pid = Integer(pid_key)
        rescue ArgumentError, TypeError
          pid = nil
        end
        entity = pid.nil? ? nil : resolve_reconcile_entity(model, pid)
        if entity.nil?
          proof = false
          break
        end
        state = semantic_entity_state(model, entity)
        if state["semantic_fingerprint"] != wanted_fp
          proof = false
          break
        end
      end
      proof
    end

    def reconcile_proof_matches(model, expect_post)
      return true if expect_post.nil?
      return false unless expect_post.is_a?(Hash)

      snapshot = semantic_active_entity_snapshot(model)
      fingerprint = semantic_model_fingerprint(model, active_snapshot: snapshot)
      if expect_post.key?("model_fingerprint")
        return false unless expect_post["model_fingerprint"] == fingerprint
      end
      reconcile_entity_proof(model, expect_post["entity_fingerprints"])
    end

  end
end
