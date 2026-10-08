class McpController < ApplicationController
  include CacheableResponse

  RATE_LIMIT_TO = 60
  RATE_LIMIT_WITHIN = 1.minute
  RATE_LIMIT_STORE = ActiveSupport::Cache::MemoryStore.new

  skip_forgery_protection

  before_action :require_mcp_auth
  rate_limit to: RATE_LIMIT_TO,
             within: RATE_LIMIT_WITHIN,
             by: -> { request.remote_ip },
             store: (Rails.env.test? ? RATE_LIMIT_STORE : Rails.cache),
             with: -> { rate_limited! }
  after_action :cache_private!

  def create
    return method_not_allowed unless request.post?

    parsed = Mcp::Server.parse(request.raw_post)
    return render_outcome(parsed) if parsed.is_a?(Mcp::Server::Outcome)

    if parsed.tool_call?
      return too_many_tools(parsed.id) unless Mcp::Inflight.try_acquire

      begin
        render_outcome(Mcp::Server.handle(parsed))
      ensure
        Mcp::Inflight.release
      end
    else
      render_outcome(Mcp::Server.handle(parsed))
    end
  end

  private

  def require_mcp_auth
    unless Mcp::Auth.configured?
      cache_private!
      head :not_found
      return
    end

    header = request.get_header("HTTP_AUTHORIZATION").to_s
    if header.bytesize > Mcp::Auth::MAX_AUTHORIZATION_BYTES
      cache_private!
      head :unauthorized
      return
    end

    return if Mcp::Auth.bearer_matches?(header)

    response.set_header("WWW-Authenticate", "Bearer")
    cache_private!
    head :unauthorized
  end

  def rate_limited!
    cache_private!
    head :too_many_requests
  end

  def method_not_allowed
    response.set_header("Allow", "POST")
    cache_private!
    head :method_not_allowed
  end

  def too_many_tools(id)
    cache_private!
    render json: Mcp::Server.busy_body(id), status: :too_many_requests
  end

  def render_outcome(outcome)
    if outcome.empty?
      head outcome.status
    else
      render json: outcome.body, status: outcome.status
    end
  end
end
