# Postgres hot + R2 cold daily archive

Keep a hot tip of daily means (and recent continuous IV) in PostgreSQL; store colder daily history in Cloudflare R2 year shards. The browser still reads `/api/gauges/:id/observations` — Rails merges Postgres + R2 and Cloudflare edge-caches the response.

Related: [`plan-3y-daily-history.md`](./plan-3y-daily-history.md), [`future.md`](./future.md) (hourly POR remains a separate track).

## Windows

| Layer | Retention |
|-------|-----------|
| Continuous IV (Postgres) | ~90 days delete buffer; chart max is `30d` |
| Rollup frontier | Local calendar **day 31** (`DailyArchive::CONTINUOUS_ROLLUP_AFTER`) |
| Daily hot tip (Postgres) | **14 months** (`DailyArchive::DAILY_HOT_RETENTION`) — covers `1y` charts + YoY |
| Daily cold (R2) | Everything else; grows past the old 3-year prune ceiling |

## Object layout

```text
daily/v1/{time_series_id}/{yyyy}.json.gz
```

Gzipped JSON array of `{ "d", "v", "s", "a?" }` where `s` is `usgs` or `derived`. Catalog rows live in `daily_archive_shards`.

## Provenance

1. Official USGS `daily` always wins over continuous-derived means.
2. Derived means use station-local midnight→midnight arithmetic mean (stat `00003`-like) via `DailyArchive::UsgsLikeDailyMean`.
3. Coverage gate (~80% of expected IV slots) — thin days are skipped, not invented.

## Env

```bash
CLOUDFLARE_R2_URL=
CLOUDFLARE_R2_YEARLY_ARCHIVE_BUCKET=
CLOUDFLARE_R2_ACCESS_KEY_ID=
CLOUDFLARE_R2_SECRET_ACCESS_KEY=
# Opt-in rollout flags (default off):
DAILY_ARCHIVE_READS=0          # hybrid 3y chart reads from R2
DAILY_ARCHIVE_PRUNE=0          # prune Postgres daily to hot tip when R2 covers
DAILY_ARCHIVE_DUAL_WRITE=1     # HistoryIngestion writes cold days to R2 (when configured)
```

Keep `CLOUDFLARE_ZONE_ID` / `CLOUDFLARE_API_TOKEN` for Cache-Tag purge only — separate from R2 keys.

## Jobs / rake

- `DailyArchiveExportJob` / `bin/rails archive:export_daily` — batch Postgres → R2 (safe to re-run).
- `ContinuousPruneJob` (daily 04:15) — rollup day-31 derived dailies, then prune IV; when `DAILY_ARCHIVE_PRUNE=1`, prune daily older than the hot tip only if archive shards cover those days.
- Historical USGS backfill **keeps running** alongside export; enable dual-write before tightening prune.

## Rollout order

1. Credentials in prod (done) + deploy code with flags off.
2. Run `archive:export_daily` until shard inventory catches up; verify samples.
3. `DAILY_ARCHIVE_READS=1` — hybrid `3y` charts.
4. Ensure dual-write on; then `DAILY_ARCHIVE_PRUNE=1`.
5. Monitor rollup deltas (`app.daily_rollup_delta`) and prune blocked-by-coverage counts.
