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

  test "email_unit formats cubic feet with superscript" do
    assert_equal "ft³/s", email_unit("ft3/s")
    assert_equal "ft³/s", email_unit("ft^3/s")
    assert_equal "ft", email_unit("ft")
    assert_nil email_unit(nil)
  end
end
