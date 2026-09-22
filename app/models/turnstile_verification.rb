class TurnstileVerification
  include ActiveModel::Model

  SITEVERIFY_URL = "https://challenges.cloudflare.com/turnstile/v0/siteverify".freeze
  MAX_TOKEN_LENGTH = 2048
  CONTACT = "contact"
  EMAIL_NOTIFICATIONS = "email-notifications"
  MANAGE_LINK = "manage-link"
  # Gauge HTML is edge-cached, so a page rendered before the action rename can
  # still submit the previous action for up to a day.
  LEGACY_ACTIONS = {
    CONTACT => [ CONTACT, "turnstile-spin-v2" ].freeze,
    EMAIL_NOTIFICATIONS => [ EMAIL_NOTIFICATIONS, "subscription-gauge-signup" ].freeze,
    MANAGE_LINK => [ MANAGE_LINK, "subscription-manage-link" ].freeze
  }.freeze

  attr_accessor :token, :remote_ip, :expected_action

  def success?
    return true if bypass_in_test?
    return false unless challenge_acceptable?

    body = siteverify_body
    return false unless body

    accepted = accepted?(body)
    log_rejection(body) unless accepted
    accepted
  end

  private

  def challenge_acceptable?
    acceptable_token? && secret.present? && expected_action.present? && expected_hostnames.any?
  end

  def acceptable_token?
    token.is_a?(String) && token.present? && token.length <= MAX_TOKEN_LENGTH
  end

  def accepted?(body)
    body["success"] == true &&
      action_allowed?(body["action"]) &&
      hostname_allowed?(body["hostname"])
  end

  def action_allowed?(action)
    allowed = LEGACY_ACTIONS.fetch(expected_action, [ expected_action ])
    allowed.include?(action)
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

  def log_rejection(body)
    Rails.logger.info(
      "turnstile_rejected expected_action=#{expected_action} action=#{body["action"]} " \
      "hostname=#{body["hostname"]} errors=#{Array(body["error-codes"]).join(",")}"
    )
  end

  def bypass_in_test?
    Rails.env.test? && ENV["TURNSTILE_SECRET"].blank?
  end

  def secret
    ENV["TURNSTILE_SECRET"]
  end

  def expected_hostnames
    self.class.hostnames_for(
      env: Rails.env,
      configured: ENV["TURNSTILE_HOSTNAMES"],
      app_host: ENV["APP_HOST"]
    )
  end

  def hostname_allowed?(hostname)
    expected_hostnames.include?(self.class.normalize_hostname(hostname))
  end

  class << self
    def hostnames_for(env:, configured:, app_host:)
      parsed = parse_hostnames(configured)
      return parsed if parsed.any?
      return [] if env.test?
      return [ "localhost", "127.0.0.1" ] if env.development?

      app_hostnames(app_host)
    end

    def normalize_hostname(value)
      host = value.to_s.strip.downcase.sub(%r{\Ahttps?://}, "").split("/").first.to_s
      host.sub(/:\d+\z/, "")
    end

    private

    def app_hostnames(app_host)
      host = normalize_hostname(app_host.presence || "waterlevels.org")
      return [] if host.blank?

      if host.start_with?("www.")
        [ host, host.delete_prefix("www.") ]
      else
        [ host, "www.#{host}" ]
      end
    end

    def parse_hostnames(raw)
      raw.to_s.split(",").filter_map { |part| normalize_hostname(part).presence }
    end
  end
end
