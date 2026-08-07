class LatestObservationSync
  include ActiveModel::Model

  attr_accessor :client, :state, :progress

  def initialize(client: Usgs::Client.for_tip, state: nil, progress: nil)
    @client = client
    @state = state.presence
    @progress = progress
  end

  def perform
    Telemetry.in_root_span(
      "latest.sync",
      attributes: {
        "app.operation" => "latest.sync",
        "app.state" => postal_code || "national"
      }
    ) do
      sync_error = nil
      @upserted_series_ids = Set.new
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

      denormalized = denormalize_locations
      record_tip_refresh_stats!
      Telemetry.add_attributes(
        "app.series_count" => @upserted_series_ids.size,
        "app.observation_count" => @upserted_series_ids.size,
        "app.locations_count" => denormalized
      )

      unless sync_error
        progress&.step("warming state listing caches")
        StateListingCache.warm_all
        AlertsListingCache.warm
        SiteStats.warm!
      end

      progress&.step("purging edge cache tags")
      EdgeCacheInvalidation.after_latest_sync!(state: state)
      progress&.finish("latest_observations=#{latest_scope.count}")
      if sync_error
        Telemetry.add_attributes("exception.slug" => "err-latest-sync")
        raise sync_error
      end

      true
    end
  end


  private

  def record_tip_refresh_stats!
    series_ids = @upserted_series_ids.to_a
    stations_updated =
      if series_ids.empty?
        0
      else
        TimeSeries.where(id: series_ids).distinct.count(:monitoring_location_id)
      end

    AdminDashboardStats.record_tip_refresh!(
      stations_updated: stations_updated,
      series_upserted: series_ids.size,
      finished_at: Time.current,
      state: postal_code
    )
  end


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
    Telemetry.in_span(
      "latest.sync_parameter",
      attributes: {
        "app.operation" => "latest.sync_parameter",
        "app.state" => postal_code || "national",
        "app.parameter_code" => parameter_code
      }
    ) do
      sync_parameter_body(parameter_code)
    end
  end

  def sync_parameter_body(parameter_code)
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
      @upserted_series_ids << series.id
      count += 1
      progress&.increment
    end

    Telemetry.add_attributes(
      "app.observation_count" => count,
      "app.series_count" => count,
      "app.skipped_count" => skipped,
      "app.batch_size" => count + skipped
    )
    progress&.step("parameter=#{parameter_code} latest upserted=#{count} skipped=#{skipped}")
  end
  private :sync_parameter_body

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

    Telemetry.add_attributes("app.locations_denormalized" => count)
    progress&.step("locations denormalized=#{count}")
    count
  end

  def parse_time(value)
    return if value.blank?
    Time.zone.parse(value.to_s)
  rescue ArgumentError
    nil
  end
end
