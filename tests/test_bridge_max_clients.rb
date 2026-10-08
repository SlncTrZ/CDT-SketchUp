# tests/test_bridge_max_clients.rb — standalone resource-containment test (SKP-R05 / B3)
#
# Runs on plain Windows Ruby (no SketchUp, no live TCP, never touches 127.0.0.1:9876).
# Loads ONLY the real bridge files under test:
#   extension/cdt_sketchup/bridge/server.rb
#   extension/cdt_sketchup/bridge/client_state.rb
#   extension/cdt_sketchup/bridge/protocol.rb
# plus fakes for the listener socket, client sockets, clock, and log sink.
#
# Preserved-behavior guards (must hold before AND after the fix):
#   MAX_CLIENTS=8, MAX_ACCEPTS_PER_TICK=4, frame bound, one-request-per-connection,
#   idle cleanup (CLIENT_IDLE_SECONDS), disconnect path, burst bound.
# Gap under test (RED before fix, GREEN after):
#   admission must enforce the active-client cap — newcomer rejected/closed with
#   control (not added to @clients, tick loop survives).
#
# Usage: ruby tests/test_bridge_max_clients.rb

require "json"
require "securerandom"

BRIDGE_DIR = File.expand_path("../../extension/cdt_sketchup/bridge", __FILE__)

module CDTSketchUp
  class BridgeServer
  end
end

load File.join(BRIDGE_DIR, "server.rb")
load File.join(BRIDGE_DIR, "client_state.rb")
load File.join(BRIDGE_DIR, "protocol.rb")

# ---- controllable clock + silent log (bridge internals call these) ----
$fake_now = 1_000.0
$logs = []
class CDTSketchUp::BridgeServer
  def monotonic_now
    $fake_now
  end

  def log(message)
    $logs << message
    nil
  end
end

# ---- fakes ----
class FakeBridgeListener
  def initialize(sockets)
    @queue = sockets.dup
  end

  def accept_nonblock(exception: false)
    return :wait_readable if @queue.empty?

    @queue.shift
  end

  def pending
    @queue.size
  end
end

class FakeBridgeSocket
  attr_reader :close_calls

  def initialize(read_script: [:wait_readable])
    @read_script = read_script.dup
    @closed = false
    @close_calls = 0
    @written = +"".b
  end

  def closed?
    @closed
  end

  def close
    @close_calls += 1
    @closed = true
    nil
  end

  def read_nonblock(_size, exception: false)
    return nil if @closed
    return :wait_readable if @read_script.empty?

    @read_script.shift
  end

  def write_nonblock(data, exception: false)
    @written << data
    data.bytesize
  end

  def written
    @written
  end
end

class FlakyCloseSocket < FakeBridgeSocket
  def close
    raise IOError, "simulated close failure"
  end
end

# ---- tiny harness (no gems) ----
class AssertError < StandardError; end

$passes = 0
$failures = []

def assert(condition, message)
  raise AssertError, message unless condition
end

def check(name)
  yield
  $passes += 1
  puts "PASS: #{name}"
rescue AssertError => error
  $failures << name
  puts "FAIL: #{name} -- #{error.message}"
rescue StandardError => error
  $failures << name
  puts "ERROR: #{name} -- #{error.class}: #{error.message}"
end

def new_server_with(listener)
  server = CDTSketchUp::BridgeServer.new(port: 19_876)
  server.instance_variable_set(:@server, listener)
  server
end

def slow_state
  { input: +"".b, output: +"".b, opened_at: $fake_now, processed: false }
end

def clients_of(server)
  server.instance_variable_get(:@clients)
end

CAP = CDTSketchUp::BridgeServer::MAX_CLIENTS
BURST = CDTSketchUp::BridgeServer::MAX_ACCEPTS_PER_TICK
IDLE = CDTSketchUp::BridgeServer::CLIENT_IDLE_SECONDS
FRAME = CDTSketchUp::BridgeServer::MAX_FRAME_BYTES

puts "constants: MAX_CLIENTS=#{CAP} MAX_ACCEPTS_PER_TICK=#{BURST} " \
     "CLIENT_IDLE_SECONDS=#{IDLE} MAX_FRAME_BYTES=#{FRAME}"

# ---- preserved-behavior guards ----
check("constants match the documented containment contract") do
  assert(CAP == 8, "MAX_CLIENTS=#{CAP}, expected 8")
  assert(BURST == 4, "MAX_ACCEPTS_PER_TICK=#{BURST}, expected 4")
  assert(IDLE == 5.0, "CLIENT_IDLE_SECONDS=#{IDLE}, expected 5.0")
  assert(FRAME == 256 * 1024, "MAX_FRAME_BYTES=#{FRAME}, expected 262144")
end

check("burst bound: one tick admits at most MAX_ACCEPTS_PER_TICK") do
  sockets = Array.new(10) { FakeBridgeSocket.new }
  server = new_server_with(FakeBridgeListener.new(sockets))
  server.send(:accept_clients)
  assert(clients_of(server).size == BURST, "admitted #{clients_of(server).size}, expected #{BURST}")
  assert(server.instance_variable_get(:@server).pending == 6, "listener should still hold 6 pending")
end

# ---- gap under test ----
check("cap: N slow clients + newcomer => newcomer rejected, not tracked") do
  actives = Array.new(CAP) { FakeBridgeSocket.new }
  newcomer = FakeBridgeSocket.new
  server = new_server_with(FakeBridgeListener.new([newcomer]))
  actives.each { |socket| clients_of(server)[socket] = slow_state }
  server.send(:accept_clients)
  assert(clients_of(server).size == CAP, "tracked #{clients_of(server).size}, expected cap #{CAP}")
  assert(!clients_of(server).key?(newcomer), "newcomer must NOT be added to @clients at cap")
  assert(newcomer.closed?, "newcomer must be closed in a controlled reject")
end

check("cap: tick loop survives a newcomer whose close raises") do
  $logs.clear
  actives = Array.new(CAP) { FakeBridgeSocket.new }
  flaky = FlakyCloseSocket.new
  server = new_server_with(FakeBridgeListener.new([flaky]))
  actives.each { |socket| clients_of(server)[socket] = slow_state }
  server.send(:tick) # must not raise
  assert(clients_of(server).size == CAP, "tracked #{clients_of(server).size}, expected cap #{CAP}")
  assert(!clients_of(server).key?(flaky), "flaky newcomer must NOT be tracked")
  assert(actives.all? { |socket| clients_of(server).key?(socket) }, "existing slow clients must be intact")
end

check("slot reuse: after cleanup a newcomer is admitted again") do
  actives = Array.new(CAP) { FakeBridgeSocket.new }
  newcomer = FakeBridgeSocket.new
  server = new_server_with(FakeBridgeListener.new([]))
  actives.each { |socket| clients_of(server)[socket] = slow_state }
  server.send(:close_client, actives.first)
  assert(clients_of(server).size == CAP - 1, "expected one freed slot")
  server.instance_variable_set(:@server, FakeBridgeListener.new([newcomer]))
  server.send(:accept_clients)
  assert(clients_of(server).size == CAP, "expected slot to be refilled to #{CAP}")
  assert(clients_of(server).key?(newcomer), "newcomer must be admitted once a slot is free")
  assert(!newcomer.closed?, "admitted newcomer must stay open")
end

# ---- preserved protocol/idle/disconnect paths ----
check("partial frame stays buffered, unprocessed, connection kept") do
  socket = FakeBridgeSocket.new(read_script: ['{"protocol":1,"part'])
  server = new_server_with(FakeBridgeListener.new([socket]))
  server.send(:tick)
  state = clients_of(server)[socket]
  assert(!socket.closed?, "slow/partial client must stay connected")
  assert(state && !state[:processed], "partial frame must not be marked processed")
  assert(state[:input].bytesize.positive?, "partial bytes must remain buffered")
  assert(state[:output].empty?, "no response may be queued for a partial frame")
end

check("one-request-per-connection: pipelined second frame is refused") do
  socket = FakeBridgeSocket.new(read_script: ["{}\nextra"])
  server = new_server_with(FakeBridgeListener.new([socket]))
  server.send(:tick) # accept + read (queues error) + flush (one-request => close)
  assert(socket.closed?, "pipelined connection must be closed after the error flush")
  assert(!clients_of(server).key?(socket), "pipelined connection must be untracked after close")
  payload = JSON.parse(socket.written.split("\n").first)
  assert(payload["error"] && payload["error"]["kind"] == "invalid_request",
         "expected invalid_request, got #{socket.written.inspect}")
end

check("frame bound: oversized input is refused") do
  socket = FakeBridgeSocket.new(read_script: ["x" * (FRAME + 1)])
  server = new_server_with(FakeBridgeListener.new([socket]))
  server.send(:tick) # accept + read (queues error) + flush (=> close)
  assert(socket.closed?, "oversized connection must be closed after the error flush")
  assert(!clients_of(server).key?(socket), "oversized connection must be untracked after close")
  payload = JSON.parse(socket.written.split("\n").first)
  assert(payload["error"] && payload["error"]["kind"] == "frame_too_large",
         "expected frame_too_large, got #{socket.written.inspect}")
end

check("idle cleanup: stale client evicted, fresh client kept") do
  stale = FakeBridgeSocket.new
  fresh = FakeBridgeSocket.new
  server = new_server_with(FakeBridgeListener.new([]))
  clients_of(server)[stale] = slow_state.merge(opened_at: $fake_now - IDLE - 1.0)
  clients_of(server)[fresh] = slow_state
  server.send(:tick)
  assert(!clients_of(server).key?(stale), "stale client must be evicted")
  assert(stale.closed?, "stale client socket must be closed")
  assert(clients_of(server).key?(fresh), "fresh client must survive idle sweep")
end

check("disconnect path: EOF (nil read) removes and closes the client") do
  socket = FakeBridgeSocket.new(read_script: [nil])
  server = new_server_with(FakeBridgeListener.new([socket]))
  server.send(:tick) # accept + read nil => close, all within one tick
  assert(!clients_of(server).key?(socket), "disconnected client must be removed")
  assert(socket.closed?, "disconnected socket must be closed")
end

puts "----"
puts "passes=#{$passes} failures=#{$failures.size}"
if $failures.empty?
  puts "RESULT: GREEN"
else
  puts "RESULT: RED (#{$failures.join(', ')})"
  exit 1
end
