class HistoryBackfillLock
  KEY_PREFIX = "history_backfill:"
  COOLDOWN_PREFIX = "history_backfill_cooldown:"
  TTL = 1.hour
  COOLDOWN_TTL = 6.hours

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
