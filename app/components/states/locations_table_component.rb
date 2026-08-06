module States
  class LocationsTableComponent < ViewComponent::Base
    FLOOD_STAGE_FILTERS = Nwps::FloodCategories::ALERT.map { |key|
      [ key, Nwps::FloodCategories.label_for(key) ]
    }.freeze

    def initialize(locations:, state_label: nil, group_by: :county, show_alerts_filter: nil, show_flood_stages_filter: false)
      @locations = Array(locations)
      @group_by = group_by.to_sym
      @show_alerts_filter = show_alerts_filter
      @show_flood_stages_filter = show_flood_stages_filter
    end

    def groups
      case @group_by
      when :state then state_groups
      else counties
      end
    end

    def counties
      @locations
        .group_by { |loc| county_key(loc) }
        .sort_by { |key, _| key }
        .map { |key, locations| [ county_label(key, locations.first), locations ] }
    end

    def state_groups
      @locations
        .group_by { |loc| state_key(loc) }
        .sort_by { |key, _| key }
        .map { |key, locations| [ state_label_for(key, locations.first), locations ] }
    end

    def group_dom_id(group_name)
      group_name.to_s.parameterize.presence || "unspecified"
    end

    def county_dom_id(county_name)
      group_dom_id(county_name)
    end

    def group_jump_links
      groups
        .map { |name, locations| [ name, locations.size, group_dom_id(name) ] }
        .sort_by { |(name, _, _)| name.downcase }
    end

    def county_jump_links
      group_jump_links
    end

    def group_jump_label
      @group_by == :state ? "Quick state jump" : "Quick county jump"
    end

    def show_alerts_filter?
      return @show_alerts_filter unless @show_alerts_filter.nil?

      any_alerts?
    end

    def show_flood_stages_filter?
      @show_flood_stages_filter
    end

    def flood_stage_filters
      FLOOD_STAGE_FILTERS
    end

    def flood_stage_token(loc)
      Nwps::FloodCategories.normalize(loc[:flood_category] || loc["flood_category"])
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

    def flood_alert?(loc)
      truthy?(loc[:flood_alert] || loc["flood_alert"])
    end

    def alert_locations
      @alert_locations ||= @locations.select { |loc| flood_alert?(loc) }
    end

    def alert_count
      alert_locations.size
    end

    def any_alerts?
      alert_count.positive?
    end

    private

    def county_key(loc)
      name = loc[:county_name].presence || loc["county_name"].presence
      name.to_s.strip.downcase
    end

    def county_label(key, sample)
      return "Unspecified" if key.blank?

      raw = sample[:county_name].presence || sample["county_name"].presence || key
      helpers.display_county_name(raw).presence || "Unspecified"
    end

    def state_key(loc)
      code = loc[:state_code].presence || loc["state_code"].presence
      code.to_s.strip.downcase
    end

    def state_label_for(key, sample)
      return "Unspecified" if key.blank?

      sample[:state_name].presence || sample["state_name"].presence || key.upcase
    end

    def truthy?(value)
      value == true || value.to_s == "true"
    end
  end
end
