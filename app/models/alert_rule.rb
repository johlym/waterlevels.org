class AlertRule < ApplicationRecord
  belongs_to :station_watch
  has_one :subscriber, through: :station_watch
  has_one :monitoring_location, through: :station_watch

  validates :kind, presence: true, inclusion: { in: AlertRuleKinds::ALL }

  scope :enabled, -> { where(enabled: true) }
  scope :of_kind, ->(kind) { where(kind: kind) }

  # Threshold-style rules default to 6 hours so a still-true condition
  # does not re-mail every tip. Flood category changes are discrete
  # events (action → minor → major); a shared default muted escalations
  # for the rest of a rising-flood window.
  THRESHOLD_COOLDOWN_KINDS = %w[threshold rate_of_rise in_range].freeze
  DEFAULT_THRESHOLD_COOLDOWN_MINUTES = 360

  def cooldown_minutes
    explicit = params["cooldown_minutes"]
    return explicit.to_i unless explicit.nil?

    THRESHOLD_COOLDOWN_KINDS.include?(kind) ? DEFAULT_THRESHOLD_COOLDOWN_MINUTES : 0
  end

  def in_cooldown?(at = Time.current)
    last_fired_at.present? && last_fired_at > cooldown_minutes.minutes.before(at)
  end

  def mark_fired!(at = Time.current)
    update!(last_fired_at: at, armed: false)
  end

  def rearm!
    update!(armed: true) unless armed?
  end

  def param(key, default = nil)
    params.fetch(key.to_s, default)
  end
end
