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
    Telemetry.in_root_span(
      "flood.sync",
      attributes: {
        "app.operation" => "flood.sync",
        "app.state" => postal_code || "national"
      }
    ) do
      progress&.step(scope_label)
      totals = blank_totals

      states_to_sync.each do |state_code|
        sync_state(state_code, totals)
      end

      Telemetry.add_attributes(
        "app.batch_size" => totals[:batch_size],
        "app.list_updated" => totals[:list_updated],
        "app.alert_matched" => totals[:alert_matched],
        "app.matched_count" => totals[:matched],
        "app.unmatched_count" => totals[:unmatched],
        "app.skipped_count" => totals[:skipped],
        "app.error_count" => totals[:errors]
      )

      progress&.step("warming caches")
      warm_caches
      progress&.finish(
        "list_updated=#{totals[:list_updated]} alert_matched=#{totals[:alert_matched]} " \
        "matched=#{totals[:matched]} unmatched=#{totals[:unmatched]} " \
        "skipped=#{totals[:skipped]} errors=#{totals[:errors]}"
      )
      AdminDashboardStats.record_job_finish!(
        :flood_sync,
        state: postal_code,
        list_updated: totals[:list_updated],
        matched: totals[:matched],
        unmatched: totals[:unmatched]
      )
      true
    end
  end

  private

  def blank_totals
    {
      batch_size: 0,
      list_updated: 0,
      alert_matched: 0,
      matched: 0,
      unmatched: 0,
      skipped: 0,
      errors: 0
    }
  end

  def scope_label
    postal_code ? "state=#{postal_code}" : "national"
  end

  def postal_code
    @postal_code ||= state && Usgs::StateCodes.normalize_postal(state)
  end

  def states_to_sync
    postal_code ? [ postal_code ] : Usgs::StateCodes::STATES.keys.sort
  end

  def sync_state(state_code, totals)
    progress&.step("state=#{state_code}")
    gauges_by_lid = fetch_gauges_by_lid(state_code)
    totals[:batch_size] += gauges_by_lid.size
    totals[:list_updated] += refresh_categories_from_list(gauges_by_lid, state_code)
    totals[:alert_matched] += match_unlinked_alert_gauges(gauges_by_lid, state_code)

    matched, unmatched, skipped, errors = discover_and_refresh_details(state_code)
    totals[:matched] += matched
    totals[:unmatched] += unmatched
    totals[:skipped] += skipped
    totals[:errors] += errors
  end

  def sync_scope(state_code)
    MonitoringLocation.active.in_state(state_code)
  end

  def fetch_gauges_by_lid(state_code)
    gauges = filter_gauges_for_state(client.gauges(state: state_code), state_code)

    by_lid = gauges.each_with_object({}) do |gauge, memo|
      lid = gauge["lid"].to_s.upcase.presence
      next unless lid

      memo[lid] = gauge
    end
    progress&.step("nwps list state=#{state_code} gauges=#{by_lid.size}")
    by_lid
  rescue Nwps::Client::Error => e
    progress&.step("list fetch skipped state=#{state_code}: #{e.message}")
    {}
  end

  # Phase 1: one list call updates flood_category for every site we already
  # crosswalked by NWPS LID. List payloads include status but not usgsId /
  # stage thresholds.
  def refresh_categories_from_list(by_lid, state_code)
    return 0 if by_lid.empty?

    updated = 0
    unchanged = 0
    sync_scope(state_code).where.not(nwps_lid: [ nil, "" ]).find_each do |location|
      gauge = by_lid[location.nwps_lid.to_s.upcase]
      next unless gauge

      if apply_list_status!(location, gauge)
        updated += 1
      else
        unchanged += 1
      end
      progress&.increment
    end
    progress&.step("list refresh state=#{state_code} updated=#{updated} unchanged=#{unchanged}")
    updated
  end

  def filter_gauges_for_state(gauges, state_code)
    abbrev = state_code.to_s.upcase
    gauges.select { |gauge| gauge.dig("state", "abbreviation").to_s.upcase == abbrev }
  end

  # Phase 1b: for NWPS points currently at action+ that we have not linked yet,
  # fetch detail by LID (includes usgsId + thresholds) and join to our catalog.
  # This prioritizes every actively flooding gauge in-state, not only sites
  # reached by USGS site-number iteration order.
  def match_unlinked_alert_gauges(by_lid, state_code)
    return 0 if by_lid.empty?

    known_lids = sync_scope(state_code).where.not(nwps_lid: [ nil, "" ]).pluck(:nwps_lid).map { |lid| lid.to_s.upcase }
    known_lids = known_lids.to_set

    candidates = by_lid.filter_map do |lid, gauge|
      next if known_lids.include?(lid)

      category, = category_from_status(gauge["status"])
      next unless Nwps::FloodCategories.alert?(category)

      gauge
    end
    progress&.step("unlinked alert gauges state=#{state_code} count=#{candidates.size}")

    matched = 0
    candidates.each do |summary|
      lid = summary["lid"].to_s
      begin
        detail = client.gauge(lid)
        next if detail.blank?

        location = find_location_for_usgs_id(detail["usgsId"], state_code)
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

  def find_location_for_usgs_id(usgs_id, state_code)
    raw = usgs_id.to_s.strip
    return if raw.blank?

    candidates = site_number_candidates(raw)
    by_site = location_by_site_number(state_code)
    candidates.each do |site_number|
      location = by_site[site_number]
      return location if location
    end
    nil
  end

  def site_number_candidates(raw)
    candidates = [ raw ]
    if raw.match?(/\A\d+\z/)
      candidates << raw.rjust(8, "0")
      candidates << raw.sub(/\A0+/, "")
    end
    candidates.map(&:presence).compact.uniq
  end

  def location_by_site_number(state_code)
    @location_by_site_number ||= {}
    @location_by_site_number[state_code] ||= sync_scope(state_code).index_by(&:site_number)
  end

  # Phase 2: USGS site-number detail lookups for first-time matches and
  # periodic threshold refresh.
  #
  # Due filtering is in SQL so we don't load the whole active catalog every
  # hour, and a canceled run naturally resumes: finished rows get a fresh
  # nwps_synced_at and drop out of the due set.
  def discover_and_refresh_details(state_code)
    matched = 0
    unmatched = 0
    skipped = 0
    errors = 0

    due = detail_scope(state_code)
    progress&.step("detail sync state=#{state_code} due=#{due.count}")

    due.find_each do |location|
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

  def detail_scope(state_code)
    matched_cutoff = MATCHED_DETAIL_REFRESH_AFTER.ago
    unmatched_cutoff = UNMATCHED_RETRY_AFTER.ago
    sync_scope(state_code).where(
      "nwps_synced_at IS NULL OR " \
      "(nwps_matched = TRUE AND nwps_synced_at < ?) OR " \
      "(nwps_matched = FALSE AND nwps_synced_at < ?)",
      matched_cutoff,
      unmatched_cutoff
    )
  end

  def apply_list_status!(location, gauge)
    category, category_at = category_from_status(gauge["status"])
    attrs = { nwps_matched: true }
    # Keep the prior category when NWPS reports only non-current sentinels.
    if category.present?
      attrs[:flood_category] = category
      attrs[:flood_category_observed_at] = category_at || location.flood_category_observed_at
    end

    # Avoid rewrite + snapshot warm when the list status did not change.
    return false if list_status_unchanged?(location, attrs)

    # List responses omit thresholds; keep existing stage columns.
    location.update!(attrs)
    StationSnapshotCache.warm(location)
    true
  end

  def list_status_unchanged?(location, attrs)
    return false unless location.nwps_matched?

    if attrs.key?(:flood_category)
      location.flood_category.to_s == attrs[:flood_category].to_s &&
        location.flood_category_observed_at.to_i == attrs[:flood_category_observed_at].to_i
    else
      true
    end
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
