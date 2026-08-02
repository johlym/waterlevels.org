class StationCatalogSync
  include ActiveModel::Model

  attr_accessor :client, :state, :progress

  def initialize(client: Usgs::Client.new, state: nil, progress: nil)
    @client = client
    @state = state.presence
    @progress = progress
  end

  def perform
    progress&.step(scope_label)
    upsert_locations
    upsert_time_series
    select_display_series
    progress&.step("refreshing nearby stations")
    NearbyStations.refresh_all
    progress&.step("warming state listing caches")
    StateListingCache.warm_all
    progress&.finish("locations=#{location_scope.count} time_series=#{time_series_scope.count}")
    true
  end

  private

  def scope_label
    postal_code ? "state=#{postal_code}" : "national"
  end

  def postal_code
    @postal_code ||= state && Usgs::StateCodes.normalize_postal(state)
  end

  def location_query
    return {} unless postal_code

    { state_code: Usgs::StateCodes.fips_for(postal_code) }
  end

  def time_series_query(parameter_code)
    query = { parameter_code: parameter_code }
    query[:state_name] = Usgs::StateCodes.name_for(postal_code) if postal_code
    query
  end

  def location_scope
    scope = MonitoringLocation.all
    postal_code ? scope.in_state(postal_code) : scope
  end

  def time_series_scope
    scope = TimeSeries.joins(:monitoring_location)
    postal_code ? scope.merge(MonitoringLocation.in_state(postal_code)) : scope
  end

  def upsert_locations
    progress&.step("upserting monitoring locations")
    count = 0
    client.each_collection_item("monitoring-locations", location_query) do |item|
      site_number = item["monitoring_location_number"].presence || item["id"].to_s.split("-").last
      next if site_number.blank?
      lat = item["latitude"] || item["dec_lat_va"]
      lon = item["longitude"] || item["dec_long_va"]
      next if lat.blank? || lon.blank?

      raw_state = item["state_code"].to_s
      next if raw_state.blank?

      state_code = Usgs::StateCodes.normalize_postal(raw_state)
      next if postal_code && state_code != postal_code

      name = item["monitoring_location_name"].presence || "Site #{site_number}"
      usgs_id = item["id"].presence || "USGS-#{site_number}"

      MonitoringLocation.upsert(
        {
          agency_code: item["agency_code"].presence || "USGS",
          usgs_monitoring_location_id: usgs_id,
          site_number: site_number,
          name: name,
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
          metadata_synced_at: Time.current,
          created_at: Time.current,
          updated_at: Time.current
        },
        unique_by: :usgs_monitoring_location_id
      )
      count += 1
      progress&.increment
    end
    progress&.step("locations upserted=#{count}")
  end

  def upsert_time_series
    Usgs::ParameterCodes::ALL.each do |parameter_code|
      progress&.step("upserting time-series metadata parameter=#{parameter_code}")
      count = 0
      client.each_collection_item("time-series-metadata", time_series_query(parameter_code)) do |item|
        location_id = item["monitoring_location_id"]
        location = MonitoringLocation.find_by(usgs_monitoring_location_id: location_id)
        next unless location
        next if postal_code && location.state_code != postal_code

        kind = Usgs::ParameterCodes.measurement_kind_for(parameter_code)
        next unless kind

        primary = ActiveModel::Type::Boolean.new.cast(item["primary"] || item["primary_series"] || true)
        usgs_ts_id = item["id"] || item["time_series_id"]
        next if usgs_ts_id.blank?

        TimeSeries.upsert(
          {
            monitoring_location_id: location.id,
            usgs_time_series_id: usgs_ts_id.to_s,
            parameter_code: parameter_code,
            parameter_name: item["parameter_name"] || item["parameter_description"],
            parameter_description: item["parameter_description"],
            statistic_code: item["statistic_id"] || item["statistic_code"],
            statistic_name: item["statistic_name"],
            unit_of_measure: item["unit_of_measure"],
            measurement_kind: kind,
            primary_series: primary,
            selected_for_display: false,
            begins_at: item["begin_date"] || item["begins_at"] || item["begin"],
            ends_at: item["end_date"] || item["ends_at"] || item["end"],
            metadata_synced_at: Time.current,
            created_at: Time.current,
            updated_at: Time.current
          },
          unique_by: :usgs_time_series_id
        )
        count += 1
        progress&.increment
      end
      progress&.step("parameter=#{parameter_code} time_series upserted=#{count}")
    end
  end

  def select_display_series
    progress&.step("selecting display series")
    kept = 0
    dropped = 0

    location_scope.find_each do |location|
      series = location.time_series.to_a
      location.time_series.update_all(selected_for_display: false)

      water_level = series
        .select { |s| s.measurement_kind == "water_level" && s.primary_series? }
        .min_by { |s| Usgs::ParameterCodes.preference_rank(s.parameter_code) }
      water_level ||= series
        .select { |s| s.measurement_kind == "water_level" }
        .min_by { |s| Usgs::ParameterCodes.preference_rank(s.parameter_code) }

      discharge = series.find { |s| s.measurement_kind == "discharge" && s.primary_series? } ||
                  series.find { |s| s.measurement_kind == "discharge" }
      temperature = series.find { |s| s.measurement_kind == "temperature" && s.primary_series? } ||
                    series.find { |s| s.measurement_kind == "temperature" }

      [ water_level, discharge, temperature ].compact.each do |ts|
        ts.update!(selected_for_display: true)
      end

      has_any = water_level.present? || discharge.present? || temperature.present?
      location.update!(
        has_water_level: water_level.present?,
        has_discharge: discharge.present?,
        has_temperature: temperature.present?
      )
      if has_any
        kept += 1
      else
        dropped += 1
      end
      progress&.increment
    end

    empty = MonitoringLocation.where(has_water_level: false, has_discharge: false, has_temperature: false)
    empty = empty.in_state(postal_code) if postal_code
    deleted = empty.delete_all
    progress&.step("display series selected kept=#{kept} empty=#{dropped} deleted=#{deleted}")
  end
end
