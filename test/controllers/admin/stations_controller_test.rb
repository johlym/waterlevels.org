require "test_helper"

class Admin::StationsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @previous_pw = ENV["DASHBOARD_PW"]
    ENV.delete("DASHBOARD_PW")
    @location = create(
      :monitoring_location,
      site_number: "08405200",
      name: "PECOS RIVER BELOW DARK CANYON AT CARLSBAD, NM",
      state_code: "nm",
      has_water_level: true,
      has_discharge: true,
      has_temperature: true
    )
    create(
      :time_series,
      monitoring_location: @location,
      parameter_code: "00065",
      measurement_kind: "water_level",
      selected_for_display: true
    )
    create(
      :time_series,
      monitoring_location: @location,
      parameter_code: "00010",
      measurement_kind: "temperature",
      selected_for_display: true
    )
  end

  teardown do
    if @previous_pw.nil?
      ENV.delete("DASHBOARD_PW")
    else
      ENV["DASHBOARD_PW"] = @previous_pw
    end
  end

  test "returns not found when DASHBOARD_PW is unset" do
    get admin_stations_path
    assert_response :not_found
  end

  test "redirects to login when signed out" do
    ENV["DASHBOARD_PW"] = "secret-dashboard"
    get admin_stations_path
    assert_redirected_to admin_login_path
  end

  test "index renders lookup form when signed in" do
    ENV["DASHBOARD_PW"] = "secret-dashboard"
    post admin_login_path, params: { password: "secret-dashboard" }

    get admin_stations_path
    assert_response :success
    assert_includes response.body, "Inspect station"
    assert_includes response.body, "Site number or slug"
  end

  test "index redirects exact site number to show" do
    ENV["DASHBOARD_PW"] = "secret-dashboard"
    post admin_login_path, params: { password: "secret-dashboard" }

    get admin_stations_path, params: { q: "08405200" }
    assert_redirected_to admin_station_path("08405200")
  end

  test "show renders diagnosis for a station" do
    ENV["DASHBOARD_PW"] = "secret-dashboard"
    post admin_login_path, params: { password: "secret-dashboard" }

    get admin_station_path("08405200")
    assert_response :success
    assert_includes response.headers["Cache-Control"], "no-store"
    assert_includes response.body, "08405200"
    assert_includes response.body, "Findings"
    assert_includes response.body, "missing_year_history?"
    assert_includes response.body, "Coverage by series"
    assert_includes response.body, "Temperature"
  end

  test "show redirects when site is unknown" do
    ENV["DASHBOARD_PW"] = "secret-dashboard"
    post admin_login_path, params: { password: "secret-dashboard" }

    get admin_station_path("99999999")
    assert_redirected_to admin_stations_path
  end
end
