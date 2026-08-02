class LatestObservationSync
  include ActiveModel::Model

  attr_accessor :client, :state, :progress

  def initialize(client: Usgs::Client.new, state: nil, progress: nil)
    @client = client
    @state = state.presence
    @progress = progress
  end

  def perform
    progress&.step(scope_label)
    Usgs::ParameterCodes::ALL.each do |parameter_code|
      sync_parameter(parameter_code)
    end
    denormalize_locations
    progress&.step("warming stale station snapshots")
    StationSnapshotCache.warm_stale_batch
    progress&.step("warming state listing caches")
    StateListingCache.warm_all
    progress&.finish("latest_observations=#{latest_scope.count}")
    true
  end

  private

  def scope_label
    postal_code ? "state=#{postal_code}" : "national"
  end

  def postal_code
    @postal_code ||= state && Usgs::StateCodes.normalize_postal(state)
  end

  def latest_query(parameter_code)
    query = { parameter_code: parameter_code }
    query[:state_code] = Usgs::StateCodes.fips_for(postal_code) if postal_code
    query
  end

  def latest_scope
    scope = LatestObservation.joins(time_series: :monitoring_location)
    postal_code ? scope.merge(MonitoringLocation.in_state(postal_code)) : scope
  end

  def sync_parameter(parameter_code)
    progress&.step("syncing latest-continuous parameter=#{parameter_code}")
    count = 0
    skipped = 0

    client.each_collection_item("latest-continuous", latest_query(parameter_code)) do |item|
      ts_id = item["time_series_id"] || item["id"]
      series = TimeSeries.find_by(usgs_time_series_id: ts_id.to_s)
      unless series&.selected_for_display?
        skipped += 1
        next
      end
      if postal_code && series.monitoring_location.state_code != postal_code
        skipped += 1
        next
      end

      observed_at = parse_time(item["time"] || item["observed_at"] || item["datetime"])
      value = item["value"] || item["observation_value"]
      if observed_at.blank? || value.blank?
        skipped += 1
        next
      end

      LatestObservation.upsert(
        {
          time_series_id: series.id,
          observed_at: observed_at,
          value: value,
          unit_of_measure: item["unit_of_measure"] || series.unit_of_measure,
          approval_status: item["approval_status"] || item["approval"],
          qualifier: item["qualifier"],
          source_last_modified_at: parse_time(item["last_modified"]),
          synced_at: Time.current,
          created_at: Time.current,
          updated_at: Time.current
        },
        unique_by: :time_series_id
      )
      count += 1
      progress&.increment
    end

    progress&.step("parameter=#{parameter_code} latest upserted=#{count} skipped=#{skipped}")
  end

  def denormalize_locations
    progress&.step("denormalizing location latest values")
    scope = MonitoringLocation.includes(time_series: :latest_observation)
    scope = scope.in_state(postal_code) if postal_code
    count = 0

    scope.find_each do |location|
      attrs = {
        latest_water_level_value: nil,
        latest_water_level_parameter_code: nil,
        latest_water_level_unit: nil,
        latest_discharge_value: nil,
        latest_discharge_unit: nil,
        latest_temperature_c: nil,
        latest_observed_at: nil,
        latest_approval_status: nil
      }

      selected = location.time_series.select(&:selected_for_display?)
      water_levels = selected
        .select { |s| s.measurement_kind == "water_level" && s.latest_observation }
        .sort_by { |s| Usgs::ParameterCodes.preference_rank(s.parameter_code) }
      preferred_water_level = water_levels.first

      if preferred_water_level
        obs = preferred_water_level.latest_observation
        attrs[:latest_water_level_value] = obs.value
        attrs[:latest_water_level_parameter_code] = preferred_water_level.parameter_code
        attrs[:latest_water_level_unit] = obs.unit_of_measure
        attrs[:latest_approval_status] = obs.approval_status
      end

      times = []
      selected.each do |series|
        obs = series.latest_observation
        next unless obs

        times << obs.observed_at
        case series.measurement_kind
        when "discharge"
          attrs[:latest_discharge_value] = obs.value
          attrs[:latest_discharge_unit] = obs.unit_of_measure
          attrs[:latest_approval_status] ||= obs.approval_status
        when "temperature"
          attrs[:latest_temperature_c] = obs.value
          attrs[:latest_approval_status] ||= obs.approval_status
        end
      end
      attrs[:latest_observed_at] = times.compact.max
      location.update!(attrs)
      StationSnapshotCache.warm(location)
      count += 1
      progress&.increment
    end

    progress&.step("locations denormalized=#{count}")
  end

  def parse_time(value)
    return if value.blank?
    Time.zone.parse(value.to_s)
  rescue ArgumentError
    nil
  end
end
