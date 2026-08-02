class TurnstileVerification
  include ActiveModel::Model

  CLOUDFLARE_SITEVERIFY = "https://challenges.cloudflare.com/turnstile/v0/siteverify".freeze

  attr_accessor :token, :remote_ip

  def success?
    return true if bypass_in_test?
    return false if token.blank? || secret_key.blank?

    response = connection.post(siteverify_url) do |req|
      req.headers["Content-Type"] = "application/json"
      req.body = {
        secret: secret_key,
        response: token,
        remoteip: remote_ip
      }.compact.to_json
    end

    body = response.body.is_a?(Hash) ? response.body : JSON.parse(response.body.to_s)
    ActiveModel::Type::Boolean.new.cast(body["success"])
  rescue Faraday::Error, JSON::ParserError
    false
  end

  private

  def bypass_in_test?
    Rails.env.test? && ENV["TURNSTILE_SECRET_KEY"].blank?
  end

  def secret_key
    ENV["TURNSTILE_SECRET_KEY"]
  end

  def siteverify_url
    ENV.fetch("TURNSTILE_SITEVERIFY_URL", CLOUDFLARE_SITEVERIFY)
  end

  def connection
    Faraday.new do |f|
      f.request :json
      f.response :json, content_type: /\bjson$/
      f.options.timeout = 10
      f.adapter Faraday.default_adapter
    end
  end
end
