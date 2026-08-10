# Gate for internal `/api/*` endpoints used by first-party Stimulus fetches.
# Requires a dedicated client header plus a same-party browser signal
# (Sec-Fetch-Site/Mode, Origin, or Referer). Not a cryptographic secret — just
# enough to block casual URL scraping. Payloads are Redis-cached via
# ApiResponseCache and returned with private/no-store HTTP headers.
class FirstPartyApiRequest
  CLIENT_HEADER = "X-WaterLevels-Client"
  CLIENT_VALUE = "web"
  ALLOWED_FETCH_SITES = %w[same-origin same-site].freeze
  ALLOWED_FETCH_MODES = %w[cors same-origin].freeze

  def self.allowed?(request)
    new(request).allowed?
  end

  def initialize(request)
    @request = request
  end

  def allowed?
    client_header_valid? && first_party_context?
  end

  private

  def client_header_valid?
    @request.get_header("HTTP_X_WATERLEVELS_CLIENT").to_s == CLIENT_VALUE
  end

  def first_party_context?
    sec_fetch_same_party? || sec_fetch_mode_browser? || origin_same_party? || referer_same_party?
  end

  def sec_fetch_same_party?
    ALLOWED_FETCH_SITES.include?(@request.get_header("HTTP_SEC_FETCH_SITE").to_s)
  end

  # Some browsers omit Sec-Fetch-Site on same-origin GET fetch but still send Mode.
  def sec_fetch_mode_browser?
    ALLOWED_FETCH_MODES.include?(@request.get_header("HTTP_SEC_FETCH_MODE").to_s)
  end

  def origin_same_party?
    origin = @request.get_header("HTTP_ORIGIN").to_s
    return false if origin.blank? || origin == "null"

    host_allowed?(origin)
  end

  def referer_same_party?
    referer = @request.referer.to_s
    return false if referer.blank?

    host_allowed?(referer)
  end

  def host_allowed?(url)
    host = URI.parse(url).host
    return false if host.blank?

    allowed_hosts.include?(host.downcase)
  rescue URI::InvalidURIError
    false
  end

  def allowed_hosts
    hosts = [ @request.host.to_s.downcase ]
    app_host = ENV["APP_HOST"].to_s.strip.downcase.sub(/\Ahttps?:\/\//, "").split("/").first
    hosts << app_host if app_host.present?
    hosts.reject(&:blank?).uniq
  end
end
