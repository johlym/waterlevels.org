# Plan: Expand daily history to 3 years

Near-term plan to grow cached daily history from ~1 year to ~3 years, without changing continuous retention (~90 days) and without blowing the USGS hourly request budget.

Related: [`future.md`](./future.md) covers period-of-record beyond 3 years.

## Goals

1. Store and chart **up to 3 years of daily means** (same `daily_observations` grain as today).
2. **Gate deep fetches**: only request the 1y→3y gap for stations that already have full ~1-year daily history.
3. Keep continuous at 90 days; peaks unchanged.
4. Stay inside existing USGS rate-limit / pacing / Sunday-catalog budget rules.

## Non-goals (this plan)

- Continuous / IV lookback beyond 90 days.
- Full period of record (see `future.md`).
- Changing YoY delta math (still “same calendar day last year”).
- National one-shot backfill from a small dyno.

---

## Current baseline

| Concern | Today |
|--------|--------|
| Daily retention | `HistoryIngestion::DAILY_RETENTION = 1.year` |
| Continuous retention | `CONTINUOUS_RETENTION = 90.days` |
| Year-ready signal | Daily point at/older than `DAILY_HISTORY_ANCHOR` (11 months) |
| Chart ranges | `24h` / `7d` / `30d` / `1y` (`HydrographSeries`) |
| Batch schedule | `HistoryBackfillBatchJob` Mon–Sat hourly `:30`, default `HISTORY_BACKFILL_BATCH=40` |
| Lazy enqueue | `GaugesController#show` → `HistoryBackfillJob` when `needs_history_backfill?` |
| Prune | `ContinuousPruneJob` deletes daily older than `DAILY_RETENTION` |
| Budget guards | Sunday pause, `Usgs::RateLimitCircuit` on 429, no 429 retries, `USGS_REQUEST_PAUSE_MS`, per-station lock + 6h cooldown |

Gap-aware daily ingest already coalesces missing older windows and stale tips (`daily_datetime_ranges` / `coalesced_daily_ranges`). Extending the window mostly means asking for an older start when the local archive is short — not re-downloading the tip every time.

---

## Design

### A. Retention + range constants

In `HistoryIngestion`:

- `DAILY_RETENTION = 3.years`
- Keep `DAILY_HISTORY_ANCHOR = 11.months` as the **1-year ready** gate
- Add `DAILY_DEEP_HISTORY_ANCHOR ≈ 35.months` (or `2.years + 11.months`) as the **3-year ready** gate
- Add range `"3y"` alongside `"1y"` / `"por"`:
  - `daily_window_start` for `"3y"` → `DAILY_RETENTION.ago.to_date`
  - `"1y"` stays a 1-year window (used for cold/lazy first fill)
  - Continuous behavior for `"3y"` same as `"1y"` (still capped by `CONTINUOUS_RETENTION`)

`ContinuousPruneJob` already keys off `DAILY_RETENTION` — raising that constant automatically keeps prune aligned.

### B. Two-phase eligibility (requirement 1a)

Keep today’s `needs_history_backfill?` / `needing_history_backfill` for **phase 1 (≤1y)**.

Add a separate deep path:

| Predicate | Meaning |
|-----------|---------|
| `missing_year_history?` | Selected series lack daily near 11-month anchor (unchanged) |
| `has_year_history?` | Inverse of above |
| `missing_deep_history?` | Has year history **and** lacks daily near `DAILY_DEEP_HISTORY_ANCHOR` |
| `needing_deep_history_backfill` | Scope of locations with `missing_deep_history?` |

Rules:

1. Lazy gauge-page enqueue stays on **phase 1 only** (`DEFAULT_RANGE = "1y"`). Never jump a cold station straight to `"3y"`.
2. Scheduled batch **prioritizes phase 1**. Only after filling the hourly phase-1 quota (or when the phase-1 candidate set is empty) spend remaining slots on deep history with `range: "3y"`.
3. Manual rake (`usgs:backfill RANGE=3y`) remains available for ops; document that `"3y"` on a station without 1y still works (gap-aware fills the whole window) but scheduled/lazy paths should not do that.

### C. Batch job budget split

Extend `HistoryBackfillBatchJob` (or a thin sibling) roughly as:

```text
phase1_budget = HISTORY_BACKFILL_BATCH          # default 40
deep_budget   = HISTORY_DEEP_BACKFILL_BATCH     # default 10 (new)

1. Enqueue up to phase1_budget from needing_history_backfill (range "1y")
2. If circuit open / Sunday / read-only → stop (existing)
3. Enqueue up to deep_budget from needing_deep_history_backfill (range "3y")
```

Tunables (document in README):

| Env | Default | Role |
|-----|---------|------|
| `HISTORY_BACKFILL_BATCH` | `40` | Phase-1 stations/hour |
| `HISTORY_DEEP_BACKFILL_BATCH` | `10` | Phase-2 (3y) stations/hour |
| `USGS_REQUEST_PAUSE_MS` | `100` | Unchanged pacing |

Deep batch defaults **low** so a national fleet of year-ready stations cannot suddenly triple daily-API pressure. Ops can raise after watching 429 / circuit metrics.

Reuse the same `HistoryBackfillLock` + cooldown so a station cannot be double-enqueued across phases in the same hour.

### D. UI / API surface

- Add a **3 Years** range tab next to **1 Year** on the gauge hydrograph (`gauges/show`, `hydrograph_controller`).
- `HydrographSeries::RANGES["3y"] = { continuous: false, duration: 3.years }`.
- Axis formatting for `"3y"` can match `"1y"` (date, not time-of-day).
- FAQ copy: daily retention “about three years”; still not full POR → USGS station page / `future.md` intent.
- History callout: keep “Full-year history is still loading” for phase 1; optional softer “Longer history is still loading” when year-ready but deep-missing (nice-to-have, not required for v1).

### E. Storage impact

Daily rows scale ~3× vs today’s retention (same unique key `(time_series_id, observed_on)`). Continuous/peaks unchanged. Confirm indexes stay sufficient (they should — prune + upsert paths already exist). No schema migration required unless we later add a denormalized “deep history ready” flag (prefer derived queries first).

### F. Tests to add/update

- `HistoryIngestion`: `"3y"` daily window; gap fetch only older than existing 1y tip; continuous still ≤90d.
- `MonitoringLocation`: `missing_deep_history?` true/false matrix (no year → false; year without deep → true; deep present → false).
- `HistoryBackfillBatchJob`: phase-1 priority; deep enqueues use `"3y"` and respect `HISTORY_DEEP_BACKFILL_BATCH`; deep skipped when circuit open / Sunday.
- `HydrographSeries` + observations controller: accept `"3y"`.
- Controller/UI: range button present; FAQ retention string.
- Prune job: deletes daily older than 3 years, not 1 year.

### G. Rollout sequence

1. Land constants + ingest + prune + deep eligibility (no UI yet, or UI behind existing API only) — safe if deep batch default is `0` or unset→`0` for the first deploy.
2. Enable `HISTORY_DEEP_BACKFILL_BATCH=10` in production; watch Sidekiq `backfill` queue depth, `RateLimitCircuit` opens, and Heroku/Postgres row growth for a few days.
3. Ship **3 Years** chart tab once a meaningful share of viewed gauges are deep-ready (or immediately — empty/partial series already degrade gracefully).
4. Update FAQ / DESIGN retention bullets to “~3 years daily”.

Suggested first-deploy kill switch: if `HISTORY_DEEP_BACKFILL_BATCH` is unset, treat as `0` until explicitly enabled. (Alternative: default `10` but keep the phase-1 gate so cold stations are unaffected.)

---

## API budget analysis

### Why this should not blow the budget

1. **Daily payloads stay small.** Three years of daily means is ~1.1k points/series. At `limit=1000`, that is usually 1–2 pages per location batch (often one page when only the 1y→3y gap is missing). Continuous pagination is unchanged.
2. **Phase gate avoids cold double-work.** New/empty stations still take the existing 1y path. Deep work is an incremental older gap, not a second full POR download.
3. **Hard hourly caps.** Deep enqueues are a separate, smaller budget (`10` vs `40`). Worst case added load ≈ 10 location-level daily requests/hour (plus rare pagination), Mon–Sat only.
4. **Existing circuit stays authoritative.** Any 429 opens `Usgs::RateLimitCircuit` for the remainder of the USGS hourly window; batch + job skip; Faraday does not retry 429.
5. **Sunday remains catalog-only.** Deep history does not run when `paused_for_catalog_sync?`.
6. **Gap-aware tip refresh unchanged.** Stations that already have deep history only hit USGS for stale tips (`DAILY_FRESHNESS`), same as today — not a rolling 3-year re-pull.

### Rough upper bound (steady state)

Assume deep batch = 10/hour × 24 × 6 days ≈ **1,440 deep station-attempts/week**. Even if each attempt were 2 HTTP calls, that is ~3k requests/week of *incremental* daily traffic — small next to hourly latest sync + flood sync + phase-1 backfill. Once the fleet is deep-ready, `needing_deep_history_backfill` shrinks to near-zero and the deep budget goes idle.

### What would blow the budget (avoid these)

- Setting deep batch equal to phase-1 batch while millions of rows are cold.
- Making lazy page-views enqueue `"3y"` for every visit.
- Replacing gap-aware windows with unconditional `now-3y..now` every run.
- Chunking continuous into multi-year fetches as part of this work.
- Retrying 429s or ignoring the circuit.

### Observability checklist (before raising deep batch)

- Log lines already emit `enqueued` / `skipped` / `range=` — extend with `deep_enqueued=`.
- Count weekly `RateLimitCircuit` opens (Redis / logs).
- Track `needing_history_backfill` vs `needing_deep_history_backfill` counts (one-off rake or Sidekiq log).
- Watch `daily_observations` table size / prune effectiveness after retention change.

---

## Implementation checklist

- [ ] Constants + `"3y"` window in `HistoryIngestion`; prune follows `DAILY_RETENTION`
- [ ] `missing_deep_history?` / scope; do **not** fold into `needs_history_backfill?`
- [ ] Batch job phase split + `HISTORY_DEEP_BACKFILL_BATCH`
- [ ] `HydrographSeries` + API allowlist + gauge range tab + axis formatting
- [ ] FAQ / DESIGN retention copy
- [ ] Tests listed above
- [ ] Production: enable deep batch gradually; confirm circuit stays quiet
- [ ] Leave POR / multi-chunk continuous to [`future.md`](./future.md)

## Open decisions

1. **Kill-switch default:** deep batch default `0` (explicit enable) vs `10` (slow drip from day one)? Recommendation: default `10` in code comments/README, but ship the first PR with default `0` if production latest-sync is already near the USGS ceiling.
2. **UI label:** replace “1 Year” with “3 Years”, or keep both tabs? Recommendation: **keep both** — 1y stays the dense recent daily view users already know; 3y is opt-in longer context.
3. **Rename prune job?** `ContinuousPruneJob` also prunes daily — out of scope; optional rename later.
