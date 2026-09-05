# frozen_string_literal: true

require "test_helper"

class MailerHelperTest < ActionView::TestCase
  include MailerHelper

  test "email_site_number inserts zero-width spaces every four digits" do
    formatted = email_site_number("12101000")
    assert_equal "1210\u200B1000", formatted
    assert_no_match(/\A\d+\z/, formatted)
  end

  test "email_site_number handles blank" do
    assert_equal "", email_site_number(nil)
    assert_equal "", email_site_number("")
  end
end
