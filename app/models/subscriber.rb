class Subscriber < ApplicationRecord
  has_many :station_watches, dependent: :destroy
  has_many :monitoring_locations, through: :station_watches
  has_many :alert_rules, through: :station_watches
  has_many :subscriber_tokens, dependent: :destroy
  has_many :alert_deliveries, dependent: :destroy

  before_validation :normalize_email
  before_validation :normalize_time_zone

  validates :email, presence: true, uniqueness: { case_sensitive: false },
                    format: { with: URI::MailTo::EMAIL_REGEXP }
  validates :time_zone, presence: true
  validates :digest_hour, inclusion: { in: 0..23 }
  validates :digest_minute, inclusion: { in: [ 0, 30 ] }

  scope :verified, -> { where.not(verified_at: nil) }
  scope :active, -> {
    verified.where(unsubscribed_at: nil).where(paused_at: nil)
  }
  scope :digest_due, -> {
    active.where(digest_enabled: true)
  }

  def verified?
    verified_at.present?
  end

  def unsubscribed?
    unsubscribed_at.present?
  end

  def paused?
    paused_at.present?
  end

  def active_for_alerts?
    verified? && !unsubscribed? && !paused?
  end

  def verify!
    update!(verified_at: Time.current) unless verified?
  end

  def pause!
    update!(paused_at: Time.current)
  end

  def unpause!
    update!(paused_at: nil)
  end

  def unsubscribe_all!
    transaction do
      update!(unsubscribed_at: Time.current, paused_at: nil, digest_enabled: false)
      alert_rules.update_all(enabled: false, updated_at: Time.current)
    end
  end

  def in_quiet_hours?(at = Time.current)
    return false if quiet_hours_start_minute.nil? || quiet_hours_end_minute.nil?

    zone = Time.find_zone(time_zone) || Time.find_zone("UTC")
    local = at.in_time_zone(zone)
    minutes = local.hour * 60 + local.min
    start_m = quiet_hours_start_minute
    end_m = quiet_hours_end_minute
    if start_m <= end_m
      minutes >= start_m && minutes < end_m
    else
      minutes >= start_m || minutes < end_m
    end
  end

  def digest_local_time_label
    format("%d:%02d", digest_hour, digest_minute)
  end

  def due_for_digest?(now = Time.current)
    return false unless digest_enabled? && active_for_alerts?

    zone = Time.find_zone(time_zone) || Time.find_zone("UTC")
    local = now.in_time_zone(zone)
    return false if digest_last_sent_on == local.to_date

    local_minutes = local.hour * 60 + local.min
    target = digest_hour * 60 + digest_minute
    local_minutes >= target && local_minutes < target + 15
  end

  def mark_digest_sent!(on: nil)
    zone = Time.find_zone(time_zone) || Time.find_zone("UTC")
    update!(digest_last_sent_on: on || Time.current.in_time_zone(zone).to_date)
  end

  def issue_token!(purpose:, expires_at: nil)
    raw = SecureRandom.urlsafe_base64(32)
    subscriber_tokens.create!(
      purpose: purpose,
      token_digest: SubscriberToken.digest(raw),
      expires_at: expires_at
    )
    raw
  end

  def manage_token!
    existing = subscriber_tokens.where(purpose: "manage", used_at: nil)
      .where("expires_at IS NULL OR expires_at > ?", Time.current)
      .order(created_at: :desc).first
    # Always issue fresh raw token; invalidate old manage digests by rotating
    subscriber_tokens.where(purpose: "manage").delete_all
    issue_token!(purpose: "manage", expires_at: 2.years.from_now)
  end

  private

  def normalize_email
    self.email = email.to_s.strip.downcase.presence
  end

  def normalize_time_zone
    self.time_zone = SubscriberTimeZones.normalize(time_zone)
  end
end
