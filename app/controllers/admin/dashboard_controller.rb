module Admin
  class DashboardController < ApplicationController
    # Test uses null_store, which cannot count attempts; keep a MemoryStore for
    # the suite. Elsewhere prefer Rails.cache (Redis in production) so limits
    # are shared across dynos.
    RATE_LIMIT_STORE = ActiveSupport::Cache::MemoryStore.new
    RATE_LIMIT_TO = 10
    RATE_LIMIT_WITHIN = 3.minutes

    before_action :ensure_dashboard_configured
    rate_limit to: RATE_LIMIT_TO,
               within: RATE_LIMIT_WITHIN,
               store: (Rails.env.test? ? RATE_LIMIT_STORE : Rails.cache)
    before_action :authenticate_dashboard

    def show
      response.set_header("Cache-Control", "private, no-store")
      @stats = AdminDashboardStats.snapshot
    end

    private

    def enable_session?
      # HTTP Basic does not need a Rails session, but keep CSRF meta off and
      # ensure nothing about this response is treated as publicly cacheable.
      false
    end

    def ensure_dashboard_configured
      return if Admin::HttpBasic.configured?

      head :not_found
    end

    def authenticate_dashboard
      authenticate_or_request_with_http_basic(Admin::HttpBasic::REALM) do |username, password|
        Admin::HttpBasic.authenticates?(username, password)
      end
    end
  end
end
