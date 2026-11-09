# One FloodStageSyncJob at a time, including copies still waiting in the sync
# queue. Claimed when the job is enqueued and held through perform (including
# inter-state pacing). A second enqueue loses the claim and is not queued, so
# it cannot take the sync worker's other thread.
class FloodStageSyncLock
  KEY = "flood_stage_sync:running"
  # Bootstrap and maintenance claim without a job id.
  DEFAULT_OWNER = "flood-stage-sync"
  # Safety TTL if a worker dies mid-job. perform renews this each state, so a
  # live run keeps the slot; a killed job frees it on its own.
  TTL = 2.hours

  def self.claim!(owner: DEFAULT_OWNER, ttl: TTL)
    Rails.cache.write(KEY, owner.to_s, expires_in: ttl, unless_exist: true) == true
  end

  def self.renew!(owner, ttl: TTL)
    owner = owner.to_s
    current = Rails.cache.read(KEY)
    if current.nil?
      claim!(owner: owner, ttl: ttl)
    elsif current.to_s == owner
      Rails.cache.write(KEY, owner, expires_in: ttl) == true
    else
      false
    end
  end

  def self.owned_by?(owner)
    Rails.cache.read(KEY).to_s == owner.to_s
  end

  # +owner+ nil force-clears the slot (admin maintenance, bootstrap ensure).
  # A job passes its id so a finishing run cannot delete a newer owner's slot.
  def self.release!(owner: nil)
    if owner.nil?
      Rails.cache.delete(KEY)
      return true
    end

    return false unless owned_by?(owner)

    Rails.cache.delete(KEY)
    true
  end

  def self.locked?
    Rails.cache.exist?(KEY)
  end
end
