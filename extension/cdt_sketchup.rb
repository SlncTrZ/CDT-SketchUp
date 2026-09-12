# CDT-SketchUp Extension Loader — Registers the live bridge extension.
# Wing: code | Topic: sketchup_bridge | Updated: 2026-09-09 19:02

require "sketchup.rb"
require "extensions.rb"

module CDTSketchUp
  unless file_loaded?(__FILE__)
    extension = SketchupExtension.new(
      "CDT-SketchUp Bridge",
      "cdt_sketchup/main"
    )
    extension.description = "Typed loopback bridge for the CDT-SketchUp MCP provider."
    extension.version = "0.1.0"
    extension.creator = "SlncTrZ"
    Sketchup.register_extension(extension, true)
    file_loaded(__FILE__)
  end
end
