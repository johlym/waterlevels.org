class FloodStageSync
  include ActiveModel::Model

  # Re-check unmatched USGS sites periodically — most will keep 404ing.
  UNMATCHED_RETRY_AFTER = 7.days
  # Detail GETs for thresholds / LID crosswalk; categories refresh via list.
  MATCHED_DETAIL_REFRESH_AFTER = 24.hours

  attr_accessor :client, :state, :progress

  def initialize(client: Nwps::Client.new, state: nil, progress: nil)
    @client = client
    @state = state.presence
    @progress = progress
  end

  def perform
    progress&.step(scope_label)
    list_updated = refresh_categories_from_list
    matched, unmatched, skipped, errors = discover_and_refresh_details

    progress&.step("warming caches")
    warm_caches
    progress&.finish(
      "list_updated=#{list_updated} matched=#{matched} unmatched=#{unmatched} " \
      "skipped=#{skipped} errors=#{errors}"
    )
    true
  end

  private

  def scope_label
    postal_code ? "state=#{postal_code}" : "national"
  end

  def postal_code
    @postal_code ||= state && Usgs::StateCodes.normalize_postal(state)
  end

  def sync_scope
    scope = MonitoringLocation.where(active: true)
    postal_code ? scope.in_state(postal_code) : scope
  end

  # Phase 1: one national (or filtered) list call updates flood_category for
  # every site we already crosswalked by NWPS LID. List payloads include
  # status.observed/forecast.floodCategory but not usgsId or stage thresholds.
  def refresh_categories_from_list
    gauges = client.gauges
    gauges = filter_gauges_for_state(gauges) if postal_code

    by_lid = gauges.each_with_object({}) do |gauge, memo|
      lid = gauge["lid"].to_s.upcase.presence
      next unless lid

      memo[lid] = gauge
    end
    progress&.step("nwps list gauges=#{by_lid.size}")

    updated = 0
    sync_scope.where.not(nwps_lid: [ nil, "" ]).find_each do |location|
      gauge = by_lid[location.nwps_lid.to_s.upcase]
      next unless gauge

      apply_list_status!(location, gauge)
      updated += 1
      progress&.increment
    end
    updated
  rescue Nwps::Client::Error => e
    progress&.step("list refresh skipped: #{e.message}")
    0
  end

  def filter_gauges_for_state(gauges)
    abbrev = postal_code.to_s.upcase
    gauges.select { |gauge| gauge.dig("state", "abbreviation").to_s.upcase == abbrev }
  end

  # Phase 2: USGS site-number detail lookups for first-time matches and
  # periodic threshold refresh. Never-synced sites are ordered first so
  # coverage expands before we re-detail known matches.
  def discover_and_refresh_details
    matched = 0
    unmatched = 0
    skipped = 0
    errors = 0

    detail_scope.find_each do |location|
      unless due_for_detail_sync?(location)
        skipped += 1
        next
      end

      begin
        gauge = client.gauge(location.site_number)
        if gauge.present?
          apply_match!(location, gauge)
          matched += 1
        else
          apply_miss!(location)
          unmatched += 1
        end
      rescue Nwps::Client::Error => e
        errors += 1
        progress&.step("error site=#{location.site_number} #{e.message}")
      end

      progress&.increment
    end

    [ matched, unmatched, skipped, errors ]
  end

  def detail_scope
    sync_scope.order(Arel.sql("nwps_synced_at ASC NULLS FIRST, site_number ASC"))
  end

  def due_for_detail_sync?(location)
    return true if location.nwps_synced_at.blank?
    return true if location.nwps_matched? && location.nwps_synced_at < MATCHED_DETAIL_REFRESH_AFTER.ago

    !location.nwps_matched? && location.nwps_synced_at < UNMATCHED_RETRY_AFTER.ago
  end

  def apply_list_status!(location, gauge)
    category, category_at = category_from_status(gauge["status"])
    attrs = {
      nwps_matched: true,
      flood_category: category,
      flood_category_observed_at: category_at || location.flood_category_observed_at
    }
    # List responses omit thresholds; keep existing stage columns.
    location.update!(attrs)
    StationSnapshotCache.warm(location)
  end

  def apply_match!(location, gauge)
    categories = gauge.dig("flood", "categories") || {}
    category, category_at = category_from_status(gauge["status"])

    location.update!(
      nwps_lid: gauge["lid"].presence || location.nwps_lid,
      nwps_matched: true,
      nwps_synced_at: Time.current,
      flood_stage_action: Nwps::FloodCategories.stage_value(categories.dig("action", "stage")),
      flood_stage_minor: Nwps::FloodCategories.stage_value(categories.dig("minor", "stage")),
      flood_stage_moderate: Nwps::FloodCategories.stage_value(categories.dig("moderate", "stage")),
      flood_stage_major: Nwps::FloodCategories.stage_value(categories.dig("major", "stage")),
      flood_category: category,
      flood_category_observed_at: category_at
    )
    StationSnapshotCache.warm(location)
  end

  def apply_miss!(location)
    location.update!(
      nwps_lid: nil,
      nwps_matched: false,
      nwps_synced_at: Time.current,
      flood_stage_action: nil,
      flood_stage_minor: nil,
      flood_stage_moderate: nil,
      flood_stage_major: nil,
      flood_category: nil,
      flood_category_observed_at: nil
    )
    StationSnapshotCache.warm(location)
  end

  def category_from_status(status)
    status = status || {}
    observed = status["observed"] || {}
    forecast = status["forecast"] || {}
    category = Nwps::FloodCategories.effective(observed["floodCategory"], forecast["floodCategory"])
    category_at = parse_time(observed["validTime"]) || parse_time(forecast["validTime"])
    [ category, category_at ]
  end

  def warm_caches
    SiteStats.bust!
    if postal_code
      StateListingCache.warm(postal_code)
    else
      StateListingCache.warm_all
    end
  end

  def parse_time(value)
    return if value.blank?

    Time.zone.parse(value.to_s)
  rescue ArgumentError
    nil
  end
end
