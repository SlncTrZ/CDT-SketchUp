"""Standalone Ruby checks for the mutation journal (no SketchUp needed).
Covers canonical JSON/hash parity vectors are exercised from
tests/test_mutation_identity.py; this file pins journal bound behavior.
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

# Canonical vectors must match the Python side byte-for-byte.
vectors = {
  '{"action":"create_box","expect":{"active_entity_delta":1},"params":{"dimensions":[1,1,1],"name":"B","origin":[0,0,0]},"unit":"in"}' => nil,
  '{"action":"transform_entity","params":{"matrix":[1,0,0,0,0,1,0,0,0,0,1,0,2.5,0,0,1],"persistent_id":7}}' => nil
}
vectors.each_key do |canonical|
  parsed = JSON.parse(canonical)
  rebuilt = server.send(:mutation_canonical_json, parsed)
  check.call("canonical stable #{canonical[0, 40]}", rebuilt == canonical)
end

payload = JSON.parse(vectors.keys.first)
ruby_hash = server.send(:mutation_request_hash, payload["action"], payload)
check.call("hash is sha256 hex", ruby_hash.match?(/\A[0-9a-f]{64}\z/))
puts "VECTOR_HASH=#{ruby_hash}"

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
end
begin
  server.send(:mutation_check, { "action" => "x", "mutation" => { "id" => "bad", "request_hash" => "h" } }, nil)
  check.call("malformed id rejected", false)
rescue CDTSketchUp::BridgeError => e
  check.call("malformed id rejected", e.kind == "invalid_argument")
end

puts "----"
puts "passes=#{failures.empty? ? 'ALL' : 'SOME FAILED'}"
exit(failures.empty? ? 0 : 1)
