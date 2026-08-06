require "test_helper"

class Admin::DashboardControllerTest < ActionDispatch::IntegrationTest
  setup do
    @previous_pw = ENV["DASHBOARD_PW"]
    ENV.delete("DASHBOARD_PW")
    AdminDashboardStats.clear_tip_refresh!
  end

  teardown do
    if @previous_pw.nil?
      ENV.delete("DASHBOARD_PW")
    else
      ENV["DASHBOARD_PW"] = @previous_pw
    end
    AdminDashboardStats.clear_tip_refresh!
  end

  test "returns not found when DASHBOARD_PW is unset" do
    get admin_path
    assert_response :not_found
  end

  test "redirects to login when signed out" do
    ENV["DASHBOARD_PW"] = "secret-dashboard"
    get admin_path
    assert_redirected_to admin_login_path
  end

  test "renders dashboard with stats when signed in" do
    ENV["DASHBOARD_PW"] = "secret-dashboard"
    location = create(:monitoring_location, name: "Cedar River near Renton")
    series = create(:time_series, monitoring_location: location)
    ContinuousObservation.create!(time_series: series, value: 3.2, observed_at: 1.hour.ago)
    AdminDashboardStats.record_tip_refresh!(
      stations_updated: 7,
      series_upserted: 12,
      finished_at: 30.minutes.ago
    )

    post admin_login_path, params: { password: "secret-dashboard" }
    get admin_path

    assert_response :success
    assert_includes response.headers["Cache-Control"], "no-store"
    assert_includes response.body, "Active stations"
    assert_includes response.body, "Needing full history"
    assert_includes response.body, "Last station updated"
    assert_includes response.body, location.reload.display_name
    assert_includes response.body, "Updated in last tip refresh"
    assert_includes response.body, ">7<"
    assert_includes response.body, "Total measurements"
    assert_includes response.body, "Tip freshness"
    assert_includes response.body, "Station &amp; backfill backlog"
    assert_includes response.body, "Sidekiq UI"
    assert_includes response.body, "/admin/sidekiq"
    assert_includes response.body, "Sign out"
    assert_includes response.body, 'name="robots"'
    assert_includes response.body, "noindex, nofollow"
  end

  test "sidekiq UI is gated like the dashboard" do
    get "/admin/sidekiq"
    assert_response :not_found

    ENV["DASHBOARD_PW"] = "secret-dashboard"
    get "/admin/sidekiq"
    assert_redirected_to admin_login_path

    begin
      Redis.new(RedisConfig.options).ping
    rescue Redis::BaseError
      skip "Redis unavailable"
    end

    post admin_login_path, params: { password: "secret-dashboard" }
    get "/admin/sidekiq"
    assert_response :success
  end
end
