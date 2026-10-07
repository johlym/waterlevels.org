import { Controller } from "@hotwired/stimulus"
import L from "leaflet"
import { setWorkerUrl } from "maplibre-gl"
import maplibreGL from "@maplibre/maplibre-gl-leaflet"
import { CARTO_ATTRIBUTION, cartoStyleUrl, cartoTransformRequest } from "../lib/carto_basemap"
import { currentMarkerIcon, escapeHtml, markerStyle, roleMarkerIcon } from "../lib/map_markers"

export default class extends Controller {
  static targets = ["canvas"]
  static values = {
    payload: Object,
    cartoApiKey: String,
    maplibreWorkerUrl: String
  }

  static MAX_ZOOM = 11

  connect() {
    const payload = this.payloadValue || {}
    const current = payload.current
    const stations = Array.isArray(payload.stations) ? payload.stations : []
    if (!this.point(current)) return

    if (this.maplibreWorkerUrlValue) setWorkerUrl(this.maplibreWorkerUrlValue)

    this.map = L.map(this.canvasTarget, {
      zoomControl: false,
      attributionControl: false,
      scrollWheelZoom: false,
      maxZoom: 18,
      maxBounds: [[-85.05112878, -180], [85.05112878, 180]],
      maxBoundsViscosity: 1
    })
    this.canvasTarget.setAttribute("role", "img")
    this.canvasTarget.setAttribute("aria-label", this.summaryLabel(stations))

    L.control.attribution({ position: "bottomleft", prefix: false }).addTo(this.map)
    this.map.attributionControl.addAttribution(CARTO_ATTRIBUTION)
    maplibreGL({
      style: cartoStyleUrl(this.cartoApiKeyValue),
      transformRequest: cartoTransformRequest(this.cartoApiKeyValue),
      attributionControl: false,
      maxZoom: 18
    }).addTo(this.map)

    this.draw(current, stations)
    this.fit(current, stations)

    this.enableWheel = () => this.map?.scrollWheelZoom.enable()
    this.disableWheel = () => this.map?.scrollWheelZoom.disable()
    this.onResize = () => this.map?.invalidateSize()
    this.canvasTarget.addEventListener("click", this.enableWheel)
    this.canvasTarget.addEventListener("mouseleave", this.disableWheel)
    window.addEventListener("resize", this.onResize)
    requestAnimationFrame(() => {
      if (!this.map) return
      this.map.invalidateSize()
      this.fit(current, stations)
    })
  }

  disconnect() {
    this.canvasTarget?.removeEventListener("click", this.enableWheel)
    this.canvasTarget?.removeEventListener("mouseleave", this.disableWheel)
    window.removeEventListener("resize", this.onResize)
    if (this.map) this.map.remove()
    this.map = null
  }

  zoomIn() {
    this.map?.zoomIn()
  }

  zoomOut() {
    this.map?.zoomOut()
  }

  draw(current, stations) {
    this.drawStream(current, stations)
    this.drawStation(current, { role: "current", name: current.name })
    stations.forEach((station) => {
      if (this.point(station)) this.drawStation(station)
    })
  }

  drawStream(current, stations) {
    const line = [
      ...stations.filter((station) => station.role === "upstream"),
      current,
      ...stations.filter((station) => station.role === "downstream")
    ].filter((station) => this.point(station))
    if (line.length < 2) return

    L.polyline(line.map((station) => [station.lat, station.lon]), {
      color: "#22d3ee",
      weight: 2,
      opacity: 0.9,
      dashArray: "6 6"
    }).addTo(this.map)

    const from = line[line.length - 2]
    const to = line[line.length - 1]
    if (from.lat === to.lat && from.lon === to.lon) return

    L.marker(this.midpoint(from, to), {
      interactive: false,
      keyboard: false,
      icon: this.arrowIcon(this.bearing(from, to))
    }).addTo(this.map)
  }

  drawStation(station, overrides = {}) {
    const plotted = { ...station, ...overrides }
    const icon = plotted.role === "current"
      ? currentMarkerIcon(L)
      : roleMarkerIcon(L, plotted, markerStyle(plotted))
    const marker = L.marker([plotted.lat, plotted.lon], {
      icon,
      keyboard: false,
      title: plotted.name || "Station",
      zIndexOffset: plotted.role === "current" ? 1000 : 0
    })
    marker.bindPopup(this.popupHtml(plotted))
    marker.addTo(this.map)
  }

  fit(current, stations) {
    const points = [current, ...stations]
      .filter((station) => this.point(station))
      .map((station) => [station.lat, station.lon])
    if (!points.length || !this.map) return

    const bounds = L.latLngBounds(points)
    this.map.fitBounds(bounds.pad(0.35), {
      padding: [36, 36],
      maxZoom: this.constructor.MAX_ZOOM
    })
  }

  popupHtml(station) {
    const role = {
      current: "This station",
      upstream: "Upstream",
      downstream: "Downstream",
      nearby: "Nearby"
    }[station.role] || "Nearby"
    const distance = Number.isFinite(Number(station.distance_mi))
      ? `${Number(station.distance_mi).toFixed(1)} mi`
      : ""
    const meta = [role, distance].filter(Boolean).join(" · ")
    const link = station.role === "current" || !station.path
      ? ""
      : `<div class="popup-link"><a href="${escapeHtml(station.path)}">Open station</a></div>`
    return `<div class="popup-title">${escapeHtml(station.name)}</div><div class="popup-meta">${escapeHtml(meta)}</div>${link}`
  }

  summaryLabel(stations) {
    const count = stations.length
    const noun = count === 1 ? "related gauge" : "related gauges"
    return `Map of this station and ${count} ${noun}. Upstream, downstream, and nearby stations are listed below.`
  }

  arrowIcon(bearing) {
    return L.divIcon({
      className: "related-map-arrow",
      html: `<span style="transform:rotate(${bearing}deg)"><svg viewBox="0 0 24 24" fill="currentColor" aria-hidden="true"><path d="M12 3l7 14H5z"></path></svg></span>`,
      iconSize: [16, 16],
      iconAnchor: [8, 8]
    })
  }

  midpoint(from, to) {
    return [(Number(from.lat) + Number(to.lat)) / 2, (Number(from.lon) + Number(to.lon)) / 2]
  }

  bearing(from, to) {
    const lat1 = Number(from.lat) * Math.PI / 180
    const lat2 = Number(to.lat) * Math.PI / 180
    const dlon = (Number(to.lon) - Number(from.lon)) * Math.PI / 180
    const y = Math.sin(dlon) * Math.cos(lat2)
    const x = Math.cos(lat1) * Math.sin(lat2) - Math.sin(lat1) * Math.cos(lat2) * Math.cos(dlon)
    return (Math.atan2(y, x) * 180 / Math.PI + 360) % 360
  }

  point(station) {
    if (!station) return false
    const lat = Number(station.lat)
    const lon = Number(station.lon)
    return Number.isFinite(lat) && Number.isFinite(lon)
  }
}
