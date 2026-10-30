ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"
require "rails/test_help"
require "rake"
require "webmock/minitest"
require "prosopite/minitest"
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
      AdminCounter.bust_request_cache!
    end

    # Registered after fixtures and the setup above, so each example is its own
    # scan and fixture load stays outside it. Teardown runs in reverse, so the
    # coverage flush runs before Prosopite.finish, and finish runs before the
    # cleanup teardown above.
    setup { Prosopite.scan("#{self.class}##{name}") }
    teardown { Prosopite.finish }
    teardown { TimeSeries.flush_coverage_refresh! }

    # Rails.application.load_tasks re-loads every .rake file and appends another
    # action each call. A second invoke in the same process then runs the task
    # twice, which Prosopite reports as an N+1. The flag lives on this class,
    # not the example's subclass, so every example in the process shares it.
    def load_rake_tasks_once!
      return if ActiveSupport::TestCase.rake_tasks_loaded

      Rails.application.load_tasks
      ActiveSupport::TestCase.rake_tasks_loaded = true
    end

    class << self
      attr_accessor :rake_tasks_loaded
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
      attrs = TimeSeries.coverage_attributes_for(series.id)
      if attrs
        series.assign_attributes(attrs)
        series.clear_changes_information
      else
        series.reload
      end
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
