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
          status = "rolled_back"
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
