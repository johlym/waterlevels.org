class SubscriberToken < ApplicationRecord
  belongs_to :subscriber

  PURPOSES = %w[manage verify unsubscribe].freeze

  validates :purpose, inclusion: { in: PURPOSES }
  validates :token_digest, presence: true, uniqueness: true

  scope :usable, -> {
    where(used_at: nil).where("expires_at IS NULL OR expires_at > ?", Time.current)
  }

  def self.digest(raw)
    Digest::SHA256.hexdigest(raw.to_s)
  end

  def self.find_usable!(raw, purpose:)
    token = usable.find_by!(purpose: purpose, token_digest: digest(raw))
    token
  end

  def expired?
    expires_at.present? && expires_at <= Time.current
  end

  def mark_used!
    update!(used_at: Time.current) if used_at.nil?
  end
end
