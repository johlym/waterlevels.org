# WaterLevels.org — Industrial Brutalist redesign proposal

Proposal only. These files are not wired into the Rails app.

Skill: [industrial-brutalist-ui](https://github.com/Leonxlnx/taste-skill/blob/main/skills/brutalist-skill/SKILL.md) (Tactical Telemetry). Mode is locked. Do not mix in Swiss Industrial Print (newsprint, light substrate) on the same surfaces.

Interactive mockups live beside this file:

- [Cover / system](index.html)
- [Home](home.html)
- [Map HUD](map.html)
- [Gauge unit](gauge.html)
- [State directory](directory.html)
- [Flood board](alerts.html)

## Locked direction

**Tactical Telemetry & CRT Terminal.** WaterLevels.org is already a dark, data-dense monitoring instrument (CARTO Dark Matter map, zinc-950 shell, 15-minute USGS IV, NWS flood stages). The skill’s dark substrate matches the product. A light “blueprint paper” theme would fight the map and split the system.

The civic job stays the same: find a gauge, read stage/flow/temp, see flood category, set an alert. The visual job changes: stop looking like a 2024 SaaS marketing site; start looking like a declassified hydrology console.

Do **not** costume the product as military fiction. No “CLASSIFIED”, threat boards, or invented ranks. Keep USGS / NWS / HUC / site numbers / parameter codes. Industrial framing (`[ NET / CONUS ]`, `>>> LOCATE`, `UNIT / 99000020`) is decoration around real identifiers.

## Audit of the current UI

The live system is coherent and usable. It is also a catalog of the patterns the skill exists to kill.

| Surface | What it does now | Why it fails the skill |
|---|---|---|
| Global type | DM Sans + Space Grotesk, sentence case, moderate scale | No macro/micro split. Display type is friendly, not structural. |
| Color | Zinc-950 + cyan/blue gradient accents; emerald/amber/orange/rose/red flood scale | Rainbow consumer palette. Gradients and translucency are banned. Hazard red is not the sole accent. |
| Chrome | `rounded-2xl`, `backdrop-blur`, `shadow-2xl`, glow blobs | Soft glass cards. Corners are not 90°. |
| Home | Centered hero, gradient “in real-time”, pill chips, four identical icon cards | Marketing landing page. Numerals are not architectural. |
| Map | Frosted panels, rounded tool buttons, cyan layer counts | HUD is a floating card kit, not a framed instrument. |
| Gauge | Breadcrumb + rounded meta card + rounded measurement cards + rounded chart | Same card language repeated. Site ID is small cyan microcopy, not the unit plate. |
| Directory / alerts | County card grid, pill type badges, six-color status dots | Low density for a station index. Status is hue, not structure. |
| Focus / skip | Cyan rings, rounded cyan skip pill | Accent leakage. |

What to **preserve** (do not “redesign” the product):

- Routes and IA: `/`, `/map`, `/gauges/:state`, `/gauges/:state/:slug`, `/alerts`, legal/about, email manage
- Search + geolocate, map layers, flood-stage legend (re-encode nominal as `+` so every glyph stays 90°)
- Hydrograph ranges, table view, CSV export, °F/°C, glossary tips
- USGS / USBR / USACE / NWPS / CDEC attribution and provisional-data honesty
- Accessibility: skip link, combobox, live regions, measurement tabs, reduced motion
- Mailers (leave them). Inbox clients cannot carry scanlines or IBM Plex Mono reliably.

## Design system (apply as tokens, not one-off CSS)

### Substrate (one palette, dark only)

| Token | Hex | Job |
|---|---|---|
| `--bg` | `#0A0A0A` | Page / deactivated CRT |
| `--bg-2` | `#121212` | Recessed cells |
| `--ink` | `#EAEAEA` | Phosphor text |
| `--dim` | `#8A8A8A` | Secondary labels |
| `--line` | `#2A2A2A` | 1px rules / grid parent |
| `--hazard` | `#E61919` | **Only** accent. Flood major, alert counts, structural rules, primary actions that mean “attention” |
| `--live` | `#4AF626` | **One** use: the LIVE network pip. Never body text. |

No gradients (except the allowed CRT scanline overlay and 45° hazard hatch). No blur, no drop shadows, no glass. `border-radius: 0` everywhere, including Leaflet popups and form controls.

### Type

- **Macro:** Archivo Black. `clamp(4rem, 10vw, 12rem)`, `letter-spacing: -0.04em` to `-0.06em`, `line-height: 0.85–0.92`, uppercase. Used for page stamps and the one number that matters (site ID, alert count, “STAGE NET”).
- **Micro:** IBM Plex Mono, 11–13px, `letter-spacing: 0.06em–0.1em`, uppercase for chrome, IDs, nav, coordinates, table heads.
- **Prose** (About, FAQ, disclosures only): same mono, sentence case, tracking 0, max-width ~64ch. Do not all-caps legal copy.

Drop Google fonts DM Sans / Space Grotesk.

### Layout

- CSS Grid with `gap: 1px` and a `--line` parent to mint hairlines. No floating cards.
- Bimodal density: packed mono metadata against one oversized stamp per view.
- Visible compartmentalization. Full-width `hr` between operational units.
- Crosshairs (`+`) at key intersections. Thin barcode ticks in the status bar. `REV` / `UNIT` strings from real data (site number, parameter code, cache generation) — not random theater.

### Flood language (life-safety, not rainbow)

The current six-hue scale is the hardest conflict with “red is the only accent.” Do not encode action/minor/moderate/major as amber→orange→rose→red.

Keep diamond / square / triangle. Replace the nominal circle (banned radius) with a `+`. Recolor:

| Category | Fill / rule | Type |
|---|---|---|
| Nominal | Phosphor `+` | `NOMINAL` |
| Action | Hollow diamond, 1px ink | `ACTION` |
| Minor | Ink square, 1px hatch | `MINOR` |
| Moderate | Ink triangle, heavier hatch | `MODERATE` |
| Major | Hazard-red triangle + 45° stripe cell | `MAJOR` in red |
| Stale | Dim `×` | `STALE` |

Screen readers and the table already speak the category name. Color is confirmation, not the channel.

`--live` green stays off this scale. “Nominal” is phosphor, not green.

### Texture

- Global 4% SVG grain on `html`.
- Static CRT scanlines (`repeating-linear-gradient`, 2px/4px). Honor `prefers-reduced-motion` by dropping the overlay if it causes flicker for a user — grain can remain.
- Halftone only if we ever print a serif wordmark. We should not.

## Page proposals

### Home — command index, not a landing page

Replace the centered marketing hero.

- Status bar: `WL.ORG` · `[ NET / CONUS ]` · LIVE pip · station count.
- Macro stamp `STAGE / NET` (or the live station count as the architecture).
- Search becomes a command row: `>>>` field + `[ LOCATE ]` + `[ QUERY ]`. Autocomplete is a framed list (`SITE`, name, state), not rounded result pills.
- Stats are four hairline cells. Only **flood alerts** uses hazard red.
- Popular waterways become an index (region / site / name / state), not four identical cards.

### Map — HUD over the existing vector basemap

Do not redraw geography. Keep MapLibre + CARTO Dark Matter. Restyle chrome:

- Header is a flush instrument bar (no blur).
- Tools are 44×44 squares, 1px ink border, no shadow.
- Settings: framed `[ LAYERS ]` checklist with tabular counts, not cyan pills.
- Legend: shape + word. No colored dots-only key.
- Popup → bottom `[ SEL ]` plate: site, name, GH, category, `>>> OPEN UNIT`.
- Attribution stays; style it as micro type on `--bg`, not a glass chip.

### Gauge — unit plate

The page is a station, not a blog post.

- Breadcrumb as a mono path: `MAP / WA / KING / UNIT`.
- Site number as the macro numeral (`99000020`). Name is the secondary line.
- If category is major: full-width hazard hatch + `MAJOR FLOOD` (this is the red moment the skill is for).
- Meta grid: flood, approval, coords, county, updated, NWS stages — 1px cells.
- Alert signup is a sibling cell, not a soft card. Submit is a square `[ ARM ALERT ]` in ink; hazard fill only if the station is already in flood.
- Current conditions: three instrument cells (GH, CFS, TEMP). Selected tab = 2px ink inset, not cyan ring.
- Hydrograph: 1px rule grid, phosphor series, **one** red dashed MAJOR stage. Period stats in a four-cell strip.
- Related stations: compact tables (up / down / nearby), current row outlined.

### Directory & flood board

Same chassis. Directory groups by county; alerts group by state.

- Left rack: search, parameter checks, county jump as a barcode list.
- Right: real tables, not station cards. `MAJOR` cells are the only red type.
- Flood board hero is the **count**, oversized, hazard red if > 0.

### Admin (not mocked)

Admin already leans red. Apply the same tokens (square controls, hairline tables, drop gradient buttons). Do not introduce a second theme.

## Implementation map (when this stops being a proposal)

Single-pass visual change. No route or Stimulus API changes.

1. `app/views/layouts/application.html.erb` — font links: Archivo Black + IBM Plex Mono.
2. `app/assets/stylesheets/application.tailwind.css` — `@theme` fonts; delete glow/blob, `rounded-*`, `shadow-*`, `backdrop-blur`, `bg-linear-*`, cyan accents; rebuild shared chrome (header, footer, buttons, tables, map overlays, gauge, directory) on the tokens above.
3. Templates — drop `.glow` / `.blob-*` wrappers; change badge copy to the flood words; home hero markup to the stamp + command row.
4. Chart.js theme in the hydrograph controller — phosphor line, red stage rules, no glow fill.
5. Map marker CSS — `+` / diamond / square / triangle / `×`; retint to ink / hatch / hazard.
6. Tests that assert class names (cyan pills, `rounded-xl`) will need updates. Behavior specs should stay green.

Out of scope for v1: mailers, OG image art, replacing CARTO, new features.

## Mock data

Mockups use representative CONUS-scale counts and the seed station `99000020` (major flood) so the flood treatment can be judged. They are not live reads.
