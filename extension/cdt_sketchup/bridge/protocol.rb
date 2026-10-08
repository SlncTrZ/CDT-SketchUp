# cdt_sketchup/bridge/protocol.rb — wire framing and error envelopes
# Wing: code | Topic: sketchup_bridge | Updated: 2026-09-12

module CDTSketchUp
  class BridgeServer
    private

    def read_client(socket, state)
      chunk = socket.read_nonblock(READ_CHUNK_BYTES, exception: false)
      return if chunk == :wait_readable

      if chunk.nil?
        close_client(socket)
        return
      end

      state[:input] << chunk
      if state[:input].bytesize > MAX_FRAME_BYTES
        queue_error(state, nil, "frame_too_large", "Bridge request exceeds maximum size")
        return
      end

      newline_index = state[:input].index("\n")
      return unless newline_index

      frame = state[:input].byteslice(0, newline_index)
      trailing = state[:input].byteslice(newline_index + 1, state[:input].bytesize) || "".b
      if trailing.bytesize.positive?
        queue_error(state, nil, "invalid_request", "Only one request is allowed per connection")
        return
      end

      response = process_frame(frame)
      queue_response(state, response)
    rescue IO::WaitReadable
      nil
    rescue EOFError, IOError, SystemCallError
      close_client(socket)
    end

    def flush_client(socket, state)
      if state[:output].empty?
        close_client(socket)
        return
      end

      written = socket.write_nonblock(state[:output], exception: false)
      return if written == :wait_writable

      state[:output] = state[:output].byteslice(written, state[:output].bytesize) || "".b
      close_client(socket) if state[:output].empty?
    rescue IO::WaitWritable
      nil
    rescue IOError, SystemCallError
      close_client(socket)
    end

    def queue_response(state, payload)
      encoded = JSON.generate(payload).encode(Encoding::UTF_8) + "\n"
      if encoded.bytesize > MAX_FRAME_BYTES
        encoded = JSON.generate(
          response_error(payload["request_id"], "response_too_large", "Bridge response exceeds maximum size")
        ) + "\n"
      end
      state[:output] = encoded.b
      state[:processed] = true
    end

    def queue_error(state, request_id, kind, message)
      queue_response(state, response_error(request_id, kind, message))
    end

    def response_error(request_id, kind, message)
      {
        "protocol" => PROTOCOL_VERSION,
        "request_id" => request_id,
        "ok" => false,
        "error" => {
          "kind" => kind,
          "message" => message
        }
      }
    end

    def secure_compare(left, right)
      return false unless left.is_a?(String) && right.is_a?(String)
      return false unless left.bytesize == right.bytesize

      mismatch = 0
      left.bytes.zip(right.bytes) { |a, b| mismatch |= (a ^ b) }
      mismatch.zero?
    end
  end
end
