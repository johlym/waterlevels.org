# Drop a second enqueue while this job class already holds its singleton slot.
# The sync worker has two threads; a duplicate national run would take both.
module SingletonRunEnqueue
  def reserve_singleton_slot(lock)
    before_enqueue do |job|
      owner = job.job_id
      next if lock.owned_by?(owner)

      if lock.claim!(owner: owner)
        job.instance_variable_set(:@_singleton_slot_lock, lock)
      else
        Rails.logger.info("#{job.class.name} enqueue skipped: another instance is queued or running")
        throw :abort
      end
    end

    around_enqueue do |job, block|
      block.call
    ensure
      claimed = job.instance_variable_get(:@_singleton_slot_lock)
      claimed.release!(owner: job.job_id) if claimed && !job.successfully_enqueued?
    end
  end
end
