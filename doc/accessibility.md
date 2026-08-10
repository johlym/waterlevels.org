# Accessibility

WaterLevels.org targets **WCAG 2.2 Level AA** as the claimable baseline. WCAG 3.0 remains a Working Draft; we use its outcome framing (especially for maps, charts, and status color) but do not claim WCAG 3 conformance.

Architectural / agent-facing contracts (contrast token bans, smoke-tested landmarks and ARIA patterns, pre-push checklist) live in [`DESIGN.md` §15](../DESIGN.md#15-accessibility-required-for-ui-work). Keep this file and that section aligned when CI guards change.

## Contrast tokens

Approved pairs on `bg-zinc-950` / `bg-zinc-900`:

| Role | Token | Notes |
| --- | --- | --- |
| Body / headings | `text-zinc-100` / white | Passes AA |
| Secondary readable text | `text-zinc-400` | Prefer over `zinc-500` |
| Placeholders | `placeholder:text-zinc-400` | Always pair with a visible label or `aria-label` |
| Focus indicator | `cyan-400` solid outline, 2px + offset | Global `:focus-visible` |
| Inactive map markers | `#d4d4d8` / `#a1a1aa` | Plus `×` glyph |
| Flood stage lines | Amber/orange/rose/red with distinct dash patterns | Plus text labels in legend |

Do not reintroduce `text-zinc-500` or `placeholder:text-zinc-600` for essential UI copy.

## Map access path

Leaflet markers are not individually keyboard-operable. Equivalent tasks:

1. **Search stations** (combobox on home and map)
2. **Stations in view** list inside Map settings
3. **State directory** and **Alerts** pages
4. **Gauge detail** pages (charts + hourly table)

Escape closes map popups, settings, and mobile search.

## Contact / Turnstile

The contact form uses Cloudflare Turnstile. If the widget fails, users can email [hello@waterlevels.org](mailto:hello@waterlevels.org). Field errors use `aria-invalid` and `aria-describedby`.

## Automated checks

```bash
bin/rails test test/integration/accessibility_smoke_test.rb
yarn test:js
```

`accessibility_smoke_test.rb` asserts skip links, landmarks, combobox wiring, FAQ semantics, contact field errors, and nav `aria-current` on key public pages. JS tests guard contrast token regressions in the Tailwind source.

For full axe-core scans (including color-contrast) in a browser:

1. Run `bin/dev`
2. Open pages with the axe DevTools extension (home, `/map`, a gauge, a state directory, `/faq`, `/contact`)
3. Fail on serious/critical issues

## Keyboard matrix (manual)

| Surface | Expected tab / key behavior |
| --- | --- |
| Global | Skip link → `#main`; visible focus on interactive controls |
| Home search | Combobox arrows, Enter, Escape; locate opens dialog with focus trap |
| Mobile nav | Toggle sets `aria-expanded`; Escape closes; focus returns to toggle |
| Map | Tools, settings (layers + stations list), search combobox; Escape closes chrome/popups |
| Gauge | Measurement tabs with arrows/Home/End; range `aria-pressed`; history table readable |
| FAQ | Category buttons (`aria-current`); accordion `aria-expanded` |
| Dialogs | Focus moves to OK; Tab cycles inside; Escape restores focus |

## Screen-reader smoke (manual)

VoiceOver or NVDA on:

- Home combobox result count live region
- Measurement tabs + chart `aria-label` + history table headers/status text
- FAQ categories and accordion answers
- Geolocation dialog title/description
- Flood / offline status text on station cards (not color alone)
