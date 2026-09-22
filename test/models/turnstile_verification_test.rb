require "test_helper"

class TurnstileVerificationTest < ActiveSupport::TestCase
  setup do
    @previous_secret = ENV["TURNSTILE_SECRET"]
    @previous_hostnames = ENV["TURNSTILE_HOSTNAMES"]
    ENV["TURNSTILE_SECRET"] = "test-secret"
    ENV["TURNSTILE_HOSTNAMES"] = "localhost,127.0.0.1"
  end

  teardown do
    restore_env("TURNSTILE_SECRET", @previous_secret)
    restore_env("TURNSTILE_HOSTNAMES", @previous_hostnames)
  end

  test "returns true when siteverify succeeds for the expected action and hostname" do
    stub_request(:post, TurnstileVerification::SITEVERIFY_URL)
      .with { |req|
        req.headers["Content-Type"] == "application/x-www-form-urlencoded" &&
          req.body.include?("secret=test-secret") &&
          req.body.include?("response=good-token") &&
          req.body.include?("remoteip=1.2.3.4")
      }
      .to_return(
        status: 200,
        body: { success: true, action: "contact", hostname: "localhost" }.to_json,
        headers: { "Content-Type" => "application/json" }
      )

    assert TurnstileVerification.new(
      token: "good-token",
      remote_ip: "1.2.3.4",
      expected_action: TurnstileVerification::CONTACT
    ).success?
  end

  test "returns false when siteverify fails closed" do
    stub_request(:post, TurnstileVerification::SITEVERIFY_URL)
      .to_return(status: 200, body: { success: false }.to_json, headers: { "Content-Type" => "application/json" })

    assert_not verification(token: "bad-token").success?
  end

  test "returns false when the action does not match" do
    stub_siteverify(success: true, action: "contact", hostname: "localhost")

    assert_not verification(expected_action: TurnstileVerification::EMAIL_NOTIFICATIONS).success?
  end

  test "returns false when the hostname is not approved" do
    stub_siteverify(success: true, action: "contact", hostname: "example.com")

    assert_not verification.success?
  end

  test "returns false on non-2xx siteverify responses" do
    stub_request(:post, TurnstileVerification::SITEVERIFY_URL).to_return(status: 503, body: "nope")

    assert_not verification.success?
  end

  test "returns false without calling siteverify when the token is too long" do
    assert_not verification(token: "x" * (TurnstileVerification::MAX_TOKEN_LENGTH + 1)).success?
    assert_not_requested :post, TurnstileVerification::SITEVERIFY_URL
  end

  test "returns false when no hostnames are configured" do
    ENV["TURNSTILE_HOSTNAMES"] = ""

    assert_not verification.success?
    assert_not_requested :post, TurnstileVerification::SITEVERIFY_URL
  end

  private

  def verification(token: "good-token", expected_action: TurnstileVerification::CONTACT)
    TurnstileVerification.new(token: token, remote_ip: "1.2.3.4", expected_action: expected_action)
  end

  def stub_siteverify(body)
    stub_request(:post, TurnstileVerification::SITEVERIFY_URL)
      .to_return(status: 200, body: body.to_json, headers: { "Content-Type" => "application/json" })
  end

  def restore_env(key, previous)
    if previous
      ENV[key] = previous
    else
      ENV.delete(key)
    end
  end
end
