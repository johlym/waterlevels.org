class ApplicationController < ActionController::Base
  include MarkdownForAgents

  # Only allow modern browsers supporting webp images, web push, badges, import maps, CSS nesting, and CSS :has.
  # Markdown-preferring agents are not browsers; skip the 406 gate so they can negotiate.
  allow_browser versions: :modern, unless: :markdown_request?

  # Public HTML is meant to be edge-cached. Loading the Rails session writes
  # `_waterlevels_session`, and Cloudflare treats Set-Cookie as BYPASS. Skip the
  # session unless a controller opts in (contact form CSRF + flash today).
  # First-party `/api/*` JSON is Redis-cached and returned private/no-store.
  before_action :skip_session_unless_needed

  helper_method :csrf_meta_tags_enabled?

  # Changes to the importmap will invalidate the etag for HTML responses
  # stale_when_importmap_changes

  private

  def skip_session_unless_needed
    request.session_options[:skip] = true unless enable_session?
  end

  def enable_session?
    false
  end

  def csrf_meta_tags_enabled?
    enable_session?
  end
end
