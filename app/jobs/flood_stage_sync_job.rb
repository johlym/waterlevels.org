class FloodStageSyncJob < ApplicationJob
  queue_as :sync

  # Minimum wall-clock per state job. Combined with FloodStageSyncLock (one flood
  # job at a time) this keeps state starts ≥31s apart even when sync_worker has
  # multiple threads. Work that already exceeds 31s is not padded.
  MIN_CYCLE_SECONDS = 31
  # How long to wait before retrying when another flood job holds the lock.
  LOCK_BUSY_REQUEUE_SECONDS = 5

  # One USPS state (or territory) per call. National coverage is
  # FloodStageSyncBatchJob → one of these per state.
  #
  # +state+ is optional only so Sidekiq retries of the old national cron
  # (`arguments: []`) hand off cleanly instead of ArgumentError-looping.
  def perform(state = nil)
    if state.blank?
      Rails.logger.info(
        "FloodStageSyncJob called without state; handing off to FloodStageSyncBatchJob"
      )
      FloodStageSyncBatchJob.perform_later
      return
    end

    if DatabaseReadOnlyCircuit.open?
      raise DatabaseReadOnlyError, "database read-only circuit open"
    end

    postal = Usgs::StateCodes.normalize_postal(state)
    progress = SyncProgress.new("FloodStageSyncJob[#{postal}]", io: nil)

    unless FloodStageSyncLock.claim!
      progress.step(
        "lock busy; requeue in #{LOCK_BUSY_REQUEUE_SECONDS}s " \
        "(only one flood sync thread at a time)"
      )
      self.class.set(wait: LOCK_BUSY_REQUEUE_SECONDS.seconds).perform_later(postal)
      return
    end

    started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    begin
      Telemetry.in_span(
        "job.flood_sync",
        attributes: {
          "app.operation" => "job.flood_sync",
          "app.state" => postal
        }
      ) do
        FloodStageSync.new(state: postal, progress: progress).perform
      end
    ensure
      pad_to_min_cycle!(started_at, progress)
      FloodStageSyncLock.release!
    end
  end

  private

  def pad_to_min_cycle!(started_at, progress)
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at
    remaining = MIN_CYCLE_SECONDS - elapsed
    if remaining.positive?
      progress&.step(
        "pacing sleep=#{format("%.1f", remaining)}s " \
        "(elapsed=#{format("%.1f", elapsed)}s min_cycle=#{MIN_CYCLE_SECONDS}s)"
      )
      sleep_for_pacing(remaining)
    else
      progress&.step(
        "pacing skip elapsed=#{format("%.1f", elapsed)}s " \
        "(min_cycle=#{MIN_CYCLE_SECONDS}s)"
      )
    end
  end

  # Isolated for tests — do not stub Kernel#sleep globally.
  def sleep_for_pacing(seconds)
    sleep(seconds)
  end
end
