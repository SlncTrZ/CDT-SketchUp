# CDT-SketchUp Live Bridge — thin entry point; implementation lives in modules.
# Wing: code | Topic: sketchup_bridge | Updated: 2026-09-12

require "sketchup.rb"
require "socket"
require "json"
require "digest"
require "securerandom"
require "fileutils"

module CDTSketchUp
require_relative "kernel/errors"
require_relative "kernel/limits"
require_relative "kernel/primitives"
require_relative "kernel/units"
require_relative "kernel/registry"
require_relative "kernel/transaction"
require_relative "kernel/context"
require_relative "kernel/entity_resolver"
require_relative "kernel/semantic_state"
require_relative "kernel/fingerprints"
require_relative "kernel/expectations"
require_relative "kernel/receipts"
require_relative "bridge/server"
require_relative "bridge/protocol"
require_relative "bridge/auth"
require_relative "bridge/client_state"
require_relative "actions/geometry"
require_relative "actions/transform"
require_relative "actions/boolean"
require_relative "actions/object"
require_relative "actions/component"
require_relative "actions/material"
require_relative "actions/asset"
require_relative "actions/camera"
require_relative "actions/scene"
require_relative "actions/document"
require_relative "queries/entity"
require_relative "queries/topology"
require_relative "queries/measurement"
require_relative "queries/integrity"

  unless file_loaded?(__FILE__)
    @bridge_server = BridgeServer.new

    menu = UI.menu("Extensions").add_submenu("CDT-SketchUp")
    menu.add_item("Start Bridge") { @bridge_server.start }
    menu.add_item("Stop Bridge") { @bridge_server.stop }
    menu.add_item("Bridge Status") do
      UI.messagebox(@bridge_server.running? ? "CDT-SketchUp bridge is running." : "CDT-SketchUp bridge is stopped.")
    end

    @bridge_server.start
    file_loaded(__FILE__)
  end
end
