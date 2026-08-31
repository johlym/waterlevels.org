# WaterLevels.org

Rails 8.1 / Ruby 4 app that maps USGS water monitoring locations (water level, flow, temperature) with cached station and state pages.

## Stack

- PostgreSQL, Redis, Sidekiq (+ sidekiq-scheduler)
- Tailwind CSS v4, esbuild, Stimulus, Leaflet + MapLibre GL (CARTO Dark Matter vector basemap), Chart.js
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

Hourly `LatestObservationSyncJob` keeps readings fresh near `:00`. `FloodStageSyncJob` runs at `:30` and loops every state in one job with ≥30s between states (one NWPS list GET per state bbox, category refresh, unlinked action+ linking, small detail-GET budget). `STATE=wa bin/rails nwps:sync_flood_stages` or `bin/rails nwps:enqueue_sync`. Bootstrap also runs flood sync per state. Hourly `HistoryBackfillBatchJob` fills gap-aware continuous history (up to ~35 days) and year daily history into R2 in batches (gauge page views also enqueue a station when charts are empty). Prefer this over a national one-off `usgs:bootstrap` on a small dyno.

### Local / single-state

```bash
STATE=wa bin/rails usgs:purge ALL=1   # wipe a bad/partial import
STATE=wa bin/rails usgs:bootstrap
# On-stream neighbors (catalog sync does one batch, then NetworkRefreshBatchJob
# drains the rest Mon–Sat). FORCE=1 recomputes fresh rows. LIMIT=50 for a chunk.
STATE=wa bin/rails nldi:refresh
```

Optional history backfill after bootstrap:

```bash
STATE=wa RANGE=1y LIMIT=25 bin/rails usgs:backfill
# optional deep daily fill after year history exists:
STATE=wa RANGE=3y LIMIT=25 bin/rails usgs:backfill
```

Tunables: `USGS_REQUEST_PAUSE_MS` (default `100` outside test), `NLDI_REQUEST_PAUSE_MS` (default `10000`; NLDI navigation is ~400 req/hr), `NLDI_REFRESH_BATCH` (default `50` stations per on-stream neighbor tick), `HISTORY_IV_REPAIR_BATCH` / `HISTORY_IV_SCAR_BATCH` (default `50` stations per catch-up tick), `HISTORY_BACKFILL_BATCH` (default `50` stations per cron tick for cold `1y` work), `HISTORY_DEEP_BACKFILL_BATCH` (default `400` stations for `3y` deep fills; set `0` to pause), `HISTORY_IV_SCAR_RETRY_DAYS` (default `7`). History pins one USGS key per purpose (`USGS_API_HISTORY_CONTINUOUS_KEY` / `_DAILY_KEY` / `_PEAKS_KEY` / `_IVREPAIR_KEY` / `_IVREPAIR2_KEY`) and opens that purpose’s circuit on a 429 for the rest of the UTC hour. Tip sync enqueues `IvRepairJob` when a new tip jumps more than 2h past the previous continuous point; tip catch-up (`IvRepairBatchJob`) runs Mon–Sat hourly at `:35` on `iv_repair` → `iv_repair_worker`. Interior scar catch-up (`IvRepairScarBatchJob`) runs Mon–Sat hourly at `:50` on `iv_repair_scar` → `iv_repair_scar_worker` using `_IVREPAIR2_KEY` across the ~35d continuous window. After a completed scar fetch, USGS-empty interior holes park on `time_series` (`iv_scar_checked_at`) until the retry window elapses or the gap worsens — the gauge page shows a known-missing callout. Cold/year backlog (`HistoryBackfillBatchJob`) runs Mon–Sat every 10 minutes on `backfill` → `historical_worker`. Circuit state per key is on `/admin`.

`FloodStageSync` expires flood alerts that drop off the NWPS state list: if a LID is unseen and `flood_category_observed_at` is blank or older than 24 hours, category resets to `no_flooding`.

See `doc/postgres-r2-daily-archive.md` (current R2-first retention), `doc/plan-3y-daily-history.md` (historical 3y plan), and `doc/future.md` (hourly POR) for retention tiers and longer-history notes.

Local archive iteration (no Cloudflare): `.env.example` sets `DAILY_ARCHIVE_STORE=local`. After seeding or backfill, run `bin/rails archive:export_daily` — shards land in `tmp/daily_archive` and `1y` / `3y` charts read them when `DAILY_ARCHIVE_READS=1`.

## Observability (Honeycomb)

OpenTelemetry traces export to Honeycomb when `OTEL_EXPORTER_OTLP_*` is set (see `.env.example`). ActiveRecord, PG, Redis, and Net::HTTP auto-spans are disabled to stay within event budgets; domain spans via `Telemetry` remain. Query recipes: [`doc/honeycomb-queries.md`](doc/honeycomb-queries.md).

## Logging

Production uses [Lograge](https://github.com/roidrage/lograge) plus `AppLogging` (`lib/app_logging.rb`) for single-line structured JSON request and ActiveJob logs (Heroku → Better Stack friendly). Each line includes `level`, `event`, a short human `message`, and flat fields. Example request line:

```json
{"level":"info","event":"request","message":"GET /gauges/wa/… 200","rid":"46dc1071-…","method":"GET","path":"/gauges/wa/…","format":"html","status":200,"duration":102.0,"view":19.8,"db":15.2,"queries":19,"cached":5,"gc":1.9,"allocations":…,"controller":"GaugesController","action":"show","ip":"…","host":"waterlevels.org"}
```

Job lifecycle lines look like `{"level":"info","event":"job.perform","message":"job.perform FloodStageSyncJob ok","job":"FloodStageSyncJob","jid":"…","queue":"sync","status":"ok","duration":12.34}`. Sync progress lines use `event=sync.progress` with flat `phase` / `updated` / `elapsed` fields. Sidekiq's own logger (job start/done and scheduler `queueing …` lines) uses the same JSON shape (`event=sidekiq.job` / `sidekiq.enqueue`). Remaining `Rails.logger` strings are wrapped as JSON (`event=app.log`) with `[Component]` prefixes and `key=value` tokens lifted into fields. Structured JSON logging is always enabled (including development and test).

Via a Heroku log drain, Better Stack nests the parsed JSON under `message.*` (for example `message.job`, `message.phase`). Configure Live Tail to show `{message.message}` and filter on those nested fields (or add a VRL transform to promote them).

## Agent discovery

There is **no public third-party data API**. First-party `/api/*` stays website-only (`X-WaterLevels-Client: web` + same-origin). Agents and scrapers should use USGS / NWPS, advertised here:

| Surface | Role |
| ------- | ---- |
| `/llms.txt` | Static site summary, page list, and “use USGS/NWPS” policy |
| `/.well-known/api-catalog` | RFC 9727 linkset (`application/linkset+json`). Anchors: site root, USGS Water Data API, NWPS API. Does **not** list `/api/*`. |
| Homepage `Link` headers | `rel="api-catalog"` → catalog; `rel="service-doc"` → `/disclosures`, `/faq`; `rel="describedby"` → `/llms.txt`. Only `/` sets the full discovery header. |
| `/robots.txt` | `Content-Signal: ai-train=no, search=yes, ai-input=no`; `Disallow: /admin` and `/api` |

HTML pages honor `Accept: text/markdown` (`MarkdownForAgents` on `ApplicationController`): if markdown quality ≥ HTML, the HTML template still renders, then `HtmlToMarkdown` converts hero + `main` (nav/header/footer/svg stripped). Response is `text/markdown; charset=utf-8` with `Vary: Accept` and `x-markdown-tokens` (rough `ceil(chars/4)`). JSON `/api/*` is unchanged. The modern-browser gate is skipped for markdown requests.

Example:

```bash
curl -sH "Accept: text/markdown" https://waterlevels.org/faq
```

## Tests

```bash
bin/rails test
```

## Heroku

- Dynos: `web`, `worker` (default queue + scheduler), `sync_worker` (`sync` queue), `iv_repair_worker` (`iv_repair` queue), `iv_repair_scar_worker` (`iv_repair_scar` queue), `historical_worker` (`backfill` queue), `notifications_worker` (`notifications` queue — email alert evaluation, digests, and `AlertMailer` `deliver_later`). Keep the two IV workers isolated: `iv_repair_worker` must listen **only** to `iv_repair` (`config/sidekiq_iv_repair.yml`). Scar jobs are consumed solely by `iv_repair_scar_worker`. After enabling `ALERTS_ENABLED`, scale with `heroku ps:scale notifications_worker=1 -a <app>` — the scheduler still enqueues digest/quiet ticks onto `notifications` even when the product flag is off, so an unscaled process lets that queue back up. Admin health warns if `notifications` / scar / tip-IV queues have depth and no matching workers.
- Add-ons: Postgres, Redis
- Set `USGS_API_KEY` (tip/catalog), optional `USGS_API_HISTORY_CONTINUOUS_KEY` / `USGS_API_HISTORY_DAILY_KEY` / `USGS_API_HISTORY_PEAKS_KEY` (purpose-pinned history backfill), `REDIS_URL`, `DATABASE_URL`, `APP_HOST`, `SENTRY_DSN`; `CARTO_API_KEY` for the `/map` Dark Matter vector basemap (higher-traffic CARTO tier; request at [carto.com/basemaps/apikey](https://carto.com/basemaps/apikey/)); optional `CLOUDFLARE_ZONE_ID` + `CLOUDFLARE_API_TOKEN` for post-sync Cache-Tag purge; optional `CLOUDFLARE_R2_*` for the yearly daily-means archive ([`doc/postgres-r2-daily-archive.md`](doc/postgres-r2-daily-archive.md))
- Enable [runtime dyno metadata](https://devcenter.heroku.com/articles/dyno-metadata) so `HEROKU_RELEASE_VERSION` is available; Sentry uses it as the release and tags environment as `production`
- Open Graph PNGs are rendered with `rsvg-convert` (`Aptfile` → `librsvg2-bin`). Requires [`heroku-community/apt`](https://elements.heroku.com/buildpacks/heroku/heroku-buildpack-apt) as buildpack **#1** (before Ruby) so the Aptfile packages install on the dyno. Station cards are **not** stored in Redis (they filled a 250MB instance); `/og/gauges/:site_number.png` rasterizes on the origin and is Cloudflare-cached (`s-maxage=3600`). Tip/flood syncs purge `og` / `gauge:{site}` tags. The default OG PNG is still Redis-cached.
- Redis TLS: Sidekiq, cache, and Action Cable use `ssl_params.verify_mode = VERIFY_NONE` for Heroku self-signed `rediss://` certs
- After deploy: `heroku run bin/rails usgs:enqueue_bootstrap -a <app>`
- Optional: `MALLOC_ARENA_MAX=2` if worker RSS climbs
- Put Cloudflare in front; honor `Cache-Control` / `Cache-Tag` from the app. Use a Cache Rule (Eligible for cache + Origin Cache Control) for public HTML; bypass `/contact`, `/admin`, and `/api/*`. Public pages skip the Rails session cookie so HTML is not forced to `BYPASS`.
- Internal `/api/*` JSON is first-party-only (`X-WaterLevels-Client: web` + same-origin browser context), returns `private, no-store`, and is cached in Redis via `ApiResponseCache` (invalidated when syncs bump generation counters).
- Optional ops dashboard at `/admin` when `DASHBOARD_PW` is set (session login at `/admin/login`). Returns 404 when the env var is unset. Login attempts are rate-limited (Rails `rate_limit`, 10 per 3 minutes per IP). Sidekiq Web is at `/admin/sidekiq` behind the same session. Inventory / growth 24h–7d numbers come from Postgres `admin_counters` (`AdminDashboardCountersJob` every 10 min) — do not `COUNT(*)` `continuous_observations` on the request. Sidekiq stats, USGS circuits, and the tip-freshness histogram stay live.
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
- On-stream upstream/downstream neighbors are precomputed from the public USGS NLDI API (no API key). Navigation is ~400 req/hr per client; a 429 trips a circuit for the rest of the UTC hour. Catalog sync refreshes one `NLDI_REFRESH_BATCH`, then `NetworkRefreshBatchJob` drains unsynced rows (Mon–Sat). One-off: `bin/rails nldi:refresh` (optional `STATE=wa`, `FORCE=1`, `LIMIT=50`). Re-runs skip stations that already have neighbor ids and a fresh `network_synced_at`; empty graphs stay pending so a failed first pass can retry. Demo seed wires a 5-station chain offline (`99000096`–`990000100`).
