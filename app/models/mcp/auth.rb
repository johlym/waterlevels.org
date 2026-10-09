module Mcp
  # Bearer token plus the Cloudflare front-door header. Either secret unset or
  # too short leaves POST /mcp disabled (404). Comparison matches Admin::Auth:
  # SHA256 hex digests via ActiveSupport::SecurityUtils.secure_compare.
  module Auth
    TOKEN_ENV = "WATERLEVELS_MCP_TOKEN"
    FRONT_DOOR_ENV = "WATERLEVELS_MCP_FRONT_DOOR"
    MIN_TOKEN_BYTES = 32
    MIN_FRONT_DOOR_BYTES = 16
    MAX_HEADER_BYTES = 512
    MAX_AUTHORIZATION_BYTES = MAX_HEADER_BYTES
    BEARER_PATTERN = /\ABearer\s+(\S+)\z/i

    module_function

    def configured?
      token.bytesize >= MIN_TOKEN_BYTES && front_door.bytesize >= MIN_FRONT_DOOR_BYTES
    end

    def token
      ENV[TOKEN_ENV].to_s
    end

    def front_door
      ENV[FRONT_DOOR_ENV].to_s
    end

    # Caller must reject oversized Authorization headers first so this never
    # hashes them.
    def bearer_matches?(authorization)
      return false unless configured?

      provided = bearer_credential(authorization)
      return false if provided.nil?

      digest_match?(provided, token)
    end

    # Header value must equal WATERLEVELS_MCP_FRONT_DOOR. Caller must reject
    # oversized headers first so this never hashes them.
    def front_door_matches?(header)
      return false unless configured?

      provided = header.to_s
      return false if provided.empty?

      digest_match?(provided, front_door)
    end

    def bearer_credential(authorization)
      match = authorization.to_s.match(BEARER_PATTERN)
      match && match[1]
    end

    def digest_match?(provided, expected)
      ActiveSupport::SecurityUtils.secure_compare(
        Digest::SHA256.hexdigest(provided),
        Digest::SHA256.hexdigest(expected)
      )
    end
  end
end
