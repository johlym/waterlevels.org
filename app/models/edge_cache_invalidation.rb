# Purges Cloudflare edge cache by Cache-Tag after Redis snapshots are rewarmed.
# Requires CLOUDFLARE_API_TOKEN + CLOUDFLARE_ZONE_ID; otherwise no-ops.
class EdgeCacheInvalidation
  include ActiveModel::Model

  attr_accessor :purger

  def initialize(purger: Cloudflare::CachePurge.new)
    @purger = purger
  end

  def self.after_latest_sync!(state: nil, purger: Cloudflare::CachePurge.new)
    new(purger: purger).after_latest_sync!(state: state)
  end

  def self.after_flood_sync!(state: nil, purger: Cloudflare::CachePurge.new)
    new(purger: purger).after_flood_sync!(state: state)
  end

  def self.after_catalog_sync!(state: nil, purger: Cloudflare::CachePurge.new)
    new(purger: purger).after_catalog_sync!(state: state)
  end

  def self.after_station_history!(location, purger: Cloudflare::CachePurge.new)
    new(purger: purger).after_station_history!(location)
  end

  def after_latest_sync!(state: nil)
    purge!(sync_tags(state: state, include_map_apis: true))
  end

  def after_flood_sync!(state: nil)
    # Flood categories change alerts + listings + gauge cards; map station payload too.
    purge!(sync_tags(state: state, include_map_apis: true))
  end

  def after_catalog_sync!(state: nil)
    purge!(sync_tags(state: state, include_map_apis: true) + %w[sitemap])
  end

  def after_station_history!(location)
    return :empty unless location

    tags = [ "gauge:#{location.site_number}", "gauges" ]
    tags << "state:#{location.state_code}" if location.state_code.present?
    tags << "states" if location.state_code.present?
    purge!(tags)
  end

  private

  def sync_tags(state:, include_map_apis:)
    tags = %w[home map alerts]
    tags.concat(%w[map-stations map-station-search map-station-nearest]) if include_map_apis

    code = state.present? ? Usgs::StateCodes.normalize_postal(state) : nil
    if code
      tags << "state:#{code}"
      tags << "states"
      tags.concat(MonitoringLocation.in_state(code).pluck(:site_number).map { |site| "gauge:#{site}" })
      tags << "gauges"
    else
      tags.concat(%w[gauges states])
    end
    tags
  end

  def purge!(tags)
    result = purger.purge_tags(tags)
    Rails.logger.info("[EdgeCacheInvalidation] purge_tags=#{Array(tags).size} result=#{result}")
    result
  rescue Cloudflare::CachePurge::Error => e
    Rails.logger.error("[EdgeCacheInvalidation] #{e.message}")
    Sentry.capture_exception(e) if defined?(Sentry)
    :failed
  end
end
