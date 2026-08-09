# DESIGN.md — WaterLevels.org

How WaterLevels.org is designed and how it should continue to be designed. This is the architectural reference and the source of truth for the conventions new code should follow. For local setup/run commands see `README.md`; for cloud-agent environment caveats see `AGENTS.md`.

## 1. Product overview

WaterLevels.org is a public, read-mostly web app that maps USGS water-monitoring locations (gage height, streamflow/discharge, water temperature) across US states and enriches them with NOAA NWPS flood categories. The product surfaces:

- An interactive national map of active continuous water-body stations.
- Per-state station directories grouped by county.
- Per-gauge detail pages with current conditions, historical trend charts, and an hourly measurements table (with CSV export).
- Static/legal pages and a spam-protected contact form.

A background pipeline continuously ingests and refreshes data from external agency APIs. The public surface is designed to sit behind Cloudflare and be served largely from cache.

## 2. Design principles

These principles explain *why* the code is shaped the way it is. New work should uphold them.

1. **Read-optimized, cache-first.** Public pages must render fast and be edge-cacheable. Prefer denormalized columns and precomputed Redis snapshots over request-time joins/aggregations.
2. **Protect the external API budget.** USGS/NWPS calls are rate-limited and happen only in background jobs (never inline on a cacheable request path, except the deliberate lazy history backfill *enqueue*). Pace requests, never retry 429s, and trip a circuit breaker when throttled.
3. **Fat POROs, thin controllers.** Business logic (sync, caching, serialization, domain rules) lives in `app/models/` as ActiveRecord entities or ActiveModel/PORO objects. Controllers only orchestrate and set cache headers. There is intentionally no `app/services/` layer.
4. **Deterministic, taggable cache contract.** Every cacheable surface emits a predictable `Cache-Tag` so Cloudflare can be purged precisely after a sync.
5. **Idempotent ingestion.** All sync/upsert paths are safe to re-run; they upsert on natural unique keys and reconcile denormalized state.
6. **Offline-capable local dev.** The demo seed (`db/seeds/demo_state.rb`) fully populates the app without any network access or API key. Live ingestion is optional locally.
7. **SEO-friendly, canonical URLs.** Human- and search-friendly slugs with a permanent redirect to one canonical path per resource.

## 3. Technology stack

- **Runtime:** Ruby 4.0.4, Rails 8.1, Puma.
- **Data:** PostgreSQL (no PostGIS — lat/lon B-tree indexes + haversine precompute), Redis (cache store, Sidekiq broker, locks, circuit breaker).
- **Background:** Sidekiq 8 + sidekiq-scheduler.
- **View layer:** ViewComponent (sidecar), Propshaft, Hotwired Turbo + Stimulus.
- **Frontend build:** esbuild (JS, ESM bundle) + Tailwind CSS v4 CLI, output to `app/assets/builds`.
- **Client libraries:** Leaflet + markercluster (map), Chart.js (hydrographs).
- **HTTP:** Faraday (+ faraday-retry) for USGS/NWPS/Turnstile.
- **Mail/anti-spam:** bento-actionmailer + premailer-rails; invisible_captcha + Cloudflare Turnstile.

## 4. Application structure

Follow Rails-with-ViewComponent conventions plus the PORO-model convention below.

```
app/
  controllers/         thin; orchestration + cache headers (see concerns/cacheable_response.rb)
    api/               JSON endpoints for map + hydrograph
  models/              AR entities AND ActiveModel/PORO domain objects
    usgs/              external client + domain constants (parameter/state/site codes, circuit)
    nwps/              external client + flood categories
  components/          ViewComponent sidecars (component.rb + component.html.erb)
  jobs/                Sidekiq jobs (thin wrappers over model sync objects)
  javascript/          Stimulus controllers + Turbo entrypoint
  mailers/             contact mailer
  helpers/             view formatting only
  views/               ERB templates + mailer/pwa templates
lib/tasks/             usgs.rake, nwps.rake (operational entrypoints)
lib/redis_config.rb    shared Redis options (TLS verify_mode for Heroku rediss://)
```

**Convention:** put new business logic in a model object, not a controller or helper. If it has a DB table it is an ActiveRecord model; otherwise it is an ActiveModel/PORO under `app/models` (e.g. `*_sync.rb`, `*_cache.rb`, serializers like `hydrograph_series.rb`). External integrations live under a namespaced folder (`usgs/`, `nwps/`).

## 5. Routing & URL design

- `root` → `home#show`; `/map` → `maps#show`.
- Static/legal pages via `pages#show` (`/about`, `/privacy`, `/terms`, `/disclosures`, `/contact`).
- **Canonical gauge URL:** `/gauges/{state}/{site_number}-{slug}` (e.g. `/gauges/wa/09380000-colorado-river-at-lees-ferry`). A numeric-only `/gauges/{site_number}` short route 301-redirects to the canonical path (`GaugesController#ensure_canonical_path!`). State is constrained to two lowercase letters.
- **State directory:** `/gauges/{state}`.
- **JSON API (`/api`):** `map/stations` (bbox, `search`, `nearest`) and `gauges/:gauge_id/observations` (hydrograph).
- **Sitemaps:** `/sitemap.xml` index + `/sitemaps/static.xml` + `/sitemaps/{state}.xml`.
- **Preferences:** `PUT /temperature_unit` sets the °F/°C cookie.
- **Ops:** `/up` health check. Password-gated `/admin` dashboard when `DASHBOARD_PW` is set (session form at `/admin/login`); returns 404 when unset. Login attempts are rate-limited via Rails `rate_limit` (10 / 3 minutes / IP). The dashboard shell loads immediately; section bodies fill via Turbo Frames (`/admin/sections/:section`) so heavy backfill aggregates do not block first paint. Sidekiq Web (+ scheduler UI) is mounted at `/admin/sidekiq` behind the same session. Not edge-cached (`private, no-store`); admin controllers opt into Rails sessions.

New public URLs should be slug-based, lowercase, and get a canonical form + `Cache-Tag`.

## 6. Data model

Design the schema so the hot read paths (map viewport, state listing, gauge snapshot) need no aggregation.

- **`monitoring_locations`** — the central entity. Identity/geo columns plus **denormalized latest values** (`has_water_level/discharge/temperature`, `latest_water_level_value/unit/parameter_code`, `latest_discharge_value/unit`, `latest_temperature_c`, `latest_observed_at`, `latest_approval_status`), NWPS flood columns (`flood_stage_*`, `flood_category`, `nwps_*`), and `nearby_station_ids` (jsonb). Indexed for map (`(latitude, longitude)`), listing (`(state_code, county_name, name)`), partial flags, and `flood_category`.
- **`time_series`** — per-parameter series metadata for a location. `measurement_kind ∈ {water_level, discharge, temperature}`, `selected_for_display` gate, `primary_series`.
- **Observation tables**, all FK → `time_series`, all upserted on natural keys:
  - `latest_observations` — one row per series (unique `time_series_id`).
  - `continuous_observations` — sub-daily points (unique `(time_series_id, observed_at)`); ~35-day retention (charts use ≤30d; day-31+ handoff ensures R2 has USGS or estimated daily before IV prune).
  - `daily_observations` — short Postgres scratch tip of daily means (unique `(time_series_id, observed_on)`); ≤7 days when R2 prune is enabled. Not the history SoR.
  - `peak_observations` — annual peaks (unique `(time_series_id, water_year, peak_kind)`).
  - `daily_archive_shards` — catalog of Cloudflare R2 year objects (`daily/v1/{time_series_id}/{yyyy}.json.gz`) for **all** daily history used by `1y` / `3y` / `Ny`. See [`doc/postgres-r2-daily-archive.md`](doc/postgres-r2-daily-archive.md).

**Conventions:**
- Store temperature canonically in **°C** (`latest_temperature_c`); convert to °F only at the edge/client.
- Denormalized columns on `monitoring_locations` are derived state — always rewrite them through `DisplaySeriesSelection` / the latest-sync denormalize step, never ad hoc.
- Retention windows in `ContinuousPruneJob` / `DailyArchive::Retention` must stay aligned with the ranges `HistoryIngestion` backfills and R2 dual-write.
- Chart browsers never talk to R2 directly — `/api/gauges/:id/observations` merges Postgres scratch tip + R2 dailies for `1y` / `3y` / `Ny` when `DAILY_ARCHIVE_READS=1`.

## 7. Ingestion pipeline

External data flows in through namespaced clients → sync objects → Sidekiq jobs, with rake tasks as manual entrypoints.

- **Clients:** `Usgs::Client` (OGC API, optional `X-Api-Key`, GeoJSON `next` link pagination) and `Nwps::Client` (gauge lookup by site number). Both pace requests via `*_REQUEST_PAUSE_MS`. Tip/catalog traffic uses `Usgs::Client.for_tip` (`USGS_API_KEY`); history backfill uses `Usgs::Client.for_history`, which round-robins `USGS_API_HISTORY_1_KEY` / `USGS_API_HISTORY_2_KEY` (falls back to `USGS_API_KEY` when unset).
- **Sync objects (`app/models/*_sync.rb`, `history_ingestion.rb`, `display_series_selection.rb`):**
  - `StationCatalogSync` (weekly / bootstrap) — discover active continuous water-body sites, filter via `Usgs::SiteTypes`, upsert series + latest, select display series, prune inactive, warm caches.
  - `LatestObservationSync` (hourly) — refresh `selected_for_display` series, denormalize location columns, warm caches.
  - `FloodStageSync` (hourly, offset) — refresh flood categories from the NWPS gauge list by LID, prioritize detail-matching for any unlinked action+ gauges (LID → usgsId → site), then discover/refresh remaining thresholds via USGS site-number lookups. Also runs at the end of each `BootstrapStateJob`.
  - `HistoryIngestion` (on-demand/batch) — fetch continuous/daily/peaks for charts; gap-aware. Cold/lazy path uses `1y`; deep `3y` daily only for year-ready stations.
  - `DisplaySeriesSelection` — choose one discharge + one temperature + ranked water-level series; set `has_*` flags and denormalized columns.
- **Jobs (`app/jobs`) + schedule (`config/sidekiq.yml`):** catalog (Sun 03:00), latest (hourly), flood (hourly :20), history backfill batch (Mon–Sat every 10 minutes), prune (daily). Queues: `default`, `sync`, `backfill`.
- **Rate-limit protection:** `ApplicationJob` retries transient `Usgs::Client::Error` but **discards** `RateLimitError`. `Usgs::RateLimitCircuit` is **per API-key id** (`tip`, `history_1`, `history_2`; TTL = rest of the UTC hour). `Usgs::HourlyRequestBudget` counts each USGS HTTP call in Redis (`usgs:req_count:{key}:{UTC hour}`) and soft-caps a key at `USGS_HOURLY_SOFT_CAP` (default 980) by opening its circuit before a hard 429. Tip/catalog jobs check the tip circuit; history jobs check `Usgs::HistoryKeyPool.exhausted?` so one history-key trip does not stop the other (or tip sync). History backfill additionally no-ops on Sundays, honors `HistoryBackfillLock` (1h TTL, 6h cooldown), skips when the backfill queue is still busy, and is enqueued lazily from `GaugesController#show` when a station `needs_history_backfill?` (phase-1 `1y` only). The batch sizes phase-1 as `HISTORY_BACKFILL_BATCH` **× available history keys** capped by **remaining** hourly request budget, and fills deep `3y` from leftover request budget up to `HISTORY_DEEP_BACKFILL_BATCH`/key. Used/remaining/budget per key is shown on `/admin`.
- **Progress:** long operations report through `SyncProgress` (stdout + logger).

**Convention:** never call an external API from a controller action on a cacheable path or from a view. Add new ingestion as a sync PORO invoked by a job and a rake task, and reuse the pacing/circuit-breaker guards.

## 8. Caching & CDN

Caching is layered; keep all three layers consistent when adding a surface.

1. **HTTP edge headers** via `CacheableResponse`: browser `Cache-Control` defaults to `public, max-age=60, s-maxage=3600` (no long browser `stale-while-revalidate` — that caused Turbo revisits to keep last visit’s HTML until a hard reload). Edge freshness uses `Cloudflare-CDN-Cache-Control: max-age={s_maxage}, stale-while-revalidate=86400` plus a `Cache-Tag`. Every gauge tags `gauge:{site_number}` **and** aggregate `gauges`; states tag `state:{code}` **and** `states`; home/map/static/sitemap/alerts/map APIs have their own tags. The contact page is explicitly `private, no-store`. HTML layouts also set `turbo-cache-control: no-cache` so Turbo Drive does not restore in-memory page snapshots for live data.
2. **Redis payload snapshots:** `StationSnapshotCache` (per gauge, versioned key + TTL) and `StateListingCache` (per state) hold fully-shaped read models so page renders avoid joins. Caches are **warmed** at the end of the relevant sync and **rebuilt lazily** on `fetch` when stale/schema-bumped. `SiteStats` is warmed by latest/flood syncs and on Puma boot (not only busted); measurement totals may use Postgres `reltuples` estimates when tables are large. `Sitemap` is similarly cached.
3. **Rails cache store:** Redis in production, memory store in development.
4. **Cloudflare tag purge** via `Cloudflare::CachePurge` + `EdgeCacheInvalidation` after latest/flood/catalog syncs (and after history ingestion). Requires `CLOUDFLARE_API_TOKEN` + `CLOUDFLARE_ZONE_ID`; no-ops when unset. National syncs purge aggregate tags (`gauges`, `states`, `home`, `map`, `alerts`, map API tags); state-scoped syncs also purge that state’s gauges. History ingestions **coalesce** tags through `EdgeCachePurgeBuffer` + debounced `EdgeCachePurgeJob` (or `EdgeCacheInvalidation.coalesce` for synchronous `usgs:backfill`) so a multi-station backfill does not fire one Instant Purge per station. `Cloudflare::CachePurge` retries rate-limit responses with backoff. Purge failures are logged/Sentry’d and do **not** fail the sync.
5. **No Rails session on cacheable pages.** `ApplicationController` sets `request.session_options[:skip] = true` by default so public HTML/JSON does not emit `_waterlevels_session`. Cloudflare treats `Set-Cookie` as `BYPASS` even when a Cache Rule marks the path Eligible for cache. **Only contact and admin opt into sessions** (`PagesController` / `ContactsController` / `Admin::*` via `enable_session?`) for CSRF + flash / login. `csrf_meta_tags` render only when the session is enabled. `PUT /temperature_unit` skips forgery protection (preference cookie is also set client-side). **If you add another form or anything that needs CSRF/flash/session, you must opt that controller into `enable_session?` and keep its path out of the edge cache (or accept that it cannot be CDN-cached).** Do not put CSRF meta tags back on the global layout for cacheable pages. Admin sets `private, no-store`.

**Cloudflare dashboard (ops):** public HTML/JSON need a Cache Rule with **Eligible for cache** + **Origin Cache Control: On**. Bypass `/contact*` and `/admin*` (and any future session-backed or credentialed paths). Without that rule, HTML stays `DYNAMIC`/`BYPASS` and tag purge has nothing to invalidate.

**Conventions:** bump the version segment in a snapshot cache key when its shape changes; emit a `Cache-Tag` for any new cacheable surface and purge it from Cloudflare after the corresponding sync; treat snapshots as derived and always warmable from the DB; never write a session cookie on a cacheable GET.

## 9. Frontend

- **Build:** esbuild bundles `app/javascript/*.*` to an ESM bundle; Tailwind v4 CLI builds CSS. `Procfile.dev` runs both in `--watch` alongside Rails; production builds the assets ahead of Propshaft serving.
- **Behavior:** progressive enhancement with Turbo + Stimulus. Notable controllers: `map` (Leaflet + clustering + bbox fetch + search/geolocation + layer filters), `hydrograph` (Chart.js dual-axis chart, range tabs, history table, CSV export), `parameter-toggle`, `temperature-unit` (cookie + `PUT /temperature_unit`), `state-directory`, `station-search`, `mobile-nav`.
- **Chart data:** the gauge view passes an observations URL; `hydrograph_controller` fetches `/api/gauges/:id/observations` per measurement. `HydrographSeries` returns `{ kind, label, range, unit, parameter_code, points:[{t,v}], peaks:[…] }`, using continuous points for `24h/7d/30d` and daily points for `1y`.
- **Units:** temperature converts to °F/°C client-side based on the `temperature_unit` cookie (default °F).

**Conventions:** one Stimulus controller per behavior, registered in `controllers/index.js`; keep server responses cache-friendly; UI chunks are ViewComponents (`component.rb` + `component.html.erb`).

## 10. Contact form

`GET /contact` renders `Contact::FormComponent` with a Turnstile widget and is served `private, no-store`. It is the only public HTML surface that enables the Rails session (CSRF meta tags + flash). `POST /contact` runs an `invisible_captcha` honeypot, validates a `ContactMessage`, verifies Cloudflare Turnstile (`TurnstileVerification`; bypassed in test when the secret is unset), and enqueues `ContactMailer` (delivered via bento-actionmailer in production, with premailer-rails inlining CSS). Recipient/from configured via `CONTACT_TO_EMAIL` / `MAIL_FROM`.

## 11. Domain/value objects

Encapsulate domain knowledge in small, well-named objects rather than scattering constants: `Usgs::ParameterCodes` (codes + preference ranking + kind mapping), `Usgs::StateCodes` (FIPS ↔ USPS), `Usgs::SiteTypes` (water-body allowlist), `Usgs::TimeZones`, `Nwps::FloodCategories`, `UnitLabel` (e.g. `ft³/s`), `NearbyStations` (grid + haversine), `TrendComparison` (24h + YoY deltas), `SiteStats`, `PopularWaterways`.

## 12. Testing

- Minitest with `ActiveSupport::TestCase` / `ActionDispatch::IntegrationTest`, parallelized.
- **FactoryBot only** (no fixtures) under `test/factories`.
- **WebMock** with `disable_net_connect!(allow_localhost: true)`; all USGS/NWPS/Turnstile calls are stubbed. `TURNSTILE_SECRET` is stripped in setup so the form path is testable.
- Controller tests assert `Cache-Tag` headers, HTML content, and JSON API shapes; mailer tests use `assert_enqueued_emails`.

**Conventions:** stub every external HTTP call; cover new cacheable surfaces with a `Cache-Tag` assertion; use factories for data. CI (`config/ci.rb` / `.github/workflows/ci.yml`) runs RuboCop (rails-omakase), Brakeman, bundler-audit, and the test suite against Postgres.

## 13. Configuration & deployment

- **Processes:** `Procfile` → `web` (Puma) + `worker` (Sidekiq) + `release` (`db:migrate`); `Procfile.dev` → Rails + JS/CSS watchers.
- **Environments:** development uses memory cache + `:async` jobs + suppressed mail errors; production uses Redis cache + Sidekiq + Bento mail + `force_ssl`.
- **Heroku target:** web + worker dynos, Postgres + Redis add-ons; env `USGS_API_KEY`, `REDIS_URL`, `DATABASE_URL`; post-deploy `bin/rails usgs:enqueue_bootstrap`. `lib/redis_config.rb` sets `ssl_params.verify_mode = VERIFY_NONE` for Heroku self-signed `rediss://`.
- **Edge:** Cloudflare in front, honoring `Cache-Control`/`Cache-Tag` for targeted purges. Set `CLOUDFLARE_ZONE_ID` + `CLOUDFLARE_API_TOKEN` (Zone.Cache Purge permission) so syncs can call Instant Purge by tag.

## 14. Extending the app (checklist)

When adding a feature, keep the design intact:

1. New logic → a model/PORO (namespaced for external integrations), not a controller/helper/service.
2. New read surface → denormalize or snapshot for speed; add a `Cache-Tag` (and aggregate tag if per-entity); warm on the relevant sync, purge via `EdgeCacheInvalidation`, and rebuild lazily on `fetch`. Do not enable a Rails session on cacheable GETs.
3. New external data → a namespaced Faraday client + a sync PORO + a Sidekiq job + a rake task, reusing pacing + `RateLimitCircuit`; never call it inline on a cached path.
4. New URL → lowercase slug + canonical redirect + sitemap entry.
5. New UI → a ViewComponent sidecar and, if interactive, a single registered Stimulus controller.
6. Tests → FactoryBot data, WebMock-stubbed HTTP, and `Cache-Tag`/JSON-shape assertions.
7. Keep prune retention aligned with backfill ranges, and store canonical units (°C) with edge conversion.
