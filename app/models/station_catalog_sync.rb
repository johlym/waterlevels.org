class StationCatalogSync
  include ActiveModel::Model

  attr_accessor :client

  def initialize(client: Usgs::Client.new)
    @client = client
  end

  def perform
    upsert_locations
    upsert_time_series
    select_display_series
    NearbyStations.refresh_all
    StateListingCache.warm_all
    true
  end

  private

  def upsert_locations
    client.each_collection_item("monitoring-locations") do |item|
      site_number = item["monitoring_location_number"].presence || item["id"].to_s.split("-").last
      next if site_number.blank?
      lat = item["latitude"] || item["dec_lat_va"]
      lon = item["longitude"] || item["dec_long_va"]
      next if lat.blank? || lon.blank?

      state = item["state_code"].to_s.downcase
      next if state.blank?

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
          state_code: state,
          state_name: item["state_name"],
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
    end
  end

  def upsert_time_series
    Usgs::ParameterCodes::ALL.each do |parameter_code|
      client.each_collection_item("time-series-metadata", parameter_code: parameter_code) do |item|
        location_id = item["monitoring_location_id"]
        location = MonitoringLocation.find_by(usgs_monitoring_location_id: location_id)
        next unless location

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
            begins_at: item["begin_date"] || item["begins_at"],
            ends_at: item["end_date"] || item["ends_at"],
            metadata_synced_at: Time.current,
            created_at: Time.current,
            updated_at: Time.current
          },
          unique_by: :usgs_time_series_id
        )
      end
    end
  end

  def select_display_series
    MonitoringLocation.find_each do |location|
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

      [water_level, discharge, temperature].compact.each do |ts|
        ts.update!(selected_for_display: true)
      end

      location.update!(
        has_water_level: water_level.present?,
        has_discharge: discharge.present?,
        has_temperature: temperature.present?
      )
    end

    # Drop locations with no selected measurements
    MonitoringLocation.where(has_water_level: false, has_discharge: false, has_temperature: false).delete_all
  end
end
