ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"
require "rails/test_help"
require "rake"
require "webmock/minitest"

module ActiveSupport
  class TestCase
    include FactoryBot::Syntax::Methods

    parallelize(workers: :number_of_processors)

    parallelize_setup do |_worker|
      # Drop forked Redis clients so each worker reconnects with its isolated DB
      # (see RedisConfig.isolate_test_worker_db / parallel_worker_id).
      eigen = AdminDashboardStats.singleton_class
      eigen.remove_instance_variable(:@redis) if eigen.instance_variable_defined?(:@redis)
      EdgeCachePurgeBuffer.reset!
    end

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
