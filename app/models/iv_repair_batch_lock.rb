class IvRepairBatchLock
  KEY = "iv_repair_batch"
  TTL = 15.minutes

  def self.claim!(ttl: TTL)
    Rails.cache.write(KEY, true, expires_in: ttl, unless_exist: true)
  end

  def self.release!
    Rails.cache.delete(KEY)
  end

  def self.locked?
    Rails.cache.exist?(KEY)
  end
end
