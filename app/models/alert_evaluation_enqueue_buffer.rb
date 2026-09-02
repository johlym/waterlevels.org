# frozen_string_literal: true

# Coalesces AlertEvaluation work during tip/flood sync bursts so one batch job
# replaces thousands of per-station AlertEvaluationJob enqueues.
class AlertEvaluationEnqueueBuffer
  KEY = "alerts:pending_evaluation_locations"
  FLUSH_LOCK_KEY = "alerts:evaluation_flush_scheduled"
  FLUSH_DELAY = 90.seconds
  KEY_TTL = 2.hours

  class MemoryBackend
    def initialize
      @location_ids = Set.new
      @mutex = Mutex.new
      @flush_scheduled = false
    end

    def add(location_id)
      id = normalize(location_id)
      return if id.nil?

      @mutex.synchronize { @location_ids << id }
    end

    def drain
      @mutex.synchronize do
        @flush_scheduled = false
        @location_ids.to_a.tap { @location_ids.clear }
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

    def normalize(location_id)
      location_id.to_i.positive? ? location_id.to_i : nil
    end
  end

  class RedisBackend
    def initialize(redis: nil)
      @redis = redis
    end

    def add(location_id)
      id = normalize(location_id)
      return if id.nil?

      redis.sadd(KEY, id)
      redis.expire(KEY, KEY_TTL.to_i)
    end

    def drain
      tmp = "#{KEY}:drain:#{Process.pid}:#{SecureRandom.hex(4)}"
      begin
        redis.rename(KEY, tmp)
      rescue Redis::CommandError
        return []
      end

      ids = redis.smembers(tmp).map(&:to_i).select(&:positive?)
      redis.del(tmp)
      ids
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

    def normalize(location_id)
      location_id.to_i.positive? ? location_id.to_i : nil
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

    def add(location_id)
      backend.add(location_id)
    end

    def drain
      backend.drain
    end

    def schedule_flush!(delay: FLUSH_DELAY)
      return false unless backend.schedule_flush?(delay)

      AlertEvaluationBatchJob.set(wait: delay).perform_later
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
      Rails.logger.warn(
        "[AlertEvaluationEnqueueBuffer] Redis unavailable (#{e.class}: #{e.message}); using memory backend"
      )
      MemoryBackend.new
    end
  end
end
