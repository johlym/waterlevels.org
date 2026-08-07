require "test_helper"

module Usgs
  class HourlyRequestBudgetTest < ActiveSupport::TestCase
    setup do
      @previous_cache = Rails.cache
      Rails.cache = ActiveSupport::Cache::MemoryStore.new
      @previous_soft_cap = ENV["USGS_HOURLY_SOFT_CAP"]
      begin
        Redis.new(RedisConfig.options).ping
      rescue Redis::BaseError
        skip "Redis unavailable"
      end
      HourlyRequestBudget.clear_all!
    end

    teardown do
      HourlyRequestBudget.clear_all!
      Rails.cache = @previous_cache
      if @previous_soft_cap.nil?
        ENV.delete("USGS_HOURLY_SOFT_CAP")
      else
        ENV["USGS_HOURLY_SOFT_CAP"] = @previous_soft_cap
      end
    end

    test "record! increments used and remaining tracks the hourly limit" do
      travel_to Time.utc(2026, 8, 7, 15, 20, 0) do
        assert_equal 0, HourlyRequestBudget.used("history_1")
        assert_equal 1000, HourlyRequestBudget.remaining("history_1")

        3.times { HourlyRequestBudget.record!("history_1") }

        assert_equal 3, HourlyRequestBudget.used("history_1")
        assert_equal 997, HourlyRequestBudget.remaining("history_1")
        refute HourlyRequestBudget.exhausted?("history_1")
      end
    end

    test "soft-cap opens the rate limit circuit and blocks further calls" do
      ENV["USGS_HOURLY_SOFT_CAP"] = "3"
      travel_to Time.utc(2026, 8, 7, 15, 20, 0) do
        3.times { HourlyRequestBudget.record!("history_2") }

        assert HourlyRequestBudget.exhausted?("history_2")
        assert RateLimitCircuit.open?("history_2")
        assert_raises(Client::RateLimitError) do
          HourlyRequestBudget.raise_if_exhausted!("history_2")
        end
      end
    end

    test "dashboard_snapshot reports tip history and pool totals" do
      previous = {
        "USGS_API_KEY" => ENV["USGS_API_KEY"],
        "USGS_API_HISTORY_1_KEY" => ENV["USGS_API_HISTORY_1_KEY"],
        "USGS_API_HISTORY_2_KEY" => ENV["USGS_API_HISTORY_2_KEY"]
      }
      ENV["USGS_API_KEY"] = "tip-key"
      ENV["USGS_API_HISTORY_1_KEY"] = "hist-1"
      ENV["USGS_API_HISTORY_2_KEY"] = "hist-2"

      travel_to Time.utc(2026, 8, 7, 15, 20, 0) do
        2.times { HourlyRequestBudget.record!(RateLimitCircuit::TIP_KEY) }
        5.times { HourlyRequestBudget.record!("history_1") }

        snap = HourlyRequestBudget.dashboard_snapshot
        assert_equal "2026080715", snap[:hour]
        assert_equal 2, snap[:tip][:used]
        assert_equal 998, snap[:tip][:remaining]
        hist1 = snap[:history_keys].find { |row| row[:key] == "history_1" }
        assert_equal 5, hist1[:used]
        assert_equal 5, snap[:history_pool][:used]
        assert_equal 2000, snap[:history_pool][:budget]
        assert_equal 1995, snap[:history_pool][:remaining]
        refute snap[:history_pool][:fallback_to_tip]
      end
    ensure
      previous.each do |key, value|
        value.nil? ? ENV.delete(key) : ENV[key] = value
      end
    end
  end
end
