require "test_helper"

class Admin::HttpBasicTest < ActiveSupport::TestCase
  setup do
    @previous = ENV["DASHBOARD_PW"]
    ENV.delete("DASHBOARD_PW")
  end

  teardown do
    if @previous.nil?
      ENV.delete("DASHBOARD_PW")
    else
      ENV["DASHBOARD_PW"] = @previous
    end
  end

  test "configured? reflects DASHBOARD_PW" do
    assert_not Admin::HttpBasic.configured?
    ENV["DASHBOARD_PW"] = "secret"
    assert Admin::HttpBasic.configured?
  end

  test "authenticates? accepts admin and DASHBOARD_PW" do
    ENV["DASHBOARD_PW"] = "secret"
    assert Admin::HttpBasic.authenticates?("admin", "secret")
    assert_not Admin::HttpBasic.authenticates?("admin", "wrong")
    assert_not Admin::HttpBasic.authenticates?("root", "secret")
  end

  test "authenticates? is false when unset" do
    assert_not Admin::HttpBasic.authenticates?("admin", "secret")
  end
end
