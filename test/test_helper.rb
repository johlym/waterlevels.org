ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"
require "rails/test_help"
require "rake"
require "webmock/minitest"
Dir[Rails.root.join("test/support/**/*.rb")].each { |f| require f }

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
      AppSetting.delete_all if ActiveRecord::Base.connection.data_source_exists?("app_settings")
      AppConfig.bust!
    end

    # Seed IV points dense enough that interior-gap repair won't re-fetch.
    # Step defaults to 1 hour (under CONTINUOUS_GAP_THRESHOLD).
    def seed_continuous_coverage!(series, from:, to:, step: 1.hour, value: 1.0)
      now = Time.current
      rows = []
      t = from
      while t <= to
        rows << {
          time_series_id: series.id,
          observed_at: t,
          value: value,
          created_at: now,
          updated_at: now
        }
        t += step
      end
      ContinuousObservation.insert_all(rows) if rows.any?
      TimeSeries.refresh_continuous_coverage!([ series.id ])
      series.reload
    end
  end
end


module ActionDispatch
  class IntegrationTest
    include FactoryBot::Syntax::Methods

    def first_party_api_headers
      {
        "X-WaterLevels-Client" => FirstPartyApiRequest::CLIENT_VALUE,
        "Sec-Fetch-Site" => "same-origin"
      }
    end

    def api_get(path, **kwargs)
      headers = kwargs.delete(:headers) || {}
      get path, **kwargs.merge(headers: first_party_api_headers.merge(headers))
    end
  end
end
