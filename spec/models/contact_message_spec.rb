require "rails_helper"

RSpec.describe ContactMessage do
  it "is valid with required fields when turnstile passes" do
    allow_any_instance_of(TurnstileVerification).to receive(:success?).and_return(true)
    message = described_class.new(
      name: "Ada",
      email: "ada@example.com",
      subject: "Hello",
      message: "Body",
      turnstile_token: "token"
    )
    expect(message).to be_valid
  end

  it "is invalid without email" do
    allow_any_instance_of(TurnstileVerification).to receive(:success?).and_return(true)
    message = described_class.new(name: "Ada", subject: "Hi", message: "Body")
    expect(message).not_to be_valid
  end

  it "is invalid when turnstile fails" do
    allow_any_instance_of(TurnstileVerification).to receive(:success?).and_return(false)
    message = described_class.new(
      name: "Ada",
      email: "ada@example.com",
      subject: "Hello",
      message: "Body",
      turnstile_token: "bad"
    )
    expect(message).not_to be_valid
    expect(message.errors[:base].join).to match(/bot check/i)
  end
end
