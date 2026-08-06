require "test_helper"

class Admin::AuthTest < ActiveSupport::TestCase
  setup do
    @previous = ENV["DASHBOARD_PW"]
    ENV.delete("DASHBOARD_PW")
    @session = {}
  end

  teardown do
    if @previous.nil?
      ENV.delete("DASHBOARD_PW")
    else
      ENV["DASHBOARD_PW"] = @previous
    end
  end

  test "configured? reflects DASHBOARD_PW" do
    assert_not Admin::Auth.configured?
    ENV["DASHBOARD_PW"] = "secret"
    assert Admin::Auth.configured?
  end

  test "authenticates? accepts DASHBOARD_PW" do
    ENV["DASHBOARD_PW"] = "secret"
    assert Admin::Auth.authenticates?("secret")
    assert_not Admin::Auth.authenticates?("wrong")
  end

  test "authenticates? is false when unset" do
    assert_not Admin::Auth.authenticates?("secret")
  end

  test "sign_in and signed_in? use a password fingerprint" do
    ENV["DASHBOARD_PW"] = "secret"
    assert_not Admin::Auth.signed_in?(@session)

    Admin::Auth.sign_in(@session)
    assert Admin::Auth.signed_in?(@session)

    ENV["DASHBOARD_PW"] = "rotated"
    assert_not Admin::Auth.signed_in?(@session)
  end

  test "sign_out clears the session" do
    ENV["DASHBOARD_PW"] = "secret"
    Admin::Auth.sign_in(@session)
    Admin::Auth.sign_out(@session)

    assert_not Admin::Auth.signed_in?(@session)
    assert_nil @session[Admin::Auth::SESSION_KEY]
  end
end
