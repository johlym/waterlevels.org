# Missing features vs HydroTrace mockups

Gaps between the Shuffle/HydroTrace mockups (`shuffle 2`) and what WaterLevels.org currently ships. Items below are not implemented unless noted as partial.

## Global / product chrome

- [ ] Sign-in / accounts
- [ ] Top-nav **Stations** and **Data** destinations (map + About only today)
- [ ] Public API docs link and product API surface
- [ ] Footer **API** / **Documentation** links from the mockup
- [x] Branded static error pages (`public/404`, `403`, `500`, `400`, `422`) from HydroTrace mockup

## Gauge detail page (`detail.html`)

Shipped in UI shape: breadcrumb, Active/Stale badges, station meta (ID, coordinates, county, updated), measurement cards, historical trends chart with legend + period high/low/average, hourly table with day select / pagination / CSV export, nearby station cards with distance + primary reading.

### Header / station meta

- [ ] Breadcrumb ending on the **station name** (we stop at county)
- [ ] Location subtitle as “County, State, United States”
- [ ] **Drainage area** in the meta panel
- [x] Last-updated formatting with **station-local timezone** (e.g. CST), not only app/browser local time

### Current conditions cards

- [ ] Fourth card: **Specific conductance** (µS/cm @ 25°C) and other WQ parameters
- [ ] Per-card icon treatments and long unit blurbs from the mockup
- [ ] Streamflow **% vs daily average** chip (we show absolute 24h/YoY deltas when available)
- [x] Gauge-height **Normal / within expected range** status chip (NWS flood category via NWPS)
- [ ] Temperature **change from yesterday** chip as a dedicated callout
- [ ] Conductance **Good / water quality** status chip
- [ ] Always show a fixed 4-up mock layout when parameters are missing (today we only render available series)

### Historical trends

- [ ] **Historical median** period stat (tile shows “Not available yet”)
- [ ] Always-on dual series (streamflow + gauge height) regardless of selected measurement tab (today companion series only overlays when both exist and the selected kind is flow or stage)
- [ ] Mock static axis / “Hover for details” chrome parity beyond Chart.js defaults

### Hourly measurements table

- [ ] **Conductance** column
- [ ] Status column driven by hydrologic thresholds (amber elevated / green nominal), not only “all parameters present”
- [x] Time column labeled with **station timezone** (e.g. Time (CST))
- [ ] Server-side or denser “true hourly” aggregation if USGS points are sub-hourly / irregular

### Nearby stations

- [ ] Up to ~10 stations within **50 miles** (we keep ~4 precomputed neighbors)
- [ ] Copy: “Other monitoring locations within 50 miles”
- [ ] **Watch** alert card treatment (amber border / pulse) for elevated neighbors
- [ ] Offline card showing “Last: N days ago” relative time when stale
- [ ] Primary reading always preferred as Flow/Level with mock formatting; richer multi-metric teaser optional

### Detail-page data dependencies

- [ ] Ingest conductance (and optional DO / other WQ) for cards + table columns
- [x] Flood stage / watch / normal-range thresholds for status chips (NWS NWPS categories; table dots still completeness-only)
- [ ] Day-of-year or climatology series for historical median
- [ ] Expand `NearbyStations` limit/radius and include richer snapshot fields for alert styling

## State directory page

Shipped in UI shape: hero, filter sidebar (search + type checkboxes + county jump), county groups, station cards with IDs, coordinates, type badges, latest readings, and Nominal/Offline status.

Still missing vs `state.html`:

- [x] **Critical alerts** count and flood/watch semantics (NWS action+ categories)
- [x] Alert statuses on cards for flood categories (Low Flow / Zero Flow still TODO; Offline retained)
- [ ] Water-quality metrics beyond temperature (**conductivity**, **dissolved O₂**, etc.)
- [ ] “Quality” measurement type as true water-quality filters (checkbox maps to temperature availability only)
- [ ] Persist filter state in the URL / shareable filtered views
- [x] Highlight elevated stage values in rose when NWS flood category is action+

## Map / homepage

- [ ] Any remaining mock marketing chrome not tied to real map data layers
- [ ] Sign-in CTA on the map header

## Data pipeline

- [ ] Ingest and store conductance / DO / other WQ parameters when available from USGS
- [x] Flood stage / watch thresholds for alert coloring (NWPS sync)
- [ ] Historical daily medians (or climatology) for period-stats fourth tile
- [ ] Expand nearby-station graph (limit + radius) and warm richer nearby snapshots
