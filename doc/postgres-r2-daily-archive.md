# R2-first daily history + 35-day IV tip

Cloudflare R2 (or local disk in development) is the **daily system of record**. Postgres keeps continuous IV for `24h` / `7d` / `30d` charts (~35 days) plus peaks/latest — **not** daily history. The browser still reads `/api/gauges/:id/observations` — Rails reads R2 for daily ranges and caches the JSON payload in Redis (`ApiResponseCache`; HTTP responses are `private, no-store`).

Related: [`plan-3y-daily-history.md`](./plan-3y-daily-history.md) (historical 1y→3y Postgres expansion; superseded for retention), [`future.md`](./future.md) (hourly POR remains a separate track).

## Product grain

| Range | Source |
|-------|--------|
| `24h` / `7d` / `30d` | Continuous IV in Postgres (~15-minute) |
| `1y` / `3y` / future `Ny` | Daily means from **R2 only** |

## Windows

| Layer | Retention |
|-------|-----------|
| Continuous IV (Postgres) | **35 days** (`HistoryIngestion::CONTINUOUS_RETENTION`) |
| Day-31 handoff frontier | Local calendar **day 31** (`DailyArchive::CONTINUOUS_ROLLUP_AFTER`) |
| Daily history (R2) | All historical dailies used by `1y` / `3y` / `Ny` |
| `daily_observations` (Postgres) | **Legacy drain only** — new ingest does not write here when archive writes are on |

## Object layout

```text
daily/v1/{time_series_id}/{yyyy}.json.gz
```

Gzipped JSON array of `{ "d", "v", "s", "a?" }` where `s` is `usgs` or `derived`. Catalog rows live in `daily_archive_shards`.

## Write path

When `DAILY_ARCHIVE_DUAL_WRITE` is enabled (default once a store is configured):

1. USGS daily ingest writes **only to R2** (env name kept for compatibility; it is not a Postgres dual-write anymore).
2. On R2 write failure, ingest falls back to Postgres so data is not dropped, then drain later.
3. Without an archive store configured (typical unit tests), ingest still upserts Postgres — offline fallback.

Year-shard writes take a short Redis lock (`daily_archive_write:{time_series_id}:{year}`) so prune handoff, history ingest, and `archive:export_daily` cannot clobber each other's read-modify-write. Contended writers wait/backoff (~30s) before raising; nightly retention treats sustained lock busy as `retrying` for that day instead of aborting the whole prune.

## Day-31 handoff (USGS-first)

Invariant: **never prune IV for local day D until R2 has D (USGS or derived) or D is an explicit alerted gap.**

1. Tip/gap ingest writes USGS dailies into R2.
2. Nightly `ContinuousPruneJob` → `DailyArchive::Retention` ensures every local day with IV older than ~30 days is present in R2:
   - Prefer official USGS daily (leftover Postgres row during drain, or bounded USGS fetch).
   - Else derive a local-midnight mean from IV (coverage-gated) and store with `s: "derived"`.
   - Else leave IV in place and count as `retrying` while inside the 35-day window.
3. When a day reaches IV prune age still uncovered: **alert** (`gaps_alerted`, log + Sentry), then allow prune.
4. When `DAILY_ARCHIVE_PRUNE=1`, delete **any** leftover Postgres `daily_observations` row whose day already exists in R2 (full drain — no scratch tip).

UI copy for derived points: **Estimated** (chart footnote + history-table status). Not conflated with Provisional.

## Provenance

1. Official USGS `daily` always wins over continuous-derived means.
2. Derived means use station-local midnight→midnight arithmetic mean via `DailyArchive::UsgsLikeDailyMean`.
3. Coverage gate (~80% of expected IV slots) — thin days are skipped, not invented.

## Env

### Local development (`.env.example` defaults)

No Cloudflare account required — year shards land on disk:

```bash
DAILY_ARCHIVE_STORE=local
DAILY_ARCHIVE_LOCAL_PATH=tmp/daily_archive
DAILY_ARCHIVE_READS=1
DAILY_ARCHIVE_DUAL_WRITE=1
DAILY_ARCHIVE_PRUNE=0
```

Workflow:

1. Copy `.env.example` → `.env` (remove empty `DATABASE_URL=` per AGENTS.md).
2. `bin/rails db:seed` (or use existing demo data).
3. `bin/rails archive:export_daily` — migrates any leftover Postgres dailies into `tmp/daily_archive/daily/v1/...`.
4. Open a gauge and use the `1y` / `3y` chart tabs (R2/disk reads).

Tests ignore `DAILY_ARCHIVE_STORE=local` from `.env` unless `DAILY_ARCHIVE_ALLOW_LOCAL_IN_TEST=1`.

### Production (Cloudflare R2)

```bash
DAILY_ARCHIVE_STORE=r2          # or leave unset
CLOUDFLARE_R2_URL=https://<ACCOUNT_ID>.r2.cloudflarestorage.com
CLOUDFLARE_R2_YEARLY_ARCHIVE_BUCKET=...
CLOUDFLARE_R2_ACCESS_KEY_ID=...
CLOUDFLARE_R2_SECRET_ACCESS_KEY=...
DAILY_ARCHIVE_READS=1
DAILY_ARCHIVE_PRUNE=1
DAILY_ARCHIVE_DUAL_WRITE=1
```

Keep `CLOUDFLARE_ZONE_ID` / `CLOUDFLARE_API_TOKEN` for Cache-Tag purge only — separate from R2 keys.

## Jobs / rake

- `DailyArchiveExportJob` / `bin/rails archive:export_daily` — one-time / catch-up Postgres → R2 for leftover rows (safe to re-run).
- `ContinuousPruneJob` (daily 04:15) — USGS-first day-31+ ensure, estimated fallback, gap alerts, IV prune, and Postgres daily drain when `DAILY_ARCHIVE_PRUNE=1`.
- Readiness / freshness gates use R2 shard catalog (`min_on` / `max_on`), not Postgres daily row presence.

## Rollout order

1. Credentials in prod + archive writes on; catch up with `archive:export_daily`.
2. `DAILY_ARCHIVE_READS=1` — `1y` / `3y` (and future `Ny`) read R2 only.
3. Day-31 ensure/retry/alert live; monitor `gaps_alerted` on `/admin` and Honeycomb.
4. `DAILY_ARCHIVE_PRUNE=1` — drain leftover Postgres `daily_observations`.
5. Confirm IV stays near 35d, Postgres daily count → 0, gap alerts stay near zero.
