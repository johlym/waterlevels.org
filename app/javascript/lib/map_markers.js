export const FLOOD_COLORS = {
  action: { color: "#fbbf24", fill: "#f59e0b", glyph: "A", shape: "diamond" },
  minor: { color: "#fb923c", fill: "#f97316", glyph: "1", shape: "square" },
  moderate: { color: "#f43f5e", fill: "#e11d48", glyph: "2", shape: "triangle" },
  major: { color: "#ef4444", fill: "#b91c1c", glyph: "3", shape: "triangle" }
}

const NORMAL_STYLE = { color: "#22d3ee", fill: "#06b6d4", glyph: "", shape: "circle" }
const STALE_STYLE = { color: "#d4d4d8", fill: "#a1a1aa", glyph: "×", shape: "circle" }

const ROLE_CHEVRON = {
  upstream: `<svg fill="none" stroke="currentColor" viewBox="0 0 24 24" aria-hidden="true"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="3" d="M5 15l7-7 7 7"></path></svg>`,
  downstream: `<svg fill="none" stroke="currentColor" viewBox="0 0 24 24" aria-hidden="true"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="3" d="M19 9l-7 7-7-7"></path></svg>`
}

export function markerStyle(station) {
  if (station.stale) return STALE_STYLE
  return FLOOD_COLORS[station.flood_category] || NORMAL_STYLE
}

export function markerIcon(leaflet, station, style) {
  const size = station.flood_alert ? 18 : 14
  return leaflet.divIcon({
    className: `map-marker map-marker--${style.shape}`,
    html: markerShapeHtml(style),
    iconSize: [size, size],
    iconAnchor: [size / 2, size / 2],
    popupAnchor: [0, -size / 2]
  })
}

export function roleMarkerIcon(leaflet, station, style) {
  const chevron = ROLE_CHEVRON[station.role]
  if (!chevron) return markerIcon(leaflet, station, style)

  const size = station.flood_alert ? 18 : 14
  const chevronHeight = 12
  const height = size + chevronHeight
  return leaflet.divIcon({
    className: `map-marker map-marker--${style.shape} map-marker--${station.role}`,
    html: `<span class="map-marker-chevron map-marker-chevron--${station.role}" aria-hidden="true">${chevron}</span>${markerShapeHtml(style)}`,
    iconSize: [size, height],
    iconAnchor: [size / 2, chevronHeight + size / 2],
    popupAnchor: [0, -size / 2]
  })
}

export function currentMarkerIcon(leaflet) {
  const size = 22
  return leaflet.divIcon({
    className: "map-marker map-marker--current",
    html: `<span class="map-marker-shape" style="--marker-color:#a5f3fc;--marker-fill:#06b6d4"></span>`,
    iconSize: [size, size],
    iconAnchor: [size / 2, size / 2],
    popupAnchor: [0, -size / 2]
  })
}

export function escapeHtml(value) {
  return String(value ?? "")
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
}

function markerShapeHtml(style) {
  const glyph = style.glyph
    ? `<span class="map-marker-glyph">${escapeHtml(style.glyph)}</span>`
    : ""
  return `<span class="map-marker-shape" style="--marker-color:${style.color};--marker-fill:${style.fill}">${glyph}</span>`
}
