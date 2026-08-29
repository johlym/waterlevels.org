# Curated IANA zones for email-alert digest / quiet-hours UX.
module SubscriberTimeZones
  OPTIONS = [
    [ "Eastern Time — New York", "America/New_York" ],
    [ "Central Time — Chicago", "America/Chicago" ],
    [ "Mountain Time — Denver", "America/Denver" ],
    [ "Arizona (no DST)", "America/Phoenix" ],
    [ "Pacific Time — Los Angeles", "America/Los_Angeles" ],
    [ "Alaska — Anchorage", "America/Anchorage" ],
    [ "Hawaii", "Pacific/Honolulu" ],
    [ "Atlantic — Puerto Rico", "America/Puerto_Rico" ],
    [ "Guam", "Pacific/Guam" ],
    [ "American Samoa", "Pacific/Pago_Pago" ],
    [ "UTC", "Etc/UTC" ]
  ].freeze

  IANA_IDS = OPTIONS.map(&:last).freeze
  DEFAULT = "America/New_York"

  module_function

  def options_for_select(extra_iana: nil)
    list = OPTIONS.dup
    if extra_iana.present? && IANA_IDS.exclude?(extra_iana) && Time.find_zone(extra_iana)
      list.unshift([ "Detected — #{extra_iana}", extra_iana ])
    end
    list
  end

  def normalize(value)
    raw = value.to_s.strip
    return DEFAULT if raw.blank?
    return raw if Time.find_zone(raw)

    DEFAULT
  end

  def label_for(iana)
    OPTIONS.find { |(_, id)| id == iana }&.first || iana
  end
end
