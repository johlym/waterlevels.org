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

  def self.for_series(series, current_value:, observed_at:)
    return new(current_value: current_value, prior_value: nil, label: "24h") if series.blank? || observed_at.blank?

    prior = series.continuous_observations
      .where("observed_at <= ?", observed_at - 24.hours)
      .order(observed_at: :desc)
      .limit(1)
      .pick(:value)

    prior ||= series.daily_observations
      .where("observed_on <= ?", (observed_at - 24.hours).to_date)
      .order(observed_on: :desc)
      .limit(1)
      .pick(:value)

    new(current_value: current_value, prior_value: prior, label: "24h")
  end

  def self.yoy_for_series(series, current_value:, observed_at:)
    return new(current_value: current_value, prior_value: nil, label: "YoY") if series.blank? || observed_at.blank?

    day = observed_at.to_date - 1.year
    prior = series.daily_observations.find_by(observed_on: day)&.value
    new(current_value: current_value, prior_value: prior, label: "YoY")
  end
end
