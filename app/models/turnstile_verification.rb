class TurnstileVerification
  include ActiveModel::Model

  SITEVERIFY_URL = "https://challenges.cloudflare.com/turnstile/v0/siteverify".freeze

  attr_accessor :token, :remote_ip

  def success?
    return true if bypass_in_test?
    return false if token.blank? || secret.blank?

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
    end

    return false unless response.success?

    body = JSON.parse(response.body.to_s)
    body["success"] == true
  rescue Faraday::Error, JSON::ParserError
    false
  end

  private

  def bypass_in_test?
    Rails.env.test? && ENV["TURNSTILE_SECRET"].blank?
  end

  def secret
    ENV["TURNSTILE_SECRET"]
  end
end
