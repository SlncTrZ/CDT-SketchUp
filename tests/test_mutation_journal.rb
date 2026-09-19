"""Standalone Ruby checks for the mutation journal (no SketchUp needed).
Covers typed canonical JSON/hash parity vectors shared with
tests/test_mutation_identity.py and journal bound behavior.
"""

require "json"
require "digest"
require "securerandom"

REPO = File.expand_path("..", __dir__)
load File.join(REPO, "extension", "cdt_sketchup", "kernel", "mutation_journal.rb")

# monotonic_now lives in kernel/primitives in the live extension; stub the
# clock here so the journal bounds run without SketchUp.
module CDTSketchUp
  class BridgeServer
    def monotonic_now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end

failures = []
check = lambda do |name, cond|
  puts((cond ? "PASS" : "FAIL") + ": #{name}")
  failures << name unless cond
end

server = CDTSketchUp::BridgeServer.allocate
server.instance_variable_set(:@mutation_journal, {})

# Canonical vectors must match Python byte-for-byte, including values whose
# native JSON float formatting differs between Python and Ruby.
vectors = [
  {
    "raw" => '{"action":"create_box","expect":{"active_entity_delta":1},"params":{"dimensions":[1,1,1],"name":"B","origin":[0,0,0]},"unit":"in"}',
    "canonical" => '["o",[["616374696f6e",["s","6372656174655f626f78"]],["657870656374",["o",[["6163746976655f656e746974795f64656c7461",["i","1"]]]]],["706172616d73",["o",[["64696d656e73696f6e73",["a",[["i","1"],["i","1"],["i","1"]]]],["6e616d65",["s","42"]],["6f726967696e",["a",[["i","0"],["i","0"],["i","0"]]]]]]],["756e6974",["s","696e"]]]]',
    "hash" => "92a81cd784c92befb1be3192f25a4adaaedf851a0999eae0c5b53361ef91c08f"
  },
  {
    "raw" => '{"action":"probe","params":{"values":[1e-7,1e20,-0.0,0.0,0.1,1.2345678901234567]}}',
    "canonical" => '["o",[["616374696f6e",["s","70726f6265"]],["706172616d73",["o",[["76616c756573",["a",[["f","3e7ad7f29abcaf48"],["f","4415af1d78b58c40"],["f","0000000000000000"],["f","0000000000000000"],["f","3fb999999999999a"],["f","3ff3c0ca428c59fb"]]]]]]]]]',
    "hash" => "2b667560010250e46fac27ece9ff5a7ff910d3deda78beae265cbbb6ddc8d593"
  }
]

vectors.each_with_index do |vector, index|
  payload = JSON.parse(vector["raw"])
  rebuilt = server.send(:mutation_canonical_json, payload)
  check.call("canonical vector #{index + 1}", rebuilt == vector["canonical"])
  hash = server.send(:mutation_request_hash, payload["action"], payload)
  check.call("hash vector #{index + 1}", hash == vector["hash"])
end

# Routing/precondition fields are part of logical operation identity.
base = {
  "action" => "create_box",
  "params" => { "origin" => [0, 0, 0], "dimensions" => [1, 1, 1] },
  "if_context" => { "id" => "ctx-a", "revision" => "rev-1" },
  "if_match" => "entity-fp-1",
  "target_context" => { "instance_path" => [11, 22] }
}
base_hash = server.send(:mutation_request_hash, base["action"], base)
changed_context = Marshal.load(Marshal.dump(base))
changed_context["if_context"]["revision"] = "rev-2"
changed_target = Marshal.load(Marshal.dump(base))
changed_target["target_context"]["instance_path"] = [11, 23]
check.call(
  "if_context bound",
  server.send(:mutation_request_hash, base["action"], changed_context) != base_hash
)
check.call(
  "target_context bound",
  server.send(:mutation_request_hash, base["action"], changed_target) != base_hash
)

# Journal bounds: 129 stores keep 128, evict oldest first.
129.times do |i|
  server.send(:journal_store, format("id%030d", i), "h", "a", "committed",
              { "n" => i }, "g", "b", "a")
end
size = server.instance_variable_get(:@mutation_journal).length
check.call("journal bounded to 128 (got #{size})", size == 128)
check.call("oldest evicted", server.send(:journal_lookup, format("id%030d", 0), "g").nil?)
check.call("newest kept", !server.send(:journal_lookup, format("id%030d", 128), "g").nil?)

# Scope: other model guid never replays.
check.call("cross-model miss",
           server.send(:journal_lookup, format("id%030d", 1), "other").nil?)

# Malformed claims raise invalid_argument (needs BridgeError; define a stub).
module CDTSketchUp
  class BridgeError < StandardError
    attr_reader :kind
    def initialize(kind, message)
      @kind = kind
      super(message)
    end
  end

  class BridgeServer
    def secure_compare(left, right)
      left == right
    end
  end
end
begin
  server.send(:mutation_check, { "action" => "x", "mutation" => { "id" => "bad", "request_hash" => "h" } }, nil)
  check.call("malformed id rejected", false)
rescue CDTSketchUp::BridgeError => e
  check.call("malformed id rejected", e.kind == "invalid_argument")
end

# Same stable ID cannot be retargeted by changing routing/precondition fields.
model = Struct.new(:guid).new("g")
stable_id = "ab" * 16
base_hash = server.send(:mutation_request_hash, base["action"], base)
server.send(
  :journal_store,
  stable_id,
  base_hash,
  base["action"],
  "committed",
  { "ok" => true },
  model.guid,
  "before",
  "after"
)
retargeted = Marshal.load(Marshal.dump(base))
retargeted["target_context"]["instance_path"] = [99]
retargeted_hash = server.send(
  :mutation_request_hash,
  retargeted["action"],
  retargeted
)
retargeted["mutation"] = {
  "id" => stable_id,
  "request_hash" => retargeted_hash
}
begin
  server.send(:mutation_check, retargeted, model)
  check.call("same id changed target rejected", false)
rescue CDTSketchUp::BridgeError => e
  check.call("same id changed target rejected", e.kind == "mutation_id_reuse")
end

# Unknown completion must never be replayed as a definitive idempotent receipt.
unknown_entry = {
  "id" => stable_id,
  "request_hash" => base_hash,
  "action" => base["action"],
  "status" => "unknown_commit",
  "receipt" => { "rollback_verified" => false }
}
check.call(
  "unknown completion is not replayable",
  server.send(:mutation_replay_receipt, unknown_entry).nil?
)

puts "----"
puts "passes=#{failures.empty? ? 'ALL' : 'SOME FAILED'}"
exit(failures.empty? ? 0 : 1)
