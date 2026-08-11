class LatestObservationSync
  include ActiveModel::Model

  # National tip sync touches thousands of selected series; flush DB writes in
  # slices instead of one upsert round-trip per USGS feature.
  UPSERT_BATCH = 200

  # Lean stand-in for TimeSeries during tip upserts — avoids caching full AR
  # graphs (and monitoring_location) for every USGS feature, including skips.
  SelectedSeries = Data.define(
    :id,
    :monitoring_location_id,
    :measurement_kind,
    :unit_of_measure
  ) do
    def selected_for_display?
      true
    end
  end

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
      @denormalize_location_ids = Set.new
      @locations_denormalized = 0
      progress&.step(scope_label)
      begin
        if postal_code
          sync_scoped!
        else
          sync_national_by_state!
        end
      rescue StandardError => e
        # Tip upserts may have succeeded for earlier parameters. Always denormalize
        # so map popups (which read MonitoringLocation tip columns) catch up.
        sync_error = e
      end

      denormalize_locations
      record_tip_refresh_stats!
      Telemetry.add_attributes(
        "app.series_count" => @upserted_series_ids.size,
        "app.observation_count" => @upserted_series_ids.size,
        "app.locations_count" => @locations_denormalized
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

  def sync_scoped!
    @selected_series_by_usgs_id = build_selected_series_index
    sync_parameters!
  ensure
    @selected_series_by_usgs_id = nil
  end

  # Cap peak memory: one state's selected-series index + one parameter stream at
  # a time, with incremental denormalize and GC between states.
  def sync_national_by_state!
    state_codes = MonitoringLocation.distinct.order(:state_code).pluck(:state_code)
    progress&.step("national states=#{state_codes.size}")

    state_codes.each do |code|
      @state = code
      @postal_code = nil
      progress&.step("state=#{code}")
      @selected_series_by_usgs_id = build_selected_series_index
      sync_parameters!
      denormalize_locations
      @selected_series_by_usgs_id = nil
      GC.start
    end
  ensure
    @state = nil
    @postal_code = nil
    @selected_series_by_usgs_id = nil
  end

  def sync_parameters!
    Usgs::ParameterCodes::ALL.each do |parameter_code|
      sync_parameter(parameter_code)
      GC.start
    end
  end

  def build_selected_series_index
    scope = TimeSeries.selected
    if postal_code
      scope = scope.joins(:monitoring_location).merge(MonitoringLocation.in_state(postal_code))
    end

    scope.pluck(
      :usgs_time_series_id,
      :id,
      :monitoring_location_id,
      :measurement_kind,
      :unit_of_measure
    ).each_with_object({}) do |(usgs_id, id, location_id, kind, unit), memo|
      memo[usgs_id.to_s] = SelectedSeries.new(id, location_id, kind, unit)
    end
  end

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
    latest_buffer = []
    continuous_buffer = []

    client.each_collection_item("latest-continuous", latest_query(parameter_code)) do |item|
      ts_id = (item["time_series_id"] || item["id"]).to_s
      series = find_series(ts_id)
      unless series
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
        # Still rewrite map columns so a prior bad/stale tip is cleared.
        @denormalize_location_ids << series.monitoring_location_id
        skipped += 1
        next
      end

      now = Time.current
      latest_buffer << {
        time_series_id: series.id,
        observed_at: observed_at,
        value: value,
        unit_of_measure: item["unit_of_measure"] || series.unit_of_measure,
        approval_status: item["approval_status"] || item["approval"],
        qualifier: item["qualifier"],
        source_last_modified_at: parse_time(item["last_modified"]),
        synced_at: now,
        created_at: now,
        updated_at: now
      }
      # Keep hydrographs / hourly tables moving between full history backfills.
      continuous_buffer << {
        time_series_id: series.id,
        observed_at: observed_at,
        value: value,
        approval_status: item["approval_status"] || item["approval"],
        qualifier: item["qualifier"],
        created_at: now,
        updated_at: now
      }
      @upserted_series_ids << series.id
      @denormalize_location_ids << series.monitoring_location_id
      count += 1
      progress&.increment

      if latest_buffer.size >= UPSERT_BATCH
        flush_tip_buffers!(latest_buffer, continuous_buffer)
      end
    end
    flush_tip_buffers!(latest_buffer, continuous_buffer)

    Telemetry.add_attributes(
      "app.observation_count" => count,
      "app.series_count" => count,
      "app.skipped_count" => skipped,
      "app.batch_size" => count + skipped
    )
    progress&.step("parameter=#{parameter_code} latest upserted=#{count} skipped=#{skipped}")
  end
  private :sync_parameter_body

  def flush_tip_buffers!(latest_buffer, continuous_buffer)
    if latest_buffer.any?
      # One tip per series — USGS can repeat a time_series_id in a page.
      latest_rows = latest_buffer.each_with_object({}) { |row, uniq|
        uniq[row[:time_series_id]] = row
      }.values
      LatestObservation.upsert_all(
        latest_rows,
        unique_by: :time_series_id,
        update_only: %i[
          observed_at
          value
          unit_of_measure
          approval_status
          qualifier
          source_last_modified_at
          synced_at
        ]
      )
      latest_buffer.clear
    end

    if continuous_buffer.any?
      # Same cardinality guard as HistoryIngestion (WATER-K): ON CONFLICT DO UPDATE
      # cannot touch a constrained key twice in one statement.
      continuous_rows = continuous_buffer.each_with_object({}) { |row, uniq|
        uniq[[ row[:time_series_id], row[:observed_at].to_i ]] = row
      }.values
      # Detect tip jumps against denorm tips *before* upsert/advance — after
      # advance, continuous_newest_at is already the new tip.
      enqueue_iv_repair_for_tip_jumps!(continuous_rows)
      ContinuousObservation.upsert_all(
        continuous_rows,
        unique_by: %i[time_series_id observed_at],
        update_only: %i[value approval_status qualifier]
      )
      tips = continuous_rows.each_with_object({}) { |row, hash|
        hash[row[:time_series_id]] = row[:observed_at]
      }
      TimeSeries.advance_continuous_tips!(tips)
      continuous_buffer.clear
    end
  end

  # When tip sync lands a new tip more than CONTINUOUS_GAP_THRESHOLD past the
  # previous continuous tip on an anchored series, the middle is hollow —
  # enqueue IV repair immediately instead of waiting for the catch-up batch.
  def enqueue_iv_repair_for_tip_jumps!(continuous_rows)
    series_ids = continuous_rows.map { |row| row[:time_series_id] }.uniq
    return if series_ids.empty?

    previous_by_id = TimeSeries.where(id: series_ids)
      .pluck(:id, :monitoring_location_id, :continuous_newest_at, :has_continuous_anchor)
      .each_with_object({}) { |(id, location_id, newest_at, anchored), memo|
        memo[id] = [ location_id, newest_at, anchored ]
      }

    threshold = HistoryIngestion.continuous_gap_threshold
    location_ids = Set.new
    continuous_rows.each do |row|
      location_id, newest_at, anchored = previous_by_id[row[:time_series_id]]
      next unless anchored
      next if newest_at.blank?

      observed_at = row[:observed_at]
      next if observed_at.blank?
      next unless (observed_at - newest_at) > threshold

      location_ids << location_id
    end
    return if location_ids.empty?

    enqueued = 0
    location_ids.each do |location_id|
      enqueued += 1 if IvRepairJob.enqueue(location_id)
    end
    Rails.logger.info(
      "LatestObservationSync tip_jump_iv_repair candidates=#{location_ids.size} " \
      "enqueued=#{enqueued} threshold=#{threshold.inspect}"
    )
    Telemetry.add_attributes(
      "app.tip_jump_iv_repair_candidates" => location_ids.size,
      "app.tip_jump_iv_repair_enqueued" => enqueued
    )
  end

  def find_series(usgs_time_series_id)
    @selected_series_by_usgs_id&.[](usgs_time_series_id)
  end

  def denormalize_locations
    progress&.step("denormalizing location latest values")
    location_ids = @denormalize_location_ids.to_a
    if location_ids.empty?
      progress&.step("locations denormalized=0")
      return 0
    end

    scope = MonitoringLocation.where(id: location_ids).includes(time_series: :latest_observation)
    scope = scope.in_state(postal_code) if postal_code
    count = 0

    scope.find_each do |location|
      # Re-apply selection so discontinued series (stale tip while siblings are
      # fresh) drop off has_* / Partial / history gates without waiting for the
      # weekly catalog sync. Snapshots rebuild lazily via StationSnapshotCache.fetch.
      DisplaySeriesSelection.apply!(location)
      count += 1
      progress&.increment
    end

    @denormalize_location_ids = Set.new
    @locations_denormalized += count
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
