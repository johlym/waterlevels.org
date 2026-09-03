# frozen_string_literal: true

module MailerHtmlAssertions
  EXTERNAL_RESOURCE_PATTERNS = [
    /<link\b[^>]+rel=["']stylesheet["']/i,
    /@import\b/i,
    /<img\b[^>]+src=["']https?:\/\//i,
    /fonts\.googleapis\.com/i,
    /fonts\.gstatic\.com/i,
    /\bcdn\./i
  ].freeze

  def assert_self_contained_mailer_html!(html)
    EXTERNAL_RESOURCE_PATTERNS.each do |pattern|
      assert_no_match pattern, html, "mailer HTML must not load external resources"
    end
  end
end
