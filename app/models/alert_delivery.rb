class AlertDelivery < ApplicationRecord
  belongs_to :subscriber
  belongs_to :alert_event, optional: true
  belongs_to :alert_rule, optional: true

  STATUSES = %w[queued sent failed skipped].freeze

  validates :mailer_action, :status, presence: true
  validates :status, inclusion: { in: STATUSES }

  scope :sent, -> { where(status: "sent") }
end
