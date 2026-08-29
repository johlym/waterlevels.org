class AlertEvent < ApplicationRecord
  belongs_to :monitoring_location
  has_many :alert_deliveries, dependent: :nullify

  validates :kind, :occurred_at, :dedupe_key, presence: true
  validates :dedupe_key, uniqueness: true

  scope :recent, -> { order(occurred_at: :desc) }

  def self.record!(location:, kind:, occurred_at:, payload:, dedupe_key:)
    create!(
      monitoring_location: location,
      kind: kind,
      occurred_at: occurred_at,
      payload: payload,
      dedupe_key: dedupe_key
    )
  rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid
    find_by(dedupe_key: dedupe_key)
  end
end
