class IvRepairLock
  KEY_PREFIX = "iv_repair:"
  COOLDOWN_PREFIX = "iv_repair_cooldown:"
  TTL = 1.hour
  # Shorter than history backfill cooldown — gap fills are cheap and should retry
  # within the same operational window if USGS was briefly unavailable.
  COOLDOWN_TTL = 1.hour

  def self.claim!(location_id, ttl: TTL)
    return false if cooling_down?(location_id)

    Rails.cache.write(
      "#{KEY_PREFIX}#{location_id}",
      true,
      expires_in: ttl,
      unless_exist: true
    )
  end

  def self.release!(location_id)
    Rails.cache.delete("#{KEY_PREFIX}#{location_id}")
  end

  def self.cooldown!(location_id, ttl: COOLDOWN_TTL)
    Rails.cache.write(
      "#{COOLDOWN_PREFIX}#{location_id}",
      true,
      expires_in: ttl
    )
  end

  def self.cooling_down?(location_id)
    Rails.cache.exist?("#{COOLDOWN_PREFIX}#{location_id}")
  end

  def self.locked?(location_id)
    Rails.cache.exist?("#{KEY_PREFIX}#{location_id}")
  end

  def self.clear!(location_id)
    release!(location_id)
    Rails.cache.delete("#{COOLDOWN_PREFIX}#{location_id}")
  end
end
