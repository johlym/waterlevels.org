# Email alert tip freshness SLA

## Current sync cadence
- Latest tips: hourly (`LatestObservationSyncJob` at `:03`)
- NWPS flood categories: hourly (`FloodStageSyncJob` at `:30`)
- Digest scheduler: every 15 minutes (`AlertDigestSchedulerJob`)

## v1 decisions
1. **Hourly tip evaluation is the SLA for threshold / rate-of-rise / in-range.**
   Duration windows (e.g. “above N for 30 minutes”) are evaluated against
   `continuous_observations` when a tip refresh produces a `reading_change`
   event — not on a separate 15-minute poll of every watched station.
2. **Stale tips do not fire threshold alerts.** If `latest_observed_at` is older
   than `Alerts::ThresholdEvaluator::STALE_TIP_AFTER` (**6 hours**), the
   evaluator returns false. This is tighter than the map “Active” window
   (`MonitoringLocation::STALE_AFTER` = 1 week). Digests still list the station
   with a stale flag.
3. **Flood category emails follow NWPS list freshness.** Categories older than
   `FloodStageSync::STALE_ALERT_AFTER` (24h) are reset to `no_flooding` by sync;
   that transition emits an all-clear event like any other category change.
4. **No targeted faster tip sync for watched stations in v1.** Revisit only if
   open rates / support tickets show hourly lag is a product problem
   (`HISTORY` / tip budget permitting).
5. **Evaluation enqueue is filtered and batched.** `AlertEventRecorder` skips
   stations with no active watches and coalesces the rest into
   `AlertEvaluationBatchJob` (~90s debounce) instead of one Sidekiq job per tip
   refresh during national sync.

## Operator notes
- Enable product with `ALERTS_ENABLED=1`.
- Scale `notifications_worker` (Sidekiq `notifications` queue) in addition to
  existing web/sync/backfill processes:
  `heroku ps:scale notifications_worker=1 -a <app>`.
  Config: `config/sidekiq_notifications.yml` / Procfile process type
  `notifications_worker`. Digest and quiet-scan cron ticks enqueue here even
  when the product flag is off — without a listener the queue backs up.
- `/admin` health flags `notifications` depth with zero workers.
