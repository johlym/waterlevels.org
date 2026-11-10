# Honeycomb query guide (WaterLevels.org)

Dataset: **`waterlevels-org`** (from `OTEL_SERVICE_NAME`, override the board with `HONEYCOMB_DATASET`).

Honeycomb is only for data-management performance: how long pipeline work takes, whether queues are backing up, and how complete the datasets are. Page views, HTTP child spans, and homepage counters are not exported. Request timing stays in the structured Rails logs.

The free plan is 20 million events per month. Each span is one event. These queries assume one span per question. Use `MAX` or `AVG` on gauge attributes. Do not `COUNT` gauge events, and do not `AVG` a ratio across states.

Historical events from before this contract still use the old span names (`history.ingest`, `app.station_inventory`, `app.page`). The filters below apply to traffic after the change.

Connect the [Honeycomb MCP](https://mcp.honeycomb.io/mcp) (US) in Cursor with OAuth. Do not commit an API key. Ask it the questions in this file and give it the WHERE / VISUALIZE lines so it does not invent columns.

## Board

The same queries are grouped into one board, **WaterLevels pipeline**, with a section for duration, unfinished runs, queues, and completeness.

```bash
bin/honeycomb-board --dry-run
HONEYCOMB_CONFIG_KEY=... bin/honeycomb-board
```

`HONEYCOMB_CONFIG_KEY` is the Configuration key **Token**, not the Key ID. In the environment's API keys, create or edit a Configuration key and enable **Manage Queries and Columns** and **Manage Public Boards**. The Key ID only labels the key (`hc…lk_` configuration, `hc…mk_` management, `hc…ik_` ingest) and is not the credential. A Management key cannot create boards. The ingest key in `OTEL_EXPORTER_OTLP_HEADERS` cannot either. Running the command again updates the existing board in place. `REPLACE=1 bin/rails honeycomb:board` deletes it first. EU teams set `HONEYCOMB_API_ENDPOINT=https://api.eu1.honeycomb.io`. `HONEYCOMB_DATASET` overrides the dataset slug (`waterlevels-org` by default). The command prints the board URL.

## Span names

| `name` | `pipeline.signal` | One event means |
| --- | --- | --- |
| `pipeline.work` | `work` | One pipeline run finished, skipped, or errored. Duration is `duration_ms`. |
| `pipeline.queue` | `queue` | Depth, oldest-job age, and listeners for one data queue. |
| `pipeline.pressure` | `pressure` | Retry, dead, and scheduled sets, plus locks, cooldowns, and USGS circuits. |
| `pipeline.coverage` | `coverage` | Station completeness. `pipeline.scope` is `national` or `state`. |

`pipeline.lane` on `pipeline.work`:

`history_backfill`, `history_backfill_batch`, `iv_repair`, `iv_repair_batch`, `iv_repair_scar`, `iv_repair_scar_batch`, `latest_sync`, `catalog_sync`, `flood_sync`, `network_refresh`, `daily_archive_export`, `daily_archive_drain`, `continuous_prune`, `admin_dashboard_counters`, `usbr_sync`, `usbr_history`, `usace_sync`, `usace_history`, `nwps_sync`, `nwps_history`, `cdec_sync`, `cdec_history`.

`pipeline.outcome` is `ok`, `skipped`, or `error`. `pipeline.incomplete` means the run returned and the station was still short (or a USGS rate limit aborted the fill). `pipeline.skip_reason` is the enum for a skipped run (`disabled_by_settings`, `history_keys_exhausted`, `backfill_queue_busy`, `lock_held`, and the other reasons set in the jobs).

Phase timings, in milliseconds, live on the work span. They are not child spans.

| Attribute | Run |
| --- | --- |
| `pipeline.phase.continuous_ms`, `.daily_ms`, `.peaks_ms` | Station history ingest |
| `pipeline.phase.phase1_scope_ms`, `.daily_tip_scope_ms`, `.deep_scope_ms` | History batch candidate scan and enqueue |
| `pipeline.phase.scope_ms` | IV repair or scar candidate scan |
| `pipeline.phase.fetch_ms`, `.upsert_ms` | Latest-observation sync. `pipeline.slowest_state` and `pipeline.slowest_state_ms` name the slowest state in that run |
| `pipeline.phase.vacuum_ms` | Daily archive export or drain |
| `pipeline.http_ms`, `pipeline.http_count` | Upstream HTTP rolled onto the work span |

`pipeline.site_number` is only on station work spans. Gauge events do not carry it.

Queue events use `pipeline.queue` (`sync`, `backfill`, `iv_repair`, `iv_repair_scar`, `default`), `pipeline.queue.depth`, `pipeline.queue.latency_s` (age of the oldest job, seconds), and `pipeline.queue.workers`. `default` also carries mail and edge-cache purge, so its latency is not only retention work. The notifications queue is not exported.

Coverage counts use the same definitions as `/admin`: recently active selected series, `usgs_daily_absent` series are not a daily backlog, and “need 3y” means year coverage is present and deep coverage is not. `pipeline.history_ready_ratio` exists only on the national event. IV repair and scar candidate counts are omitted until a sweeper has scanned; a missing attribute is not zero. Tip freshness buckets (`pipeline.tip_current`, `pipeline.tip_h1_plus`, `pipeline.tip_h6_plus`, `pipeline.tip_h24_plus`, `pipeline.tip_h72_plus`, `pipeline.tip_stale`) are national only. `pipeline.tip_stale` is stations whose tip is missing or older than 7 days.

Archive gaps stay on the prune work span: `pipeline.gaps_alerted`, `pipeline.retrying`, `pipeline.iv_prune_blocked`.

## How long does work take?

**VISUALIZE** `P95(duration_ms)`, `HEATMAP(duration_ms)`, `COUNT`
**WHERE** `name = pipeline.work`
**GROUP BY** `pipeline.lane`
**TIME RANGE** last 24h

History fills only:

**VISUALIZE** `P95(duration_ms)`, `HEATMAP(duration_ms)`, `COUNT`
**WHERE** `name = pipeline.work` **AND** `pipeline.lane = history_backfill`
**GROUP BY** `pipeline.range`

Which phase:

**VISUALIZE** `P95(pipeline.phase.continuous_ms)`, `P95(pipeline.phase.daily_ms)`, `P95(pipeline.phase.peaks_ms)`
**WHERE** `name = pipeline.work` **AND** `pipeline.lane = history_backfill`

Upstream versus local write, for tip sync:

**VISUALIZE** `P95(pipeline.phase.fetch_ms)`, `P95(pipeline.phase.upsert_ms)`, `P95(pipeline.http_ms)`
**WHERE** `name = pipeline.work` **AND** `pipeline.lane = latest_sync`

Slowest stations:

**VISUALIZE** `MAX(duration_ms)`
**WHERE** `name = pipeline.work` **AND** `pipeline.lane = history_backfill`
**GROUP BY** `pipeline.site_number`
**ORDER** `MAX(duration_ms)` descending
**LIMIT** 20

Planner scope time (the candidate queries, not the station fill):

**VISUALIZE** `P95(duration_ms)`, `P95(pipeline.phase.phase1_scope_ms)`, `P95(pipeline.phase.deep_scope_ms)`
**WHERE** `name = pipeline.work` **AND** `pipeline.lane = history_backfill_batch`

## What is failing to finish?

**VISUALIZE** `COUNT`
**WHERE** `name = pipeline.work` **AND** `pipeline.outcome != ok`
**GROUP BY** `pipeline.lane`, `pipeline.skip_reason`

Runs that returned while the station was still short:

**VISUALIZE** `COUNT`, `P95(duration_ms)`
**WHERE** `name = pipeline.work` **AND** `pipeline.incomplete = true`
**GROUP BY** `pipeline.lane`

A high incomplete rate together with a high `P95(pipeline.http_ms)` means the upstream call, not the database, is the long part.

## Are queues backing up?

**VISUALIZE** `MAX(pipeline.queue.depth)`, `MAX(pipeline.queue.latency_s)`
**WHERE** `name = pipeline.queue`
**GROUP BY** `pipeline.queue`

Stuck worker: depth is sitting and nobody is listening.

**VISUALIZE** `MAX(pipeline.queue.depth)`, `MAX(pipeline.queue.latency_s)`, `MAX(pipeline.queue.workers)`
**WHERE** `name = pipeline.queue` **AND** `pipeline.queue.latency_s > 0` **AND** `pipeline.queue.workers = 0`
**GROUP BY** `pipeline.queue`

Retry and dead sets, locks, and open USGS circuits:

**VISUALIZE** `MAX(pipeline.retry_size)`, `MAX(pipeline.dead_size)`, `MAX(pipeline.history_backfill_cooldowns)`, `MAX(pipeline.iv_repair_cooldowns)`
**WHERE** `name = pipeline.pressure`

Which circuit is open (1 is open):

**VISUALIZE** `MAX(pipeline.circuit.tip)`, `MAX(pipeline.circuit.continuous)`, `MAX(pipeline.circuit.daily)`, `MAX(pipeline.circuit.peaks)`, `MAX(pipeline.circuit.iv_repair)`, `MAX(pipeline.circuit.iv_repair2)`
**WHERE** `name = pipeline.pressure`

## Is the backlog moving?

National work still waiting, not the Sidekiq depth. A queue at zero with a large needing-deep count and an open daily circuit means the scheduler is budget-blocked.

**VISUALIZE** `MAX(pipeline.stations_needing_history)`, `MAX(pipeline.stations_needing_deep)`, `MAX(pipeline.stations_daily_tip_refresh)`, `MAX(pipeline.history_ready)`
**WHERE** `name = pipeline.coverage` **AND** `pipeline.scope = national`

Stations enqueued versus station runs that finished:

**VISUALIZE** `SUM(pipeline.items)`
**WHERE** `name = pipeline.work` **AND** `pipeline.lane = history_backfill_batch`

**VISUALIZE** `COUNT`
**WHERE** `name = pipeline.work` **AND** `pipeline.lane = history_backfill` **AND** `pipeline.outcome = ok`

## How complete is a state?

**VISUALIZE** `MAX(pipeline.stations)`, `MAX(pipeline.history_ready)`, `MAX(pipeline.stations_needing_history)`, `MAX(pipeline.stations_needing_deep)`, `MAX(pipeline.stations_missing_year)`, `MAX(pipeline.stations_missing_continuous_anchor)`, `MAX(pipeline.stations_missing_continuous_tip)`, `MAX(pipeline.stations_missing_daily_tip)`, `MAX(pipeline.stations_daily_tip_refresh)`
**WHERE** `name = pipeline.coverage` **AND** `pipeline.scope = state` **AND** `pipeline.state = wa`

Do not `AVG(pipeline.history_ready_ratio)` across states. That field is only on `pipeline.scope = national`, where `MAX(pipeline.history_ready_ratio)` is the latest ratio.

National tip age:

**VISUALIZE** `MAX(pipeline.tip_current)`, `MAX(pipeline.tip_h1_plus)`, `MAX(pipeline.tip_h6_plus)`, `MAX(pipeline.tip_h24_plus)`, `MAX(pipeline.tip_h72_plus)`, `MAX(pipeline.tip_stale)`
**WHERE** `name = pipeline.coverage` **AND** `pipeline.scope = national`

IV repair and scar backlog from the last sweeper scan. If the attribute is missing, no scan has been recorded.

**VISUALIZE** `MAX(pipeline.stations_needing_iv_repair)`, `MAX(pipeline.stations_needing_iv_scar)`
**WHERE** `name = pipeline.coverage` **AND** `pipeline.scope = national`

## Are we deleting history we never archived?

**VISUALIZE** `SUM(pipeline.gaps_alerted)`, `SUM(pipeline.iv_prune_blocked)`, `SUM(pipeline.retrying)`
**WHERE** `name = pipeline.work` **AND** `pipeline.lane = continuous_prune`

`pipeline.gaps_alerted` above zero means a day hit IV prune without R2 coverage. The same count is on `/admin`.

## Triggers

The free plan includes two triggers. Set them after a week of the new events, from the Honeycomb UI or MCP, not from application code:

1. `pipeline.queue` where `pipeline.queue.latency_s` stays above 30 minutes.
2. `pipeline.work` where `pipeline.lane = continuous_prune` and `pipeline.gaps_alerted > 0`.

## Local setup

Set `OTEL_EXPORTER_OTLP_ENDPOINT`, `OTEL_EXPORTER_OTLP_PROTOCOL`, and `OTEL_EXPORTER_OTLP_HEADERS` as in `.env.example`. The SDK does not read `HONEYCOMB_API_KEY`. Tests force `OTEL_TRACES_EXPORTER=none`. There is no auto-instrumentation: do not add `use_all` or per-request spans. Do not sample `pipeline.work`.
