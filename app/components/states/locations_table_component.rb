module States
  class LocationsTableComponent < ViewComponent::Base
    def initialize(locations:)
      @locations = Array(locations)
    end

    def counties
      @locations
        .group_by { |loc| county_key(loc) }
        .sort_by { |key, _| key }
        .map { |key, locations| [ county_label(key, locations.first), locations ] }
    end

    def county_dom_id(county_name)
      "county-#{county_name.to_s.parameterize.presence || "unspecified"}"
    end

    private

    def county_key(loc)
      name = loc[:county_name].presence || loc["county_name"].presence
      name.to_s.strip.downcase
    end

    def county_label(key, sample)
      return "Unspecified" if key.blank?

      raw = sample[:county_name].presence || sample["county_name"].presence || key
      raw.to_s.sub(/\s+County\z/i, "")
    end
  end
end
