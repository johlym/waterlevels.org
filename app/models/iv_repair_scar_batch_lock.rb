class IvRepairScarBatchLock
  KEY = "iv_repair_scar_batch"
  TTL = 15.minutes

  def self.claim!
    Rails.cache.write(KEY, true, expires_in: TTL, unless_exist: true)
  end

  def self.release!
    Rails.cache.delete(KEY)
  end
end
