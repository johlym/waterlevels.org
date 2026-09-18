module Nwps
  # Curated NWPS gauges that have no usgsId — first-class MonitoringLocation
  # rows for P3. Skip lids that NWPS already joins to USGS (FloodStageSync) and
  # water bodies already covered by USBR (e.g. Mead / Mohave via BHDA3/MOHA3
  # which publish usgsId). Prefer stage-in-feet tips over discharge-primary lids.
  module GaugeCatalog
    Entry = Data.define(
      :lid,
      :site_number,
      :name,
      :state_code,
      :state_name,
      :latitude,
      :longitude,
      :time_zone,
      :parameter_code,
      :unit_of_measure,
      :parameter_description
    )

    ALLOWLIST = [
      Entry.new(
        lid: "ACRW1",
        site_number: "nwpsacrw1",
        name: "Alpowa Creek at Mouth",
        state_code: "wa",
        state_name: "Washington",
        latitude: 46.412222222222,
        longitude: -117.21333333333,
        time_zone: "PST",
        parameter_code: ParameterCodes::STAGE,
        unit_of_measure: "ft",
        parameter_description: "Gage height, feet (NWS NWPS observed stage)"
      ),
      Entry.new(
        lid: "BLKW1",
        site_number: "nwpsblkw1",
        name: "Black River at Hwy 12",
        state_code: "wa",
        state_name: "Washington",
        latitude: 46.8305555555556,
        longitude: -123.184722222222,
        time_zone: "PST",
        parameter_code: ParameterCodes::STAGE,
        unit_of_measure: "ft",
        parameter_description: "Gage height, feet (NWS NWPS observed stage)"
      ),
      Entry.new(
        lid: "ASTO3",
        site_number: "nwpsasto3",
        name: "Columbia River at Tongue Point near Astoria",
        state_code: "or",
        state_name: "Oregon",
        latitude: 46.208333333333,
        longitude: -123.76666666667,
        time_zone: "PST",
        parameter_code: ParameterCodes::STAGE,
        unit_of_measure: "ft",
        parameter_description: "Gage height, feet (NWS NWPS observed stage)"
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

    def find_by_lid(lid)
      ALLOWLIST.find { |entry| entry.lid.casecmp?(lid.to_s) }
    end

    def provider_location_id(lid)
      "NWPS-#{lid.to_s.upcase}"
    end

    def provider_series_id(lid)
      "NWPS-#{lid.to_s.upcase}-stage"
    end
  end
end
