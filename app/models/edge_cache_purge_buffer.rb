# Accumulates Cache-Tag values across history ingestions so Cloudflare Instant
# Purge is called in coalesced batches instead of once per station.
class EdgeCachePurgeBuffer
  KEY = "edge_cache:pending_purge_tags"
  FLUSH_LOCK_KEY = "edge_cache:purge_flush_scheduled"
  FLUSH_DELAY = 20.seconds
  KEY_TTL = 1.hour

  class MemoryBackend
    def initialize
      @tags = Set.new
      @mutex = Mutex.new
      @flush_scheduled = false
    end

    def add(tags)
      list = normalize(tags)
      return if list.empty?

      @mutex.synchronize { list.each { |tag| @tags << tag } }
    end

    def drain
      @mutex.synchronize do
        @flush_scheduled = false
        @tags.to_a.tap { @tags.clear }
      end
    end

    def schedule_flush?(delay)
      @mutex.synchronize do
        return false if @flush_scheduled

        @flush_scheduled = true
        true
      end
    end

    def clear_flush_lock!
      @mutex.synchronize { @flush_scheduled = false }
    end

    private

    def normalize(tags)
      Array(tags).map(&:to_s).map(&:strip).reject(&:blank?)
    end
  end

  class RedisBackend
    def initialize(redis: nil)
      @redis = redis
    end

    def add(tags)
      list = normalize(tags)
      return if list.empty?

      redis.sadd(KEY, *list)
      redis.expire(KEY, KEY_TTL.to_i)
    end

    def drain
      tmp = "#{KEY}:drain:#{Process.pid}:#{SecureRandom.hex(4)}"
      begin
        redis.rename(KEY, tmp)
      rescue Redis::CommandError
        return []
      end

      tags = redis.smembers(tmp)
      redis.del(tmp)
      tags
    end

    def schedule_flush?(delay)
      !!redis.set(FLUSH_LOCK_KEY, "1", nx: true, ex: [ delay.to_i, 1 ].max)
    end

    def clear_flush_lock!
      redis.del(FLUSH_LOCK_KEY)
    end

    private

    def redis
      @redis ||= Redis.new(RedisConfig.options)
    end

    def normalize(tags)
      Array(tags).map(&:to_s).map(&:strip).reject(&:blank?)
    end
  end

  class << self
    attr_writer :backend

    def backend
      @backend ||= default_backend
    end

    def reset!
      @backend = nil
    end

    def add(tags)
      backend.add(tags)
    end

    def drain
      backend.drain
    end

    def schedule_flush!(delay: FLUSH_DELAY)
      return false unless backend.schedule_flush?(delay)

      EdgeCachePurgeJob.set(wait: delay).perform_later
      true
    end

    def clear_flush_lock!
      backend.clear_flush_lock!
    end

    private

    def default_backend
      return MemoryBackend.new if Rails.env.test?

      RedisBackend.new
    rescue Redis::BaseError, Errno::ECONNREFUSED => e
      Rails.logger.warn("[EdgeCachePurgeBuffer] Redis unavailable (#{e.class}: #{e.message}); using memory backend")
      MemoryBackend.new
    end
  end
end
