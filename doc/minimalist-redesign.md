# Proposed redesign: WaterLevels.org as a field notebook

This is a visual-direction proposal, not an implementation. Interactive comps live in [`doc/redesign/mockups/`](redesign/mockups/index.html). Information architecture, cache tags, Stimulus behavior, and the WCAG 2.2 AA contracts in `DESIGN.md` §15 stay as they are.

The direction follows a utilitarian-minimal / editorial protocol: warm monochrome paper, serif titles, hairline structure, and pastel used only for flood state. It rejects the current generic dark-SaaS shell.

## What is wrong with the current shell

The product is a public observational record. The UI currently presents it as a neon operations console.

| Current pattern | Why it fights the product |
| --- | --- |
| `bg-zinc-950` + cyan/blue gradients | Primary-colored heroes, gradient wordmarks, and glow blobs are generic SaaS. Water data does not need a marketing aurora. |
| Space Grotesk + DM Sans + gradient `bg-clip-text` | Display type is used as decoration. Titles should carry the station or the question, not a color wash. |
| `shadow-2xl`, `backdrop-blur-xl`, glass search | Heavy shadow and frost flatten hierarchy and read as a dashboard kit. |
| `rounded-2xl` cards and `rounded-full` CTAs | Large pills and soft tiles make every block equally loud. |
| Thin Heroicon-style strokes | Icons look like a default kit. Stroke weight should match the ink line of the page. |
| Rainbow icon tiles (cyan / blue / violet / rose) | Color is spent on chrome instead of flood category. |
| FAQ and directory items in boxed cards | Peers that already have spacing do not need a second chrome layer. |
| Copy such as “Monitor water levels in real-time” | Promotional. The site already states the source and the update cadence. |

The map is the exception. CARTO Dark Matter is a working instrument. Keep it. Restyle only the paper chrome that sits on top.

## Direction

Treat every HTML page as a typeset report. The map is one dark inset in that report.

1. **Paper, not void.** Canvas `#F7F6F3`, surfaces `#FFFFFF`, rules `#EAEAEA`.
2. **Ink, not neon.** Body `#2F3437`, actions `#111111`. Secondary text `#5C5B58` (slightly darker than the protocol’s `#787774` so small type stays AA on bone paper).
3. **Two type families, one job each.** Serif for titles and large readings. Sans for UI. Mono for site numbers, coordinates, and table values.
4. **Color is scarce.** Pastel chips only for flood / status. Measurement identity stays charcoal; the selected card uses a 1px ink border, not a cyan ring.
5. **Hairlines instead of tiles.** Lists, FAQ, and on-stream neighbors are stacked rows with a bottom rule. Cards exist only when a block is a true peer in an asymmetric grid.
6. **The map stays dark.** Light header, white tool/legend sheets, Dark Matter (or equivalent) field underneath. Do not redraw geography in the comps; the live map keeps MapLibre.

## Tokens

```
--paper:        #F7F6F3
--paper-warm:   #FBFBFA
--surface:      #FFFFFF
--line:         #EAEAEA
--ink:          #2F3437
--ink-strong:   #111111
--mute:         #5C5B58
--cta:          #111111
--pale-green:   #EDF3EC / #346538   normal
--pale-yellow:  #FBF3DB / #956400   action
--pale-blue:    #E1F3FE / #1F6C9F   measurement hint, optional
--pale-red:     #FDEBEC / #9F2F2D   moderate / major
```

Radius: 8px on sheets, 5px on controls. No `rounded-full` except 12px status pills. No `shadow-md` or heavier. Hover on a sheet may use `0 2px 8px rgba(0,0,0,0.04)`.

Focus: 2px ink outline, 2px offset. Drop the cyan focus ring.

Flood shape contract does not change: normal circle, action diamond, minor triangle, moderate square, major square plus the word “Major”. Color never travels alone.

## Type

Do not load Inter, Roboto, or Open Sans.

| Role | Proposed face | Fallback in these comps |
| --- | --- | --- |
| Titles, large readings | Newsreader or Instrument Serif | Liberation Serif |
| Body, nav, forms | Geist Sans or SF Pro / Helvetica Neue | Cantarell, Liberation Sans |
| Site IDs, coords, tables | Geist Mono or JetBrains Mono | JetBrains Mono |

Self-host the production faces next to the existing `vendor/fonts` OG assets. Remove the Google Fonts request for DM Sans / Space Grotesk from `application.html.erb`.

Title tracking about `-0.03em` to `-0.04em`, title line-height `1.1`. Body line-height `1.6`.

## Screen-by-screen

### Home — [`home.html`](redesign/mockups/home.html)

Left-aligned editorial opening. No live pill, no gradient accent line.

- Kicker: station count in small caps.
- Title: “US water observations, kept current.”
- Search: one paper field, ink submit. Locate can sit as a text control under the field, not a second saturated button.
- Popular waterways become in-page text links, not chips.
- Network counts sit in an asymmetric bento: one tall “stations” cell, three smaller peers. The flood cell is a link, still ink, not rose.
- Region lists are documents: name, one-line blurb, hairline station rows, site number in mono.

### Gauge — [`gauge.html`](redesign/mockups/gauge.html)

The station name is the page. Everything else is metadata.

- Breadcrumb as `Map / Washington / King County`.
- Site number and agency on one mono line under the title.
- Flood pill aligned to the title block.
- Three measurement tabs as flat sheets. Selected = ink border.
- Chart on paper. Series is charcoal. Flood thresholds are labeled hairlines in the pastel family, not glowing overlays.
- Period stats and station facts are definition lists, not a second card stack.
- On-stream / nearby stay as rows. “This station” is weight, not a cyan wash.

### State directory — [`state.html`](redesign/mockups/state.html)

Drop the glowing hero and the floating filter card.

- Title names the state. Counts live in the lede.
- Left rail is a filter column, not a boxed panel.
- County headings are serif; station rows are a single hairline table: name + ID, stage, flow, temperature, status pill.

Flood alerts reuse this list. See [`alerts.html`](redesign/mockups/alerts.html).

### Map — [`map.html`](redesign/mockups/map.html)

The comp is chrome only: a dark field with abstract marks, not a drawn coastline.

- Header stays paper.
- Zoom / locate / settings are a white 1px sheet.
- Settings and legend are the same sheet language.
- Marker fills mute toward the pastel set; shapes stay. Cluster badges become ink-on-paper, not cyan glass.
- Leaflet popups: white sheet, serif name, mono ID, text link. No 50px black shadow.

Keep `CARTO_API_KEY` and the Dark Matter style. A light basemap is optional later, not required for this pass.

### FAQ and legal — [`faq.html`](redesign/mockups/faq.html)

No boxed questions. Category buttons are a left index. Items are a title row plus `+` / `−`, divided by `#EAEAEA`. Contact and disclosures lose glow blobs and gradient submit buttons: ink button, paper fields, 1px rules.

### Admin

Leave the red ops shell alone. It is a private instrument and should not pretend to be the public notebook. If admin contrast work happens later, do it as a separate pass.

## What this proposal does not change

- Routes, slugs, cache tags, snapshot caches, or session rules.
- Stimulus controllers or ARIA patterns (combobox, tablist, FAQ buttons, dialogs, skip link → `#main`).
- Flood shape + text contract.
- Chart ranges, CSV export, temperature cookie.
- Ingestion, R2 archive, or Sidekiq layout.

## Implementation sequence (when accepted)

Work in the existing Tailwind + ViewComponent CSS. Do not rewrite the app.

1. **Tokens and type.** Replace `@theme` fonts. Invert `html` to paper/ink. Rewrite `:focus-visible` and `.skip-link`. Update `test/javascript/a11y_contrast_tokens.test.js` for the light shell (ban dim paper grays, keep a hard mute floor).
2. **Chrome.** Header, footer, brand mark (stroke drop, no gradient tile).
3. **Home and static pages.** Hero, search, stats, popular, FAQ, about, contact.
4. **Gauge and charts.** Measurement cards, hydrograph colors in the Stimulus controller, tables, related rows.
5. **Directories.** State hero, filter rail, station rows, alerts list.
6. **Map chrome and popups.** Keep the basemap. Restyle `.map-panel`, tools, legend, Leaflet popup, clusters.
7. **OG cards last.** Station PNGs should follow paper/ink so shares match the site.

Motion: optional `translateY(12px)` + opacity on section entry, IntersectionObserver, `prefers-reduced-motion` already in the base sheet. No scroll listeners.

## Accessibility notes

- Public pages remain light. Recheck every mute token at 4.5:1 on `#F7F6F3`.
- Do not reintroduce `text-zinc-500` or the current banned placeholders.
- Map markers stay non-tabbable; search, stations-in-view, directories, and gauge pages remain the keyboard path.
- Chart canvas keeps its accessible-name + table alternative.

## Decision asked

Adopt this paper-and-ink public shell, keep Dark Matter as the map instrument, and leave admin dark. If that is accepted, the first implementation PR should be tokens + chrome + home only, with the contrast test rewritten in the same change.
