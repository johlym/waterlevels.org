require "test_helper"

module Usgs
  class HistoryKeyPoolTest < ActiveSupport::TestCase
    setup do
      @previous_cache = Rails.cache
      Rails.cache = ActiveSupport::Cache::MemoryStore.new
      @previous_env = {
        "USGS_API_KEY" => ENV["USGS_API_KEY"],
        "USGS_API_HISTORY_CONTINUOUS_KEY" => ENV["USGS_API_HISTORY_CONTINUOUS_KEY"],
        "USGS_API_HISTORY_DAILY_KEY" => ENV["USGS_API_HISTORY_DAILY_KEY"],
        "USGS_API_HISTORY_PEAKS_KEY" => ENV["USGS_API_HISTORY_PEAKS_KEY"]
      }
    end

    teardown do
      Rails.cache = @previous_cache
      @previous_env.each do |key, value|
        if value.nil?
          ENV.delete(key)
        else
          ENV[key] = value
        end
      end
    end

    test "falls back to tip key when purpose keys are unset" do
      ENV["USGS_API_KEY"] = "tip-key"
      ENV.delete("USGS_API_HISTORY_CONTINUOUS_KEY")
      ENV.delete("USGS_API_HISTORY_DAILY_KEY")
      ENV.delete("USGS_API_HISTORY_PEAKS_KEY")

      refute HistoryKeyPool.configured?
      entry = HistoryKeyPool.claim!(:continuous)
      assert_equal "tip-key", entry[:api_key]
      assert_equal RateLimitCircuit::TIP_KEY, entry[:circuit_key]
      assert_equal "USGS_API_KEY", entry[:env]
    end

    test "pins each purpose to its own key and circuit" do
      ENV["USGS_API_KEY"] = "tip-key"
      ENV["USGS_API_HISTORY_CONTINUOUS_KEY"] = "hist-continuous"
      ENV["USGS_API_HISTORY_DAILY_KEY"] = "hist-daily"
      ENV["USGS_API_HISTORY_PEAKS_KEY"] = "hist-peaks"

      assert HistoryKeyPool.configured?
      continuous = HistoryKeyPool.claim!(:continuous)
      daily = HistoryKeyPool.claim!(:daily)
      peaks = HistoryKeyPool.claim!(:peaks)

      assert_equal "hist-continuous", continuous[:api_key]
      assert_equal "history_continuous", continuous[:circuit_key]
      assert_equal "hist-daily", daily[:api_key]
      assert_equal "history_daily", daily[:circuit_key]
      assert_equal "hist-peaks", peaks[:api_key]
      assert_equal "history_peaks", peaks[:circuit_key]
    end

    test "claim! raises when that purpose circuit is open" do
      ENV["USGS_API_HISTORY_CONTINUOUS_KEY"] = "hist-continuous"
      ENV["USGS_API_HISTORY_DAILY_KEY"] = "hist-daily"
      RateLimitCircuit.open!(key_id: "history_continuous", ttl: 1.minute)

      assert_raises(Client::RateLimitError) { HistoryKeyPool.claim!(:continuous) }
      refute HistoryKeyPool.exhausted?
      assert HistoryKeyPool.available?(:daily)
      assert_equal "hist-daily", HistoryKeyPool.claim!(:daily)[:api_key]
    end

    test "exhausted? when every purpose circuit is open" do
      ENV["USGS_API_HISTORY_CONTINUOUS_KEY"] = "hist-continuous"
      ENV["USGS_API_HISTORY_DAILY_KEY"] = "hist-daily"
      ENV["USGS_API_HISTORY_PEAKS_KEY"] = "hist-peaks"
      RateLimitCircuit.open!(key_id: "history_continuous", ttl: 1.minute)
      RateLimitCircuit.open!(key_id: "history_daily", ttl: 1.minute)
      RateLimitCircuit.open!(key_id: "history_peaks", ttl: 1.minute)

      assert HistoryKeyPool.exhausted?
      refute HistoryKeyPool.phase1_available?
      refute HistoryKeyPool.deep_available?
    end

    test "tip circuit open does not exhaust a configured history pool" do
      ENV["USGS_API_HISTORY_CONTINUOUS_KEY"] = "hist-continuous"
      ENV["USGS_API_HISTORY_DAILY_KEY"] = "hist-daily"
      ENV["USGS_API_HISTORY_PEAKS_KEY"] = "hist-peaks"
      RateLimitCircuit.open!(key_id: RateLimitCircuit::TIP_KEY, ttl: 1.minute)

      refute HistoryKeyPool.exhausted?
      assert HistoryKeyPool.phase1_available?
      assert HistoryKeyPool.deep_available?
      assert_equal "hist-continuous", HistoryKeyPool.claim!(:continuous)[:api_key]
    end

    test "deep_available? follows the daily circuit" do
      ENV["USGS_API_HISTORY_CONTINUOUS_KEY"] = "hist-continuous"
      ENV["USGS_API_HISTORY_DAILY_KEY"] = "hist-daily"
      assert HistoryKeyPool.deep_available?

      RateLimitCircuit.open!(key_id: "history_daily", ttl: 1.minute)
      refute HistoryKeyPool.deep_available?
      assert HistoryKeyPool.phase1_available?
      refute HistoryKeyPool.available?(:daily)
    end

    test "dashboard_statuses reports tip and purpose keys" do
      ENV["USGS_API_KEY"] = "tip-key"
      ENV["USGS_API_HISTORY_CONTINUOUS_KEY"] = "hist-continuous"
      ENV.delete("USGS_API_HISTORY_DAILY_KEY")
      ENV["USGS_API_HISTORY_PEAKS_KEY"] = "hist-peaks"
      RateLimitCircuit.open!(key_id: "history_continuous", ttl: 1.minute)

      snap = HistoryKeyPool.dashboard_statuses
      assert_equal "tip", snap[:tip][:key]
      assert_equal true, snap[:tip][:configured]
      continuous = snap[:history].find { |row| row[:purpose] == :continuous }
      daily = snap[:history].find { |row| row[:purpose] == :daily }
      assert_equal true, continuous[:open]
      assert_equal true, continuous[:configured]
      assert_equal false, daily[:configured]
      assert_equal true, daily[:fallback_to_tip]
      refute snap[:exhausted]
    end
  end
end
