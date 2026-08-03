# frozen_string_literal: true

# Demo catalog for local/dev: one state, 100 stations, 30 days of USGS-shaped data.
# Idempotent — re-running replaces the reserved demo site-number range only.
module DemoStateSeed
  STATE_CODE = "wa"
  STATE_NAME = "Washington"
  TIME_ZONE = "PST"
  STATION_COUNT = 100
  HISTORY_DAYS = 30
  # USGS instantaneous values are commonly published on a 15-minute cadence.
  CONTINUOUS_INTERVAL = 15.minutes
  SITE_NUMBER_BASE = 99_000_000
  # One station kept in major flood with gage height above the major threshold so
  # map/state/detail/chart UIs all have a coherent flood-alert example offline.
  FLOOD_DEMO_N = 20
  FLOOD_DEMO_STAGES = {
    action: 8.0,
    minor: 10.0,
    moderate: 12.0,
    major: 14.0
  }.freeze

  COLORS = %w[Blue Red Green Amber Silver Crimson Ivory Azure Coral Jade].freeze
  FLOWERS = %w[Rose Lily Iris Daisy Tulip Violet Orchid Poppy Jasmine Lotus].freeze
  TREES = %w[Cedar Oak Maple Pine Willow Birch Aspen Hemlock Spruce Alder].freeze
  DIRECTIONS = %w[North South East West Northeast Northwest Southeast Southwest Upper Lower].freeze

  COUNTIES = [
    [ "033", "King" ],
    [ "053", "Pierce" ],
    [ "061", "Snohomish" ],
    [ "073", "Whatcom" ],
    [ "077", "Yakima" ],
    [ "063", "Spokane" ],
    [ "067", "Thurston" ],
    [ "011", "Clark" ],
    [ "005", "Benton" ],
    [ "029", "Island" ]
  ].freeze

  SERIES_SPECS = [
    {
      parameter_code: Usgs::ParameterCodes::WATER_LEVEL_PREFERENCE.first,
      measurement_kind: "water_level",
      parameter_name: "Gage height",
      parameter_description: "Gage height, feet",
      unit_of_measure: "ft",
      base: ->(n) { 2.5 + (n % 20) * 0.35 },
      amplitude: 0.85,
      noise: 0.08
    },
    {
      parameter_code: Usgs::ParameterCodes::DISCHARGE,
      measurement_kind: "discharge",
      parameter_name: "Streamflow",
      parameter_description: "Discharge, cubic feet per second",
      unit_of_measure: "ft3/s",
      base: ->(n) { 120.0 + (n % 40) * 35.0 },
      amplitude: 90.0,
      noise: 8.0
    },
    {
      parameter_code: Usgs::ParameterCodes::TEMPERATURE,
      measurement_kind: "temperature",
      parameter_name: "Temperature",
      parameter_description: "Temperature, water, degrees Celsius",
      unit_of_measure: "deg C",
      base: ->(n) { 9.0 + (n % 10) * 0.4 },
      amplitude: 3.5,
      noise: 0.25
    }
  ].freeze

  module_function

  def run!(stdout: $stdout)
    stdout.puts "Demo seed: #{STATE_NAME} (#{STATE_CODE}), #{STATION_COUNT} stations, #{HISTORY_DAYS} days"

    purge_previous!
    locations = create_locations!
    series_by_location = create_time_series!(locations)
    insert_observations!(series_by_location)
    finalize!(locations)

    stdout.puts "Demo seed finished: locations=#{MonitoringLocation.in_state(STATE_CODE).count} " \
                "time_series=#{TimeSeries.joins(:monitoring_location).merge(MonitoringLocation.in_state(STATE_CODE)).count} " \
                "continuous=#{ContinuousObservation.count} daily=#{DailyObservation.count}"
  end

  def site_numbers
    (1..STATION_COUNT).map { |n| format("%08d", SITE_NUMBER_BASE + n) }
  end

  def purge_previous!
    ids = MonitoringLocation.where(site_number: site_numbers).pluck(:id)
    deleted = MonitoringLocation.purge_ids!(ids)
    puts "Purged previous demo locations=#{deleted}" if deleted.positive?
  end

  def station_name(n)
    # Different strides so colors/flowers/trees/directions all vary within 100 stations.
    i = n - 1
    direction = DIRECTIONS[i % DIRECTIONS.size]
    color = COLORS[(i / 2) % COLORS.size]
    flower = FLOWERS[(i / 3) % FLOWERS.size]
    tree = TREES[(i / 5) % TREES.size]
    "#{direction} #{color} #{flower} #{tree} Creek near Site #{n}"
  end

  def create_locations!
    now = Time.current
    rows = (1..STATION_COUNT).map do |n|
      site_number = format("%08d", SITE_NUMBER_BASE + n)
      name = station_name(n)
      derived_names = MonitoringLocation.derived_names_for(name)
      county_code, county_name = COUNTIES[(n - 1) % COUNTIES.size]
      # Spread stations across Washington's approximate bounding box.
      lat = 45.55 + ((n - 1) % 10) * 0.32 + ((n - 1) / 10) * 0.01
      lon = -124.20 + ((n - 1) / 10) * 0.55 + ((n - 1) % 10) * 0.02

      {
        agency_code: "USGS",
        usgs_monitoring_location_id: "USGS-#{site_number}",
        site_number: site_number,
        name: name,
        display_name: derived_names[:display_name],
        search_name: derived_names[:search_name],
        slug: MonitoringLocation.slug_for(name),
        site_type_code: n.even? ? "ST" : "LK",
        site_type_name: n.even? ? "Stream" : "Lake, Reservoir, Impoundment",
        latitude: lat.round(7),
        longitude: lon.round(7),
        state_code: STATE_CODE,
        state_name: STATE_NAME,
        county_code: county_code,
        county_name: county_name,
        hydrologic_unit_code: format("1709%04d", n),
        drainage_area: (25.0 + n * 3.7).round(3),
        time_zone: TIME_ZONE,
        active: true,
        has_water_level: true,
        has_discharge: true,
        has_temperature: true,
        nearby_station_ids: [],
        nwps_matched: nwps_station?(n),
        flood_category: flood_category_for(n),
        flood_stage_action: nwps_station?(n) ? FLOOD_DEMO_STAGES[:action] : nil,
        flood_stage_minor: nwps_station?(n) ? FLOOD_DEMO_STAGES[:minor] : nil,
        flood_stage_moderate: nwps_station?(n) ? FLOOD_DEMO_STAGES[:moderate] : nil,
        flood_stage_major: nwps_station?(n) ? FLOOD_DEMO_STAGES[:major] : nil,
        flood_category_observed_at: nwps_station?(n) ? now : nil,
        nwps_lid: nwps_station?(n) ? format("SEED%02d", n) : nil,
        nwps_synced_at: nwps_station?(n) ? now : nil,
        metadata_synced_at: now,
        created_at: now,
        updated_at: now
      }
    end

    MonitoringLocation.insert_all!(rows)
    MonitoringLocation.where(site_number: site_numbers).order(:site_number).to_a
  end

  def nwps_station?(n)
    n % 5 == 0
  end

  def flood_demo?(n)
    n == FLOOD_DEMO_N
  end

  def flood_category_for(n)
    return "major" if flood_demo?(n)
    return unless nwps_station?(n)

    Nwps::FloodCategories::ALL[(n / 5) % Nwps::FloodCategories::ALL.size]
  end

  def create_time_series!(locations)
    now = Time.current
    begins_at = HISTORY_DAYS.days.ago.beginning_of_day
    rows = []

    locations.each do |location|
      SERIES_SPECS.each do |spec|
        rows << {
          monitoring_location_id: location.id,
          usgs_time_series_id: "seed-ts-#{location.site_number}-#{spec[:parameter_code]}",
          parameter_code: spec[:parameter_code],
          parameter_name: spec[:parameter_name],
          parameter_description: spec[:parameter_description],
          statistic_code: nil,
          statistic_name: nil,
          unit_of_measure: spec[:unit_of_measure],
          measurement_kind: spec[:measurement_kind],
          primary_series: true,
          selected_for_display: true,
          begins_at: begins_at,
          ends_at: now,
          metadata_synced_at: now,
          created_at: now,
          updated_at: now
        }
      end
    end

    TimeSeries.insert_all!(rows)
    TimeSeries.where(monitoring_location_id: locations.map(&:id)).includes(:monitoring_location).group_by(&:monitoring_location_id)
  end

  def insert_observations!(series_by_location)
    ends_at = Time.current.utc.change(sec: 0)
    # Align tip to the USGS-style 15-minute clock.
    ends_at -= (ends_at.min % 15).minutes
    starts_at = ends_at - HISTORY_DAYS.days
    timestamps = []
    t = starts_at
    while t <= ends_at
      timestamps << t
      t += CONTINUOUS_INTERVAL
    end
    days = (starts_at.to_date..ends_at.to_date).to_a
    now = Time.current

    continuous_batch = []
    daily_batch = []
    latest_batch = []
    peak_batch = []
    flush_size = 5_000
    total_series = series_by_location.values.sum(&:size)
    done_series = 0
    puts "Inserting observations for #{total_series} time series " \
         "(#{timestamps.size} continuous points × series ≈ #{timestamps.size * total_series} rows)"

    series_by_location.each_value do |series_list|
      site_number = series_list.first.monitoring_location.site_number
      n = site_number.to_i - SITE_NUMBER_BASE

      series_list.each do |series|
        spec = SERIES_SPECS.find { |s| s[:parameter_code] == series.parameter_code }
        base = spec[:base].call(n)
        amplitude = spec[:amplitude]
        noise = spec[:noise]
        daily_values = Hash.new { |h, day| h[day] = [] }

        tip_at = nil
        tip_value = nil
        tip_approval = nil

        timestamps.each_with_index do |observed_at, index|
          # Diurnal + slow multi-day oscillation with deterministic noise (idempotent values).
          phase = index * 0.04 + n * 0.17
          wobble = Math.sin(phase) * amplitude + Math.sin(phase / 7.0) * (amplitude * 0.35)
          jitter = Math.sin((index + 1) * (n + 3) * 0.613) * noise
          value = base + wobble + jitter
          value += flood_demo_boost(series.measurement_kind, index, timestamps.size) if flood_demo?(n)
          value = value.round(3)
          approval = observed_at > 7.days.ago ? "Provisional" : "Approved"

          continuous_batch << {
            time_series_id: series.id,
            observed_at: observed_at,
            value: value,
            approval_status: approval,
            qualifier: nil,
            created_at: now,
            updated_at: now
          }
          daily_values[observed_at.to_date] << value
          tip_at = observed_at
          tip_value = value
          tip_approval = approval

          if continuous_batch.size >= flush_size
            ContinuousObservation.insert_all!(continuous_batch)
            continuous_batch.clear
          end
        end

        days.each do |day|
          values = daily_values[day]
          next if values.empty?

          mean = (values.sum / values.size).round(3)
          daily_batch << {
            time_series_id: series.id,
            observed_on: day,
            value: mean,
            approval_status: day > 7.days.ago.to_date ? "Provisional" : "Approved",
            qualifier: nil,
            created_at: now,
            updated_at: now
          }
        end

        next if tip_at.blank?

        latest_batch << {
          time_series_id: series.id,
          observed_at: tip_at,
          value: tip_value,
          unit_of_measure: series.unit_of_measure,
          approval_status: tip_approval,
          qualifier: nil,
          source_last_modified_at: tip_at,
          synced_at: now,
          created_at: now,
          updated_at: now
        }

        if series.measurement_kind.in?(%w[water_level discharge])
          peak_value = daily_values.values.flatten.max
          peak_batch << {
            time_series_id: series.id,
            water_year: ends_at.month >= 10 ? ends_at.year + 1 : ends_at.year,
            observed_at: ends_at - ((n % 10) + 1).days,
            value: peak_value,
            peak_kind: "high",
            approval_status: "Provisional",
            created_at: now,
            updated_at: now
          }
        end

        done_series += 1
        puts "  series #{done_series}/#{total_series}" if (done_series % 25).zero? || done_series == total_series
      end
    end

    ContinuousObservation.insert_all!(continuous_batch) if continuous_batch.any?
    DailyObservation.insert_all!(daily_batch) if daily_batch.any?
    LatestObservation.insert_all!(latest_batch) if latest_batch.any?
    PeakObservation.insert_all!(peak_batch) if peak_batch.any?
  end

  # Ramp the flood-demo station into major flooding over the last ~5 days so the
  # hydrograph crosses action/minor/moderate/major reference lines and the tip
  # reading matches the major flood_category badge.
  def flood_demo_boost(measurement_kind, index, total_points)
    return 0.0 if total_points <= 1

    progress = index.to_f / (total_points - 1)
    rise = [ (progress - 0.82) / 0.18, 0.0 ].max # last ~18% of the series (~5.4 days)
    case measurement_kind
    when "water_level"
      # Target tip ~15.8 ft (above major 14.0); earlier history stays below action.
      13.5 * rise
    when "discharge"
      2_400.0 * rise
    else
      0.0
    end
  end

  def finalize!(locations)
    MonitoringLocation.where(id: locations.map(&:id)).includes(time_series: :latest_observation).find_each do |location|
      DisplaySeriesSelection.apply!(location)
      StationSnapshotCache.warm(location)
    end

    NearbyStations.refresh_all
    StateListingCache.warm(STATE_CODE)
    SiteStats.warm!
  end
end

DemoStateSeed.run!
