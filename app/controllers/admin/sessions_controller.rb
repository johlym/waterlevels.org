module Admin
  class SessionsController < ApplicationController
    # Test uses null_store, which cannot count attempts; keep a MemoryStore for
    # the suite. Elsewhere prefer Rails.cache (Redis in production) so limits
    # are shared across dynos.
    RATE_LIMIT_STORE = ActiveSupport::Cache::MemoryStore.new
    RATE_LIMIT_TO = 10
    RATE_LIMIT_WITHIN = 3.minutes

    layout "admin"

    before_action :ensure_dashboard_configured
    before_action :set_no_store_headers
    rate_limit to: RATE_LIMIT_TO,
               within: RATE_LIMIT_WITHIN,
               only: :create,
               store: (Rails.env.test? ? RATE_LIMIT_STORE : Rails.cache)
    before_action :redirect_if_signed_in, only: %i[new create]

    def new
    end

    def create
      if Admin::Auth.authenticates?(params[:password])
        Admin::Auth.sign_in(session)
        redirect_to admin_path
      else
        flash.now[:alert] = "Incorrect password."
        render :new, status: :unprocessable_content
      end
    end

    def destroy
      Admin::Auth.sign_out(session)
      redirect_to admin_login_path, notice: "Signed out."
    end

    private

    def enable_session?
      true
    end

    def ensure_dashboard_configured
      return if Admin::Auth.configured?

      head :not_found
    end

    def set_no_store_headers
      response.set_header("Cache-Control", "private, no-store")
    end

    def redirect_if_signed_in
      redirect_to admin_path if Admin::Auth.signed_in?(session)
    end
  end
end
