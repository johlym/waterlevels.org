module Admin
  class DashboardController < ApplicationController
    before_action :ensure_dashboard_configured
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
      return if ENV["DASHBOARD_PW"].to_s.present?

      head :not_found
    end

    def authenticate_dashboard
      authenticate_or_request_with_http_basic("WaterLevels Admin") do |username, password|
        expected_user = "admin"
        expected_password = ENV.fetch("DASHBOARD_PW")
        user_ok = ActiveSupport::SecurityUtils.secure_compare(
          Digest::SHA256.hexdigest(username.to_s),
          Digest::SHA256.hexdigest(expected_user)
        )
        password_ok = ActiveSupport::SecurityUtils.secure_compare(
          Digest::SHA256.hexdigest(password.to_s),
          Digest::SHA256.hexdigest(expected_password)
        )
        user_ok && password_ok
      end
    end
  end
end
