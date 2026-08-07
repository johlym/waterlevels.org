class DailyArchiveShard < ApplicationRecord
  belongs_to :time_series

  validates :year, :object_key, :content_sha256, :synced_at, presence: true
  validates :year, uniqueness: { scope: :time_series_id }
  validates :object_key, uniqueness: true

  SOURCE_MIXES = %w[usgs derived both].freeze
  validates :source_mix, inclusion: { in: SOURCE_MIXES }

  def covers?(day)
    return false if min_on.blank? || max_on.blank?

    day >= min_on && day <= max_on
  end
end
