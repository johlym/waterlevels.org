# Frozen constants and helpers for multi-agency monitoring locations.
# USGS remains the default; non-USGS providers plug in after P0 identity work.
module DataProviders
  USGS = "usgs"
  USBR = "usbr"
  USACE = "usace"
  NWPS = "nwps"
  CDEC = "cdec"

  ALL = [ USGS, USBR, USACE, NWPS, CDEC ].freeze

  AGENCY_LABELS = {
    USGS => "U.S. Geological Survey",
    USBR => "U.S. Bureau of Reclamation",
    USACE => "U.S. Army Corps of Engineers",
    NWPS => "National Weather Service",
    CDEC => "California Data Exchange Center"
  }.freeze

  module_function

  def label_for(provider)
    AGENCY_LABELS[provider.to_s] || provider.to_s.upcase
  end

  def agency_url_for(location)
    provider = location.data_provider.to_s
    external_id = location.provider_location_id.to_s

    case provider
    when USGS
      "https://waterdata.usgs.gov/monitoring-location/#{external_id}/"
    when USBR
      rise_id = external_id.delete_prefix("USBR-")
      "https://data.usbr.gov/location/#{rise_id}"
    when USACE
      # USACE-NAB-Raystown → office NAB, CWMS location name Raystown
      rest = external_id.delete_prefix("USACE-")
      office, name = rest.split("-", 2)
      if office.present? && name.present?
        encoded_name = URI.encode_www_form_component(name)
        encoded_office = URI.encode_www_form_component(office)
        "https://cwms-data.usace.army.mil/cwms-data/locations/#{encoded_name}?office=#{encoded_office}"
      end
    when NWPS
      lid = location.nwps_lid.presence || external_id.delete_prefix("NWPS-")
      "https://water.noaa.gov/gauges/#{lid}" if lid.present?
    when CDEC
      station = external_id.delete_prefix("CDEC-")
      "https://cdec.water.ca.gov/dynamicapp/staMeta?station_id=#{station}" if station.present?
    end
  end
end
