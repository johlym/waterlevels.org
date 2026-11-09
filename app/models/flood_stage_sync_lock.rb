# One FloodStageSyncJob at a time, including copies still waiting in the sync
# queue.
#
# The slot lives in Sidekiq's Redis (REDIS_URL), not Rails.cache. The cache
# database is optional (REDIS_CACHE_URL) and is the store the job fills with
# station snapshots. A lock written once with a TTL is eligible for
# volatile-lru eviction there; after it disappears the next hourly run claims
# the slot and both jobs stay busy. This key has no TTL. A live run rewrites
# its heartbeat every state. A dead run can be taken over after STALE_AFTER.
class FloodStageSyncLock
  KEY = "flood_stage_sync:running"
  # Bootstrap and maintenance claim without a job id.
  DEFAULT_OWNER = "flood-stage-sync"
  # A worker that dies stops heartbeating. Same safety window as the old TTL.
  STALE_AFTER = 2.hours

  CLAIM_LUA = <<~LUA.freeze
    local current = redis.call("get", KEYS[1])
    if not current then
      redis.call("set", KEYS[1], ARGV[1])
      return 1
    end
    local sep = string.find(current, "|", 1, true)
    local beat = sep and tonumber(string.sub(current, sep + 1))
    if beat and beat < tonumber(ARGV[3]) then
      redis.call("set", KEYS[1], ARGV[1])
      return 1
    end
    return 0
  LUA

  RENEW_LUA = <<~LUA.freeze
    local current = redis.call("get", KEYS[1])
    if not current then
      redis.call("set", KEYS[1], ARGV[1])
      return 1
    end
    local sep = string.find(current, "|", 1, true)
    if not sep then
      return 0
    end
    local current_owner = string.sub(current, 1, sep - 1)
    local beat = tonumber(string.sub(current, sep + 1))
    if current_owner == ARGV[2] or (beat and beat < tonumber(ARGV[3])) then
      redis.call("set", KEYS[1], ARGV[1])
      return 1
    end
    return 0
  LUA

  RELEASE_LUA = <<~LUA.freeze
    local current = redis.call("get", KEYS[1])
    if not current then
      return 0
    end
    local sep = string.find(current, "|", 1, true)
    local current_owner = sep and string.sub(current, 1, sep - 1) or current
    if current_owner == ARGV[1] then
      return redis.call("del", KEYS[1])
    end
    return 0
  LUA

  def self.claim!(owner: DEFAULT_OWNER, ttl: nil)
    # ttl is accepted so older callers keep working; the key itself does not expire.
    _ = ttl
    write_heartbeat!(CLAIM_LUA, owner)
  end

  def self.renew!(owner, ttl: nil)
    _ = ttl
    write_heartbeat!(RENEW_LUA, owner)
  end

  def self.owned_by?(owner)
    current_owner == owner.to_s
  end

  # +owner+ nil force-clears the slot (admin maintenance, bootstrap ensure).
  # A job passes its id so a finishing run cannot delete a newer owner's slot.
  def self.release!(owner: nil)
    with_redis do |redis|
      if owner.nil?
        redis.del(KEY)
        true
      else
        redis.eval(RELEASE_LUA, keys: [ KEY ], argv: [ owner.to_s ]) == 1
      end
    end
  end

  def self.locked?
    with_redis { |redis| redis.exists?(KEY) }
  end

  def self.write_heartbeat!(script, owner)
    owner = owner.to_s
    value = "#{owner}|#{Time.now.to_i}"
    stale_before = STALE_AFTER.ago.to_i
    with_redis do |redis|
      redis.eval(script, keys: [ KEY ], argv: [ value, owner, stale_before ]) == 1
    end
  end
  private_class_method :write_heartbeat!

  def self.current_owner
    raw = with_redis { |redis| redis.get(KEY) }
    return if raw.blank?

    owner, _beat = raw.split("|", 2)
    owner
  end
  private_class_method :current_owner

  def self.with_redis
    redis = Redis.new(**RedisConfig.options)
    yield redis
  rescue Redis::BaseError, IOError, SystemCallError => e
    Rails.logger.warn("FloodStageSyncLock redis #{e.class}: #{e.message}")
    false
  ensure
    redis&.close
  end
  private_class_method :with_redis
end
