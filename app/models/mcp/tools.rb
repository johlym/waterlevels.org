module Mcp
  # Read-only MCP tools. Arguments are allowlisted before any query or HTTP
  # lookup. Database work runs inside one Mcp::ReadOnly transaction. Archive
  # object reads happen only after that transaction commits.
  module Tools
    KINDS = %w[water_level discharge temperature].freeze
    SITE_NUMBER = /\A[A-Za-z0-9]{2,32}\z/
    PARAMETER_CODE = /\A[A-Za-z0-9._-]{1,32}\z/
    STATE_CODE = /\A[a-z]{2}\z/
    QUERY_LENGTH = 2..64
    KIND_ORDER = { "water_level" => 0, "discharge" => 1, "temperature" => 2 }.freeze
    SEARCH_DEFAULT = 8
    SEARCH_MAX = 25
    FLOOD_DEFAULT = 50
    FLOOD_MAX = 100
    SAMPLE_RANGE = 0..48

    module_function

    def definitions
      [
        tool_def(
          "search_stations",
          "Search stations, states, and ZIP codes. Returns id, name, state, type, path, flood_category, and stale.",
          { query: { type: "string", minLength: 2, maxLength: 64 }, limit: { type: "integer", minimum: 1, maximum: SEARCH_MAX } },
          %w[query]
        ),
        tool_def(
          "get_station",
          "One station: identity, flood stages, latest denormalized readings, and selected series (no points).",
          { site_number: { type: "string" } },
          %w[site_number]
        ),
        tool_def(
          "station_trend",
          "24h and year-over-year change for a station series. kind defaults to the preferred selected series.",
          { site_number: { type: "string" }, kind: { type: "string", enum: KINDS } },
          %w[site_number]
        ),
        tool_def(
          "series_summary",
          "Count, min, max, earliest, latest, and delta for a chart range. sample (0-48) adds evenly spaced points.",
          {
            site_number: { type: "string" },
            kind: { type: "string", enum: KINDS },
            parameter_code: { type: "string" },
            range: { type: "string", enum: HydrographSeries::RANGES.keys },
            sample: { type: "integer", minimum: 0, maximum: 48 }
          },
          %w[site_number range]
        ),
        tool_def(
          "list_flooding",
          "Stations at action stage or flood. Optional state and category. Does not warm the alerts cache.",
          {
            state: { type: "string" },
            category: { type: "string", enum: Nwps::FloodCategories::ALERT },
            limit: { type: "integer", minimum: 1, maximum: FLOOD_MAX }
          },
          []
        )
      ]
    end

    def call(name, arguments)
      args = normalize_arguments(arguments)
      return failure("arguments must be an object") if args.nil?

      log_tool(name, args)
      case name
      when "search_stations" then search_stations(args)
      when "get_station" then get_station(args)
      when "station_trend" then station_trend(args)
      when "series_summary" then series_summary(args)
      when "list_flooding" then list_flooding(args)
      else failure("Unknown tool")
      end
    end

    def search_stations(args)
      error = unknown_keys(args, %w[query limit])
      return failure(error) if error
      return failure("query is required") unless args.key?("query")

      query = args["query"]
      return failure("query must be a string") unless query.is_a?(String)

      query = query.strip
      return failure("query must be 2..64 characters") unless QUERY_LENGTH.cover?(query.length)

      limit = parse_limit(args, default: SEARCH_DEFAULT, max: SEARCH_MAX)
      return failure("limit must be an integer >= 1") if limit.nil?

      zip = ZipCodeLookup.lookup(query)
      stations = Mcp::ReadOnly.during { compose_search(query, limit, zip) }
      ok("stations" => stations)
    end

    def get_station(args)
      error = unknown_keys(args, %w[site_number])
      return failure(error) if error

      site_number = parse_site_number(args)
      return failure("site_number is invalid") if site_number.nil?

      payload = Mcp::ReadOnly.during do
        location = MonitoringLocation.find_by(site_number: site_number)
        next { error: "Unknown station" } unless location

        station_payload(location)
      end
      return failure(payload[:error]) if payload.is_a?(Hash) && payload[:error]

      ok(payload)
    end

    def station_trend(args)
      error = unknown_keys(args, %w[site_number kind])
      return failure(error) if error

      site_number = parse_site_number(args)
      return failure("site_number is invalid") if site_number.nil?

      kind = parse_kind(args)
      return failure("kind is invalid") if kind == :invalid

      archive_plan = nil
      payload = Mcp::ReadOnly.during do
        built = build_trend(site_number, kind)
        archive_plan = built[:archive]
        built
      end
      return failure(payload[:error]) if payload[:error]

      if archive_plan
        prior = archive_yoy_prior(archive_plan)
        payload[:yoy] = TrendComparison.new(
          current_value: payload[:current],
          prior_value: prior,
          label: "YoY"
        )
      end
      ok(trend_payload(payload))
    end

    def series_summary(args)
      error = unknown_keys(args, %w[site_number kind parameter_code range sample])
      return failure(error) if error

      site_number = parse_site_number(args)
      return failure("site_number is invalid") if site_number.nil?

      kind = parse_kind(args)
      return failure("kind is invalid") if kind == :invalid

      parameter_code = parse_parameter_code(args)
      return failure("parameter_code is invalid") if parameter_code == :invalid

      range = args["range"]
      return failure("range is invalid") unless range.is_a?(String) && HydrographSeries::RANGES.key?(range)

      sample = parse_sample(args)
      return failure("sample must be an integer from 0 to 48") if sample.nil?

      archive_plan = nil
      summary = Mcp::ReadOnly.during do
        location = MonitoringLocation.find_by(site_number: site_number)
        next { error: "Unknown station" } unless location

        series = resolve_series(location, kind: kind, parameter_code: parameter_code)
        next { error: "Unknown series" } unless series

        collected = Mcp::SeriesPoints.collect(series, range)
        if collected.is_a?(Hash) && collected[:archive]
          archive_plan = collected[:archive]
          { series: series, points: nil }
        else
          { series: series, points: collected }
        end
      end
      return failure(summary[:error]) if summary[:error]

      points = summary[:points] || Mcp::SeriesPoints.read_archive(archive_plan)
      ok(summary_payload(site_number, summary[:series], range, points, sample))
    end

    def list_flooding(args)
      error = unknown_keys(args, %w[state category limit])
      return failure(error) if error

      state = parse_state(args)
      return failure("state is invalid") if state == :invalid

      category = parse_category(args)
      return failure("category is invalid") if category == :invalid

      limit = parse_limit(args, default: FLOOD_DEFAULT, max: FLOOD_MAX)
      return failure("limit must be an integer >= 1") if limit.nil?

      rows = Mcp::ReadOnly.during { flood_rows(state, category, limit) }
      ok("stations" => rows)
    end

    def compose_search(query, limit, zip)
      zip_hits = zip ? [ zip_hit(zip) ] : []
      state_hits = if MonitoringLocation.exact_search_match(query).exists?
        []
      else
        Usgs::StateCodes.match_query(query).map { |match| state_hit(match) }
      end
      used = zip_hits.length + state_hits.length
      station_limit = [ limit - used, 0 ].max
      station_hits = MonitoringLocation.search(query).limit(station_limit).map { |location| station_hit(location) }
      zip_hits + state_hits + station_hits
    end

    def build_trend(site_number, kind)
      location = MonitoringLocation.find_by(site_number: site_number)
      return { error: "Unknown station" } unless location

      series = resolve_series(location, kind: kind, parameter_code: nil)
      return { error: "Unknown series" } unless series

      latest = series.latest_observation
      return { error: "No latest observation" } if latest.nil? || latest.observed_at.blank?

      trend = TrendComparison.for_series(
        series,
        current_value: latest.value,
        observed_at: latest.observed_at
      )
      base = {
        error: nil,
        series: series,
        site_number: location.site_number,
        current: latest.value,
        observed_at: latest.observed_at,
        trend: trend
      }
      if DailyArchive.reads_enabled?
        day = latest.observed_at.to_date - 1.year
        shard = DailyArchiveShard.where(time_series_id: series.id, year: day.year).exists?
        base[:archive] = {
          day: day,
          key: (DailyArchive.object_key(series.id, day.year) if shard),
          pg_prior: series.daily_observations.where(observed_on: day).pick(:value)
        }
      else
        base[:yoy] = TrendComparison.yoy_for_series(
          series,
          current_value: latest.value,
          observed_at: latest.observed_at
        )
      end
      base
    end

    def archive_yoy_prior(plan)
      from_archive = Mcp::SeriesPoints.value_on_key(plan[:key], plan[:day])
      from_archive.nil? ? plan[:pg_prior] : from_archive
    end

    def flood_rows(state, category, limit)
      scope = MonitoringLocation.flood_alert
      scope = scope.where(state_code: state) if state
      scope = scope.where(flood_category: category) if category
      scope.order(Arel.sql("LOWER(state_code) ASC, #{AlertsListingCache::SEVERITY_ORDER_SQL}, LOWER(display_name) ASC"))
        .limit(limit)
        .map { |location| flood_hit(location) }
    end

    def resolve_series(location, kind:, parameter_code:)
      if parameter_code.present?
        series = location.time_series.selected.find_by(parameter_code: parameter_code) ||
          location.time_series.find_by(parameter_code: parameter_code)
        return if series.nil?
        return if kind.present? && series.measurement_kind != kind

        return series
      end

      if kind.present?
        return preferred_series(location, kind: kind) ||
            ranked_series(location.time_series.where(measurement_kind: kind))
      end

      preferred_series(location)
    end

    def preferred_series(location, kind: nil)
      scope = location.time_series.selected
      scope = scope.where(measurement_kind: kind) if kind
      ranked_series(scope)
    end

    def ranked_series(scope)
      scope.to_a.min_by { |series| [ kind_rank(series.measurement_kind), Usgs::ParameterCodes.preference_rank(series.parameter_code) ] }
    end

    def kind_rank(kind)
      KIND_ORDER.fetch(kind, 9)
    end

    def station_payload(location)
      {
        id: location.site_number,
        name: location.display_name,
        agency: DataProviders.label_for(location.data_provider),
        latitude: Mcp::Numbers.round(location.latitude, digits: 6),
        longitude: Mcp::Numbers.round(location.longitude, digits: 6),
        county: location.county_name,
        path: station_path(location),
        stale: location.stale?,
        flood_category: location.flood_category,
        flood_category_label: location.flood_category_label,
        stages: {
          action: stage_float(location.flood_stage_action),
          minor: stage_float(location.flood_stage_minor),
          moderate: stage_float(location.flood_stage_moderate),
          major: stage_float(location.flood_stage_major)
        },
        water_level: {
          value: Mcp::Numbers.round(location.latest_water_level_value),
          unit: UnitLabel.format(location.latest_water_level_unit),
          parameter_code: location.latest_water_level_parameter_code
        },
        discharge: {
          value: Mcp::Numbers.round(location.latest_discharge_value),
          unit: UnitLabel.format(location.latest_discharge_unit)
        },
        temperature: {
          celsius: Mcp::Numbers.round(location.latest_temperature_c),
          fahrenheit: Mcp::Numbers.fahrenheit(location.latest_temperature_c)
        },
        observed_at: location.latest_observed_at&.iso8601,
        series: location.time_series.selected.order(:parameter_code).map { |series| series_ref(series) }
      }
    end

    def trend_payload(payload)
      series = payload[:series]
      trend = payload[:trend]
      yoy = payload[:yoy]
      body = {
        site_number: payload[:site_number],
        kind: series.measurement_kind,
        parameter_code: series.parameter_code,
        value: Mcp::Numbers.round(payload[:current]),
        unit: UnitLabel.format(series.unit_of_measure),
        observed_at: payload[:observed_at].iso8601,
        delta_24h: Mcp::Numbers.round(trend.delta),
        percent_24h: percent(trend),
        delta_yoy: Mcp::Numbers.round(yoy&.delta),
        percent_yoy: yoy ? percent(yoy) : nil
      }
      return body unless series.measurement_kind == "temperature"

      body.merge(
        fahrenheit: Mcp::Numbers.fahrenheit(payload[:current]),
        delta_24h_fahrenheit: Mcp::Numbers.fahrenheit_delta(trend.delta),
        delta_yoy_fahrenheit: Mcp::Numbers.fahrenheit_delta(yoy&.delta)
      )
    end

    def summary_payload(site_number, series, range, points, sample)
      values = points.map { |point| point[:v] }
      earliest = points.first
      latest = points.last
      body = {
        site_number: site_number,
        kind: series.measurement_kind,
        parameter_code: series.parameter_code,
        unit: UnitLabel.format(series.unit_of_measure),
        range: range,
        count: points.size,
        min: values.min,
        max: values.max,
        earliest: earliest,
        latest: latest,
        delta: (earliest && latest) ? Mcp::Numbers.round(latest[:v] - earliest[:v]) : nil
      }
      body[:sample] = sample_points(points, sample) if sample.positive?
      body
    end

    def sample_points(points, sample)
      return [] if points.empty?
      return points if points.size <= sample
      return [ points.last ] if sample == 1

      last_index = points.size - 1
      indexes = (0...sample).map { |i| (i * last_index.to_f / (sample - 1)).round }
      indexes.uniq.map { |index| points[index] }
    end

    def flood_hit(location)
      {
        site_number: location.site_number,
        name: location.display_name,
        state: location.state_code,
        path: station_path(location),
        flood_category: location.flood_category,
        flood_category_label: location.flood_category_label,
        water_level: {
          value: Mcp::Numbers.round(location.latest_water_level_value),
          unit: UnitLabel.format(location.latest_water_level_unit)
        },
        latest_observed_at: location.latest_observed_at&.iso8601,
        stale: location.stale?
      }
    end

    def station_hit(location)
      {
        id: location.site_number,
        name: location.display_name,
        state: location.state_code,
        type: "station",
        path: station_path(location),
        flood_category: location.flood_category,
        stale: location.stale?
      }
    end

    def zip_hit(result)
      {
        id: result.zip,
        name: result.display_name,
        state: result.state_code.to_s.downcase,
        type: "zip",
        path: result.map_path,
        flood_category: nil,
        stale: false
      }
    end

    def state_hit(match)
      {
        id: match[:postal],
        name: match[:name],
        state: match[:postal],
        type: "state",
        path: "/gauges/#{match[:postal]}",
        flood_category: nil,
        stale: false
      }
    end

    def series_ref(series)
      {
        kind: series.measurement_kind,
        parameter_code: series.parameter_code,
        unit: UnitLabel.format(series.unit_of_measure)
      }
    end

    def station_path(location)
      "/gauges/#{location.path_state}/#{location.to_param}"
    end

    def stage_float(value)
      Mcp::Numbers.round(value)
    end

    def percent(trend)
      change = trend.percent_change
      return if change.nil?

      change.to_f.round(2)
    end

    def normalize_arguments(arguments)
      return {} if arguments.nil?
      return arguments.stringify_keys if arguments.is_a?(Hash)

      nil
    end

    def unknown_keys(args, allowed)
      extra = args.keys - allowed
      return if extra.empty?

      "unknown argument #{extra.first}"
    end

    def parse_limit(args, default:, max:)
      return default unless args.key?("limit")

      value = args["limit"]
      return unless value.is_a?(Integer)
      return if value < 1

      [ value, max ].min
    end

    def parse_site_number(args)
      return unless args.key?("site_number")

      value = args["site_number"]
      value = value.to_s if value.is_a?(Integer)
      return unless value.is_a?(String) && value.match?(SITE_NUMBER)

      value
    end

    def parse_kind(args)
      return unless args.key?("kind")
      return if args["kind"].nil?

      kind = args["kind"]
      return :invalid unless kind.is_a?(String) && KINDS.include?(kind)

      kind
    end

    def parse_parameter_code(args)
      return unless args.key?("parameter_code")
      return if args["parameter_code"].nil?

      code = args["parameter_code"]
      return :invalid unless code.is_a?(String) && code.match?(PARAMETER_CODE)

      code
    end

    def parse_state(args)
      return unless args.key?("state")
      return if args["state"].nil?

      state = args["state"]
      return :invalid unless state.is_a?(String)

      state = state.downcase
      return :invalid unless state.match?(STATE_CODE)

      state
    end

    def parse_category(args)
      return unless args.key?("category")
      return if args["category"].nil?

      category = args["category"]
      return :invalid unless category.is_a?(String) && Nwps::FloodCategories::ALERT.include?(category)

      category
    end

    def parse_sample(args)
      return 0 unless args.key?("sample")

      value = args["sample"]
      return unless value.is_a?(Integer) && SAMPLE_RANGE.cover?(value)

      value
    end

    def log_tool(name, args)
      site = args["site_number"]
      site = site.to_s if site.is_a?(Integer)
      site = nil unless site.is_a?(String) && site.match?(SITE_NUMBER)
      Rails.logger.info(
        AppLogging.event(
          event: "mcp.tool",
          component: "Mcp::Tools",
          message: "mcp.tool name=#{name} site_number=#{site}",
          tool: name,
          site_number: site
        )
      )
    end

    def ok(payload)
      {
        content: [ { type: "text", text: JSON.generate(payload) } ],
        structuredContent: payload
      }
    end

    def failure(message)
      payload = { error: message }
      {
        content: [ { type: "text", text: JSON.generate(payload) } ],
        structuredContent: payload,
        isError: true
      }
    end

    def tool_def(name, description, properties, required)
      definition = {
        name: name,
        description: description,
        inputSchema: {
          type: "object",
          properties: properties,
          additionalProperties: false
        }
      }
      definition[:inputSchema][:required] = required if required.any?
      definition
    end
  end
end
