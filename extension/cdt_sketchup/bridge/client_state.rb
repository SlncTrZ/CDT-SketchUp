# cdt_sketchup/bridge/client_state.rb — connected-client bookkeeping
# Wing: code | Topic: sketchup_bridge | Updated: 2026-09-12

module CDTSketchUp
  class BridgeServer
    private

    def close_client(socket)
      @clients.delete(socket)
      socket.close unless socket.closed?
    rescue IOError, SystemCallError
      nil
    end
  end
end
