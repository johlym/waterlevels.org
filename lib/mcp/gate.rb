module Mcp
  # Rack gate for POST /mcp. Rejects before the rest of the stack and never
  # reads rack.input. Authenticated requests fall through to McpController.
  class Gate
    PATH = "/mcp"
    MAX_BODY_BYTES = 16 * 1024

    def initialize(app)
      @app = app
    end

    def call(env)
      return @app.call(env) unless env["PATH_INFO"] == PATH
      return finish(404) unless Mcp::Auth.configured?

      front_door = env["HTTP_X_BLUE_ALPHA_SPOOKY"].to_s
      authorization = env["HTTP_AUTHORIZATION"].to_s
      # Length checks happen before any digest so an oversized header is never hashed.
      return finish(404) if front_door.bytesize > Mcp::Auth::MAX_HEADER_BYTES
      if authorization.bytesize > Mcp::Auth::MAX_AUTHORIZATION_BYTES
        return finish(401, "www-authenticate" => "Bearer")
      end
      return finish(404) unless Mcp::Auth.front_door_matches?(front_door)
      unless Mcp::Auth.bearer_matches?(authorization)
        return finish(401, "www-authenticate" => "Bearer")
      end

      length = content_length_state(env["CONTENT_LENGTH"])
      return finish(413) if length == :too_large

      if env["REQUEST_METHOD"] == "POST"
        return finish(411) if length == :missing || length == :invalid
        return finish(415) unless json_content_type?(env["CONTENT_TYPE"])
      end

      @app.call(env)
    end

    private

    def content_length_state(raw)
      return :missing if raw.nil? || (raw.is_a?(String) && raw.empty?)

      string = raw.is_a?(Integer) ? raw.to_s : raw
      return :invalid unless string.is_a?(String) && string.match?(/\A\d+\z/)

      value = Integer(string, 10)
      value > MAX_BODY_BYTES ? :too_large : value
    end

    def json_content_type?(value)
      media, *params = value.to_s.split(";").map(&:strip)
      return false unless media&.casecmp("application/json")&.zero?

      params.all? { |part| part.match?(/\Acharset\s*=\s*\S+\z/i) }
    end

    def finish(status, extra = {})
      headers = {
        "content-type" => "application/json; charset=utf-8",
        "cache-control" => "private, no-store"
      }.merge(extra)
      [ status, headers, [] ]
    end
  end
end
