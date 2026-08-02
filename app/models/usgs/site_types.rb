module Usgs
  module SiteTypes
    # Surface-water / water-body site types we keep in the product catalog.
    # Groundwater wells (GW*) dominate the USGS monitoring-locations collection
    # and are excluded unless they also report continuous surface parameters via
    # latest-continuous and pass this allowlist after location metadata fetch.
    WATER_BODY = %w[
      ST
      ST-CA
      ST-DCH
      ST-TS
      LK
      ES
      OC
      SP
    ].freeze

    module_function

    def water_body?(code)
      WATER_BODY.include?(code.to_s.upcase)
    end
  end
end
