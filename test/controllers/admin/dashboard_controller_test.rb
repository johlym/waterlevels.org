require "test_helper"

class Admin::DashboardControllerTest < ActionDispatch::IntegrationTest
  setup do
    @previous_pw = ENV["DASHBOARD_PW"]
    ENV.delete("DASHBOARD_PW")
    AdminDashboardStats.clear_tip_refresh!
    AdminDashboardStats.bust_backfill_cache!
  end

  teardown do
    if @previous_pw.nil?
      ENV.delete("DASHBOARD_PW")
    else
      ENV["DASHBOARD_PW"] = @previous_pw
    end
    AdminDashboardStats.clear_tip_refresh!
    AdminDashboardStats.bust_backfill_cache!
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

  test "renders dashboard shell with sequential section frames when signed in" do
    ENV["DASHBOARD_PW"] = "secret-dashboard"

    post admin_login_path, params: { password: "secret-dashboard" }
    get admin_path

    assert_response :success
    assert_includes response.headers["Cache-Control"], "no-store"
    assert_includes response.body, "Dashboard"
    assert_includes response.body, "Sidekiq UI"
    assert_includes response.body, "/admin/sidekiq"
    assert_includes response.body, "Sign out"
    assert_includes response.body, 'name="robots"'
    assert_includes response.body, "noindex, nofollow"
    assert_includes response.body, "Loading…"
    assert_includes response.body, 'data-controller="admin-sections"'

    AdminDashboardStats::SECTIONS.each do |section|
      assert_includes response.body, "id=\"admin_section_#{section}\""
      # Frames are filled one-at-a-time via Stimulus; src is data-driven, not set on paint.
      assert_includes response.body, "data-admin-sections-src=\"#{admin_dashboard_section_path(section: section)}\""
    end
    refute_match(/turbo-frame[^>]*\ssrc=/, response.body)
  end

  test "section endpoints render filled stats when signed in" do
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

    get admin_dashboard_section_path(section: :core)
    assert_response :success
    assert_includes response.headers["Cache-Control"], "no-store"
    assert_includes response.body, 'id="admin_section_core"'
    assert_includes response.body, "Active stations"
    assert_includes response.body, "Need ≤1y fill"
    assert_includes response.body, "Last station updated"
    assert_includes response.body, location.reload.display_name
    assert_includes response.body, "Updated in last tip refresh"
    assert_includes response.body, ">7<"
    assert_includes response.body, "Total measurements"

    get admin_dashboard_section_path(section: :pipeline)
    assert_response :success
    assert_includes response.body, "Have ~1y, need 3y"
    assert_includes response.body, "History ready (3y)"

    get admin_dashboard_section_path(section: :growth)
    assert_response :success
    assert_includes response.body, "Tip freshness"

    get admin_dashboard_section_path(section: :jobs)
    assert_response :success
    assert_includes response.body, "Latest tip sync"

    get admin_dashboard_section_path(section: :states)
    assert_response :success
    assert_includes response.body, "Station &amp; backfill backlog"
    assert_includes response.body, "Have ~1y → need 3y"

    get admin_dashboard_section_path(section: :health)
    assert_response :success
    assert_includes response.body, "History pool used"
    assert_includes response.body, "History pool remaining"
    assert_includes response.body, "Per-key hourly budget"
    assert_includes response.body, "Sidekiq UI"
  end

  test "unknown section returns not found" do
    ENV["DASHBOARD_PW"] = "secret-dashboard"
    post admin_login_path, params: { password: "secret-dashboard" }
    get "/admin/sections/nope"
    assert_response :not_found
  end

  test "section endpoint soft-fails on statement timeout" do
    ENV["DASHBOARD_PW"] = "secret-dashboard"
    post admin_login_path, params: { password: "secret-dashboard" }

    original = AdminDashboardStats.method(:section)
    AdminDashboardStats.define_singleton_method(:section) do |*_args|
      raise ActiveRecord::QueryCanceled, "canceling statement due to statement timeout"
    end

    get admin_dashboard_section_path(section: :states)

    assert_response :service_unavailable
    assert_includes response.body, 'id="admin_section_states"'
    assert_includes response.body, "timed out"
    assert_includes response.body, "Retry"
  ensure
    AdminDashboardStats.define_singleton_method(:section, original) if original
  end

  test "section endpoints require admin session" do
    ENV["DASHBOARD_PW"] = "secret-dashboard"
    get admin_dashboard_section_path(section: :jobs)
    assert_redirected_to admin_login_path
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
