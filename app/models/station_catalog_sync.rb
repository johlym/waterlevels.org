require "set"

class StationCatalogSync
  include ActiveModel::Model

  ID_BATCH_SIZE = 100

  attr_accessor :client, :state, :progress

  def initialize(client: Usgs::Client.for_tip, state: nil, progress: nil, checkpoint: nil)
    @client = client
    @state = state.presence
    @progress = progress
    @checkpoint = checkpoint
  end

  def perform
    Telemetry.in_root_span(
      "catalog.sync",
      attributes: {
        "app.operation" => "catalog.sync",
        "app.state" => postal_code || "national"
      }
    ) do
      perform_body
    end
  end

  def perform_body
    checkpoint = @checkpoint || StationCatalogCheckpoint.resume_or_start!(state: postal_code)
    skipped_parameter_codes = checkpoint.completed_parameter_codes
    kept_location_ids = checkpoint.kept_location_ids.to_set
    discovered_rows = checkpoint.discovered_rows
    resumed = checkpoint.resumed

    progress&.step(scope_label)
    if resumed
      remaining = checkpoint.remaining_parameter_codes
      progress&.step(
        "resuming catalog completed=#{skipped_parameter_codes.join(",")} " \
        "remaining=#{remaining.join(",").presence || "none"}"
      )
    else
      progress&.step("starting catalog")
    end
    Telemetry.add_attributes(
      "app.catalog_resumed" => resumed,
      "app.completed_parameter_codes" => skipped_parameter_codes.join(",")
    )

    begin
      Usgs::ParameterCodes::ALL.each do |parameter_code|
        if checkpoint.completed?(parameter_code)
          progress&.step("parameter=#{parameter_code} skipped (completed)")
          next
        end

        rows = discover_active_series_for(parameter_code)
        parameter_discovered = rows.size
        discovered_rows += parameter_discovered
        progress&.step("parameter=#{parameter_code} active series=#{parameter_discovered}")
        Telemetry.add_attributes(
          "app.parameter_code" => parameter_code,
          "app.batch_size" => parameter_discovered
        )

        kept = upsert_locations_for(rows)
        kept_location_ids.merge(kept)

        rows.select! { |row| kept.include?(row[:monitoring_location_id]) }
        upsert_time_series_for(rows)
        upsert_latest_observations(rows)
        # New series default to selected_for_display=false. Reselect just the
        # locations this parameter touched so 00065 is displayable before 00060
        # starts paging — do not wait for the final full pass.
        select_display_series(usgs_ids: kept)
        checkpoint.mark_parameter!(
          parameter_code,
          kept_location_ids: kept,
          discovered_rows: parameter_discovered
        )
      end
    ensure
      # Full pass drops discontinued kinds (locations not in this week's
      # latest-continuous for that code) and heals selection if the loop aborted.
      select_display_series
    end

    progress&.step("water-body locations kept=#{kept_location_ids.size}")
    prune_inactive_locations!(kept_location_ids.to_a)

    progress&.step("refreshing nearby stations")
    NearbyStations.refresh_all
    progress&.step("refreshing network stations")
    network_batch = AppConfig.integer(:nldi_refresh_batch)
    network_refreshed = NetworkStations.refresh(location_scope, limit: network_batch)
    progress&.step("network stations refreshed=#{network_refreshed} batch=#{network_batch}")
    NetworkRefreshBatchJob.perform_later
    progress&.step("warming state listing caches")
    StateListingCache.warm_all
    AlertsListingCache.warm
    progress&.step("warming station snapshots")
    location_scope.find_each { |location| StationSnapshotCache.warm(location) }
    progress&.step("purging edge cache tags")
    EdgeCacheInvalidation.after_catalog_sync!(state: state)
    location_count = location_scope.count
    series_count = time_series_scope.count
    Telemetry.add_attributes(
      "app.locations_kept" => kept_location_ids.size,
      "app.locations_count" => location_count,
      "app.series_count" => series_count,
      "app.observation_count" => discovered_rows,
      "app.batch_size" => kept_location_ids.size,
      "app.catalog_resumed" => resumed
    )
    progress&.finish("locations=#{location_count} time_series=#{series_count}")
    AdminDashboardStats.record_job_finish!(
      :catalog_sync,
      state: postal_code,
      locations: location_count,
      resumed: resumed,
      skipped_parameter_codes: skipped_parameter_codes.join(",")
    )
    checkpoint.clear!
    AdminDashboardStats.schedule_inventory_refresh!
    true
  end
  private :perform_body

  private

  def scope_label
    postal_code ? "state=#{postal_code} (active continuous only)" : "national (active continuous only)"
  end

  def postal_code
    @postal_code ||= state && Usgs::StateCodes.normalize_postal(state)
  end

  def location_scope
    scope = MonitoringLocation.all
    postal_code ? scope.in_state(postal_code) : scope
  end

  def time_series_scope
    scope = TimeSeries.joins(:monitoring_location)
    postal_code ? scope.merge(MonitoringLocation.in_state(postal_code)) : scope
  end

  def latest_query(parameter_code)
    query = { parameter_code: parameter_code }
    query[:state_code] = Usgs::StateCodes.fips_for(postal_code) if postal_code
    query
  end

  def discover_active_series_for(parameter_code)
    progress&.step("discovering latest-continuous parameter=#{parameter_code}")
    rows = []
    client.each_collection_item("latest-continuous", latest_query(parameter_code)) do |item|
      location_id = item["monitoring_location_id"]
      ts_id = item["time_series_id"] || item["id"]
      next if location_id.blank? || ts_id.blank?

      kind = Usgs::ParameterCodes.measurement_kind_for(parameter_code)
      next unless kind

      rows << {
        monitoring_location_id: location_id.to_s,
        time_series_id: ts_id.to_s,
        parameter_code: parameter_code,
        measurement_kind: kind,
        value: item["value"] || item["observation_value"],
        observed_at: item["time"] || item["observed_at"] || item["datetime"],
        unit_of_measure: item["unit_of_measure"],
        approval_status: item["approval_status"] || item["approval"],
        qualifier: item["qualifier"],
        last_modified: item["last_modified"],
        longitude: item["longitude"],
        latitude: item["latitude"]
      }
      progress&.increment
    end
    rows.uniq { |row| row[:time_series_id] }
  end

  def upsert_locations_for(active_rows)
    location_ids = active_rows.map { |row| row[:monitoring_location_id] }.uniq
    kept = []

    location_ids.each_slice(ID_BATCH_SIZE) do |batch|
      progress&.step("fetching location metadata batch=#{batch.size}")
      client.each_collection_item("monitoring-locations", id: batch.join(",")) do |item|
        usgs_id = item["id"].presence || item["monitoring_location_id"]
        site_type = item["site_type_code"].to_s.upcase
        unless Usgs::SiteTypes.water_body?(site_type)
          progress&.step("skip non-water-body #{usgs_id} site_type=#{site_type}") if ENV["USGS_VERBOSE"]
          next
        end

        site_number = item["monitoring_location_number"].presence || usgs_id.to_s.split("-").last
        lat = item["latitude"] || item["dec_lat_va"]
        lon = item["longitude"] || item["dec_long_va"]
        next if site_number.blank? || lat.blank? || lon.blank?

        # National latest-continuous discovery includes sites in Canada/Mexico
        # (USGS FIPS 81–86 / 90–98). Skip jurisdictions we do not catalog —
        # raising here would abort the whole weekly StationCatalogSyncJob.
        state_code = Usgs::StateCodes.try_normalize_postal(item["state_code"])
        unless state_code
          if ENV["USGS_VERBOSE"]
            progress&.step("skip unsupported state #{usgs_id} state_code=#{item["state_code"]}")
          end
          next
        end
        next if postal_code && state_code != postal_code

        name = item["monitoring_location_name"].presence || "Site #{site_number}"
        derived_names = MonitoringLocation.derived_names_for(name)

        MonitoringLocation.upsert(
          {
            agency_code: item["agency_code"].presence || "USGS",
            usgs_monitoring_location_id: usgs_id,
            site_number: site_number,
            name: name,
            display_name: derived_names[:display_name],
            search_name: derived_names[:search_name],
            slug: MonitoringLocation.slug_for(name),
            site_type_code: item["site_type_code"],
            site_type_name: item["site_type"],
            latitude: lat,
            longitude: lon,
            state_code: state_code,
            state_name: item["state_name"].presence || Usgs::StateCodes.name_for(state_code),
            county_code: item["county_code"],
            county_name: item["county_name"],
            hydrologic_unit_code: item["hydrologic_unit_code"],
            drainage_area: item["drainage_area"],
            time_zone: item["time_zone_abbreviation"],
            active: true,
            metadata_synced_at: Time.current
          },
          unique_by: :usgs_monitoring_location_id,
          # New rows still get slug / active from the insert hash. Existing rows
          # must keep created_at, slug, and active — weekly catalog is not the
          # source of truth for those. Do not list updated_at: Rails already
          # stamps it, and including it in update_only makes Postgres reject
          # the statement (#152).
          update_only: %i[
            agency_code
            site_number
            name
            display_name
            search_name
            site_type_code
            site_type_name
            latitude
            longitude
            state_code
            state_name
            county_code
            county_name
            hydrologic_unit_code
            drainage_area
            time_zone
            metadata_synced_at
          ]
        )
        kept << usgs_id.to_s
        progress&.increment
      end
    end

    kept.uniq
  end

  def upsert_time_series_for(active_rows)
    return if active_rows.empty?

    locations = MonitoringLocation.where(usgs_monitoring_location_id: active_rows.map { |r| r[:monitoring_location_id] })
      .pluck(:usgs_monitoring_location_id, :id)
      .to_h

    rows_by_ts = active_rows.index_by { |row| row[:time_series_id] }

    rows_by_ts.keys.each_slice(ID_BATCH_SIZE) do |batch|
      progress&.step("fetching time-series metadata batch=#{batch.size}")
      found = {}
      client.each_collection_item("time-series-metadata", id: batch.join(",")) do |item|
        found[item["id"].to_s] = item
      end

      batch.each do |ts_id|
        row = rows_by_ts[ts_id]
        next unless row

        location_id = locations[row[:monitoring_location_id]]
        next unless location_id

        item = found[ts_id] || {}
        primary = primary_series?(item["primary"])

        TimeSeries.upsert(
          {
            monitoring_location_id: location_id,
            usgs_time_series_id: ts_id,
            parameter_code: row[:parameter_code],
            parameter_name: item["parameter_name"] || item["parameter_description"],
            parameter_description: item["parameter_description"],
            statistic_code: item["statistic_id"] || item["statistic_code"],
            statistic_name: item["statistic_name"],
            unit_of_measure: item["unit_of_measure"] || row[:unit_of_measure],
            measurement_kind: row[:measurement_kind],
            primary_series: primary,
            begins_at: item["begin_date"] || item["begins_at"] || item["begin"] || item["begin_utc"],
            ends_at: item["end_date"] || item["ends_at"] || item["end"] || item["end_utc"],
            metadata_synced_at: Time.current
          },
          unique_by: :usgs_time_series_id,
          # New rows keep the schema default (false) until select_display_series.
          # Existing rows must keep selected_for_display — a national catalog run
          # upserts every series before the final apply!, and overwriting the flag
          # empties /api/gauges/:id/observations for the rest of the job.
          update_only: %i[
            monitoring_location_id
            parameter_code
            parameter_name
            parameter_description
            statistic_code
            statistic_name
            unit_of_measure
            measurement_kind
            primary_series
            begins_at
            ends_at
            metadata_synced_at
          ]
        )
        progress&.increment
      end
    end

    progress&.step("time_series upserted=#{rows_by_ts.size}")
  end

  def upsert_latest_observations(active_rows)
    return if active_rows.empty?

    progress&.step("upserting latest observations from discovery")
    series_ids = TimeSeries.where(usgs_time_series_id: active_rows.map { |r| r[:time_series_id] })
      .pluck(:usgs_time_series_id, :id, :unit_of_measure)
      .to_h { |usgs_id, id, unit| [ usgs_id, [ id, unit ] ] }

    count = 0
    continuous_tips = {}
    active_rows.each do |row|
      series_id, unit = series_ids[row[:time_series_id]]
      next unless series_id

      observed_at = parse_time(row[:observed_at])
      next if observed_at.blank? || row[:value].blank?
      if row[:measurement_kind] == "temperature" && !Usgs::ParameterCodes.plausible_temperature_c?(row[:value])
        next
      end

      LatestObservation.upsert(
        {
          time_series_id: series_id,
          observed_at: observed_at,
          value: row[:value],
          unit_of_measure: row[:unit_of_measure] || unit,
          approval_status: row[:approval_status],
          qualifier: row[:qualifier],
          source_last_modified_at: parse_time(row[:last_modified]),
          synced_at: Time.current,
          created_at: Time.current,
          updated_at: Time.current
        },
        unique_by: :time_series_id
      )
      ContinuousObservation.upsert(
        {
          time_series_id: series_id,
          observed_at: observed_at,
          value: row[:value],
          approval_status: row[:approval_status],
          qualifier: row[:qualifier],
          created_at: Time.current,
          updated_at: Time.current
        },
        unique_by: %i[time_series_id observed_at]
      )
      continuous_tips[series_id] = observed_at
      count += 1
      progress&.increment
    end
    TimeSeries.advance_continuous_tips!(continuous_tips)
    progress&.step("latest observations upserted=#{count}")
  end

  def select_display_series(usgs_ids: nil)
    scope = location_scope.includes(time_series: :latest_observation)
    if usgs_ids
      ids = Array(usgs_ids).map(&:to_s).uniq
      return 0 if ids.empty?

      scope = scope.where(usgs_monitoring_location_id: ids)
      progress&.step("selecting display series dirty=#{ids.size}")
    else
      progress&.step("selecting display series")
    end

    kept = 0
    scope.find_each do |location|
      DisplaySeriesSelection.apply!(location)
      kept += 1 if location.time_series.selected.exists?
      progress&.increment
    end

    progress&.step("display series selected locations=#{kept}")
    kept
  end

  def prune_inactive_locations!(kept_usgs_ids)
    progress&.step("pruning locations without active continuous data")
    kept_set = kept_usgs_ids.to_set
    deleted = 0
    batch = []

    # Stream candidates instead of plucking the whole catalog into one id list
    # and issuing a single giant purge (IV tip deletes dominate).
    location_scope
      .select(
        :id,
        :usgs_monitoring_location_id,
        :has_water_level,
        :has_discharge,
        :has_temperature,
        :latest_observed_at
      )
      .find_each do |location|
        inactive =
          kept_set.exclude?(location.usgs_monitoring_location_id) ||
          location.latest_observed_at.nil? ||
          !(location.has_water_level? || location.has_discharge? || location.has_temperature?)
        next unless inactive

        batch << location.id
        next if batch.size < MonitoringLocation::PURGE_LOCATION_BATCH

        deleted += MonitoringLocation.purge_ids!(batch)
        batch.clear
        progress&.step("pruned locations=#{deleted}")
      end

    deleted += MonitoringLocation.purge_ids!(batch) if batch.any?
    progress&.step("pruned locations=#{deleted}")
  end

  def primary_series?(value)
    return true if value.to_s.downcase.include?("primary")

    ActiveModel::Type::Boolean.new.cast(value) == true
  end

  def parse_time(value)
    return if value.blank?
    Time.zone.parse(value.to_s)
  rescue ArgumentError
    nil
  end
end
