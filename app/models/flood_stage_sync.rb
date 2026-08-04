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
    gauges_by_lid = fetch_gauges_by_lid
    list_updated = refresh_categories_from_list(gauges_by_lid)
    alert_matched = match_unlinked_alert_gauges(gauges_by_lid)
    matched, unmatched, skipped, errors = discover_and_refresh_details

    progress&.step("warming caches")
    warm_caches
    progress&.finish(
      "list_updated=#{list_updated} alert_matched=#{alert_matched} " \
      "matched=#{matched} unmatched=#{unmatched} skipped=#{skipped} errors=#{errors}"
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

  def fetch_gauges_by_lid
    gauges = client.gauges
    gauges = filter_gauges_for_state(gauges) if postal_code

    by_lid = gauges.each_with_object({}) do |gauge, memo|
      lid = gauge["lid"].to_s.upcase.presence
      next unless lid

      memo[lid] = gauge
    end
    progress&.step("nwps list gauges=#{by_lid.size}")
    by_lid
  rescue Nwps::Client::Error => e
    progress&.step("list fetch skipped: #{e.message}")
    {}
  end

  # Phase 1: one list call updates flood_category for every site we already
  # crosswalked by NWPS LID. List payloads include status but not usgsId /
  # stage thresholds.
  def refresh_categories_from_list(by_lid)
    return 0 if by_lid.empty?

    updated = 0
    sync_scope.where.not(nwps_lid: [ nil, "" ]).find_each do |location|
      gauge = by_lid[location.nwps_lid.to_s.upcase]
      next unless gauge

      apply_list_status!(location, gauge)
      updated += 1
      progress&.increment
    end
    updated
  end

  def filter_gauges_for_state(gauges)
    abbrev = postal_code.to_s.upcase
    gauges.select { |gauge| gauge.dig("state", "abbreviation").to_s.upcase == abbrev }
  end

  # Phase 1b: for NWPS points currently at action+ that we have not linked yet,
  # fetch detail by LID (includes usgsId + thresholds) and join to our catalog.
  # This prioritizes every actively flooding gauge nationally, not only sites
  # reached by USGS site-number iteration order.
  def match_unlinked_alert_gauges(by_lid)
    return 0 if by_lid.empty?

    known_lids = sync_scope.where.not(nwps_lid: [ nil, "" ]).pluck(:nwps_lid).map { |lid| lid.to_s.upcase }
    known_lids = known_lids.to_set

    candidates = by_lid.filter_map do |lid, gauge|
      next if known_lids.include?(lid)

      category, = category_from_status(gauge["status"])
      next unless Nwps::FloodCategories.alert?(category)

      gauge
    end
    progress&.step("unlinked alert gauges=#{candidates.size}")

    matched = 0
    candidates.each do |summary|
      lid = summary["lid"].to_s
      begin
        detail = client.gauge(lid)
        next if detail.blank?

        location = find_location_for_usgs_id(detail["usgsId"])
        next unless location

        apply_match!(location, detail)
        matched += 1
        progress&.increment
      rescue Nwps::Client::Error => e
        progress&.step("error lid=#{lid} #{e.message}")
      end
    end
    matched
  end

  def find_location_for_usgs_id(usgs_id)
    raw = usgs_id.to_s.strip
    return if raw.blank?

    candidates = [ raw ]
    if raw.match?(/\A\d+\z/)
      candidates << raw.rjust(8, "0")
      candidates << raw.sub(/\A0+/, "")
    end
    candidates = candidates.map(&:presence).compact.uniq
    sync_scope.find_by(site_number: candidates)
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
    attrs = { nwps_matched: true }
    # Keep the prior category when NWPS reports only non-current sentinels.
    if category.present?
      attrs[:flood_category] = category
      attrs[:flood_category_observed_at] = category_at || location.flood_category_observed_at
    end
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
    status ||= {}
    observed = status["observed"] || {}
    forecast = status["forecast"] || {}
    category = Nwps::FloodCategories.effective(observed["floodCategory"], forecast["floodCategory"])
    category_at = parse_time(observed["validTime"]) || parse_time(forecast["validTime"])
    [ category, category_at ]
  end

  def warm_caches
    # Recompute in-process so the next home origin hit is not a cold COUNT(*) miss.
    SiteStats.warm!
    AlertsListingCache.warm
    if postal_code
      StateListingCache.warm(postal_code)
    else
      StateListingCache.warm_all
    end
    EdgeCacheInvalidation.after_flood_sync!(state: state)
  end


  def parse_time(value)
    return if value.blank?

    Time.zone.parse(value.to_s)
  rescue ArgumentError
    nil
  end
end
