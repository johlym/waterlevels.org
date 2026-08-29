# Feature flag for consumer email alerts (Wave 0+).
# Off by default — enable with ALERTS_ENABLED=1|true|yes|on.
module AlertsConfig
  TRUTHY = %w[1 true yes on].freeze

  module_function

  def enabled?
    TRUTHY.include?(ENV.fetch("ALERTS_ENABLED", "").to_s.strip.downcase)
  end

  def disabled?
    !enabled?
  end
end
