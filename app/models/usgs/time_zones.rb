module Usgs
  # Maps USGS `time_zone_abbreviation` values (e.g. CST, PDT) to IANA zones
  # so observation timestamps can be shown in the station's local clock.
  module TimeZones
    ABBREVIATION_TO_IANA = {
      "EST" => "America/New_York",
      "EDT" => "America/New_York",
      "ET" => "America/New_York",
      "CST" => "America/Chicago",
      "CDT" => "America/Chicago",
      "CT" => "America/Chicago",
      "MST" => "America/Denver",
      "MDT" => "America/Denver",
      "MT" => "America/Denver",
      "PST" => "America/Los_Angeles",
      "PDT" => "America/Los_Angeles",
      "PT" => "America/Los_Angeles",
      "AKST" => "America/Anchorage",
      "AKDT" => "America/Anchorage",
      "HST" => "Pacific/Honolulu",
      "HAST" => "Pacific/Honolulu",
      "HADT" => "Pacific/Honolulu",
      "SST" => "Pacific/Pago_Pago",
      "CHST" => "Pacific/Guam",
      "AST" => "America/Puerto_Rico",
      "ADT" => "America/Halifax",
      "GMT" => "Etc/UTC",
      "UTC" => "Etc/UTC"
    }.freeze

    module_function

    def iana_identifier(abbreviation, state_code: nil)
      raw = abbreviation.to_s.strip
      return if raw.blank?
      return raw if iana_name?(raw)

      key = raw.upcase
      if key == "MST" && state_code.to_s.downcase == "az"
        return "America/Phoenix"
      end

      ABBREVIATION_TO_IANA[key]
    end

    def resolve(abbreviation, state_code: nil)
      identifier = iana_identifier(abbreviation, state_code: state_code)
      return if identifier.blank?

      Time.find_zone(identifier)
    end

    def iana_name?(value)
      value.include?("/") && Time.find_zone(value).present?
    end
  end
end
