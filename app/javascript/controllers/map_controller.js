import { Controller } from "@hotwired/stimulus"
import L from "leaflet"
import "leaflet.markercluster"

export default class extends Controller {
  static targets = [
    "canvas",
    "search",
    "results",
    "filter",
    "dischargeCount",
    "waterLevelCount",
    "temperatureCount",
    "layersPanel"
  ]
  static values = {
    stationsUrl: String,
    searchUrl: String
  }

  connect() {
    this.stations = []
    this.searchResults = []
    this.markersById = new Map()
    this.query = ""
    this.searchRequestId = 0
    this.layers = {
      discharge: true,
      water_level: true,
      temperature: true
    }

    this.map = L.map(this.canvasTarget, { zoomControl: false, attributionControl: false }).setView([39.5, -98.35], 4)
    L.control.attribution({ position: "bottomleft" }).addTo(this.map)
    L.tileLayer("https://{s}.basemaps.cartocdn.com/dark_all/{z}/{x}/{y}{r}.png", {
      attribution: '&copy; <a href="https://www.openstreetmap.org/copyright">OpenStreetMap</a> &copy; <a href="https://carto.com/attributions">CARTO</a>',
      maxZoom: 18
    }).addTo(this.map)

    this.cluster = L.markerClusterGroup()
    this.map.addLayer(this.cluster)
    this.map.on("moveend", () => this.loadStations())
    this.loadStations()

    this.layersMediaQuery = window.matchMedia("(min-width: 640px)")
    this.syncLayersPanel = this.syncLayersPanel.bind(this)
    this.syncLayersPanel()
    this.layersMediaQuery.addEventListener("change", this.syncLayersPanel)
  }

  disconnect() {
    this.layersMediaQuery?.removeEventListener("change", this.syncLayersPanel)
    if (this.searchTimer) clearTimeout(this.searchTimer)
    if (this.map) this.map.remove()
  }

  syncLayersPanel() {
    if (!this.hasLayersPanelTarget) return
    this.layersPanelTarget.open = this.layersMediaQuery.matches
  }

  zoomIn() {
    this.map?.zoomIn()
  }

  zoomOut() {
    this.map?.zoomOut()
  }

  locate() {
    if (!navigator.geolocation || !this.map) return
    navigator.geolocation.getCurrentPosition(
      (pos) => {
        const { latitude, longitude } = pos.coords
        this.map.setView([latitude, longitude], 12)
        if (this.locationMarker) this.map.removeLayer(this.locationMarker)
        this.locationMarker = L.circleMarker([latitude, longitude], {
          radius: 7,
          color: "#34d399",
          fillColor: "#10b981",
          fillOpacity: 0.95,
          weight: 2
        }).addTo(this.map)
      },
      () => {},
      { enableHighAccuracy: true, timeout: 10000 }
    )
  }

  filterChanged() {
    this.layers = {
      discharge: false,
      water_level: false,
      temperature: false
    }
    this.filterTargets.forEach((input) => {
      const layer = input.dataset.mapLayerParam
      if (layer) this.layers[layer] = input.checked
    })
    this.renderStations()
  }

  search() {
    this.query = (this.searchTarget.value || "").trim()
    if (this.searchTimer) clearTimeout(this.searchTimer)

    if (this.query.length < 2) {
      this.searchRequestId += 1
      this.searchResults = []
      this.renderSearchResults({ waiting: this.query.length === 1 })
      return
    }

    this.searchTimer = setTimeout(() => this.fetchSearchResults(), 200)
  }

  async fetchSearchResults() {
    if (!this.hasSearchUrlValue || !this.searchUrlValue) return

    const requestId = ++this.searchRequestId
    const query = this.query
    const url = `${this.searchUrlValue}?q=${encodeURIComponent(query)}`
    const response = await fetch(url, { headers: { Accept: "application/json" } })
    if (!response.ok) return
    if (requestId !== this.searchRequestId || query !== this.query) return

    const data = await response.json()
    this.searchResults = data.stations || []
    this.renderSearchResults()
  }

  async loadStations() {
    const bounds = this.map.getBounds()
    const bbox = [bounds.getWest(), bounds.getSouth(), bounds.getEast(), bounds.getNorth()].join(",")
    const url = `${this.stationsUrlValue}?bbox=${encodeURIComponent(bbox)}`
    const response = await fetch(url, { headers: { Accept: "application/json" } })
    if (!response.ok) return
    const data = await response.json()
    this.stations = data.stations || []
    this.updateCounts()
    this.renderStations()
  }

  updateCounts() {
    const counts = { discharge: 0, water_level: 0, temperature: 0 }
    this.stations.forEach((station) => {
      if (station.has_discharge) counts.discharge += 1
      if (station.has_water_level) counts.water_level += 1
      if (station.has_temperature) counts.temperature += 1
    })

    this.setCount(this.dischargeCountTarget, counts.discharge)
    this.setCount(this.waterLevelCountTarget, counts.water_level)
    this.setCount(this.temperatureCountTarget, counts.temperature)
  }

  setCount(target, value) {
    target.textContent = String(value)
    if (value === 0) target.setAttribute("data-zero", "")
    else target.removeAttribute("data-zero")
  }

  matchesLayers(station) {
    const anyLayerOn = this.layers.discharge || this.layers.water_level || this.layers.temperature
    if (!anyLayerOn) return false

    const matches =
      (this.layers.discharge && station.has_discharge) ||
      (this.layers.water_level && station.has_water_level) ||
      (this.layers.temperature && station.has_temperature)

    return Boolean(matches)
  }

  visibleStations() {
    return this.stations.filter((station) => this.matchesLayers(station))
  }

  renderStations() {
    this.cluster.clearLayers()
    this.markersById.clear()

    this.visibleStations().forEach((station) => {
      const active = !station.stale
      const marker = L.circleMarker([station.lat, station.lon], {
        radius: 6,
        color: active ? "#22d3ee" : "#71717a",
        fillColor: active ? "#06b6d4" : "#a1a1aa",
        fillOpacity: 0.85,
        weight: 2
      })
      marker.bindPopup(this.popupHtml(station))
      this.markersById.set(station.id, marker)
      this.cluster.addLayer(marker)
    })
  }

  renderSearchResults({ waiting = false } = {}) {
    if (!this.hasResultsTarget) return

    if (!this.query || waiting) {
      this.resultsTarget.innerHTML = ""
      this.resultsTarget.setAttribute("data-empty", "")
      this.resultsTarget.hidden = true
      return
    }

    const matches = this.searchResults

    this.resultsTarget.hidden = false
    this.resultsTarget.removeAttribute("data-empty")

    if (!matches.length) {
      this.resultsTarget.innerHTML = `<p class="empty">No matching stations.</p>`
      return
    }

    this.resultsTarget.innerHTML = matches.map((station) => {
      const status = station.stale ? "Inactive" : "Active"
      const layers = [
        station.has_discharge ? "Streamflow" : null,
        station.has_water_level ? "Water level" : null,
        station.has_temperature ? "Temperature" : null
      ].filter(Boolean).join(" · ")

      return `
        <a href="${this.escapeHtml(station.path)}" class="result">
          <span class="name">${this.escapeHtml(station.name)}</span>
          <span class="meta">${this.escapeHtml(station.id)} · ${status}${layers ? ` · ${layers}` : ""}</span>
        </a>
      `
    }).join("")
  }

  popupHtml(station) {
    const rows = []
    const status = station.stale ? "Inactive" : "Active"
    rows.push(`<div class="popup-meta">Status: <strong>${status}</strong></div>`)

    if (station.water_level != null) {
      const label = station.water_level_label || "Water level"
      rows.push(`<div class="popup-meta">${label}: <strong>${station.water_level} ${this.formatUnit(station.water_level_unit)}</strong></div>`)
    }
    if (station.discharge != null) {
      rows.push(`<div class="popup-meta">Streamflow: <strong>${station.discharge} ${this.formatUnit(station.discharge_unit)}</strong></div>`)
    }
    if (station.temperature_c != null) {
      const unit = this.tempUnit()
      const value = unit === "c" ? station.temperature_c : (station.temperature_c * 9) / 5 + 32
      rows.push(`<div class="popup-meta">Temp: <strong>${value.toFixed(1)} °${unit.toUpperCase()}</strong></div>`)
    }
    if (station.observed_at) {
      rows.push(`<div class="popup-meta">Updated: ${this.formatTimestamp(station.observed_at, station)}</div>`)
    }
    rows.push(`<div class="popup-link"><a href="${station.path}">View station</a></div>`)
    return `<div class="popup-title">${this.escapeHtml(station.name)}</div>${rows.join("")}`
  }

  formatTimestamp(value, station = {}) {
    const date = new Date(value)
    if (Number.isNaN(date.getTime())) return value || "—"
    const options = {}
    if (station.time_zone_identifier) options.timeZone = station.time_zone_identifier
    const day = date.toLocaleDateString("en-US", {
      ...options,
      month: "long",
      day: "numeric",
      year: "numeric"
    })
    const time = date.toLocaleTimeString("en-US", {
      ...options,
      hour: "2-digit",
      minute: "2-digit",
      second: "2-digit",
      hour12: true,
      timeZoneName: station.time_zone_identifier ? "short" : undefined
    })
    return `${day} at ${time}`
  }

  tempUnit() {
    const match = document.cookie.match(/(?:^|; )temperature_unit=([^;]*)/)
    return match && match[1] === "c" ? "c" : "f"
  }

  formatUnit(unit) {
    if (!unit) return ""
    return String(unit).replace(/ft\^?3/gi, "ft³")
  }

  escapeHtml(value) {
    return String(value ?? "")
      .replaceAll("&", "&amp;")
      .replaceAll("<", "&lt;")
      .replaceAll(">", "&gt;")
      .replaceAll('"', "&quot;")
  }
}
