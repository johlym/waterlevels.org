class LatestObservationSync
  include ActiveModel::Model

  attr_accessor :client, :state, :progress

  def initialize(client: Usgs::Client.new, state: nil, progress: nil)
    @client = client
    @state = state.presence
    @progress = progress
  end

  def perform
    sync_error = nil
    progress&.step(scope_label)
    begin
      Usgs::ParameterCodes::ALL.each do |parameter_code|
        sync_parameter(parameter_code)
      end
    rescue StandardError => e
      # Tip upserts may have succeeded for earlier parameters. Always denormalize
      # so map popups (which read MonitoringLocation tip columns) catch up.
      sync_error = e
    end

    denormalize_locations

    unless sync_error
      progress&.step("warming state listing caches")
      StateListingCache.warm_all
      AlertsListingCache.warm
      SiteStats.warm!
    end

    progress&.step("purging edge cache tags")
    EdgeCacheInvalidation.after_latest_sync!(state: state)
    progress&.finish("latest_observations=#{latest_scope.count}")
    raise sync_error if sync_error

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
      # USGS fault sentinels (e.g. -100000 degC) overflow latest_temperature_c.
      if series.measurement_kind == "temperature" && !Usgs::ParameterCodes.plausible_temperature_c?(value)
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
      # Keep hydrographs / hourly tables moving between full history backfills.
      ContinuousObservation.upsert(
        {
          time_series_id: series.id,
          observed_at: observed_at,
          value: value,
          approval_status: item["approval_status"] || item["approval"],
          qualifier: item["qualifier"],
          created_at: Time.current,
          updated_at: Time.current
        },
        unique_by: %i[time_series_id observed_at]
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
      selected = location.time_series.select(&:selected_for_display?)
      DisplaySeriesSelection.denormalize!(location, selected: selected)
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
