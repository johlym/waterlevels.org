class MonitoringLocation < ApplicationRecord
  STALE_AFTER = 1.week

  has_many :time_series, dependent: :destroy
  has_many :selected_time_series, -> { where(selected_for_display: true) }, class_name: "TimeSeries"

  before_validation :assign_derived_names

  validates :usgs_monitoring_location_id, :site_number, :name, :display_name, :search_name, :slug, :state_code, :latitude, :longitude, presence: true
  validates :usgs_monitoring_location_id, :site_number, uniqueness: true

  scope :active, -> { where(active: true) }
  # Matches #stale? inverted — recent enough for the map "Active" status.
  scope :not_stale, -> { where(latest_observed_at: STALE_AFTER.ago..) }
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
  # Anchored stations with a stale continuous tip or tip-sync hollow middle.
  # Tip sync enqueues IvRepairJob on tip jumps; IvRepairBatchJob is the slower
  # catch-up sweeper on USGS_API_HISTORY_IVREPAIR_KEY — not the cold history
  # backlog (missing ~32d archive / year daily). Deeper interior scars use
  # needing_iv_scar_repair / USGS_API_HISTORY_IVREPAIR2_KEY.
  #
  # Prefer MonitoringLocation.iv_repair_candidate_ids for batch work — that path
  # logs each step and avoids rebuilding the expensive tip-sync scan twice.
  scope :needing_iv_repair, lambda {
    where(id: iv_repair_candidate_ids)
  }

  # Anchored stations with a healthy tip but a deeper interior IV hole inside
  # CONTINUOUS_RETENTION (denorm continuous_max_gap_seconds). Scar lane / key2.
  scope :needing_iv_scar_repair, lambda {
    where(id: iv_scar_candidate_ids)
  }

  # Materialize IV-repair location ids with staged logs. Continuous tip/anchor
  # gates read denorm columns on time_series — no fleet scan of continuous_observations.
  def self.iv_repair_candidate_ids
    continuous_since = HistoryIngestion.continuous_gap_threshold.ago
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    Rails.logger.info("IvRepair candidates step=start")

    step_started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    tip_sync_gap_ids = HistoryIngestion.time_series_ids_with_tip_sync_gaps
    Rails.logger.info(
      "IvRepair candidates step=tip_sync_gaps ids=#{tip_sync_gap_ids.size} " \
      "elapsed_ms=#{((Process.clock_gettime(Process::CLOCK_MONOTONIC) - step_started) * 1000).round}"
    )

    step_started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    hollow_location_ids = []
    tip_sync_without_anchor = 0
    if tip_sync_gap_ids.any?
      gap_series = TimeSeries.selected.where(id: tip_sync_gap_ids)
      anchored_gap_ids = gap_series.with_continuous_anchor.pluck(:id)
      tip_sync_without_anchor = tip_sync_gap_ids.size - anchored_gap_ids.size
      hollow_location_ids = TimeSeries.where(id: anchored_gap_ids)
        .distinct
        .pluck(:monitoring_location_id)
    end
    Rails.logger.info(
      "IvRepair candidates step=hollow_middle_locations ids=#{hollow_location_ids.size} " \
      "tip_sync_without_anchor=#{tip_sync_without_anchor} " \
      "(those stay on history cold-fill) " \
      "elapsed_ms=#{((Process.clock_gettime(Process::CLOCK_MONOTONIC) - step_started) * 1000).round}"
    )

    Rails.logger.info(
      "IvRepair candidates step=missing_tip_locations starting " \
      "(anchored selected series with no IV tip in #{HistoryIngestion.continuous_gap_threshold.inspect})"
    )
    step_started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    missing_tip_location_ids = TimeSeries.selected_recently_active
      .with_continuous_anchor
      .where("continuous_newest_at IS NULL OR continuous_newest_at < ?", continuous_since)
      .distinct
      .pluck(:monitoring_location_id)
    Rails.logger.info(
      "IvRepair candidates step=missing_tip_locations ids=#{missing_tip_location_ids.size} " \
      "elapsed_ms=#{((Process.clock_gettime(Process::CLOCK_MONOTONIC) - step_started) * 1000).round}"
    )

    ids = (hollow_location_ids + missing_tip_location_ids).uniq.sort
    Rails.logger.info(
      "IvRepair candidates step=done count=#{ids.size} " \
      "hollow=#{hollow_location_ids.size} missing_tip=#{missing_tip_location_ids.size} " \
      "tip_sync_without_anchor=#{tip_sync_without_anchor} " \
      "elapsed_ms=#{((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round}"
    )
    ids
  end

  # Warm null max-gap denorm, then return location ids with an interior scar
  # and healthy tip adjacency (tip lane owns stale tip / tip-vs-prev hollow).
  def self.iv_scar_candidate_ids
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    threshold = HistoryIngestion.continuous_gap_threshold
    threshold_seconds = threshold.to_i
    tip_since = threshold.ago
    Rails.logger.info("IvScar candidates step=start threshold_s=#{threshold_seconds}")

    step_started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    null_denorm_ids = TimeSeries.selected
      .with_continuous_anchor
      .where(continuous_max_gap_seconds: nil)
      .limit(2_000)
      .pluck(:id)
    if null_denorm_ids.any?
      TimeSeries.refresh_continuous_coverage!(null_denorm_ids)
    end
    Rails.logger.info(
      "IvScar candidates step=warm_null_max_gap ids=#{null_denorm_ids.size} " \
      "elapsed_ms=#{((Process.clock_gettime(Process::CLOCK_MONOTONIC) - step_started) * 1000).round}"
    )

    step_started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    # Denorm-only: large interior max gap, tip fresh, tip-vs-prev healthy.
    location_ids = TimeSeries.selected
      .with_continuous_anchor
      .where("continuous_max_gap_seconds > ?", threshold_seconds)
      .where("continuous_newest_at >= ?", tip_since)
      .where.not(continuous_prev_at: nil)
      .where("continuous_newest_at - continuous_prev_at <= INTERVAL '#{threshold_seconds} seconds'")
      .where(
        "iv_scar_checked_at IS NULL OR iv_scar_checked_at < ? OR continuous_max_gap_seconds > COALESCE(iv_scar_checked_max_gap_seconds, 0)",
        HistoryIngestion.iv_scar_retry_after
      )
      .distinct
      .order(:monitoring_location_id)
      .pluck(:monitoring_location_id)
    Rails.logger.info(
      "IvScar candidates step=done count=#{location_ids.size} " \
      "elapsed_ms=#{((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round} " \
      "(gap_filter_ms=#{((Process.clock_gettime(Process::CLOCK_MONOTONIC) - step_started) * 1000).round})"
    )
    location_ids
  end

  scope :needing_history_backfill, lambda {
    # Cold / year-daily backlog only. Recent IV tip/hollow-middle repair for
    # already-anchored stations lives in needing_iv_repair so the long history
    # queue cannot starve IV completeness.
    daily_anchor = HistoryIngestion::DAILY_HISTORY_ANCHOR.ago.to_date
    daily_fresh_since = HistoryIngestion::DAILY_FRESHNESS.ago.to_date

    # Ignore long-inactive / POR-ended series via denorm continuous_newest_at
    # (and latest tip / ends_at). Brand-new catalog rows with no tip and no
    # ends_at still qualify.
    recently_active = TimeSeries.selected_recently_active

    missing_continuous_anchor = recently_active.where(has_continuous_anchor: false)
    # Year anchor lives in R2 (legacy Postgres rows still count during drain).
    # Skip parameters USGS does not publish daily DV for (IV-only series).
    expecting_daily = recently_active.merge(TimeSeries.expecting_daily)
    missing_daily_anchor = expecting_daily.where.not(
      id: DailyArchive.time_series_ids_with_daily_on_or_before(daily_anchor)
    )
    fresh_daily_tip_ids = DailyArchive.time_series_ids_with_fresh_daily_tip(daily_fresh_since)
    fresh_daily_tip_ids = DailyObservation
      .select(:time_series_id)
      .from(
        Arel.sql(
          "(#{fresh_daily_tip_ids.to_sql} UNION #{DailyObservation.where(observed_on: daily_fresh_since..).select(:time_series_id).to_sql}) AS daily_observations"
        )
      )
    stale_daily_tip = expecting_daily.where.not(id: fresh_daily_tip_ids)
    where(id: missing_continuous_anchor.select(:monitoring_location_id))
      .or(where(id: missing_daily_anchor.select(:monitoring_location_id)))
      .or(where(id: stale_daily_tip.select(:monitoring_location_id)))
      .distinct
  }
  # Year-ready stations that still lack ~3-year daily history. Excludes phase-1
  # candidates so the deep batch never competes with cold/lazy 1y fills.
  # Deep anchors are expected in R2. Intentionally does NOT nest
  # needing_history_backfill; phase-1 continuous/tip gates use denorm columns.
  scope :needing_deep_history_backfill, lambda {
    year_anchor = HistoryIngestion::DAILY_HISTORY_ANCHOR.ago.to_date
    deep_anchor = HistoryIngestion::DAILY_DEEP_HISTORY_ANCHOR.ago.to_date
    continuous_since = HistoryIngestion.continuous_freshness.ago
    daily_fresh_since = HistoryIngestion::DAILY_FRESHNESS.ago.to_date

    has_year = DailyArchive.time_series_ids_with_daily_on_or_before(year_anchor)
    has_deep = DailyArchive.time_series_ids_with_daily_on_or_before(deep_anchor)
    has_daily_tip = DailyArchive.time_series_ids_with_fresh_daily_tip(daily_fresh_since)
    has_daily_tip = DailyObservation
      .select(:time_series_id)
      .from(
        Arel.sql(
          "(#{has_daily_tip.to_sql} UNION #{DailyObservation.where(observed_on: daily_fresh_since..).select(:time_series_id).to_sql}) AS daily_observations"
        )
      )

    candidate_series = TimeSeries.selected_recently_active
      .merge(TimeSeries.expecting_daily)
      .with_continuous_anchor
      .where("continuous_newest_at >= ?", continuous_since)
      .where(id: has_year)
      .where.not(id: has_deep)
      .where(id: has_daily_tip)

    where(id: candidate_series.select(:monitoring_location_id)).distinct
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

  # Anchored series with a stale tip or tip-vs-previous hollow middle — tip IV
  # repair lane (not cold year/daily backlog, not deeper scar lane).
  def needs_iv_repair?
    series = time_series.selected.select(&:eligible_for_recent_history_backfill?)
    return false if series.none?

    series.any? { |s| HistoryIngestion.series_needs_iv_repair?(s) }
  end

  # Anchored series with a healthy tip adjacency but a deeper interior IV hole
  # inside CONTINUOUS_RETENTION — scar lane on USGS_API_HISTORY_IVREPAIR2_KEY.
  def needs_iv_scar_repair?
    series = time_series.selected.select(&:eligible_for_recent_history_backfill?)
    return false if series.none?

    series.any? { |s| HistoryIngestion.series_needs_iv_scar_repair?(s) }
  end

  # Selected series whose interior IV hole USGS already confirmed it cannot fill.
  def known_missing_usgs_iv_series
    time_series.selected.select { |series| HistoryIngestion.series_iv_scar_recently_checked?(series) }
  end

  def known_missing_usgs_iv?
    known_missing_usgs_iv_series.any?
  end

  def usgs_iv_gap_recheck_at
    known_missing_usgs_iv_series
      .filter_map { |series| HistoryIngestion.iv_scar_recheck_at(series.iv_scar_checked_at) }
      .min
  end

  def needs_history_backfill?
    series = time_series.selected.select(&:eligible_for_recent_history_backfill?)
    return false if series.none?

    daily_anchor = HistoryIngestion::DAILY_HISTORY_ANCHOR.ago.to_date
    daily_fresh_since = HistoryIngestion::DAILY_FRESHNESS.ago.to_date
    window_start = HistoryIngestion.continuous_retention.ago

    series.any? do |s|
      HistoryIngestion.series_has_continuous_coverage_gap?(s, window_start: window_start) ||
        (
          s.expects_daily_history? && (
            !s.has_daily_on_or_before?(daily_anchor) ||
            s.newest_daily_on.blank? || s.newest_daily_on < daily_fresh_since
          )
        )
    end
  end

  # True when a selected series that expects USGS daily still lacks points near
  # the ~1-year anchor — i.e. the 1 Year chart is not fully loaded yet.
  # IV-only / long-inactive parameters do not keep this callout up.
  def missing_year_history?
    series = time_series.selected.select { |s|
      s.expects_daily_history? && s.eligible_for_recent_history_backfill?
    }
    return false if series.none?

    daily_anchor = HistoryIngestion::DAILY_HISTORY_ANCHOR.ago.to_date
    series.any? { |s| !s.has_daily_on_or_before?(daily_anchor) }
  end

  # True when year history is present but a selected series still lacks daily
  # points near the ~3-year deep anchor (Postgres hot tip or cold archive).
  def missing_deep_history?
    series = time_series.selected.select { |s|
      s.expects_daily_history? && s.eligible_for_recent_history_backfill?
    }
    return false if series.none?
    return false if missing_year_history?

    deep_anchor = HistoryIngestion::DAILY_DEEP_HISTORY_ANCHOR.ago.to_date
    series.any? { |s| !s.has_daily_on_or_before?(deep_anchor) }
  end

  # True when every selected series that expects daily has points near the
  # ~3-year anchor — used to expose the 3 Years chart tab.
  def has_deep_history?
    series = time_series.selected.select { |s|
      s.expects_daily_history? && s.eligible_for_recent_history_backfill?
    }
    return false if series.none?

    deep_anchor = HistoryIngestion::DAILY_DEEP_HISTORY_ANCHOR.ago.to_date
    series.all? { |s| s.has_daily_on_or_before?(deep_anchor) }
  end

  # Selected series confirmed to have no USGS daily DV (IV-only parameters).
  # Only surface when recent continuous exists — otherwise the flag may be a
  # false positive from an empty recent-window fetch on a long-dead POR series.
  def daily_history_unavailable_series
    time_series.selected.where(usgs_daily_absent: true).select(&:recent_continuous_evidence?)
  end

  def daily_history_unavailable_labels
    daily_history_unavailable_series.map do |series|
      Usgs::ParameterCodes.label_for(series.parameter_code, fallback: series.parameter_description)
    end.uniq
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

  # Hard-delete locations and dependent rows without AR callbacks.
  # Chunked so Sunday catalog prune / cleanup cannot issue one multi-million-row
  # DELETE against continuous_observations (IV tip) and stall Postgres.
  PURGE_LOCATION_BATCH = 50
  PURGE_CONTINUOUS_BATCH = 5_000

  def self.purge_ids!(
    ids,
    location_batch_size: PURGE_LOCATION_BATCH,
    continuous_batch_size: PURGE_CONTINUOUS_BATCH
  )
    ids = Array(ids).compact.uniq
    return 0 if ids.empty?

    deleted = 0
    ids.each_slice(location_batch_size) do |batch|
      deleted += purge_id_batch!(batch, continuous_batch_size: continuous_batch_size)
    end
    deleted
  end

  def self.purge_id_batch!(ids, continuous_batch_size: PURGE_CONTINUOUS_BATCH)
    ids = Array(ids).compact.uniq
    return 0 if ids.empty?

    transaction do
      ts_ids = TimeSeries.where(monitoring_location_id: ids).pluck(:id)
      if ts_ids.any?
        LatestObservation.where(time_series_id: ts_ids).delete_all
        ts_ids.each do |ts_id|
          purge_continuous_for_series!(ts_id, batch_size: continuous_batch_size)
        end
        DailyObservation.where(time_series_id: ts_ids).delete_all
        PeakObservation.where(time_series_id: ts_ids).delete_all
        # Catalog rows for R2 year objects — must go before time_series (FK).
        DailyArchiveShard.where(time_series_id: ts_ids).delete_all
        TimeSeries.where(id: ts_ids).delete_all
      end
      where(id: ids).delete_all
    end
  end
  private_class_method :purge_id_batch!

  def self.purge_continuous_for_series!(time_series_id, batch_size: PURGE_CONTINUOUS_BATCH)
    scope = ContinuousObservation.where(time_series_id: time_series_id)
    scope.in_batches(of: batch_size) do |batch|
      batch.delete_all
    end
  end
  private_class_method :purge_continuous_for_series!

  private

  def assign_derived_names
    return if name.blank?
    return unless display_name.blank? || search_name.blank? || will_save_change_to_name?

    derived = self.class.derived_names_for(name)
    self.display_name = derived[:display_name]
    self.search_name = derived[:search_name]
  end
end
