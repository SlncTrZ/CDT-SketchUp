# cdt_sketchup/queries/recovery.rb — read-only mutation reconciliation query
# Wing: code | Topic: sketchup_recovery | Updated: 2026-09-18

module CDTSketchUp
  class BridgeServer
    private

    def handle_mutation_reconcile(params)
      started_at = monotonic_now
      model = require_model
      mid = params["mutation_id"]
      unless mid.is_a?(String) && mid.match?(MUTATION_ID_RE)
        raise BridgeError.new(
          "invalid_argument", "mutation_id must be hex32")
      end
      entry = journal_lookup(mid, model.guid.to_s)
      snapshot = semantic_active_entity_snapshot(model)
      fingerprint = semantic_model_fingerprint(model, active_snapshot: snapshot)
      context = receipt_context(model, model_fingerprint: fingerprint)
      before = params["before"]
      expect_post = params["expect_post"]
      if params.key?("expect_post") && !expect_post.nil?
        unless expect_post.is_a?(Hash) &&
               (expect_post.key?("model_fingerprint") || expect_post.key?("entity_fingerprints")) &&
               !expect_post.empty?
          raise BridgeError.new(
            "invalid_argument",
            "expect_post must be a non-empty Hash containing model_fingerprint or entity_fingerprints"
          )
        end
        if expect_post.key?("model_fingerprint")
          unless expect_post["model_fingerprint"].is_a?(String) && !expect_post["model_fingerprint"].empty?
            raise BridgeError.new("invalid_argument", "model_fingerprint must be non-empty string")
          end
        end
        if expect_post.key?("entity_fingerprints")
          unless expect_post["entity_fingerprints"].is_a?(Hash) && !expect_post["entity_fingerprints"].empty?
            raise BridgeError.new("invalid_argument", "entity_fingerprints must be non-empty hash")
          end
        end
      end
      before_matches = false
      if before.is_a?(Hash) && before["context"].is_a?(Hash)
        before_matches = before["model_fingerprint"] == fingerprint &&
          before["context"]["revision"] == context["revision"]
      end
      status = "diverged_unknown"
      receipt = nil
      unless entry.nil?
        receipt = entry["receipt"]
        if entry["status"] == "committed"
          status = "committed"
        elsif entry["status"] == "rolled_back"
          if receipt.is_a?(Hash) && receipt["rollback_verified"] == true
            status = "rolled_back"
          end
        elsif entry["status"] == "unknown_commit"
          if !expect_post.nil? && reconcile_proof_matches(model, expect_post)
            status = "committed"
          elsif before_matches
            status = "not_started"
          end
        end
      end
      if entry.nil?
        if before_matches
          status = "not_started"
        elsif !expect_post.nil? && reconcile_proof_matches(model, expect_post)
          status = "committed_but_receipt_lost"
        end
      end
      {
        "mutation_id" => mid,
        "status" => status,
        "retryable" => false,
        "journal" => entry.nil? ? "miss" : entry["status"],
        "receipt" => receipt,
        "current" => {
          "model_fingerprint" => fingerprint,
          "context_revision" => context["revision"]
        },
        "checked_at_ms" => receipt_duration_ms(started_at)
      }
    end
  end
end
