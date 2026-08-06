require "test_helper"

class Admin::DashboardControllerTest < ActionDispatch::IntegrationTest
  setup do
    @previous_pw = ENV["DASHBOARD_PW"]
    ENV.delete("DASHBOARD_PW")
  end

  teardown do
    if @previous_pw.nil?
      ENV.delete("DASHBOARD_PW")
    else
      ENV["DASHBOARD_PW"] = @previous_pw
    end
  end

  test "returns not found when DASHBOARD_PW is unset" do
    get admin_path
    assert_response :not_found
  end

  test "requires http basic auth when DASHBOARD_PW is set" do
    ENV["DASHBOARD_PW"] = "secret-dashboard"
    get admin_path
    assert_response :unauthorized
  end

  test "rejects wrong password" do
    ENV["DASHBOARD_PW"] = "secret-dashboard"
    get admin_path, headers: basic_auth_headers("admin", "wrong")
    assert_response :unauthorized
  end

  test "rejects wrong username" do
    ENV["DASHBOARD_PW"] = "secret-dashboard"
    get admin_path, headers: basic_auth_headers("root", "secret-dashboard")
    assert_response :unauthorized
  end

  test "renders dashboard with stats when authenticated" do
    ENV["DASHBOARD_PW"] = "secret-dashboard"
    location = create(:monitoring_location, display_name: "Cedar River near Renton")
    series = create(:time_series, monitoring_location: location)
    ContinuousObservation.create!(time_series: series, value: 3.2, observed_at: 1.hour.ago)
    AdminDashboardStats.record_tip_refresh!(
      stations_updated: 7,
      series_upserted: 12,
      finished_at: 30.minutes.ago
    )

    get admin_path, headers: basic_auth_headers("admin", "secret-dashboard")

    assert_response :success
    assert_includes response.headers["Cache-Control"], "no-store"
    assert_includes response.body, "Admin"
    assert_includes response.body, "dashboard"
    assert_includes response.body, "Active stations"
    assert_includes response.body, "Needing full history"
    assert_includes response.body, "Last station updated"
    assert_includes response.body, "Cedar River near Renton"
    assert_includes response.body, "Updated in last tip refresh"
    assert_includes response.body, ">7<"
    assert_includes response.body, "Total measurements"
    assert_includes response.body, "name=\"robots\""
    assert_includes response.body, "noindex, nofollow"
  end

  private

  def basic_auth_headers(username, password)
    {
      "HTTP_AUTHORIZATION" => ActionController::HttpAuthentication::Basic.encode_credentials(username, password)
    }
  end
end
