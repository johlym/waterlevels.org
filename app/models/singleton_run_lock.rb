# One national/batch run at a time.
#
# The slot lives in Sidekiq's Redis (REDIS_URL), not Rails.cache. The cache
# database is optional (REDIS_CACHE_URL) and is filled with station snapshots
# during these jobs. A lock written once with a TTL is eligible for
# volatile-lru eviction there; after it disappears the next cron claims the
# slot and two copies stay busy. This key has no TTL. A live run rewrites its
# heartbeat. A dead run can be taken over after STALE_AFTER.
#
# Including classes set KEY, DEFAULT_OWNER, and STALE_AFTER.
module SingletonRunLock
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

  def default_owner
    self::DEFAULT_OWNER
  end

  def claim!(owner: default_owner, ttl: nil)
    # ttl is accepted so older callers keep working; the key itself does not expire.
    _ = ttl
    with_redis do |redis|
      redis.eval(CLAIM_LUA, keys: [ redis_key ], argv: heartbeat_argv(owner)) == 1
    end
  end

  def renew!(owner = default_owner, ttl: nil)
    _ = ttl
    with_redis do |redis|
      redis.eval(RENEW_LUA, keys: [ redis_key ], argv: heartbeat_argv(owner)) == 1
    end
  end

  def owned_by?(owner)
    current_owner == owner.to_s
  end

  # +owner+ nil force-clears the slot (admin maintenance).
  # A job passes its id so a finishing run cannot delete a newer owner's slot.
  def release!(owner: nil)
    with_redis do |redis|
      if owner.nil?
        redis.del(redis_key)
        true
      else
        redis.eval(RELEASE_LUA, keys: [ redis_key ], argv: [ owner.to_s ]) == 1
      end
    end
  end

  def locked?
    with_redis { |redis| redis.exists?(redis_key) }
  end

  private

  def redis_key
    self::KEY
  end

  def heartbeat_argv(owner)
    owner = owner.to_s
    [ "#{owner}|#{Time.now.to_i}", owner, self::STALE_AFTER.ago.to_i ]
  end

  def current_owner
    raw = with_redis { |redis| redis.get(redis_key) }
    return if raw.blank?

    owner, _beat = raw.split("|", 2)
    owner
  end

  def with_redis
    redis = Redis.new(**RedisConfig.options)
    yield redis
  rescue Redis::BaseError, IOError, SystemCallError => e
    Rails.logger.warn("#{name} redis #{e.class}: #{e.message}")
    false
  ensure
    redis&.close
  end
end
