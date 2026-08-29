class AlertRule < ApplicationRecord
  belongs_to :station_watch
  has_one :subscriber, through: :station_watch
  has_one :monitoring_location, through: :station_watch

  validates :kind, presence: true, inclusion: { in: AlertRuleKinds::ALL }

  scope :enabled, -> { where(enabled: true) }
  scope :of_kind, ->(kind) { where(kind: kind) }

  def cooldown_minutes
    (params["cooldown_minutes"] || 360).to_i
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
