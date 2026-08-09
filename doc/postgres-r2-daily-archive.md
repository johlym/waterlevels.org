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

### Local development (`.env.example` defaults)

No Cloudflare account required — year shards land on disk:

```bash
DAILY_ARCHIVE_STORE=local
DAILY_ARCHIVE_LOCAL_PATH=tmp/daily_archive
DAILY_ARCHIVE_HOT_RETENTION_DAYS=7   # short tip so 30-day demo seed has "cold" days
DAILY_ARCHIVE_READS=1
DAILY_ARCHIVE_DUAL_WRITE=1
DAILY_ARCHIVE_PRUNE=0
```

Workflow:

1. Copy `.env.example` → `.env` (remove empty `DATABASE_URL=` per AGENTS.md).
2. `bin/rails db:seed` (or use existing demo data).
3. `bin/rails archive:export_daily` — writes `tmp/daily_archive/daily/v1/...`.
4. Open a gauge and use the `3y` chart tab (hybrid read merges disk + Postgres).

Tests ignore `DAILY_ARCHIVE_STORE=local` from `.env` unless `DAILY_ARCHIVE_ALLOW_LOCAL_IN_TEST=1` (same spirit as leaving `REDIS_URL` out of test runs).

### Production (Cloudflare R2)

```bash
DAILY_ARCHIVE_STORE=r2          # or leave unset
CLOUDFLARE_R2_URL=https://<ACCOUNT_ID>.r2.cloudflarestorage.com
CLOUDFLARE_R2_YEARLY_ARCHIVE_BUCKET=...
CLOUDFLARE_R2_ACCESS_KEY_ID=...
CLOUDFLARE_R2_SECRET_ACCESS_KEY=...
# Omit DAILY_ARCHIVE_HOT_RETENTION_DAYS → default 14-month hot tip
DAILY_ARCHIVE_READS=1
DAILY_ARCHIVE_PRUNE=1
DAILY_ARCHIVE_DUAL_WRITE=1
```

Keep `CLOUDFLARE_ZONE_ID` / `CLOUDFLARE_API_TOKEN` for Cache-Tag purge only — separate from R2 keys.

## Jobs / rake

- `DailyArchiveExportJob` / `bin/rails archive:export_daily` — batch Postgres → R2 (safe to re-run).
- `ContinuousPruneJob` (daily 04:15) — rollup day-31 derived dailies, then prune IV; when `DAILY_ARCHIVE_PRUNE=1`, prune daily older than the hot tip only if archive shards cover those days.
- Historical USGS backfill **keeps running** alongside export; enable dual-write before tightening prune.

## Admin / readiness after prune

Backfill eligibility and `/admin` 1y/3y backlog treat a series as having a daily anchor when **either** hot `daily_observations` **or** a `daily_archive_shards` row has `min_on` on/before that anchor. Otherwise pruned deep history would look “missing”, inflate “need 3y”, hide the gauge `3y` tab, and re-fetch USGS.

Measurement totals add `DailyArchive.cold_archive_point_count` (sum of `point_count` for shards with `max_on` before the hot cutoff) so fully cold years are not dropped from marketing/admin counts after prune. Boundary-year cold days in a straddling shard are omitted rather than double-counted with the hot tip.

Admin aggregates are set-based (one coverage pass, not nested ActiveRecord scopes), cached ~10 minutes with `race_condition_ttl`, and section frames load **sequentially** so a 3-thread web dyno is not stampeded. Section requests also set a Postgres `statement_timeout` (default 12s) and soft-fail inside the Turbo Frame instead of hanging until Heroku H12.

## Rollout order

1. Credentials in prod (done) + deploy code with flags off.
2. Run `archive:export_daily` until shard inventory catches up; verify samples.
3. `DAILY_ARCHIVE_READS=1` — hybrid `3y` charts.
4. Ensure dual-write on; then `DAILY_ARCHIVE_PRUNE=1`.
5. Monitor rollup deltas (`app.daily_rollup_delta`) and prune blocked-by-coverage counts.
