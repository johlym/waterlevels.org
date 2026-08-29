// CARTO Dark Matter vector style (replacement for raster dark_all).
// Docs: https://docs.carto.com/faqs/carto-basemaps
export const CARTO_DARK_STYLE_URL = "https://basemaps.cartocdn.com/gl/dark-matter-gl-style/style.json"

export const CARTO_ATTRIBUTION =
  '&copy; <a href="https://www.openstreetmap.org/copyright">OpenStreetMap</a> &copy; <a href="https://carto.com/attributions">CARTO</a>'

const CARTO_HOST_SUFFIX = "basemaps.cartocdn.com"

export function normalizeCartoApiKey(apiKey) {
  if (apiKey == null) return ""
  return String(apiKey).trim()
}

export function isCartoBasemapUrl(url) {
  try {
    const host = new URL(url).hostname
    return host === CARTO_HOST_SUFFIX || host.endsWith(`.${CARTO_HOST_SUFFIX}`)
  } catch {
    return false
  }
}

export function cartoStyleUrl(apiKey) {
  const url = new URL(CARTO_DARK_STYLE_URL)
  const key = normalizeCartoApiKey(apiKey)
  if (key) url.searchParams.set("key", key)
  return url.toString()
}

// Stamp `key` on every CARTO style / TileJSON / tile / sprite / glyph request
// so the same public key unlocks the higher-traffic tier even when the style
// JSON does not rewrite nested source URLs.
export function cartoTransformRequest(apiKey) {
  const key = normalizeCartoApiKey(apiKey)
  return (url) => {
    if (!key || !isCartoBasemapUrl(url)) return { url }

    const parsed = new URL(url)
    if (!parsed.searchParams.has("key")) parsed.searchParams.set("key", key)
    return { url: parsed.toString() }
  }
}
