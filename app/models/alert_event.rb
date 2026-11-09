class AlertEvent < ApplicationRecord
  belongs_to :monitoring_location
  has_many :alert_deliveries, dependent: :nullify

  # Mail evaluation looks back 2 hours. Quiet/resume detection looks back 7
  # days, but only at those kinds. reading_change is one row per changed tip
  # and is otherwise unread.
  READING_RETENTION = 7.days
  PRUNE_BATCH = 5_000

  validates :kind, :occurred_at, :dedupe_key, presence: true
  validates :dedupe_key, uniqueness: true

  scope :recent, -> { order(occurred_at: :desc) }

  # Drop reading_change rows past READING_RETENTION. Flood, quiet, and resume
  # rows stay. Deliveries keep their own metadata; the event FK is cleared
  # first because alert_deliveries.alert_event_id is ON DELETE RESTRICT and
  # delete_all does not run dependent: :nullify.
  def self.prune_reading_changes!(older_than: READING_RETENTION.ago, batch_size: PRUNE_BATCH)
    deleted = 0
    min_id, max_id = where(kind: AlertEventRecorder::READING_KIND).pick(Arel.sql("MIN(id)"), Arel.sql("MAX(id)"))
    return 0 if min_id.nil?

    cursor = min_id
    while cursor <= max_id
      upper = cursor + batch_size
      ids = where(kind: AlertEventRecorder::READING_KIND, id: cursor...upper)
        .where(occurred_at: ...older_than)
        .pluck(:id)
      if ids.any?
        AlertDelivery.where(alert_event_id: ids).update_all(alert_event_id: nil, updated_at: Time.current)
        deleted += where(id: ids).delete_all
      end
      cursor = upper
    end
    deleted
  end

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
