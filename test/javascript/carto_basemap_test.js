import { describe, it } from "node:test"
import assert from "node:assert/strict"
import {
  CARTO_ATTRIBUTION,
  CARTO_DARK_STYLE_URL,
  cartoStyleUrl,
  cartoTransformRequest,
  isCartoBasemapUrl,
  normalizeCartoApiKey
} from "../../app/javascript/lib/carto_basemap.js"

describe("normalizeCartoApiKey", () => {
  it("trims and treats blank as empty", () => {
    assert.equal(normalizeCartoApiKey("  abc  "), "abc")
    assert.equal(normalizeCartoApiKey(""), "")
    assert.equal(normalizeCartoApiKey("   "), "")
    assert.equal(normalizeCartoApiKey(null), "")
    assert.equal(normalizeCartoApiKey(undefined), "")
  })
})

describe("isCartoBasemapUrl", () => {
  it("accepts CARTO CDN hosts used by the dark vector style", () => {
    assert.equal(isCartoBasemapUrl("https://basemaps.cartocdn.com/gl/dark-matter-gl-style/style.json"), true)
    assert.equal(isCartoBasemapUrl("https://tiles.basemaps.cartocdn.com/vector/carto.streets/v1/tiles.json"), true)
    assert.equal(
      isCartoBasemapUrl("https://tiles-a.basemaps.cartocdn.com/vectortiles/carto.streets/v1/6/10/20.mvt"),
      true
    )
  })

  it("rejects unrelated hosts and invalid URLs", () => {
    assert.equal(isCartoBasemapUrl("https://waterlevels.org/map"), false)
    assert.equal(isCartoBasemapUrl("https://carto.com/attributions"), false)
    assert.equal(isCartoBasemapUrl("not-a-url"), false)
  })
})

describe("cartoStyleUrl", () => {
  it("uses the Dark Matter vector style", () => {
    assert.equal(cartoStyleUrl(""), CARTO_DARK_STYLE_URL)
    assert.match(CARTO_DARK_STYLE_URL, /dark-matter-gl-style\/style\.json$/)
  })

  it("appends the public key query param when present", () => {
    assert.equal(
      cartoStyleUrl(" test-key "),
      `${CARTO_DARK_STYLE_URL}?key=test-key`
    )
  })
})

describe("cartoTransformRequest", () => {
  const transform = cartoTransformRequest("traffic-key")

  it("stamps key on CARTO style, TileJSON, and vector tile URLs", () => {
    assert.equal(
      transform("https://basemaps.cartocdn.com/gl/dark-matter-gl-style/style.json").url,
      "https://basemaps.cartocdn.com/gl/dark-matter-gl-style/style.json?key=traffic-key"
    )
    assert.equal(
      transform("https://tiles.basemaps.cartocdn.com/vector/carto.streets/v1/tiles.json").url,
      "https://tiles.basemaps.cartocdn.com/vector/carto.streets/v1/tiles.json?key=traffic-key"
    )
    assert.equal(
      transform("https://tiles-b.basemaps.cartocdn.com/vectortiles/carto.streets/v1/5/8/12.mvt").url,
      "https://tiles-b.basemaps.cartocdn.com/vectortiles/carto.streets/v1/5/8/12.mvt?key=traffic-key"
    )
  })

  it("does not overwrite an existing key or touch other hosts", () => {
    assert.equal(
      transform("https://basemaps.cartocdn.com/gl/dark-matter-gl-style/style.json?key=already").url,
      "https://basemaps.cartocdn.com/gl/dark-matter-gl-style/style.json?key=already"
    )
    assert.equal(
      transform("https://waterlevels.org/api/map/stations").url,
      "https://waterlevels.org/api/map/stations"
    )
  })

  it("leaves URLs unchanged when no key is configured", () => {
    const passthrough = cartoTransformRequest("")
    const url = "https://basemaps.cartocdn.com/gl/dark-matter-gl-style/style.json"
    assert.equal(passthrough(url).url, url)
  })
})

describe("CARTO_ATTRIBUTION", () => {
  it("credits OpenStreetMap and CARTO", () => {
    assert.match(CARTO_ATTRIBUTION, /openstreetmap\.org\/copyright/)
    assert.match(CARTO_ATTRIBUTION, /carto\.com\/attributions/)
  })
})
