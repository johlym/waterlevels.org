require "test_helper"

class Admin::MaintenanceControllerTest < ActionDispatch::IntegrationTest
  setup do
    @previous_pw = ENV["DASHBOARD_PW"]
    ENV["DASHBOARD_PW"] = "secret-dashboard"
    Admin::SessionsController::RATE_LIMIT_STORE.clear
    post admin_login_path, params: { password: "secret-dashboard" }
  end

  teardown do
    if @previous_pw.nil?
      ENV.delete("DASHBOARD_PW")
    else
      ENV["DASHBOARD_PW"] = @previous_pw
    end
    Admin::SessionsController::RATE_LIMIT_STORE.clear
  end

  test "runs a safe maintenance action" do
    SiteStats.warm!
    post admin_maintenance_path(key: "bust_site_stats")
    assert_redirected_to admin_settings_path(anchor: "maintenance")
    assert_equal "Bust site stats completed.", flash[:notice]
  end

  test "rejects unknown actions" do
    post admin_maintenance_path(key: "not_real")
    assert_redirected_to admin_settings_path
    assert_equal "Unknown maintenance action.", flash[:alert]
  end

  test "rejects danger actions without a matching confirm token" do
    post admin_maintenance_path(key: "clear_usgs_rate_limit_circuits")
    assert_redirected_to admin_settings_path(anchor: "maintenance")
    assert_match(/Confirm/, flash[:alert].to_s)
  end

  test "runs a danger action when confirm matches the key" do
    post admin_maintenance_path(key: "clear_usgs_rate_limit_circuits"),
         params: { confirm: "clear_usgs_rate_limit_circuits" }
    assert_redirected_to admin_settings_path(anchor: "maintenance")
    assert_match(/completed/, flash[:notice].to_s)
  end
end
