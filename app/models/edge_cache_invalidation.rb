# Purges Cloudflare edge cache by Cache-Tag after Redis snapshots are rewarmed,
# and bumps ApiResponseCache generations for first-party `/api/*` JSON.
# Requires CLOUDFLARE_API_TOKEN + CLOUDFLARE_ZONE_ID for edge purge; otherwise
# edge purge no-ops (Redis API invalidation still runs).
#
# History ingestions coalesce tags via EdgeCachePurgeBuffer so a backfill does
# not fire one Instant Purge per station (Cloudflare rate limits are tight on
# Free/Pro). Latest/flood/catalog syncs still purge immediately.
class EdgeCacheInvalidation
  include ActiveModel::Model

  HISTORY_SHARED_TAGS = %w[
    map
    gauges
  ].freeze

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

  def self.flush_pending!(purger: Cloudflare::CachePurge.new)
    new(purger: purger).flush_pending!
  end

  # Buffer history purge tags in-process and flush once at the end. Used by
  # synchronous bulk rake tasks (usgs:backfill).
  def self.coalesce(purger: Cloudflare::CachePurge.new)
    previous = Thread.current[:edge_cache_coalesce]
    Thread.current[:edge_cache_coalesce] = []
    yield
    tags = Array(Thread.current[:edge_cache_coalesce]).uniq
    new(purger: purger).purge!(tags) if tags.present?
  ensure
    Thread.current[:edge_cache_coalesce] = previous
  end

  def after_latest_sync!(state: nil)
    ApiResponseCache.invalidate_after_sync!
    purge!(sync_tags(state: state))
  end

  def after_flood_sync!(state: nil)
    # Flood categories change alerts + listings + gauge cards; map station payload too.
    ApiResponseCache.invalidate_after_sync!
    purge!(sync_tags(state: state))
  end

  def after_catalog_sync!(state: nil)
    ApiResponseCache.invalidate_after_sync!
    purge!(sync_tags(state: state) + %w[sitemap])
  end

  def after_station_history!(location)
    return :empty unless location

    ApiResponseCache.invalidate_observations!(location.site_number)

    tags = history_tags_for(location)
    if (buffer = Thread.current[:edge_cache_coalesce])
      buffer.concat(tags)
      return :coalesced
    end

    EdgeCachePurgeBuffer.add(tags)
    EdgeCachePurgeBuffer.schedule_flush!
    :queued
  end

  def flush_pending!
    tags = EdgeCachePurgeBuffer.drain
    purge!(tags)
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

  private

  def history_tags_for(location)
    # Shared tags are deduped in the buffer / coalesce list so N stations become
    # one purge of those aggregates plus up to N gauge:/state: tags.
    tags = HISTORY_SHARED_TAGS.dup
    tags << "gauge:#{location.site_number}"
    if location.state_code.present?
      tags << "state:#{location.state_code}"
      tags << "states"
    end
    tags
  end

  def sync_tags(state:)
    tags = %w[home map alerts]

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
end
