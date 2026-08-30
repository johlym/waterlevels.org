require "test_helper"

class AccessibilitySmokeTest < ActionDispatch::IntegrationTest
  test "public pages expose skip link and main landmark" do
    [
      root_path,
      map_path,
      about_path,
      faq_path,
      contact_path,
      disclosures_path,
      privacy_path,
      terms_path,
      alerts_path
    ].each do |path|
      get path
      assert_response :success, "expected success for #{path}"
      assert_includes response.body, 'href="#main"', "missing skip link on #{path}"
      assert_includes response.body, 'id="main"', "missing #main on #{path}"
      assert_includes response.body, "<main", "missing main landmark on #{path}"
    end
  end

  test "home search uses combobox pattern" do
    get root_path
    assert_response :success
    assert_includes response.body, 'role="combobox"'
    assert_includes response.body, 'aria-controls="home-search-results"'
    assert_includes response.body, 'role="listbox"'
    assert_includes response.body, 'data-station-search-target="status"'
    assert_includes response.body, 'aria-live="polite"'
  end

  test "map search and stations list are keyboard-accessible" do
    get map_path
    assert_response :success
    assert_includes response.body, 'role="combobox"'
    assert_includes response.body, 'aria-controls="map-search-results"'
    assert_includes response.body, "Stations in view"
    assert_includes response.body, 'data-map-target="stationList"'
    assert_includes response.body, "Normal (circle)"
    assert_includes response.body, "Action (A / diamond)"
  end

  test "faq categories are navigation buttons not incomplete tabs" do
    get faq_path
    assert_response :success
    assert_includes response.body, 'aria-label="FAQ categories"'
    assert_not_includes response.body, 'role="tablist"'
    assert_includes response.body, 'aria-current="true"'
    assert_includes response.body, 'aria-expanded="false"'
  end

  test "mobile nav exposes expanded state and includes Data link" do
    get about_path
    assert_response :success
    assert_includes response.body, 'aria-controls="mobile-primary-nav"'
    assert_includes response.body, 'aria-expanded="false"'
    assert_includes response.body, 'id="mobile-primary-nav"'
    assert_includes response.body, ">Data</a>"
  end

  test "nav marks the current page" do
    get about_path
    assert_response :success
    assert_includes response.body, 'aria-current="page"'
    assert_match(%r{aria-current="page"[^>]*>About</a>}, response.body)
  end

  test "nav omits manage email alerts when the feature is off" do
    get about_path
    assert_response :success
    assert_not_includes response.body, "Manage Email Alerts"
  end

  test "nav ends with manage email alerts when the feature is on" do
    previous = ENV["ALERTS_ENABLED"]
    ENV["ALERTS_ENABLED"] = "1"

    get about_path
    assert_response :success
    assert_includes response.body, ">Manage Email Alerts</a>"
    assert_includes response.body, "href=\"#{subscriptions_path}\""
    data_at = response.body.index(">Data</a>")
    manage_at = response.body.index(">Manage Email Alerts</a>")
    assert data_at
    assert manage_at
    assert_operator data_at, :<, manage_at
  ensure
    if previous
      ENV["ALERTS_ENABLED"] = previous
    else
      ENV.delete("ALERTS_ENABLED")
    end
  end

  test "contact field errors are associated for assistive tech" do
    post contact_path, params: {
      contact_message: {
        name: "",
        email: "bad",
        subject: "",
        message: ""
      },
      "cf-turnstile-response" => "test-token"
    }
    assert_response :unprocessable_content
    assert_includes response.body, 'aria-invalid="true"'
    assert_includes response.body, 'id="contact-name-error"'
    assert_includes response.body, 'aria-describedby="contact-name-error"'
    assert_includes response.body, "Email hello@waterlevels.org"
  end

  test "gauge measurement tabs keep tablist semantics" do
    location = create(:monitoring_location)
    series = create(:time_series, monitoring_location: location, parameter_code: "00065")
    LatestObservation.create!(
      time_series: series,
      value: 12.34,
      unit_of_measure: "ft",
      observed_at: Time.utc(2026, 8, 2, 4, 30, 0),
      synced_at: Time.current,
      approval_status: "Provisional"
    )
    location.update!(
      latest_water_level_value: 12.34,
      latest_water_level_unit: "ft",
      latest_water_level_parameter_code: "00065",
      latest_observed_at: Time.utc(2026, 8, 2, 4, 30, 0)
    )

    get "/gauges/#{location.state_code}/#{location.to_param}"
    assert_response :success
    assert_includes response.body, 'role="tablist"'
    assert_includes response.body, 'role="tab"'
    assert_includes response.body, 'aria-controls="graph-panel"'
    assert_includes response.body, 'data-hydrograph-target="canvas"'
    assert_includes response.body, "aria-label="
  end
end
