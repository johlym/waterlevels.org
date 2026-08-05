class TrendComparison
  include ActiveModel::Model

  attr_accessor :current_value, :prior_value, :label

  def delta
    return if current_value.nil? || prior_value.nil?

    current_value.to_f - prior_value.to_f
  end

  def percent_change
    return if delta.nil? || prior_value.to_f.zero?

    (delta / prior_value.to_f) * 100.0
  end

  def self.for_series(series, current_value:, observed_at:, prior_continuous: :lookup)
    return new(current_value: current_value, prior_value: nil, label: "24h") if series.blank? || observed_at.blank?

    cutoff_at = observed_at - 24.hours
    prior = if prior_continuous == :lookup
      lookup_continuous_prior(series, cutoff_at)
    else
      prior_continuous
    end

    prior ||= lookup_daily_prior(series, cutoff_at.to_date)

    new(current_value: current_value, prior_value: prior, label: "24h")
  end

  def self.yoy_for_series(series, current_value:, observed_at:)
    return new(current_value: current_value, prior_value: nil, label: "YoY") if series.blank? || observed_at.blank?

    day = observed_at.to_date - 1.year
    prior = lookup_daily_on(series, day)
    new(current_value: current_value, prior_value: prior, label: "YoY")
  end

  # One query for all series: most recent continuous value at or before each
  # series' (latest_observed_at - 24h) cutoff. Returns { time_series_id => value }.
  def self.prior_24h_continuous_by_series(series_list)
    cutoffs = Array(series_list).filter_map do |series|
      observed_at = series.latest_observation&.observed_at
      next if observed_at.blank?

      [ series.id, observed_at - 24.hours ]
    end
    return {} if cutoffs.empty?

    ids = cutoffs.map(&:first)
    times = cutoffs.map { |(_, cutoff)| cutoff.utc }

    rows = ContinuousObservation.connection.select_rows(
      ActiveRecord::Base.sanitize_sql_array(
        [
          <<~SQL.squish,
            SELECT DISTINCT ON (c.time_series_id) c.time_series_id, c.value
            FROM continuous_observations c
            INNER JOIN unnest(ARRAY[?]::bigint[], ARRAY[?]::timestamptz[])
              AS cutoffs(time_series_id, cutoff)
              ON c.time_series_id = cutoffs.time_series_id
            WHERE c.observed_at <= cutoffs.cutoff
            ORDER BY c.time_series_id, c.observed_at DESC
          SQL
          ids,
          times
        ]
      )
    )

    rows.to_h { |id, value| [ id.to_i, value ] }
  end

  def self.lookup_continuous_prior(series, cutoff_at)
    if series.association(:continuous_observations).loaded?
      series.continuous_observations
        .select { |o| o.observed_at <= cutoff_at }
        .max_by(&:observed_at)
        &.value
    else
      series.continuous_observations
        .where("observed_at <= ?", cutoff_at)
        .order(observed_at: :desc)
        .limit(1)
        .pick(:value)
    end
  end
  private_class_method :lookup_continuous_prior

  def self.lookup_daily_prior(series, cutoff_on)
    if series.association(:daily_observations).loaded?
      series.daily_observations
        .select { |d| d.observed_on <= cutoff_on }
        .max_by(&:observed_on)
        &.value
    else
      series.daily_observations
        .where("observed_on <= ?", cutoff_on)
        .order(observed_on: :desc)
        .limit(1)
        .pick(:value)
    end
  end
  private_class_method :lookup_daily_prior

  def self.lookup_daily_on(series, day)
    if series.association(:daily_observations).loaded?
      series.daily_observations.find { |d| d.observed_on == day }&.value
    else
      series.daily_observations.find_by(observed_on: day)&.value
    end
  end
  private_class_method :lookup_daily_on
end
