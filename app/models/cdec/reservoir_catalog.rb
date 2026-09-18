module Cdec
  # Curated California reservoirs for P4. Daily reservoir elevation (sensor 6).
  # Skip pools already ingested from USBR or USACE — none of these three are on
  # those allowlists. Shasta is USBR-operated, but RISE is not the source here
  # (P1 only covers Lake Mead), so CDEC fills that gap.
  module ReservoirCatalog
    Entry = Data.define(
      :station_id,
      :sensor_num,
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
        station_id: "ORO",
        sensor_num: 6,
        site_number: "cdecoro",
        name: "Lake Oroville",
        state_code: "ca",
        state_name: "California",
        latitude: 39.54,
        longitude: -121.493,
        time_zone: "PST",
        parameter_code: ParameterCodes::ELEVATION,
        unit_of_measure: "ft",
        parameter_description: "Lake/reservoir elevation, feet (CDEC sensor 6)",
        datum_note: "CDEC reservoir elevation (feet)"
      ),
      Entry.new(
        station_id: "SHA",
        sensor_num: 6,
        site_number: "cdecsha",
        name: "Lake Shasta",
        state_code: "ca",
        state_name: "California",
        latitude: 40.718,
        longitude: -122.42,
        time_zone: "PST",
        parameter_code: ParameterCodes::ELEVATION,
        unit_of_measure: "ft",
        parameter_description: "Lake/reservoir elevation, feet (CDEC sensor 6)",
        datum_note: "CDEC reservoir elevation (feet); Shasta is USBR-operated but not in the USBR RISE allowlist"
      ),
      Entry.new(
        station_id: "FOL",
        sensor_num: 6,
        site_number: "cdecfol",
        name: "Folsom Lake",
        state_code: "ca",
        state_name: "California",
        latitude: 38.683,
        longitude: -121.183,
        time_zone: "PST",
        parameter_code: ParameterCodes::ELEVATION,
        unit_of_measure: "ft",
        parameter_description: "Lake/reservoir elevation, feet (CDEC sensor 6)",
        datum_note: "CDEC reservoir elevation (feet)"
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

    def provider_location_id(station_id)
      "CDEC-#{station_id}"
    end

    def provider_series_id(station_id, sensor_num)
      "CDEC-#{station_id}-#{sensor_num}"
    end
  end
end
