ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"
require "rails/test_help"
require "rake"
require "webmock/minitest"

module ActiveSupport
  class TestCase
    include FactoryBot::Syntax::Methods

    parallelize(workers: :number_of_processors)

    setup do
      @previous_turnstile_secret = ENV.delete("TURNSTILE_SECRET")
      WebMock.disable_net_connect!(allow_localhost: true)
    end

    teardown do
      if @previous_turnstile_secret
        ENV["TURNSTILE_SECRET"] = @previous_turnstile_secret
      else
        ENV.delete("TURNSTILE_SECRET")
      end
    end
  end
end

module ActionDispatch
  class IntegrationTest
    include FactoryBot::Syntax::Methods
  end
end
