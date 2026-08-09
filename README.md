# WaterLevels.org

Rails 8.1 / Ruby 4 app that maps USGS water monitoring locations (water level, flow, temperature) with cached station and state pages.

## Stack

- PostgreSQL, Redis, Sidekiq (+ sidekiq-scheduler)
- Tailwind CSS v4, esbuild, Stimulus, Leaflet, Chart.js
- ViewComponent (sidecar)

## Local setup

```bash
rvm use 4.0.4
nvm use          # Node 20+ required (see .nvmrc / .node-version)
bundle install
yarn install
createdb waterlevels_development waterlevels_test
bin/rails db:migrate
cp .env.example .env   # add USGS_API_KEY
bin/dev
```

Bootstrap USGS data (rate-limit aware; prints progress). Catalog sync keeps **active continuous water-body sites only** (streams/lakes/estuaries with current `latest-continuous` data — not the full USGS well archive).

### Production (preferred)

With the Sidekiq worker running, enqueue staggered per-state catalog+latest jobs:

```bash
bin/rails usgs:enqueue_bootstrap
# optional: STATE=wa DELAY_SECONDS=120
```

Hourly `LatestObservationSyncJob` keeps readings fresh. Hourly `FloodStageSyncJob` refreshes NWS NWPS flood categories from the national gauge list (by LID), prioritizes linking any currently flooding unlinked gauges, and discovers stage thresholds via USGS site-number detail lookups (`STATE=wa bin/rails nwps:sync_flood_stages`, or `bin/rails nwps:enqueue_sync` for staggered per-state jobs). Bootstrap also runs flood sync per state. Hourly `HistoryBackfillBatchJob` fills gap-aware continuous history (up to ~35 days) and year daily history into R2 in batches (gauge page views also enqueue a station when charts are empty). Prefer this over a national one-off `usgs:bootstrap` on a small dyno.

### Local / single-state

```bash
STATE=wa bin/rails usgs:purge ALL=1   # wipe a bad/partial import
STATE=wa bin/rails usgs:bootstrap
```

Optional history backfill after bootstrap:

```bash
STATE=wa RANGE=1y LIMIT=25 bin/rails usgs:backfill
# optional deep daily fill after year history exists:
STATE=wa RANGE=3y LIMIT=25 bin/rails usgs:backfill
```

Tunables: `USGS_REQUEST_PAUSE_MS` (default `100` outside test), `USGS_HOURLY_SOFT_CAP` (default `980` — park a key for the rest of the UTC hour before a hard 429), `HISTORY_BACKFILL_BATCH` (default `50` **per available history key**, further capped by remaining hourly request budget), `HISTORY_DEEP_BACKFILL_BATCH` (default `400`/key ceiling; actual deep slots use leftover request budget after phase-1; set `0` to pause 3y deep fills). History backfill batch runs Mon–Sat every 10 minutes and no-ops when keys are exhausted or the backfill queue is still draining. Live used/remaining per key is on `/admin`.

See `doc/postgres-r2-daily-archive.md` (current R2-first retention), `doc/plan-3y-daily-history.md` (historical 3y plan), and `doc/future.md` (hourly POR) for retention tiers and longer-history notes.

Local archive iteration (no Cloudflare): `.env.example` sets `DAILY_ARCHIVE_STORE=local`. After seeding or backfill, run `bin/rails archive:export_daily` — shards land in `tmp/daily_archive` and `1y` / `3y` charts read them when `DAILY_ARCHIVE_READS=1`.

## Observability (Honeycomb)

OpenTelemetry traces export to Honeycomb when `OTEL_EXPORTER_OTLP_*` is set (see `.env.example`). ActiveRecord, PG, Redis, and Net::HTTP auto-spans are disabled to stay within event budgets; domain spans via `Telemetry` remain. Query recipes: [`doc/honeycomb-queries.md`](doc/honeycomb-queries.md).

## Tests

```bash
bin/rails test
```

## Heroku

- Dynos: `web`, `worker`
- Add-ons: Postgres, Redis
- Set `USGS_API_KEY` (tip/catalog), optional `USGS_API_HISTORY_1_KEY` / `USGS_API_HISTORY_2_KEY` (history backfill), `REDIS_URL`, `DATABASE_URL`, `APP_HOST`, `SENTRY_DSN`; optional `CLOUDFLARE_ZONE_ID` + `CLOUDFLARE_API_TOKEN` for post-sync Cache-Tag purge; optional `CLOUDFLARE_R2_*` for the yearly daily-means archive ([`doc/postgres-r2-daily-archive.md`](doc/postgres-r2-daily-archive.md))
- Enable [runtime dyno metadata](https://devcenter.heroku.com/articles/dyno-metadata) so `HEROKU_RELEASE_VERSION` is available; Sentry uses it as the release and tags environment as `production`
- Open Graph PNGs are rendered with `rsvg-convert` (`Aptfile` → `librsvg2-bin`). Requires [`heroku-community/apt`](https://elements.heroku.com/buildpacks/heroku/heroku-buildpack-apt) as buildpack **#1** (before Ruby) so the Aptfile packages install on the dyno.
- Redis TLS: Sidekiq, cache, and Action Cable use `ssl_params.verify_mode = VERIFY_NONE` for Heroku self-signed `rediss://` certs
- After deploy: `heroku run bin/rails usgs:enqueue_bootstrap -a <app>`
- Optional: `MALLOC_ARENA_MAX=2` if worker RSS climbs
- Put Cloudflare in front; honor `Cache-Control` / `Cache-Tag` from the app. Use a Cache Rule (Eligible for cache + Origin Cache Control) for public HTML/JSON; bypass `/contact` and `/admin`. Public pages skip the Rails session cookie so HTML is not forced to `BYPASS`.
- Optional ops dashboard at `/admin` when `DASHBOARD_PW` is set (session login at `/admin/login`). Returns 404 when the env var is unset. Login attempts are rate-limited (Rails `rate_limit`, 10 per 3 minutes per IP). Sidekiq Web is at `/admin/sidekiq` behind the same session.
- **Cold first request:** Eco/Hobby web dynos sleep when idle; the next hit waits for Puma/Rails boot (often multi-second). Prefer an always-on web dyno, or ping `/up` every few minutes. Puma also warms DB/Redis/`SiteStats` on boot so a post-sleep origin render is cheaper once the process is up.

## Contact form

`GET /contact` is served by `PagesController` (not edge-cached). `POST /contact` uses `ContactMessage` + `invisible_captcha` + Cloudflare Turnstile, then `ContactMailer`.

Set in `.env`:

- `TURNSTILE_SITE_KEY` (defaults to the existing widget) / `TURNSTILE_SECRET`
- `CONTACT_TO_EMAIL` / `MAIL_FROM`
- `BENTO_SITE_UUID`, `BENTO_PUBLISHABLE_KEY`, `BENTO_SECRET_KEY` (Action Mailer via `bento-actionmailer` + `premailer-rails`)

## Notes

- Map may be empty until catalog sync lands locations.
- Temperature is stored in °C; UI defaults to °F via a preference cookie.
- Local PostGIS is optional; nearby stations use haversine precompute, map bbox uses lat/lon indexes.
