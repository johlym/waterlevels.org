require "test_helper"

class ContactMessageTest < ActiveSupport::TestCase
  test "is valid with required fields when turnstile passes" do
    message = ContactMessage.new(
      name: "Ada",
      email: "ada@example.com",
      subject: "Hello",
      message: "Body",
      turnstile_token: "token"
    )
    assert message.valid?
  end

  test "is invalid without email" do
    message = ContactMessage.new(name: "Ada", subject: "Hi", message: "Body")
    assert_not message.valid?
  end

  test "is invalid when turnstile fails" do
    previous = ENV["TURNSTILE_SECRET"]
    ENV["TURNSTILE_SECRET"] = "secret"
    stub_request(:post, TurnstileVerification::SITEVERIFY_URL)
      .to_return(status: 200, body: { success: false }.to_json, headers: { "Content-Type" => "application/json" })

    message = ContactMessage.new(
      name: "Ada",
      email: "ada@example.com",
      subject: "Hello",
      message: "Body",
      turnstile_token: "bad"
    )
    assert_not message.valid?
    assert_match(/bot check/i, message.errors[:base].join)
  ensure
    if previous
      ENV["TURNSTILE_SECRET"] = previous
    else
      ENV.delete("TURNSTILE_SECRET")
    end
  end
end
