class FloodStageSyncJob < ApplicationJob
  queue_as :sync

  # Minimum wall-clock per state job. With sync concurrency=1, sequential state
  # jobs therefore start ≥31s apart. Work that already exceeds 31s is not padded.
  MIN_CYCLE_SECONDS = 31

  # One USPS state (or territory) per call. National coverage is
  # FloodStageSyncBatchJob → one of these per state.
  def perform(state)
    if state.blank?
      raise ArgumentError, "FloodStageSyncJob requires a state (use FloodStageSyncBatchJob for national)"
    end

    if DatabaseReadOnlyCircuit.open?
      raise DatabaseReadOnlyError, "database read-only circuit open"
    end

    started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    postal = Usgs::StateCodes.normalize_postal(state)
    progress = SyncProgress.new("FloodStageSyncJob[#{postal}]", io: nil)

    Telemetry.in_span(
      "job.flood_sync",
      attributes: {
        "app.operation" => "job.flood_sync",
        "app.state" => postal
      }
    ) do
      FloodStageSync.new(state: postal, progress: progress).perform
    ensure
      pad_to_min_cycle!(started_at, progress)
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
