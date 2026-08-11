require "test_helper"

class AppConfigTest < ActiveSupport::TestCase
  setup do
    @previous_env = ENV["HISTORY_BACKFILL_BATCH"]
    ENV.delete("HISTORY_BACKFILL_BATCH")
    AppSetting.delete_all
    AppConfig.bust!
  end

  teardown do
    if @previous_env.nil?
      ENV.delete("HISTORY_BACKFILL_BATCH")
    else
      ENV["HISTORY_BACKFILL_BATCH"] = @previous_env
    end
  end

  test "returns code default when unset" do
    assert_equal 50, AppConfig.integer(:history_backfill_batch)
    assert_equal :default, AppConfig.source(:history_backfill_batch)
  end

  test "ENV wins over default" do
    ENV["HISTORY_BACKFILL_BATCH"] = "12"
    AppConfig.bust!(:history_backfill_batch)

    assert_equal 12, AppConfig.integer(:history_backfill_batch)
    assert_equal :env, AppConfig.source(:history_backfill_batch)
  end

  test "DB override wins over ENV" do
    ENV["HISTORY_BACKFILL_BATCH"] = "12"
    AppConfig.write!(:history_backfill_batch, 9)

    assert_equal 9, AppConfig.integer(:history_backfill_batch)
    assert_equal :override, AppConfig.source(:history_backfill_batch)
  end

  test "reset removes override and falls back" do
    ENV["HISTORY_BACKFILL_BATCH"] = "12"
    AppConfig.write!(:history_backfill_batch, 9)
    AppConfig.reset!(:history_backfill_batch)

    assert_equal 12, AppConfig.integer(:history_backfill_batch)
    assert_equal :env, AppConfig.source(:history_backfill_batch)
  end

  test "boolean pipeline lever defaults on" do
    assert AppConfig.boolean?(:latest_observation_sync_enabled)
  end

  test "rejects unknown keys" do
    assert_raises(AppConfig::UnknownKeyError) { AppConfig.get(:not_a_real_setting) }
  end

  test "validates integer bounds" do
    assert_raises(ArgumentError) { AppConfig.write!(:history_backfill_batch, 0) }
  end
end
