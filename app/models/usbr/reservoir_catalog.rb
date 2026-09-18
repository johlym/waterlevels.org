module Usbr
  # Curated RISE reservoirs for P1. List filters on data.usbr.gov were unreliable;
  # pin location + catalog-item ids explicitly. Expand ACTIVE after Mead ships.
  module ReservoirCatalog
    Entry = Data.define(
      :rise_location_id,
      :elevation_item_id,
      :site_number,
      :name,
      :state_code,
      :state_name,
      :latitude,
      :longitude,
      :time_zone,
      :parameter_code,
      :unit_of_measure,
      :parameter_description,
      :datum_note
    )

    ALLOWLIST = [
      Entry.new(
        rise_location_id: 3514,
        elevation_item_id: 6123,
        site_number: "usbr3514",
        name: "Lake Mead at Hoover Dam",
        state_code: "nv",
        state_name: "Nevada",
        latitude: 36.0163,
        longitude: -114.7374,
        time_zone: "MT",
        parameter_code: ParameterCodes::ELEVATION,
        unit_of_measure: "ft",
        parameter_description: "Lake/reservoir elevation, feet (USGS 1912 / Power House Datum)",
        datum_note: "USGS 1912 (Power House Datum)"
      )
    ].freeze

    ACTIVE = ALLOWLIST.freeze

    module_function

    def active_entries
      ACTIVE
    end

    def find_by_site_number(site_number)
      ALLOWLIST.find { |entry| entry.site_number == site_number.to_s }
    end

    def provider_location_id(rise_location_id)
      "USBR-#{rise_location_id}"
    end

    def provider_series_id(elevation_item_id)
      "USBR-item-#{elevation_item_id}"
    end
  end
end
