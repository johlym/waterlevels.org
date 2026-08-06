module Admin
  # Shared HTTP Basic credentials for /admin and /admin/sidekiq.
  module HttpBasic
    REALM = "WaterLevels Admin".freeze
    USERNAME = "admin".freeze

    module_function

    def configured?
      ENV["DASHBOARD_PW"].to_s.present?
    end

    def authenticates?(username, password)
      return false unless configured?

      expected_password = ENV.fetch("DASHBOARD_PW")
      user_ok = ActiveSupport::SecurityUtils.secure_compare(
        Digest::SHA256.hexdigest(username.to_s),
        Digest::SHA256.hexdigest(USERNAME)
      )
      password_ok = ActiveSupport::SecurityUtils.secure_compare(
        Digest::SHA256.hexdigest(password.to_s),
        Digest::SHA256.hexdigest(expected_password)
      )
      user_ok && password_ok
    end

    # Rack middleware proc for Sidekiq::Web (and any other mounted apps).
    def rack_authenticate
      lambda do |username, password|
        authenticates?(username, password)
      end
    end
  end
end
