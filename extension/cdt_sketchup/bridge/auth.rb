# cdt_sketchup/bridge/auth.rb — per-user bridge credential
# Wing: code | Topic: sketchup_bridge | Updated: 2026-09-12

module CDTSketchUp
  class BridgeServer
    private

    def load_or_create_token
      path = token_path
      if File.file?(path)
        token = File.read(path, encoding: "UTF-8").strip
        return token if token.length >= 32
      end

      FileUtils.mkdir_p(File.dirname(path))
      token = SecureRandom.hex(32)
      temp_path = "#{path}.tmp-#{Process.pid}"
      File.open(temp_path, File::WRONLY | File::CREAT | File::TRUNC, 0o600) do |file|
        file.write(token)
        file.write("\n")
      end
      begin
        File.chmod(0o600, temp_path)
      rescue SystemCallError, NotImplementedError
        nil
      end
      File.rename(temp_path, path)
      token
    ensure
      begin
        File.delete(temp_path) if defined?(temp_path) && temp_path && File.exist?(temp_path)
      rescue SystemCallError
        nil
      end
    end

    def token_path
      configured = ENV["CDT_SKETCHUP_BRIDGE_TOKEN_FILE"]
      return File.expand_path(configured) if configured && !configured.empty?

      local_app_data = ENV["LOCALAPPDATA"]
      if local_app_data && !local_app_data.empty?
        File.join(local_app_data, "CDT-SketchUp", "bridge.token")
      else
        File.join(Dir.home, ".cdt-sketchup", "bridge.token")
      end
    end
  end
end
