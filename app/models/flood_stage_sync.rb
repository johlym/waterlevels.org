class FloodStageSync
  include ActiveModel::Model

  # Re-check unmatched USGS sites periodically — most will keep 404ing.
  UNMATCHED_RETRY_AFTER = 7.days

  attr_accessor :client, :state, :progress

  def initialize(client: Nwps::Client.new, state: nil, progress: nil)
    @client = client
    @state = state.presence
    @progress = progress
  end

  def perform
    progress&.step(scope_label)
    matched = 0
    unmatched = 0
    skipped = 0
    errors = 0

    sync_scope.find_each do |location|
      unless due_for_sync?(location)
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

    progress&.step("warming caches")
    warm_caches
    progress&.finish("matched=#{matched} unmatched=#{unmatched} skipped=#{skipped} errors=#{errors}")
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
    scope = MonitoringLocation.where(active: true).order(:site_number)
    postal_code ? scope.in_state(postal_code) : scope
  end

  def due_for_sync?(location)
    return true if location.nwps_synced_at.blank?
    return true if location.nwps_matched?

    location.nwps_synced_at < UNMATCHED_RETRY_AFTER.ago
  end

  def apply_match!(location, gauge)
    categories = gauge.dig("flood", "categories") || {}
    observed = gauge.dig("status", "observed") || {}
    category = Nwps::FloodCategories.normalize(observed["floodCategory"])
    category_at = parse_time(observed["validTime"])

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
