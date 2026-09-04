class FloodStageSync
  include ActiveModel::Model

  # Re-check unmatched USGS sites periodically — most will keep 404ing.
  UNMATCHED_RETRY_AFTER = 7.days
  # Thresholds rarely change; list refresh already updates flood_category hourly.
  MATCHED_DETAIL_REFRESH_AFTER = 7.days
  # Drop action+ categories we have not seen a current NWPS status for. List
  # refresh skips missing LIDs and keeps the prior category on obs/fcst
  # sentinels; without an age-out those rows ratchet the national alert count.
  STALE_ALERT_AFTER = 24.hours
  # Per-state detail GET cap (alert LID + site discovery). Keep small so each
  # state usually finishes near the job's 30s inter-state timer under NWPS pacing.
  DEFAULT_DETAIL_REQUEST_BUDGET = 3

  attr_accessor :client, :state, :progress

  def initialize(client: Nwps::Client.new, state: nil, progress: nil)
    @client = client
    @state = state.presence
    @progress = progress
  end

  def perform
    raise ArgumentError, "FloodStageSync requires a state (national runs use FloodStageSyncJob)" if postal_code.blank?

    Telemetry.in_root_span(
      "flood.sync",
      attributes: {
        "app.operation" => "flood.sync",
        "app.state" => postal_code
      }
    ) do
      @detail_requests_remaining = detail_request_budget
      progress&.step("#{scope_label} detail_budget=#{@detail_requests_remaining}")

      phase_start = monotonic_now
      gauges_by_lid = fetch_gauges_by_lid
      progress&.step(
        phase: "list_fetch",
        status: "done",
        gauges: gauges_by_lid.size,
        list_fetch_failed: @list_fetch_failed,
        elapsed: elapsed_s(phase_start).to_f
      )

      phase_start = monotonic_now
      list_updated = refresh_categories_from_list(gauges_by_lid)
      expired = expire_stale_unseen_alerts!(gauges_by_lid)
      progress&.step(
        phase: "list_refresh",
        status: "done",
        updated: list_updated,
        expired: expired,
        elapsed: elapsed_s(phase_start).to_f
      )

      phase_start = monotonic_now
      alert_matched = match_unlinked_alert_gauges(gauges_in_state(gauges_by_lid))
      progress&.step(
        phase: "alert_match",
        status: "done",
        matched: alert_matched,
        budget_remaining: @detail_requests_remaining,
        elapsed: elapsed_s(phase_start).to_f
      )

      phase_start = monotonic_now
      matched, unmatched, skipped, errors = discover_and_refresh_details
      progress&.step(
        phase: "detail_sync",
        status: "done",
        matched: matched,
        unmatched: unmatched,
        skipped: skipped,
        errors: errors,
        budget_remaining: @detail_requests_remaining,
        elapsed: elapsed_s(phase_start).to_f
      )

      Telemetry.add_attributes(
        "app.batch_size" => gauges_by_lid.size,
        "app.list_updated" => list_updated,
        "app.expired_count" => expired,
        "app.alert_matched" => alert_matched,
        "app.matched_count" => matched,
        "app.unmatched_count" => unmatched,
        "app.skipped_count" => skipped,
        "app.error_count" => errors,
        "app.detail_budget" => detail_request_budget,
        "app.detail_budget_remaining" => @detail_requests_remaining
      )

      changed = list_updated.positive? || expired.positive? ||
        alert_matched.positive? || matched.positive? || unmatched.positive?
      warm_caches(changed: changed)
      progress&.finish(
        list_updated: list_updated,
        expired: expired,
        alert_matched: alert_matched,
        matched: matched,
        unmatched: unmatched,
        skipped: skipped,
        errors: errors,
        detail_budget_remaining: @detail_requests_remaining
      )
      AdminDashboardStats.record_job_finish!(
        :flood_sync,
        state: postal_code,
        list_updated: list_updated,
        expired: expired,
        matched: matched,
        unmatched: unmatched
      )
      true
    end
  end

  private

  def scope_label
    "state=#{postal_code}"
  end

  def postal_code
    @postal_code ||= state && Usgs::StateCodes.normalize_postal(state)
  end

  def sync_scope
    MonitoringLocation.active.in_state(postal_code)
  end

  def detail_request_budget
    AppConfig.integer(:nwps_detail_request_budget)
  end

  def consume_detail_request!
    return false if @detail_requests_remaining <= 0

    @detail_requests_remaining -= 1
    true
  end

  def monotonic_now
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end

  def elapsed_s(started_at)
    format("%.1f", monotonic_now - started_at)
  end

  # One padded state bbox list GET per state. FloodStageSyncJob paces states
  # ≥30s apart so a full national pass is 53 list calls, not repeated multi-state
  # region downloads.
  def fetch_gauges_by_lid
    @list_fetch_failed = false
    progress&.step("nwps list state=#{postal_code}")
    # Keep the padded bbox payload (neighbor-state LIDs included) so a WA
    # station crosswalked to an OR-classified point still gets hourly status.
    # Alert matching filters to this state's abbreviation so we do not spend
    # the detail budget on neighbor gauges we cannot join.
    by_lid = index_gauges_by_lid(client.gauges(state: postal_code))
    progress&.step("nwps list state=#{postal_code} gauges=#{by_lid.size}")
    by_lid
  rescue Nwps::Client::Error => e
    @list_fetch_failed = true
    progress&.step("list fetch skipped state=#{postal_code}: #{e.message}")
    {}
  end

  def index_gauges_by_lid(gauges)
    Array(gauges).each_with_object({}) do |gauge, memo|
      lid = gauge["lid"].to_s.upcase.presence
      next unless lid

      memo[lid] = gauge
    end
  end

  def gauges_in_state(by_lid)
    by_lid.select { |_lid, gauge| gauge_in_state?(gauge) }
  end

  def gauge_in_state?(gauge)
    gauge.dig("state", "abbreviation").to_s.upcase == postal_code.to_s.upcase
  end

  # Phase 1: list calls update flood_category for every site we already
  # crosswalked by NWPS LID. List payloads include status but not usgsId /
  # stage thresholds.
  def refresh_categories_from_list(by_lid)
    return 0 if by_lid.empty?

    updated = 0
    unchanged = 0
    scoped = sync_scope.where.not(nwps_lid: [ nil, "" ])
    progress&.step("list refresh candidates=#{scoped.count}")
    scoped.find_each do |location|
      gauge = by_lid[location.nwps_lid.to_s.upcase]
      next unless gauge

      if apply_list_status!(location, gauge)
        updated += 1
      else
        unchanged += 1
      end
      progress&.increment
    end
    progress&.step("list refresh updated=#{updated} unchanged=#{unchanged}")
    updated
  end

  # After a successful non-empty list, drop action+ rows whose LID was not in
  # the payload and whose last current NWPS status is older than
  # STALE_ALERT_AFTER. Empty / failed lists must not wipe a state's alerts.
  def expire_stale_unseen_alerts!(by_lid)
    return 0 if @list_fetch_failed || by_lid.blank?

    expired = 0
    sync_scope.flood_alert.where.not(nwps_lid: [ nil, "" ]).find_each do |location|
      next if by_lid.key?(location.nwps_lid.to_s.upcase)
      next unless stale_alert?(location)

      clear_stale_alert!(location)
      expired += 1
      progress&.increment
    end
    progress&.step("stale unseen alerts expired=#{expired}")
    expired
  end

  def stale_alert?(location)
    return false unless location.flood_alert?
    return true if location.flood_category_observed_at.blank?

    location.flood_category_observed_at < STALE_ALERT_AFTER.ago
  end

  def clear_stale_alert!(location)
    old_category = location.flood_category
    observed_at = Time.current
    location.update!(flood_category: "no_flooding")
    AlertEventRecorder.flood_category_change!(
      location: location,
      from: old_category,
      to: "no_flooding",
      observed_at: observed_at
    )
    StationSnapshotCache.warm(location)
  end

  # Phase 1b: for NWPS points currently at action+ that we have not linked yet,
  # fetch detail by LID (includes usgsId + thresholds) and join to our catalog.
  # This prioritizes every actively flooding gauge, not only sites reached by
  # USGS site-number iteration order.
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
    progress&.step(
      "unlinked alert gauges=#{candidates.size} detail_budget=#{@detail_requests_remaining}"
    )

    matched = 0
    candidates.each_with_index do |summary, index|
      unless consume_detail_request!
        progress&.step(
          "alert match paused budget exhausted at #{index}/#{candidates.size} matched=#{matched}"
        )
        break
      end

      lid = summary["lid"].to_s
      progress&.step("alert match fetch lid=#{lid} (#{index + 1}/#{candidates.size})")
      begin
        detail = client.gauge(lid)
        if detail.blank?
          progress&.step("alert miss lid=#{lid} (#{index + 1}/#{candidates.size})")
          next
        end

        location = find_location_for_usgs_id(detail["usgsId"])
        unless location
          progress&.step(
            "alert unlinkable lid=#{lid} usgsId=#{detail["usgsId"]} " \
            "(#{index + 1}/#{candidates.size})"
          )
          next
        end

        apply_match!(location, detail)
        matched += 1
        progress&.increment
        progress&.step(
          "alert matched lid=#{lid} site=#{location.site_number} " \
          "(#{index + 1}/#{candidates.size})"
        )
      rescue Nwps::Client::Error => e
        progress&.step("error lid=#{lid} #{e.message}")
      end
    end
    matched
  end

  def find_location_for_usgs_id(usgs_id)
    raw = usgs_id.to_s.strip
    return if raw.blank?

    candidates = site_number_candidates(raw)
    # Point lookup — avoid loading the whole active catalog into memory on the
    # 512MB sync dyno (national index_by was a silent stall / GC thrash risk).
    sync_scope.find_by(site_number: candidates)
  end

  def site_number_candidates(raw)
    candidates = [ raw ]
    if raw.match?(/\A\d+\z/)
      candidates << raw.rjust(8, "0")
      candidates << raw.sub(/\A0+/, "")
    end
    candidates.map(&:presence).compact.uniq
  end

  # Phase 2: USGS site-number detail lookups for first-time matches and
  # periodic threshold refresh.
  #
  # Due filtering is in SQL so we don't load the whole active catalog every
  # hour, and a canceled run naturally resumes: finished rows get a fresh
  # nwps_synced_at and drop out of the due set. A hard request budget keeps
  # each state job finite under the NWPS 30s pause.
  def discover_and_refresh_details
    matched = 0
    unmatched = 0
    skipped = 0
    kept_after_miss = 0
    errors = 0

    due = detail_scope
    due_count = due.count
    budget = @detail_requests_remaining
    progress&.step("detail sync due=#{due_count} budget=#{budget}")

    if budget <= 0
      skipped = due_count
      progress&.step("detail sync skipped budget exhausted due=#{due_count}")
      return [ matched, unmatched, skipped, errors ]
    end

    # limit + each (not find_each): find_each ignores order/limit, and the
    # budget is small enough to load in one pass.
    due.limit(budget).each do |location|
      break unless consume_detail_request!

      progress&.step(
        "detail fetch site=#{location.site_number} " \
        "(#{matched + unmatched + errors + 1}/#{budget})"
      )
      begin
        gauge = client.gauge(detail_identifier(location))
        if gauge.present?
          apply_match!(location, gauge)
          matched += 1
        elsif location.nwps_matched?
          # 404 / blank detail must not tear down a working LID crosswalk.
          # Hourly list refresh and stale-unseen expiry already handle gauges
          # that left NWPS. Stamp synced_at so this row leaves the due set.
          keep_match_after_detail_miss!(location)
          kept_after_miss += 1
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

    skipped = [ due_count - matched - unmatched - errors - kept_after_miss, 0 ].max
    if skipped.positive?
      progress&.step("detail sync deferred=#{skipped} (budget); resumes next run")
    end

    [ matched, unmatched, skipped, errors ]
  end

  def detail_scope
    matched_cutoff = MATCHED_DETAIL_REFRESH_AFTER.ago
    unmatched_cutoff = UNMATCHED_RETRY_AFTER.ago
    sync_scope.where(
      "nwps_synced_at IS NULL OR " \
      "(nwps_matched = TRUE AND nwps_synced_at < ?) OR " \
      "(nwps_matched = FALSE AND nwps_synced_at < ?)",
      matched_cutoff,
      unmatched_cutoff
    ).order(Arel.sql("nwps_synced_at ASC NULLS FIRST, site_number ASC"))
  end

  def apply_list_status!(location, gauge)
    category, category_at = category_from_status(gauge["status"])
    attrs = { nwps_matched: true }
    if category.present?
      attrs[:flood_category] = category
      attrs[:flood_category_observed_at] = category_at || location.flood_category_observed_at
    elsif stale_alert?(location)
      # Sentinels only (obs_not_current / fcst_not_current). Keep a recent
      # category to avoid flicker; drop it once the last current status ages out.
      attrs[:flood_category] = "no_flooding"
    end

    # Avoid rewrite + snapshot warm when the list status did not change.
    return false if list_status_unchanged?(location, attrs)

    old_category = location.flood_category
    # List responses omit thresholds; keep existing stage columns.
    location.update!(attrs)
    if attrs.key?(:flood_category)
      AlertEventRecorder.flood_category_change!(
        location: location,
        from: old_category,
        to: attrs[:flood_category],
        observed_at: attrs[:flood_category_observed_at] || Time.current
      )
    end
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
    old_category = location.flood_category

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
    AlertEventRecorder.flood_category_change!(
      location: location,
      from: old_category,
      to: category,
      observed_at: category_at || Time.current
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

  # Prefer the LID we already crosswalked — alert matching stores it, and
  # USGS site-number lookup 404s when NWPS only indexes the NWS identifier
  # (or uses different zero-padding than our catalog).
  def detail_identifier(location)
    location.nwps_lid.presence || location.site_number
  end

  def keep_match_after_detail_miss!(location)
    location.update_columns(nwps_synced_at: Time.current, updated_at: Time.current)
  end

  def category_from_status(status)
    status ||= {}
    observed = status["observed"] || {}
    forecast = status["forecast"] || {}
    category = Nwps::FloodCategories.effective(observed["floodCategory"], forecast["floodCategory"])
    category_at = parse_time(observed["validTime"]) || parse_time(forecast["validTime"])
    [ category, category_at ]
  end

  def warm_caches(changed:)
    progress&.step("warming state listing cache state=#{postal_code}")
    StateListingCache.warm(postal_code)

    if changed
      progress&.step("warming national site stats + alerts caches")
      SiteStats.warm!
      AlertsListingCache.warm
      AdminDashboardStats.schedule_inventory_refresh!
    else
      progress&.step("skipping national cache warm (no flood changes)")
    end

    progress&.step("invalidating edge cache")
    EdgeCacheInvalidation.after_flood_sync!(state: state)
  end

  def parse_time(value)
    return if value.blank?

    Time.zone.parse(value.to_s)
  rescue ArgumentError
    nil
  end
end
