require "test_helper"

class Admin::SessionsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @previous_pw = ENV["DASHBOARD_PW"]
    ENV.delete("DASHBOARD_PW")
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

  test "login is not found when DASHBOARD_PW is unset" do
    get admin_login_path
    assert_response :not_found
  end

  test "renders login form when DASHBOARD_PW is set" do
    ENV["DASHBOARD_PW"] = "secret-dashboard"
    previous = ActionController::Base.allow_forgery_protection
    ActionController::Base.allow_forgery_protection = true
    get admin_login_path

    assert_response :success
    assert_includes response.headers["Cache-Control"], "no-store"
    assert_includes response.headers["Set-Cookie"].to_s, "_waterlevels_session"
    assert_includes response.body, "Admin sign in"
    assert_includes response.body, "Admin"
    assert_includes response.body, "Return to site"
    assert_includes response.body, 'name="password"'
    assert_includes response.body, 'name="csrf-token"'
    refute_includes response.body, "cdn.usefathom.com"
  ensure
    ActionController::Base.allow_forgery_protection = previous
  end

  test "rejects wrong password" do
    ENV["DASHBOARD_PW"] = "secret-dashboard"
    post admin_login_path, params: { password: "wrong" }

    assert_response :unprocessable_content
    assert_includes response.body, "Incorrect password"
    get admin_path
    assert_redirected_to admin_login_path
  end

  test "accepts correct password and signs in" do
    ENV["DASHBOARD_PW"] = "secret-dashboard"
    post admin_login_path, params: { password: "secret-dashboard" }

    assert_redirected_to admin_path
    follow_redirect!
    assert_response :success
    assert_includes response.body, "Core stats"
  end

  test "rate limits repeated password attempts from the same IP" do
    ENV["DASHBOARD_PW"] = "secret-dashboard"
    limit = Admin::SessionsController::RATE_LIMIT_TO

    limit.times do |i|
      post admin_login_path, params: { password: "wrong-#{i}" }
      assert_response :unprocessable_content
    end

    post admin_login_path, params: { password: "wrong-overflow" }
    assert_response :too_many_requests

    post admin_login_path, params: { password: "secret-dashboard" }
    assert_response :too_many_requests
  end

  test "sign out clears the session" do
    ENV["DASHBOARD_PW"] = "secret-dashboard"
    post admin_login_path, params: { password: "secret-dashboard" }
    delete admin_logout_path

    assert_redirected_to admin_login_path
    get admin_path
    assert_redirected_to admin_login_path
  end
end
