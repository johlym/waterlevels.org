# Future: history beyond 3 years

How we can go past the near-term **3-year daily** cache ([`plan-3y-daily-history.md`](./plan-3y-daily-history.md)) toward longer period-of-record (POR) without exhausting the USGS Water Data API budget.

## What USGS allows today

We use the modern OGC API (`https://api.waterdata.usgs.gov/ogcapi/v0/`), not legacy Waterservices `/iv` / `/dv`.

| Collection | Long history? | Constraint |
|------------|---------------|------------|
| **`daily`** | Yes — full daily POR | No documented 3-year-per-request cap like continuous. Query with `datetime=YYYY-MM-DD/YYYY-MM-DD` (gap/chunk as needed for size). |
| **`continuous`** | Yes — full IV-style POR | **Max ~3 years per request.** For longer spans, chunk (USGS recommends ~1 calendar year per call) and merge client-side. |
| **`peaks`** | Yes — annual peaks POR | We already fetch without a datetime window; UI currently shows the latest 20 water years. |
| **`time-series-metadata`** | POR bounds | `start` / `end` per series — use to know how far back is worth fetching. |

Official USGS/`dataRetrieval` guidance: continuous is limited to three years **per request**, not three years total archive. Longer continuous POR is done by partitioning queries. Direct-download helpers may improve later; until then, chunked API pulls are the supported path.

**Product implication:** multi-decade charts should prefer **daily** (and peaks). Continuous beyond 90 days (or eventually beyond 3 years) is a separate, much heavier product choice.

---

## Recommended stages after 3-year daily

### Stage A — Deepen daily only (cheap POR)

Keep continuous at ~90 days. Grow `daily_observations` in steps, e.g. **3y → 5y → 10y → metadata `start` (true POR)**.

Why daily-first:

- ~1 point/day/series vs hundreds of continuous points/day.
- Fits the existing upsert + prune model.
- Matches how we already render the long-range chart (`HydrographSeries` non-continuous ranges).

Gate each deepening stage the same way as 1y→3y: **only stations that already satisfy the previous anchor** enter the next candidate scope (`missing_Ny_history?`).

### Stage B — Weave POR into the regular schedule

Do **not** add a national “download all history” cron. Extend the existing Mon–Sat hourly backfill pattern:

```text
Hourly HistoryBackfillBatchJob (conceptual priority):
  1. phase_1y     — cold / incomplete year          (highest)
  2. phase_3y     — year-ready, missing 3y          (near-term plan)
  3. phase_deep   — 3y-ready, missing next tier     (future)
  4. tip refresh  — already covered by gap-aware    (idle when fresh)
```

Concrete weaving rules:

1. **Shared hourly budget.** One batch job (or chained steps in one job) with explicit slot counts, e.g. `HISTORY_BACKFILL_BATCH` + `HISTORY_DEEP_BACKFILL_BATCH` + `HISTORY_POR_BACKFILL_BATCH`. Sum of slots is the dial; never unbounded `find_each` against USGS in the scheduler.
2. **Priority waterfalls.** Fill higher-priority queues first; spill remaining slots downward. Cold stations always beat POR archaeology.
3. **Anchor predicates.** Each tier has a dated daily anchor (`11.months`, `35.months`, `9.years`, …). Eligibility = previous anchor present ∧ current anchor missing.
4. **Gap-only requests.** Continue using `daily_datetime_ranges`: when a station has 3y locally and the target is 10y, request only `target_start .. (oldest_local - 1 day)`.
5. **Optional year chunks for very long gaps.** Even though daily has no hard 3y request limit, chunk large POR gaps (e.g. 5-year slices) to bound response size, timeout risk, and wasted work if a page fails mid-way.
6. **Metadata-guided stop.** Before deep POR, read `time-series-metadata` `start` so we do not ask for years before the series existed.
7. **Sunday still off-limits.** Catalog sync keeps the USGS hourly window; history tiers stay Mon–Sat.
8. **Circuit + pause unchanged.** `Usgs::RateLimitCircuit`, discard-on-429, `USGS_REQUEST_PAUSE_MS` remain global governors for every tier.
9. **Lazy page views never pull POR.** Gauge `show` may enqueue phase_1y (and maybe phase_3y once year-ready); it must not trigger decade-scale fetches on a cacheable request path.
10. **Prune aligns with product retention.** If product keeps “rolling last N years,” prune older daily. If product wants true POR, stop pruning daily (or prune only continuous) and budget storage separately.

### Stage C — Continuous beyond 90 days / beyond 3 years (optional, expensive)

Only if product needs sub-daily charts past the current window:

- Raise continuous retention in steps (e.g. 90d → 1y) with a **much smaller** station batch than daily deep fills.
- For spans **>3 years**, implement a chunker in `HistoryIngestion` (calendar-year or ≤3y slices), serializing chunks behind the same pause/circuit.
- Prefer doing this **after** daily POR stages; continuous POR for a national fleet is the budget-dominant path.

Peaks: optionally raise the UI `limit(20)` or add a “peaks” tab — already multi-decade capable with almost no schedule change (one-time fetch per series).

---

## Storage & product notes

- **Daily POR** for selected series nationwide is large but usually manageable compared to continuous POR (order-of-magnitude fewer rows).
- Chart UX: add ranges (`5y` / `10y` / `POR`) only when enough stations have data; otherwise users see sparse empty states.
- FAQ should keep pointing at the official USGS station page for authoritative full archive / provenance, even if we cache long daily history.
- Climatology / “historical median” (`TODO.md`) can build on multi-year daily once Stage A is real — do not block median work on continuous POR.

---

## Budget summary

| Approach | Relative USGS cost | When to use |
|----------|-------------------|-------------|
| Extend daily retention + gap fills | Low | Default path past 3y |
| Tiered hourly slots (1y → 3y → deeper) | Controlled | Always |
| Chunked continuous ≤3y windows | Medium–high | Only if sub-daily long range is required |
| Unchunked / unbounded POR jobs | Unsafe | Never |

The invariant: **every new history depth is another gated, slot-capped phase on the existing backfill schedule**, not a new firehose. Raise tiers only after the previous tier’s candidate set is mostly drained and the rate-limit circuit stays quiet.
