require "test_helper"

class TurnstileVerificationTest < ActiveSupport::TestCase
  setup do
    @previous_secret = ENV["TURNSTILE_SECRET"]
    ENV["TURNSTILE_SECRET"] = "test-secret"
  end

  teardown do
    if @previous_secret
      ENV["TURNSTILE_SECRET"] = @previous_secret
    else
      ENV.delete("TURNSTILE_SECRET")
    end
  end

  test "returns true when siteverify succeeds" do
    stub_request(:post, TurnstileVerification::SITEVERIFY_URL)
      .with { |req|
        req.headers["Content-Type"] == "application/x-www-form-urlencoded" &&
          req.body.include?("secret=test-secret") &&
          req.body.include?("response=good-token") &&
          req.body.include?("remoteip=1.2.3.4")
      }
      .to_return(status: 200, body: { success: true }.to_json, headers: { "Content-Type" => "application/json" })

    assert TurnstileVerification.new(token: "good-token", remote_ip: "1.2.3.4").success?
  end

  test "returns false when siteverify fails closed" do
    stub_request(:post, TurnstileVerification::SITEVERIFY_URL)
      .to_return(status: 200, body: { success: false }.to_json, headers: { "Content-Type" => "application/json" })

    assert_not TurnstileVerification.new(token: "bad-token").success?
  end

  test "returns false on non-2xx siteverify responses" do
    stub_request(:post, TurnstileVerification::SITEVERIFY_URL).to_return(status: 503, body: "nope")

    assert_not TurnstileVerification.new(token: "token").success?
  end
end
