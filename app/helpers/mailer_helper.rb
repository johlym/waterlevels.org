# frozen_string_literal: true

module MailerHelper
  # Break digit runs so iOS Mail / Gmail do not auto-link USGS site numbers as
  # phone numbers. Zero-width spaces are invisible but defeat tel: detection.
  def email_site_number(site)
    digits = site.to_s
    return digits if digits.blank?

    digits.scan(/.{1,4}/).join("\u200B")
  end
end
