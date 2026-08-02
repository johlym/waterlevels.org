require "rails_helper"

RSpec.describe "Contacts", type: :request do
  before do
    allow_any_instance_of(TurnstileVerification).to receive(:success?).and_return(true)
  end

  it "renders the contact form without public cache" do
    get "/contact"
    expect(response).to have_http_status(:ok)
    expect(response.body).to include("Send message")
    expect(response.headers["Cache-Control"]).to include("no-store")
  end

  it "delivers a contact message" do
    expect {
      post "/contact", params: {
        contact_message: {
          name: "Ada",
          email: "ada@example.com",
          subject: "Hello",
          message: "Testing the form"
        },
        "cf-turnstile-response" => "test-token"
      }
    }.to have_enqueued_mail(ContactMailer, :contact_email)

    expect(response).to redirect_to(contact_path)
    follow_redirect!
    expect(response.body).to include("Thanks")
  end

  it "re-renders with errors when invalid" do
    post "/contact", params: {
      contact_message: {
        name: "",
        email: "bad",
        subject: "",
        message: ""
      },
      "cf-turnstile-response" => "test-token"
    }
    expect(response).to have_http_status(:unprocessable_content)
  end
end
