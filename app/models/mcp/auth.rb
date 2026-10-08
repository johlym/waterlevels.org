module Mcp
  # Bearer check for WATERLEVELS_MCP_TOKEN. Unset or shorter than 32 bytes
  # leaves the endpoint disabled (404). Comparison matches Admin::Auth:
  # SHA256 hex digests via ActiveSupport::SecurityUtils.secure_compare.
  module Auth
    TOKEN_ENV = "WATERLEVELS_MCP_TOKEN"
    MIN_TOKEN_BYTES = 32
    MAX_AUTHORIZATION_BYTES = 512
    BEARER_PATTERN = /\ABearer\s+(\S+)\z/i

    module_function

    def configured?
      token.bytesize >= MIN_TOKEN_BYTES
    end

    def token
      ENV[TOKEN_ENV].to_s
    end

    # Caller must reject oversized Authorization headers first so this never
    # hashes them.
    def bearer_matches?(authorization)
      return false unless configured?

      provided = bearer_credential(authorization)
      return false if provided.nil?

      ActiveSupport::SecurityUtils.secure_compare(
        Digest::SHA256.hexdigest(provided),
        Digest::SHA256.hexdigest(token)
      )
    end

    def bearer_credential(authorization)
      match = authorization.to_s.match(BEARER_PATTERN)
      match && match[1]
    end
  end
end
