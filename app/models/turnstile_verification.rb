class TurnstileVerification
  include ActiveModel::Model

  SITEVERIFY_URL = "https://challenges.cloudflare.com/turnstile/v0/siteverify".freeze
  MAX_TOKEN_LENGTH = 2048
  CONTACT = "contact"
  EMAIL_NOTIFICATIONS = "email-notifications"
  MANAGE_LINK = "manage-link"

  attr_accessor :token, :remote_ip, :expected_action

  def success?
    return true if bypass_in_test?
    return false unless challenge_acceptable?

    body = siteverify_body
    return false unless body

    body["success"] == true &&
      body["action"] == expected_action &&
      expected_hostnames.include?(body["hostname"])
  end

  private

  def challenge_acceptable?
    acceptable_token? && secret.present? && expected_action.present? && expected_hostnames.any?
  end

  def acceptable_token?
    token.is_a?(String) && token.present? && token.length <= MAX_TOKEN_LENGTH
  end

  def siteverify_body
    response = Faraday.post(SITEVERIFY_URL) do |req|
      req.headers["Content-Type"] = "application/x-www-form-urlencoded"
      req.body = URI.encode_www_form(
        {
          secret: secret,
          response: token,
          remoteip: remote_ip
        }.compact
      )
      req.options.timeout = 10
      req.options.open_timeout = 10
    end

    return unless response.success?

    body = JSON.parse(response.body.to_s)
    body if body.is_a?(Hash)
  rescue Faraday::Error, JSON::ParserError
    nil
  end

  def bypass_in_test?
    Rails.env.test? && ENV["TURNSTILE_SECRET"].blank?
  end

  def secret
    ENV["TURNSTILE_SECRET"]
  end

  def expected_hostnames
    ENV.fetch("TURNSTILE_HOSTNAMES", "").split(",").map(&:strip).compact_blank
  end
end
