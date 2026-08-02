class HistoryBackfillLock
  KEY_PREFIX = "history_backfill:"
  TTL = 1.hour

  def self.claim!(location_id, ttl: TTL)
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
end
