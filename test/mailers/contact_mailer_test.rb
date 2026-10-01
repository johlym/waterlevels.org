# frozen_string_literal: true

require "test_helper"

class ContactMailerTest < ActionMailer::TestCase
  include MailerHtmlAssertions

  test "contact_email is self-contained and loosely styled for light and dark clients" do
    email = ContactMailer.with(
      name: "Ada",
      email: "ada@example.com",
      subject: "Hello",
      message: "Testing the form\n\nA <tag> & an ampersand."
    ).contact_email

    assert_emails 1 do
      email.deliver_now
    end

    html = email.html_part.body.to_s
    css = html[/<style\b[^>]*>(.*?)<\/style>/m, 1].to_s
    assert_self_contained_mailer_html!(html)
    assert_match(/font-family: -apple-system/, html)
    assert_match(/name="color-scheme" content="light dark"/, html)
    assert_match(/name="supported-color-schemes" content="light dark"/, html)
    assert_no_match(/\bbackground(?:-color)?\s*:/i, css)
    assert_empty css.scan(/(?:^|[;{])\s*color\s*:/i), "contact mail must not set a text color"
    assert_no_match(/#[0-9a-fA-F]{3,8}/, html)
    assert_no_match(/class="muted/, html)
    assert_match(/Ada/, html)
    assert_match(/ada@example\.com/, html)
    assert_match(/Testing the form/, html)
    assert_match(/A &lt;tag&gt; &amp; an ampersand\./, html)
    assert_no_match(/&amp;lt;|&amp;amp;/, html)
    assert_match(/Sent via the WaterLevels.org contact form/, html)
    assert_match(/disable_open/, html)
    assert_match(/disable_click/, html)
    assert_match(/disable_utms/, html)
  end

  test "contact_email deliver_later lands on the default queue" do
    assert_enqueued_with(job: ActionMailer::MailDeliveryJob, queue: "default") do
      ContactMailer.with(
        name: "Ada",
        email: "ada@example.com",
        subject: "Hello",
        message: "Testing the form"
      ).contact_email.deliver_later
    end
  end
end
