class FloodStageSyncJob < ApplicationJob
  queue_as :sync

  # Minimum wall-clock between state syncs inside one national run. If a state
  # already took longer, start the next immediately (no extra pause).
  MIN_STATE_SECONDS = 30

  # National run (state omitted): loop every USPS state/territory with the
  # in-process timer. Optional +state+ keeps bootstrap/rake single-state calls.
  #
  # Also accepts blank/omitted args so old Sidekiq retries of the former
  # national cron (`arguments: []`) run the loop instead of failing.
  def perform(state = nil)
    unless AppConfig.boolean?(:flood_stage_sync_enabled)
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
  end

  private

  def sync_all_states!
    states = states_to_sync
    progress = SyncProgress.new("FloodStageSyncJob", io: nil)
    progress.step("national states=#{states.size} min_state_seconds=#{MIN_STATE_SECONDS}")

    unless FloodStageSyncLock.claim!(ttl: 2.hours)
      progress.step("skip already running (lock held)")
      return
    end

    begin
      Telemetry.in_root_span(
        "job.flood_sync_national",
        attributes: {
          "app.operation" => "job.flood_sync_national",
          "app.batch_size" => states.size
        }
      ) do
        states.each_with_index do |code, index|
          started_at = monotonic_now
          progress.step("state=#{code} (#{index + 1}/#{states.size})")
          run_state_sync(code, progress)
          pad_to_min_cycle!(started_at, progress, label: code)
        end
        progress.finish("states=#{states.size}")
      end
    ensure
      FloodStageSyncLock.release!
    end
  end

  def sync_one_state!(postal)
    progress = SyncProgress.new("FloodStageSyncJob[#{postal}]", io: nil)

    unless FloodStageSyncLock.claim!
      progress.step("lock busy; skip state=#{postal}")
      return
    end

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
      FloodStageSyncLock.release!
    end
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
