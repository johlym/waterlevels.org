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
   than `MonitoringLocation::STALE_AFTER`, `Alerts::ThresholdEvaluator` returns
   false. Digests still list the station with a stale flag.
3. **Flood category emails follow NWPS list freshness.** Categories older than
   `FloodStageSync::STALE_ALERT_AFTER` (24h) are reset to `no_flooding` by sync;
   that transition emits an all-clear event like any other category change.
4. **No targeted faster tip sync for watched stations in v1.** Revisit only if
   open rates / support tickets show hourly lag is a product problem
   (`HISTORY` / tip budget permitting).

## Operator notes
- Enable product with `ALERTS_ENABLED=1`.
- Run `notifications_worker` (Sidekiq `notifications` queue) in addition to
  existing web/sync/backfill processes.
