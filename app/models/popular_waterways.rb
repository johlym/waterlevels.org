class PopularWaterways
  REGIONS = [
    {
      key: "colorado-river",
      name: "Colorado River",
      blurb: "Major gauges along the Colorado and its lower basin.",
      site_numbers: %w[09380000 09421500 09427520]
    },
    {
      key: "mississippi-basin",
      name: "Mississippi Basin",
      blurb: "Key Mississippi River measuring points from Midwest to the Gulf.",
      site_numbers: %w[07010000 07032000 07374000]
    },
    {
      key: "great-lakes",
      name: "Great Lakes",
      blurb: "Connecting-channel and shoreline stations around the lakes.",
      site_numbers: %w[04165710 04216000 04159130]
    },
    {
      key: "pacific-northwest",
      name: "Pacific Northwest",
      blurb: "Columbia, Willamette, and Snake River reference gauges.",
      site_numbers: %w[14105700 14211720 13334300]
    }
  ].freeze

  Region = Data.define(:key, :name, :blurb, :stations)

  class << self
    def regions
      by_site = MonitoringLocation.where(site_number: all_site_numbers).index_by(&:site_number)

      REGIONS.map do |region|
        stations = region[:site_numbers].filter_map { |site_number| by_site[site_number] }
        Region.new(
          key: region[:key],
          name: region[:name],
          blurb: region[:blurb],
          stations: stations
        )
      end
    end

    def all_site_numbers
      REGIONS.flat_map { |region| region[:site_numbers] }
    end
  end
end
