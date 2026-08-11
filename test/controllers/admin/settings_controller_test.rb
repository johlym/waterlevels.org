require "test_helper"

class Admin::SettingsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @previous_pw = ENV["DASHBOARD_PW"]
    ENV.delete("DASHBOARD_PW")
    AppSetting.delete_all
    AppConfig.bust!
    Admin::SessionsController::RATE_LIMIT_STORE.clear
  end

  teardown do
    if @previous_pw.nil?
      ENV.delete("DASHBOARD_PW")
    else
      ENV["DASHBOARD_PW"] = @previous_pw
    end
    Admin::SessionsController::RATE_LIMIT_STORE.clear
  end

  test "returns not found when DASHBOARD_PW is unset" do
    get admin_settings_path
    assert_response :not_found
  end

  test "redirects to login when signed out" do
    ENV["DASHBOARD_PW"] = "secret-dashboard"
    get admin_settings_path
    assert_redirected_to admin_login_path
  end

  test "renders settings groups when signed in" do
    ENV["DASHBOARD_PW"] = "secret-dashboard"
    post admin_login_path, params: { password: "secret-dashboard" }

    get admin_settings_path
    assert_response :success
    assert_includes response.headers["Cache-Control"], "no-store"
    assert_includes response.body, "Settings"
    assert_includes response.body, "Pipeline jobs"
    assert_includes response.body, "Ingestion throughput"
    assert_includes response.body, "Daily archive"
    assert_includes response.body, "History retention"
    assert_includes response.body, "Maintenance"
    assert_includes response.body, "Hourly tip sync"
    assert_includes response.body, "When off, LatestObservationSyncJob no-ops"
    assert_includes response.body, admin_path
  end

  test "updates a boolean override" do
    ENV["DASHBOARD_PW"] = "secret-dashboard"
    post admin_login_path, params: { password: "secret-dashboard" }

    patch admin_settings_path, params: {
      group: "pipeline_jobs",
      settings: { latest_observation_sync_enabled: "0" }
    }

    assert_redirected_to admin_settings_path(anchor: "pipeline_jobs")
    refute AppConfig.boolean?(:latest_observation_sync_enabled)
    assert_equal :override, AppConfig.source(:latest_observation_sync_enabled)
  end

  test "resets an override" do
    previous_batch = ENV["HISTORY_BACKFILL_BATCH"]
    ENV.delete("HISTORY_BACKFILL_BATCH")
    AppConfig.bust!(:history_backfill_batch)

    ENV["DASHBOARD_PW"] = "secret-dashboard"
    post admin_login_path, params: { password: "secret-dashboard" }
    AppConfig.write!(:history_backfill_batch, 3)

    delete reset_admin_settings_path(key: "history_backfill_batch")
    assert_redirected_to admin_settings_path(anchor: "ingestion_throughput")
    assert_equal :default, AppConfig.source(:history_backfill_batch)
  ensure
    if previous_batch.nil?
      ENV.delete("HISTORY_BACKFILL_BATCH")
    else
      ENV["HISTORY_BACKFILL_BATCH"] = previous_batch
    end
    AppConfig.bust!(:history_backfill_batch)
  end
end
