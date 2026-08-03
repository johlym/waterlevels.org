class MonitoringLocation < ApplicationRecord
  STALE_AFTER = 1.week

  has_many :time_series, dependent: :destroy
  has_many :selected_time_series, -> { where(selected_for_display: true) }, class_name: "TimeSeries"

  before_validation :assign_derived_names

  validates :usgs_monitoring_location_id, :site_number, :name, :display_name, :search_name, :slug, :state_code, :latitude, :longitude, presence: true
  validates :usgs_monitoring_location_id, :site_number, uniqueness: true

  scope :in_state, ->(code) { where(state_code: code.to_s.downcase) }
  scope :ordered_for_state_table, -> { order(Arel.sql("LOWER(COALESCE(county_name, '')) ASC, LOWER(display_name) ASC")) }
  scope :in_bbox, lambda { |west, south, east, north|
    where(latitude: south..north, longitude: west..east)
  }
  scope :flood_alert, -> { where(flood_category: Nwps::FloodCategories::ALERT) }
  scope :search, lambda { |query|
    q = query.to_s.strip
    return none if q.blank?

    expanded = Usgs::LocationNames.search_key(q)
    pattern = "%#{sanitize_sql_like(q)}%"
    expanded_pattern = "%#{sanitize_sql_like(expanded)}%"
    where(
      "name ILIKE :pattern OR display_name ILIKE :pattern OR search_name ILIKE :expanded_pattern OR site_number ILIKE :pattern OR state_code ILIKE :pattern OR state_name ILIKE :pattern OR COALESCE(county_name, '') ILIKE :pattern OR COALESCE(nwps_lid, '') ILIKE :pattern",
      pattern: pattern,
      expanded_pattern: expanded_pattern
    ).order(
      Arel.sql(
        sanitize_sql_array([
          "CASE
            WHEN site_number = :exact THEN 0
            WHEN UPPER(COALESCE(nwps_lid, '')) = UPPER(:exact) THEN 1
            WHEN site_number ILIKE :prefix THEN 2
            WHEN display_name ILIKE :prefix OR search_name ILIKE :expanded_prefix OR name ILIKE :prefix THEN 3
            ELSE 4
          END, display_name ASC",
          {
            exact: q,
            prefix: "#{sanitize_sql_like(q)}%",
            expanded_prefix: "#{sanitize_sql_like(expanded)}%"
          }
        ])
      )
    )
  }
  scope :exact_search_match, lambda { |query|
    q = query.to_s.strip
    return none if q.blank?

    expanded = Usgs::LocationNames.search_key(q)
    where(
      "site_number = :exact OR UPPER(COALESCE(nwps_lid, '')) = UPPER(:exact) OR LOWER(display_name) = LOWER(:exact) OR LOWER(name) = LOWER(:exact) OR search_name = :expanded",
      exact: q,
      expanded: expanded
    )
  }
  scope :needing_history_backfill, lambda {
    continuous_since = HistoryIngestion::CONTINUOUS_FRESHNESS.ago
    daily_anchor = HistoryIngestion::DAILY_HISTORY_ANCHOR.ago.to_date
    daily_fresh_since = HistoryIngestion::DAILY_FRESHNESS.ago.to_date

    missing_continuous = TimeSeries.selected.where.not(
      id: ContinuousObservation.where(observed_at: continuous_since..).select(:time_series_id)
    )
    missing_daily_anchor = TimeSeries.selected.where.not(
      id: DailyObservation.where(observed_on: ..daily_anchor).select(:time_series_id)
    )
    stale_daily_tip = TimeSeries.selected.where.not(
      id: DailyObservation.where(observed_on: daily_fresh_since..).select(:time_series_id)
    )
    where(id: missing_continuous.select(:monitoring_location_id))
      .or(where(id: missing_daily_anchor.select(:monitoring_location_id)))
      .or(where(id: stale_daily_tip.select(:monitoring_location_id)))
      .distinct
  }

  def stale?
    latest_observed_at.blank? || latest_observed_at < STALE_AFTER.ago
  end

  def flood_alert?
    Nwps::FloodCategories.alert?(flood_category)
  end

  def flood_category_label
    Nwps::FloodCategories.label_for(flood_category)
  end

  def flood_category_short_label
    Nwps::FloodCategories.short_label_for(flood_category)
  end

  def has_flood_stages?
    flood_stage_action.present? || flood_stage_minor.present? ||
      flood_stage_moderate.present? || flood_stage_major.present?
  end

  def needs_history_backfill?
    series = time_series.selected
    return false if series.none?

    continuous_since = HistoryIngestion::CONTINUOUS_FRESHNESS.ago
    daily_anchor = HistoryIngestion::DAILY_HISTORY_ANCHOR.ago.to_date
    daily_fresh_since = HistoryIngestion::DAILY_FRESHNESS.ago.to_date

    series.any? do |s|
      s.continuous_observations.where(observed_at: continuous_since..).none? ||
        s.daily_observations.where(observed_on: ..daily_anchor).none? ||
        s.daily_observations.where(observed_on: daily_fresh_since..).none?
    end
  end

  def to_param
    "#{site_number}-#{slug}"
  end

  def path_state
    state_code.to_s.downcase
  end

  # IANA zone for the USGS `time_zone` abbreviation (e.g. CST → America/Chicago).
  def time_zone_identifier
    Usgs::TimeZones.iana_identifier(time_zone, state_code: state_code)
  end

  def measurement_kinds
    kinds = []
    kinds << "water_level" if has_water_level?
    kinds << "discharge" if has_discharge?
    kinds << "temperature" if has_temperature?
    kinds
  end

  def self.slug_for(name)
    name.to_s.parameterize.presence || "gauge"
  end

  # Derived display/search fields for upsert/insert_all paths that skip callbacks.
  def self.derived_names_for(name)
    display = Usgs::LocationNames.format(name)
    { display_name: display, search_name: display.downcase }
  end

  # Hard-delete locations and dependent rows without AR callbacks (fast purge).
  def self.purge_ids!(ids)
    ids = Array(ids).compact.uniq
    return 0 if ids.empty?

    ts_ids = TimeSeries.where(monitoring_location_id: ids).pluck(:id)
    if ts_ids.any?
      LatestObservation.where(time_series_id: ts_ids).delete_all
      ContinuousObservation.where(time_series_id: ts_ids).delete_all
      DailyObservation.where(time_series_id: ts_ids).delete_all
      PeakObservation.where(time_series_id: ts_ids).delete_all
      TimeSeries.where(id: ts_ids).delete_all
    end
    where(id: ids).delete_all
  end

  private

  def assign_derived_names
    return if name.blank?
    return unless display_name.blank? || search_name.blank? || will_save_change_to_name?

    derived = self.class.derived_names_for(name)
    self.display_name = derived[:display_name]
    self.search_name = derived[:search_name]
  end
end
