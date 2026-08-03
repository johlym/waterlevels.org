module Usgs
  # Reporting-agency helpers for USGS NWIS `agency_code` / `agency_name`.
  # Non-USGS codes (e.g. TX071 = LCRA) identify the agency that operates the site;
  # USGS remains the distribution channel via the Water Data APIs.
  module AgencyCodes
    USGS = "USGS"

    module_function

    def usgs?(agency_code)
      agency_code.to_s.strip.casecmp?(USGS)
    end

    # Human-facing co-credit for the gauge footer, or nil when USGS / unknown.
    def credit_for(agency_code, agency_name: nil)
      return if usgs?(agency_code)

      clean_name(agency_name)
    end

    # "Lower Colorado River Authority, TX" → "Lower Colorado River Authority"
    def clean_name(agency_name)
      agency_name.to_s.sub(/,\s*[A-Za-z]{2}\z/, "").strip.presence
    end
  end
end
