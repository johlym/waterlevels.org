require "rails_helper"

RSpec.describe TurnstileVerification do
  around do |example|
    previous = ENV["TURNSTILE_SECRET"]
    ENV["TURNSTILE_SECRET"] = "test-secret"
    example.run
  ensure
    if previous
      ENV["TURNSTILE_SECRET"] = previous
    else
      ENV.delete("TURNSTILE_SECRET")
    end
  end

  it "returns true when siteverify succeeds" do
    stub_request(:post, TurnstileVerification::SITEVERIFY_URL)
      .with { |req|
        req.headers["Content-Type"] == "application/x-www-form-urlencoded" &&
          req.body.include?("secret=test-secret") &&
          req.body.include?("response=good-token") &&
          req.body.include?("remoteip=1.2.3.4")
      }
      .to_return(status: 200, body: { success: true }.to_json, headers: { "Content-Type" => "application/json" })

    expect(described_class.new(token: "good-token", remote_ip: "1.2.3.4")).to be_success
  end

  it "returns false when siteverify fails closed" do
    stub_request(:post, TurnstileVerification::SITEVERIFY_URL)
      .to_return(status: 200, body: { success: false }.to_json, headers: { "Content-Type" => "application/json" })

    expect(described_class.new(token: "bad-token")).not_to be_success
  end

  it "returns false on non-2xx siteverify responses" do
    stub_request(:post, TurnstileVerification::SITEVERIFY_URL).to_return(status: 503, body: "nope")

    expect(described_class.new(token: "token")).not_to be_success
  end
end
