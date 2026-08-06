# Future: history beyond 3 years

How we go past the near-term **3-year daily** cache ([`plan-3y-daily-history.md`](./plan-3y-daily-history.md)) toward **hourly resolution for the full period of record**, without exhausting the USGS Water Data API budget.

North star: same sub-daily grain on long charts (hourly, not daily-after-30d), back to each series’ historical max (metadata `start`), filled as a rising tide on the dedicated history API keys.

## What USGS allows today

We use the modern OGC API (`https://api.waterdata.usgs.gov/ogcapi/v0/`), not legacy Waterservices `/iv` / `/dv`.

| Collection | Long history? | Constraint |
|------------|---------------|------------|
| **`daily`** | Yes — full daily POR | No documented 3-year-per-request cap like continuous. Query with `datetime=YYYY-MM-DD/YYYY-MM-DD` (gap/chunk as needed for size). |
| **`continuous`** | Yes — full IV-style POR | **Max ~3 years per request.** For longer spans, chunk (USGS recommends ~1 calendar year per call) and merge client-side. |
| **`peaks`** | Yes — annual peaks POR | We already fetch without a datetime window; UI currently shows the latest 20 water years. |
| **`time-series-metadata`** | POR bounds | `start` / `end` per series — use to know how far back is worth fetching. |

Official USGS/`dataRetrieval` guidance: continuous is limited to three years **per request**, not three years total archive. Longer continuous POR is done by partitioning queries. Direct-download helpers may improve later; until then, chunked API pulls are the supported path.

**Today’s product grain:** short charts use ~15‑minute continuous (retained ~90 days); `1y` / `3y` charts use **daily** means. There is no hourly series yet.

**Target product grain (this doc’s north star):** **hourly resolution for the full period of record** (metadata `start` → now), so long-range charts no longer drop to daily after 30 days. Daily can remain as a cheap derived/summary layer; full IV (~15‑minute) stays for the recent window only unless product later demands it.

USGS does not expose a first-class “hourly” collection. Hourly POR means: fetch `continuous` in chunked windows, **downsample to one point/hour on ingest** (e.g. mean or last-in-bucket), and store that grain (new table or a `resolution` discriminator — TBD). API cost still tracks continuous page volume; storage is ~24× daily, ~1/4 to ~1/6 of raw 15‑minute IV.

---

## Recommended stages

### Stage A — Finish near-term daily 3y (current plan)

Ship / stabilize [`plan-3y-daily-history.md`](./plan-3y-daily-history.md). Keep continuous at ~90 days. This remains the cheap chart path until hourly coverage exists.

### Stage B — Hourly rising tide to POR (primary future path)

Replace “deeper daily forever” as the long-range goal with **hourly all the way back to historical max** (per-series metadata `start`).

Do **not** fill 10y on one station before the fleet has shallow hourly. Use a **rising tide**:

```text
Hourly HistoryBackfillBatchJob (history API keys only):
  1. recent IV tip / 30d continuous     (highest — cold / tip-only)
  2. hourly → 90d
  3. hourly → 180d
  4. hourly → 360d
  5. hourly → 540d … → multi-year steps
  6. hourly → metadata start (true POR)
  7. tip refresh                        (gap-aware; idle when fresh)
```

Concrete rules:

1. **History key pool.** Backfill uses dedicated history keys (`USGS_API_HISTORY_*_KEY` via `Usgs::Client.for_history`); tip/catalog stays on `USGS_API_KEY`. Per-key circuits so one 429 does not darken the pool or tip sync.
2. **Wide before deep.** Advance all stations through the shallowest incomplete hourly tier before spending budget on deeper tiers. Lazy gauge views enqueue only the shallowest needed tier — never POR.
3. **Slot caps.** Explicit per-tier budgets on the Mon–Sat hourly batch; sum of slots is the dial. Never unbounded `find_each` against USGS in the scheduler.
4. **Gap-only + chunked continuous.** Request only missing older windows; respect USGS ~3y/request continuous cap (prefer ~1y chunks). Downsample each page to hourly before upsert.
5. **Anchor predicates.** Eligibility = previous hourly anchor present ∧ current anchor missing; POR stage also requires metadata `start`.
6. **Chart unlocks with coverage.** Expose longer range tabs (`1y` / `3y` / `5y` / `10y` / `POR`) only when that station has hourly through the tab’s window; downsample further for payload size if needed.
7. **Sunday.** Catalog remains on the tip key; history may run if the history pool is isolated (revisit the Sunday pause once tip/history split is proven in prod).
8. **Prune / retention.** Recent window may keep native continuous (~15‑minute). Hourly POR is retained to metadata `start` (or a product max). Daily optional for medians / FAQ.

### Stage C — Optional: native continuous (15‑minute) beyond 90 days

Only if product needs sub-hourly charts past the recent window. Much heavier than hourly POR — treat as a separate, smaller-batch ladder after hourly tide is healthy.

Peaks: optionally raise the UI `limit(20)` or add a “peaks” tab — already multi-decade capable with almost no schedule change.

---

## Storage & product notes

- **Hourly POR** is the intended long archive: far smaller than IV POR, far richer than daily POR.
- **Daily POR** stays useful as a low-cost interim and possibly for climatology / “historical median” (`TODO.md`) until hourly coverage is dense enough.
- FAQ should keep pointing at the official USGS station page for authoritative full archive / provenance.
- Chart payloads for multi-year hourly will need server- or client-side decimation even when the DB keeps full hourly fidelity.

---

## Budget summary

| Approach | Relative USGS cost | When to use |
|----------|-------------------|-------------|
| Daily 3y (near-term plan) | Low | Current / bridge |
| Rising-tide **hourly → POR** (chunked continuous → downsample) | Medium–high | **Primary future path** |
| Full IV continuous beyond 90d | High | Only if sub-hourly long range is required |
| Unchunked / unbounded POR jobs | Unsafe | Never |

The invariant: **every new history depth is another gated, slot-capped phase on the existing backfill schedule**, not a new firehose. Prefer a rising tide across the fleet; raise tiers only after the previous tier’s candidate set is mostly drained and history-key circuits stay quiet.
