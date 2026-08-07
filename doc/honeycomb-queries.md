# Honeycomb query guide (WaterLevels.org)

Dataset: **`waterlevels`** (from `OTEL_SERVICE_NAME`).  
Environment: whatever your API key targets (local/dev often `test`).

Traces are OpenTelemetry spans. Domain dimensions live under the `app.*` namespace so you can GROUP BY / BubbleUp without parsing span names.

## Field cheat sheet

| Field | Meaning |
| --- | --- |
| `name` | Span name (`history.ingest`, `app.station_inventory`, Rack/Rails route span, …) |
| `is_root` | Prefer this for user-facing latency (exclude child DB/HTTP spans) |
| `duration_ms` | Span duration |
| `app.page` | Public page id: `home`, `map`, `state`, `alerts`, `gauge_detail` |
| `app.stations_count` | Active stations (inventory snapshot) |
| `app.stations_non_stale_count` | Active stations with a tip newer than 1 week |
| `app.observation_count` | Rows upserted (history ingest) or points returned (hydrograph) |
| `app.batch_size` | Series/stations in a batch |
| `app.site_number` / `app.state` / `app.range` | Station / state / history window |

**Stale definition:** `latest_observed_at` blank or older than 1 week (`MonitoringLocation::STALE_AFTER`) — same as the map “Active” toggle.

**Where inventory comes from:** `SiteStats.compute` emits a root span `app.station_inventory` whenever stats are recomputed (hourly tip sync warm, Puma boot, homepage cache miss ~every 10 minutes). Use `MAX`/`AVG` of the count fields over time — not `COUNT` of spans — so extra warmups don’t inflate the graph.

---

## 1. Stations over time

**VISUALIZE** `MAX(app.stations_count)`  
**WHERE** `name = app.station_inventory`  
**TIME RANGE** last 7 days (granularity auto, or 1 hour)

Optional: also plot `MAX(app.stations_stale_count)` on the same query.

UI steps: New Query → VISUALIZE `MAX` of `app.stations_count` → WHERE `name` `=` `app.station_inventory` → run.

---

## 2. Non-stale stations over time

**VISUALIZE** `MAX(app.stations_non_stale_count)`  
**WHERE** `name = app.station_inventory`  
**TIME RANGE** last 7 days

Compare freshness vs catalog size:

**VISUALIZE** `MAX(app.stations_count)`, `MAX(app.stations_non_stale_count)`  
**WHERE** `name = app.station_inventory`

---

## 3. Stations getting history backfill per hour

Each completed station backfill is a root span `history.ingest` (one station per span).

**VISUALIZE** `COUNT`  
**WHERE** `name = history.ingest` **AND** `is_root = true`  
**TIME RANGE** last 24h  
**GRANULARITY** `1 hour` (or leave default and read the rate from the graph)

Breakdowns that help:

- **GROUP BY** `app.state` — which states are filling
- **GROUP BY** `app.range` — `1y` vs `3y` deep fills

Planner volume (stations *enqueued*, not necessarily finished) from the hourly batch job:

**VISUALIZE** `SUM(app.phase1_enqueued)`, `SUM(app.deep_enqueued)`  
**WHERE** `name = job.history_backfill_batch`

---

## 4. History backfill duration over time

**VISUALIZE** `P95(duration_ms)`, `HEATMAP(duration_ms)`, `COUNT`  
**WHERE** `name = history.ingest` **AND** `is_root = true`  
**TIME RANGE** last 24h

Use **P95** (not AVG) so a few huge cold fills don’t hide the typical case; keep the heatmap to spot bimodal cold-vs-refresh populations.

Slice further:

- **GROUP BY** `app.range`
- **GROUP BY** `app.state`
- Correlate size: **VISUALIZE** `HEATMAP(app.observation_count)` on the same filter

Slowest recent fills: same WHERE, **VISUALIZE** `MAX(duration_ms)`, **GROUP BY** `app.site_number`, order descending, limit 20 — then open a sample trace.

---

## 5. P95 request time for home, map, state, alerts, gauge detail

Public HTML controllers set `app.page` on the request span. Filter to roots so child SQL/HTTP spans don’t dilute latency.

**VISUALIZE** `P95(duration_ms)`, `HEATMAP(duration_ms)`, `COUNT`  
**WHERE** `is_root = true` **AND** `app.page` exists  
  **AND** `app.page` **in** `home`, `map`, `state`, `alerts`, `gauge_detail`  
**GROUP BY** `app.page`  
**TIME RANGE** last 24h

Per-page graphs (one query each), e.g. home only:

**VISUALIZE** `P95(duration_ms)`  
**WHERE** `is_root = true` **AND** `app.page = home`

| Page | `app.page` | Typical path |
| --- | --- | --- |
| Home | `home` | `/` |
| Map | `map` | `/map` |
| State directory | `state` | `/gauges/:state` |
| Alerts | `alerts` | `/alerts` |
| Gauge detail | `gauge_detail` | `/gauges/:state/:site_number_slug` |

Fallback if `app.page` is missing on older traffic: GROUP BY `http.route` (Rails OTel semantic convention) for `/`, `/map`, `/alerts`, `/gauges/:state`, `/gauges/:state/:site_number_slug`.

---

## Query patterns worth remembering

1. **Latency → percentiles + heatmap**, never AVG alone.
2. **User-facing latency → `is_root = true`** (or an explicit business root like `history.ingest`).
3. **Inventory / gauge values → `MAX`/`AVG` of the attribute**, not `COUNT` of events.
4. **Combine CALCULATIONS** in one query (`COUNT`, `P95(duration_ms)`, `HEATMAP(duration_ms)`).
5. After a spike, use BubbleUp on the query run to diff attributes (state, range, cache hit, …).

## Related instrumentation

| Signal | Span / attributes |
| --- | --- |
| Catalog health snapshot | `app.station_inventory` + `app.stations_*` |
| History backfill | `history.ingest` (+ `.continuous` / `.daily` / `.peaks`) |
| Backfill planner | `job.history_backfill_batch` |
| Tip / catalog / flood sync | `latest.sync`, `catalog.sync`, `flood.sync` |
| Page latency | request root + `app.page` |

Local/dev: set `OTEL_*` / Honeycomb headers as in `.env.example`. Tests force `OTEL_TRACES_EXPORTER=none`.
