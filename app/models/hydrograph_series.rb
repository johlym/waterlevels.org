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
        "station.site_number" => location.site_number,
        "parameter_code" => parameter_code,
        "measurement.kind" => kind,
        "range" => range
      }
    ) do
      series = find_series(location, kind: kind, parameter_code: parameter_code)
      return empty(kind || parameter_code, range) unless series

      payload = new(time_series: series, range: range).as_json
      Telemetry.add_attributes(
        "parameter_code" => series.parameter_code,
        "measurement.kind" => series.measurement_kind,
        "points.count" => Array(payload[:points]).size
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
      time_series.continuous_observations
        .where("observed_at >= ?", config[:duration].ago)
        .order(:observed_at)
        .pluck(:observed_at, :value)
        .map { |t, v| { t: t.iso8601, v: v.to_f } }
    else
      time_series.daily_observations
        .where("observed_on >= ?", config[:duration].ago.to_date)
        .order(:observed_on)
        .pluck(:observed_on, :value)
        .map { |d, v| { t: d.iso8601, v: v.to_f } }
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
end
