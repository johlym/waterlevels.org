module States
  class LocationsTableComponent < ViewComponent::Base
    def initialize(locations:, state_label: nil)
      @locations = Array(locations)
    end

    def counties
      @locations
        .group_by { |loc| county_key(loc) }
        .sort_by { |key, _| key }
        .map { |key, locations| [ county_label(key, locations.first), locations ] }
    end

    def county_dom_id(county_name)
      county_name.to_s.parameterize.presence || "unspecified"
    end

    def county_jump_links
      counties
        .map { |name, locations| [ name, locations.size, county_dom_id(name) ] }
        .sort_by { |(name, _, _)| name.downcase }
    end

    def type_tokens(loc)
      tokens = []
      tokens << "streamflow" if truthy?(loc[:has_discharge] || loc["has_discharge"])
      tokens << "gauge-height" if truthy?(loc[:has_water_level] || loc["has_water_level"])
      tokens << "water-quality" if truthy?(loc[:has_temperature] || loc["has_temperature"])
      tokens
    end

    def stale?(loc)
      truthy?(loc[:stale] || loc["stale"])
    end

    private

    def county_key(loc)
      name = loc[:county_name].presence || loc["county_name"].presence
      name.to_s.strip.downcase
    end

    def county_label(key, sample)
      return "Unspecified" if key.blank?

      raw = sample[:county_name].presence || sample["county_name"].presence || key
      label = raw.to_s.sub(/\s+County\z/i, "")
      label = "#{label} County" unless label.casecmp("unspecified").zero? || label.match?(/county\z/i)
      label
    end

    def truthy?(value)
      value == true || value.to_s == "true"
    end
  end
end
