require "test_helper"

class ContactsControllerTest < ActionDispatch::IntegrationTest
  include ActionMailer::TestHelper

  test "renders the contact form without public cache" do
    get contact_path
    assert_response :success
    assert_includes response.body, "Send message"
    assert_includes response.headers["Cache-Control"], "no-store"
  end

  test "contact enables a Rails session and CSRF meta tags" do
    previous = ActionController::Base.allow_forgery_protection
    ActionController::Base.allow_forgery_protection = true
    get contact_path
    assert_response :success
    assert_includes response.headers["Set-Cookie"].to_s, "_waterlevels_session"
    assert_includes response.body, 'name="csrf-token"'
  ensure
    ActionController::Base.allow_forgery_protection = previous
  end



  test "delivers a contact message" do
    assert_enqueued_emails 1 do
      post contact_path, params: {
        contact_message: {
          name: "Ada",
          email: "ada@example.com",
          subject: "Hello",
          message: "Testing the form"
        },
        "cf-turnstile-response" => "test-token"
      }
    end

    assert_redirected_to contact_path
    follow_redirect!
    assert_includes response.body, "Thanks"
  end

  test "re-renders with errors when invalid" do
    post contact_path, params: {
      contact_message: {
        name: "",
        email: "bad",
        subject: "",
        message: ""
      },
      "cf-turnstile-response" => "test-token"
    }
    assert_response :unprocessable_content
    assert_includes response.body, 'aria-invalid="true"'
    assert_includes response.body, "contact-email-error"
    assert_includes response.body, "Email hello@waterlevels.org"
  end
end

