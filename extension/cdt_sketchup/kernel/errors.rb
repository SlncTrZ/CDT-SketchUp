# cdt_sketchup/kernel/errors.rb — typed bridge errors
# Wing: code | Topic: sketchup_bridge | Updated: 2026-09-12

module CDTSketchUp
  class BridgeError < StandardError
    attr_reader :kind

    def initialize(kind, message)
      super(message)
      @kind = kind
    end
  end
end
