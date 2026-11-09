class FloodStageSyncJob < ApplicationJob
  queue_as :sync

  # Minimum wall-clock between state syncs inside one national run. If a state
  # already took longer, start the next immediately (no extra pause).
  MIN_STATE_SECONDS = 30

  # Reserve the single slot before the job is pushed. The hourly cron otherwise
  # enqueues another copy while a long run is still in the sync queue, and the
  # second thread picks it up. A retry of this same job id already owns the slot.
  before_enqueue do |job|
    owner = job.job_id
    next if FloodStageSyncLock.owned_by?(owner)

    if FloodStageSyncLock.claim!(owner: owner)
      job.instance_variable_set(:@flood_slot_claimed, true)
    else
      Rails.logger.info("FloodStageSyncJob enqueue skipped: another instance is queued or running")
      throw :abort
    end
  end

  around_enqueue do |job, block|
    block.call
  ensure
    if job.instance_variable_get(:@flood_slot_claimed) && !job.successfully_enqueued?
      FloodStageSyncLock.release!(owner: job.job_id)
    end
  end

  # National run (state omitted): loop every USPS state/territory with the
  # in-process timer. Optional +state+ keeps bootstrap/rake single-state calls.
  #
  # Also accepts blank/omitted args so old Sidekiq retries of the former
  # national cron (`arguments: []`) run the loop instead of failing.
  def perform(state = nil)
    unless hold_lock!
      Rails.logger.info("FloodStageSyncJob skipped: another instance is queued or running")
      return
    end

    unless AppConfig.boolean?(:flood_stage_sync_enabled)
      FloodStageSyncLock.release!(owner: job_id)
      Rails.logger.info("FloodStageSyncJob skipped: disabled by admin settings")
      return
    end
    if DatabaseReadOnlyCircuit.open?
      raise DatabaseReadOnlyError, "database read-only circuit open"
    end

    postal = state.present? ? Usgs::StateCodes.normalize_postal(state) : nil
    if postal
      sync_one_state!(postal)
    else
      sync_all_states!
    end
    FloodStageSyncLock.release!(owner: job_id)
  end

  private

  def sync_all_states!
    states = states_to_sync
    progress = SyncProgress.new("FloodStageSyncJob", io: nil)
    progress.step("national states=#{states.size} min_state_seconds=#{MIN_STATE_SECONDS}")

    Telemetry.in_root_span(
      "job.flood_sync_national",
      attributes: {
        "app.operation" => "job.flood_sync_national",
        "app.batch_size" => states.size
      }
    ) do
      states.each_with_index do |code, index|
        unless FloodStageSyncLock.renew!(job_id)
          progress.step("stop state=#{code} lock lost")
          break
        end

        started_at = monotonic_now
        progress.step("state=#{code} (#{index + 1}/#{states.size})")
        run_state_sync(code, progress)
        pad_to_min_cycle!(started_at, progress, label: code)
      end
      progress.finish("states=#{states.size}")
    end
  end

  def sync_one_state!(postal)
    progress = SyncProgress.new("FloodStageSyncJob[#{postal}]", io: nil)
    started_at = monotonic_now
    begin
      Telemetry.in_span(
        "job.flood_sync",
        attributes: {
          "app.operation" => "job.flood_sync",
          "app.state" => postal
        }
      ) do
        run_state_sync(postal, progress)
      end
    ensure
      pad_to_min_cycle!(started_at, progress, label: postal)
    end
  end

  # Enqueue already claimed the slot for this job id. perform_now and a
  # Sidekiq retry claim here. A different owner means another instance holds it.
  def hold_lock!
    FloodStageSyncLock.renew!(job_id) || FloodStageSyncLock.claim!(owner: job_id)
  end

  def states_to_sync
    Usgs::StateCodes::STATES.keys.sort
  end

  def run_state_sync(postal, progress)
    FloodStageSync.new(state: postal, progress: progress).perform
  end

  def pad_to_min_cycle!(started_at, progress, label:)
    elapsed = monotonic_now - started_at
    remaining = MIN_STATE_SECONDS - elapsed
    if remaining.positive?
      progress&.step(
        "state=#{label} pacing sleep=#{format("%.1f", remaining)}s " \
        "(elapsed=#{format("%.1f", elapsed)}s min=#{MIN_STATE_SECONDS}s)"
      )
      sleep_for_pacing(remaining)
    else
      progress&.step(
        "state=#{label} pacing skip elapsed=#{format("%.1f", elapsed)}s " \
        "(min=#{MIN_STATE_SECONDS}s)"
      )
    end
  end

  def monotonic_now
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end

  # Isolated for tests — do not stub Kernel#sleep globally.
  def sleep_for_pacing(seconds)
    sleep(seconds)
  end
end
