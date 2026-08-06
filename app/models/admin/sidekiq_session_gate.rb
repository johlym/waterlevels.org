module Admin
  # Rack middleware for Sidekiq::Web — requires the same Rails session login
  # used by /admin. Unset DASHBOARD_PW → 404; signed out → redirect to login.
  class SidekiqSessionGate
    def initialize(app)
      @app = app
    end

    def call(env)
      unless Auth.configured?
        return [ 404, { "Content-Type" => "text/plain" }, [ "Not Found" ] ]
      end

      request = ActionDispatch::Request.new(env)
      unless Auth.signed_in?(request.session)
        return [
          302,
          {
            "Location" => "/admin/login",
            "Content-Type" => "text/plain",
            "Cache-Control" => "private, no-store"
          },
          [ "Redirecting to login" ]
        ]
      end

      @app.call(env)
    end
  end
end
