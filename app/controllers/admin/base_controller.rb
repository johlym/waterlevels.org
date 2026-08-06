module Admin
  class BaseController < ApplicationController
    before_action :ensure_dashboard_configured
    before_action :require_admin_session
    before_action :set_no_store_headers

    private

    def enable_session?
      true
    end

    def ensure_dashboard_configured
      return if Admin::Auth.configured?

      head :not_found
    end

    def require_admin_session
      return if Admin::Auth.signed_in?(session)

      redirect_to admin_login_path, alert: "Sign in to continue."
    end

    def set_no_store_headers
      response.set_header("Cache-Control", "private, no-store")
    end
  end
end
