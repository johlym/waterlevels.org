module Usace
  # Curated CWMS projects for P2. Prefer Corps-owned pool elevation series and
  # skip USGS-revision mirrors (e.g. *.Rev-USGS). Expand ACTIVE after the
  # initial three reservoirs ship.
  module ProjectCatalog
    Entry = Data.define(
      :office,
      :location_name,
      :site_number,
      :name,
      :state_code,
      :state_name,
      :latitude,
      :longitude,
      :time_zone,
      :tip_timeseries_name,
      :history_timeseries_name,
      :parameter_code,
      :unit_of_measure,
      :parameter_description,
      :datum_note
    )

    ALLOWLIST = [
      Entry.new(
        office: "NAB",
        location_name: "Raystown",
        site_number: "usacenabraystown",
        name: "Raystown Lake",
        state_code: "pa",
        state_name: "Pennsylvania",
        latitude: 40.4271314,
        longitude: -78.0013693,
        time_zone: "EST",
        tip_timeseries_name: "Raystown.Elev.Inst.15Minutes.0.Best-NAB",
        history_timeseries_name: "Raystown.Elev.Ave.~1Day.1Day.Best-NAB",
        parameter_code: ParameterCodes::ELEVATION,
        unit_of_measure: "ft",
        parameter_description: "Lake/reservoir elevation, feet (PCD / local datum)",
        datum_note: "PCD (local); offsets to NAVD-88 published by CWMS"
      ),
      Entry.new(
        office: "SAS",
        location_name: "Hartwell",
        site_number: "usacesashartwell",
        name: "Hartwell Dam",
        state_code: "ga",
        state_name: "Georgia",
        latitude: 34.357464600771,
        longitude: -82.821377999205,
        time_zone: "CST",
        tip_timeseries_name: "Hartwell.Elev-Pool_Avg.Inst.1Day.0.ARCHIVE-DAILY",
        history_timeseries_name: "Hartwell.Elev-Pool_Avg.Inst.1Day.0.ARCHIVE-DAILY",
        parameter_code: ParameterCodes::ELEVATION,
        unit_of_measure: "ft",
        parameter_description: "Lake/reservoir pool elevation, feet",
        datum_note: "NGVD29"
      ),
      Entry.new(
        office: "SAJ",
        location_name: "Okeechobee",
        site_number: "usacesajokeechobee",
        name: "Lake Okeechobee",
        state_code: "fl",
        state_name: "Florida",
        latitude: 26.945821,
        longitude: -80.809896,
        time_zone: "EST",
        tip_timeseries_name: "Okeechobee.Elev.Ave.~1Day.1Day.Best-SAJ-POR",
        history_timeseries_name: "Okeechobee.Elev.Ave.~1Day.1Day.Best-SAJ-POR",
        parameter_code: ParameterCodes::ELEVATION,
        unit_of_measure: "ft",
        parameter_description: "Lake/reservoir elevation, feet (NGVD29)",
        datum_note: "NGVD29"
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

    def provider_location_id(office, location_name)
      "USACE-#{office}-#{location_name}"
    end

    def provider_series_id(office, timeseries_name)
      "USACE-#{office}-#{timeseries_name}"
    end
  end
end
