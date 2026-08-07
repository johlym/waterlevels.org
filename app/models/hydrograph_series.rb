class HydrographSeries
  include ActiveModel::Model

  RANGES = {
    "24h" => { continuous: true, duration: 24.hours },
    "7d" => { continuous: true, duration: 7.days },
    "30d" => { continuous: true, duration: 30.days },
    "1y" => { continuous: false, duration: 1.year },
    "3y" => { continuous: false, duration: 3.years }
  }.freeze

  attr_accessor :time_series, :range

  def self.for(location:, kind: nil, parameter_code: nil, range: "7d")
    Telemetry.in_span(
      "hydrograph.build",
      attributes: {
        "app.operation" => "hydrograph.build",
        "app.site_number" => location.site_number,
        "app.state" => location.state_code,
        "app.parameter_code" => parameter_code,
        "app.measurement_kind" => kind,
        "app.range" => range
      }
    ) do
      series = find_series(location, kind: kind, parameter_code: parameter_code)
      return empty(kind || parameter_code, range) unless series

      payload = new(time_series: series, range: range).as_json
      Telemetry.add_attributes(
        "app.parameter_code" => series.parameter_code,
        "app.measurement_kind" => series.measurement_kind,
        "app.observation_count" => Array(payload[:points]).size,
        "app.batch_size" => Array(payload[:points]).size
      )
      payload
    end
  end

  def self.find_series(location, kind:, parameter_code:)
    selected = location.time_series.selected
    if parameter_code.present?
      return selected.find_by(parameter_code: parameter_code)
    end

    return unless kind.present?

    selected.where(measurement_kind: kind)
      .min_by { |s| Usgs::ParameterCodes.preference_rank(s.parameter_code) }
  end
  private_class_method :find_series

  def self.empty(kind, range)
    { kind: kind, range: range, unit: nil, points: [], peaks: [] }
  end

  def as_json(*)
    config = RANGES[range] || RANGES["7d"]
    points = if config[:continuous]
      continuous_points(config[:duration])
    else
      daily_points(config[:duration])
    end

    peaks = time_series.peak_observations.order(water_year: :desc).limit(20).map do |peak|
      { water_year: peak.water_year, v: peak.value.to_f, kind: peak.peak_kind, t: peak.observed_at&.iso8601 }
    end

    {
      kind: time_series.measurement_kind,
      label: Usgs::ParameterCodes.label_for(time_series.parameter_code, fallback: time_series.parameter_description),
      range: range,
      unit: UnitLabel.format(time_series.unit_of_measure),
      parameter_code: time_series.parameter_code,
      points: points,
      peaks: peaks
    }
  end

  private

  def continuous_points(duration)
    time_series.continuous_observations
      .where("observed_at >= ?", duration.ago)
      .order(:observed_at)
      .pluck(:observed_at, :value)
      .map { |t, v| { t: t.iso8601, v: v.to_f } }
  end

  def daily_points(duration)
    start_on = duration.ago.to_date
    hot = time_series.daily_observations
      .where("observed_on >= ?", start_on)
      .order(:observed_on)
      .pluck(:observed_on, :value)
      .map { |d, v| { t: d.iso8601, v: v.to_f } }

    return hot unless range == "3y" && DailyArchive.reads_enabled?

    hot_cutoff = DailyArchive.hot_cutoff_on
    cold_end = [ hot_cutoff - 1, Date.current ].min
    return hot if start_on > cold_end

    cold = DailyArchive::Reader.new.points_for(
      time_series_id: time_series.id,
      start_on: start_on,
      end_on: cold_end
    )

    merge_daily_points(cold, hot)
  end

  def merge_daily_points(cold, hot)
    by_day = {}
    cold.each { |p| by_day[p[:t]] = p }
    hot.each { |p| by_day[p[:t]] = p }
    by_day.values.sort_by { |p| p[:t] }
  end
end
