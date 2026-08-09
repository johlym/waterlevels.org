# R2-first daily history + 35-day IV tip

Cloudflare R2 (or local disk in development) is the **daily system of record**. Postgres keeps a short continuous IV tip for `24h` / `7d` / `30d` charts and a tiny daily scratch tip for ingest convenience. The browser still reads `/api/gauges/:id/observations` — Rails merges scratch tip + R2 and Cloudflare edge-caches the response.

Related: [`plan-3y-daily-history.md`](./plan-3y-daily-history.md) (historical 1y→3y Postgres expansion; superseded for retention), [`future.md`](./future.md) (hourly POR remains a separate track).

## Product grain

| Range | Source |
|-------|--------|
| `24h` / `7d` / `30d` | Continuous IV in Postgres (~15-minute) |
| `1y` / `3y` / future `Ny` | Daily means from **R2** (plus optional Postgres scratch tip) |

## Windows

| Layer | Retention |
|-------|-----------|
| Continuous IV (Postgres) | **35 days** (`HistoryIngestion::CONTINUOUS_RETENTION`) |
| Day-31 handoff frontier | Local calendar **day 31** (`DailyArchive::CONTINUOUS_ROLLUP_AFTER`) |
| Daily scratch tip (Postgres) | **≤7 days** (`DailyArchive::DAILY_SCRATCH_RETENTION`) — not history SoR |
| Daily history (R2) | All historical dailies used by `1y` / `3y` / `Ny` |

## Object layout

```text
daily/v1/{time_series_id}/{yyyy}.json.gz
```

Gzipped JSON array of `{ "d", "v", "s", "a?" }` where `s` is `usgs` or `derived`. Catalog rows live in `daily_archive_shards`.

## Day-31 handoff (USGS-first)

Invariant: **never prune IV for local day D until R2 has D (USGS or derived) or D is an explicit alerted gap.**

1. Tip/gap ingest dual-writes **all** USGS dailies into R2.
2. Nightly `ContinuousPruneJob` → `DailyArchive::Retention` ensures every local day with IV older than ~30 days is present in R2:
   - Prefer official USGS daily (Postgres tip or bounded USGS fetch).
   - Else derive a local-midnight mean from IV (coverage-gated) and store with `s: "derived"`.
   - Else leave IV in place and count as `retrying` while inside the 35-day window.
3. When a day reaches IV prune age still uncovered: **alert** (`gaps_alerted`, log + Sentry), then allow prune.
4. Scratch `daily_observations` older than the tip cutoff delete only when that day exists in R2 (`DAILY_ARCHIVE_PRUNE=1`).

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
DAILY_ARCHIVE_HOT_RETENTION_DAYS=7   # Postgres daily scratch tip
DAILY_ARCHIVE_READS=1
DAILY_ARCHIVE_DUAL_WRITE=1
DAILY_ARCHIVE_PRUNE=0
```

Workflow:

1. Copy `.env.example` → `.env` (remove empty `DATABASE_URL=` per AGENTS.md).
2. `bin/rails db:seed` (or use existing demo data).
3. `bin/rails archive:export_daily` — writes `tmp/daily_archive/daily/v1/...`.
4. Open a gauge and use the `1y` / `3y` chart tabs (reads merge disk + scratch tip).

Tests ignore `DAILY_ARCHIVE_STORE=local` from `.env` unless `DAILY_ARCHIVE_ALLOW_LOCAL_IN_TEST=1`.

### Production (Cloudflare R2)

```bash
DAILY_ARCHIVE_STORE=r2          # or leave unset
CLOUDFLARE_R2_URL=https://<ACCOUNT_ID>.r2.cloudflarestorage.com
CLOUDFLARE_R2_YEARLY_ARCHIVE_BUCKET=...
CLOUDFLARE_R2_ACCESS_KEY_ID=...
CLOUDFLARE_R2_SECRET_ACCESS_KEY=...
# Omit DAILY_ARCHIVE_HOT_RETENTION_DAYS → default 7-day scratch tip
DAILY_ARCHIVE_READS=1
DAILY_ARCHIVE_PRUNE=1
DAILY_ARCHIVE_DUAL_WRITE=1
```

Keep `CLOUDFLARE_ZONE_ID` / `CLOUDFLARE_API_TOKEN` for Cache-Tag purge only — separate from R2 keys.

## Jobs / rake

- `DailyArchiveExportJob` / `bin/rails archive:export_daily` — batch Postgres → R2 catch-up (safe to re-run).
- `ContinuousPruneJob` (daily 04:15) — USGS-first day-31+ ensure, estimated fallback, gap alerts, then prune IV older than 35d when covered/alerted; when `DAILY_ARCHIVE_PRUNE=1`, prune scratch dailies older than the tip only if archive shards cover those days.
- Historical USGS backfill continues alongside; readiness gates use R2 shard coverage (not Postgres daily row presence alone).

## Rollout order

1. Credentials in prod + dual-write all dailies; catch up with `archive:export_daily`.
2. `DAILY_ARCHIVE_READS=1` — `1y` / `3y` (and future `Ny`) read R2.
3. Day-31 ensure/retry/alert live; monitor `gaps_alerted` on `/admin` and Honeycomb.
4. `DAILY_ARCHIVE_PRUNE=1` — collapse Postgres daily to the scratch tip.
5. Confirm IV stays near 35d and gap alerts stay near zero.
