module Admin
  # Password gate for /admin and /admin/sidekiq. Password comes from DASHBOARD_PW.
  module Auth
    SESSION_KEY = :admin_authenticated
    # Fingerprint so rotating DASHBOARD_PW invalidates existing sessions.
    SESSION_TOKEN_KEY = :admin_password_digest

    module_function

    def configured?
      ENV["DASHBOARD_PW"].to_s.present?
    end

    def authenticates?(password)
      return false unless configured?

      expected = ENV.fetch("DASHBOARD_PW")
      ActiveSupport::SecurityUtils.secure_compare(
        Digest::SHA256.hexdigest(password.to_s),
        Digest::SHA256.hexdigest(expected)
      )
    end

    def password_digest
      return unless configured?

      Digest::SHA256.hexdigest(ENV.fetch("DASHBOARD_PW"))
    end

    def sign_in(session)
      session[SESSION_KEY] = true
      session[SESSION_TOKEN_KEY] = password_digest
    end

    def sign_out(session)
      session.delete(SESSION_KEY)
      session.delete(SESSION_TOKEN_KEY)
    end

    def signed_in?(session)
      return false unless configured?
      return false unless session[SESSION_KEY]
      return false unless session[SESSION_TOKEN_KEY].present?

      ActiveSupport::SecurityUtils.secure_compare(
        session[SESSION_TOKEN_KEY].to_s,
        password_digest.to_s
      )
    end
  end
end
