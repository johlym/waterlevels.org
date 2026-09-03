# frozen_string_literal: true

require "test_helper"

class ContactMailerTest < ActionMailer::TestCase
  include MailerHtmlAssertions

  test "contact_email is self-contained and uses shared mailer styles" do
    email = ContactMailer.with(
      name: "Ada",
      email: "ada@example.com",
      subject: "Hello",
      message: "Testing the form"
    ).contact_email

    assert_emails 1 do
      email.deliver_now
    end

    html = email.html_part.body.to_s
    assert_self_contained_mailer_html!(html)
    assert_match(/font-family: -apple-system/, html)
    assert_match(/Ada/, html)
    assert_match(/ada@example\.com/, html)
    assert_match(/Testing the form/, html)
    assert_match(/Sent via the WaterLevels.org contact form/, html)
  end
end
