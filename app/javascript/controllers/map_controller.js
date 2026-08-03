import { Controller } from "@hotwired/stimulus"
import L from "leaflet"
import "leaflet.markercluster"
import { geolocationErrorMessage } from "../lib/geolocation_errors"

export default class extends Controller {
  static targets = [
    "canvas",
    "search",
    "results",
    "filter",
    "dischargeCount",
    "waterLevelCount",
    "temperatureCount",
    "settingsPanel",
    "settingsButton",
    "mobileSearch"
  ]
  static outlets = ["dialog"]

  static FLOOD_COLORS = {
    action: { color: "#fbbf24", fill: "#f59e0b" },
    minor: { color: "#fb923c", fill: "#f97316" },
    moderate: { color: "#f43f5e", fill: "#e11d48" },
    major: { color: "#ef4444", fill: "#b91c1c" }
  }
  static values = {
    stationsUrl: String,
    searchUrl: String,
    privacyUrl: String,
    termsUrl: String,
    year: Number
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
    L.control.attribution({
      position: "bottomleft",
      prefix: this.attributionPrefix()
    }).addTo(this.map)
    L.tileLayer("https://{s}.basemaps.cartocdn.com/dark_all/{z}/{x}/{y}{r}.png", {
      attribution: '&copy; <a href="https://www.openstreetmap.org/copyright">OpenStreetMap</a> &copy; <a href="https://carto.com/attributions">CARTO</a>',
      maxZoom: 18
    }).addTo(this.map)

    this.cluster = L.markerClusterGroup()
    this.map.addLayer(this.cluster)
    this.map.on("moveend", () => this.loadStations())
    this.loadStations()

    this.onKeydown = this.onKeydown.bind(this)
    document.addEventListener("keydown", this.onKeydown)
  }

  disconnect() {
    document.removeEventListener("keydown", this.onKeydown)
    if (this.searchTimer) clearTimeout(this.searchTimer)
    if (this.map) this.map.remove()
  }

  attributionPrefix() {
    const year = this.hasYearValue ? this.yearValue : new Date().getFullYear()
    const privacy = this.hasPrivacyUrlValue ? this.privacyUrlValue : "/privacy"
    const terms = this.hasTermsUrlValue ? this.termsUrlValue : "/terms"

    return [
      '<a href="https://leafletjs.com" title="A JavaScript library for interactive maps"><svg aria-hidden="true" xmlns="http://www.w3.org/2000/svg" width="12" height="8" viewBox="0 0 12 8" class="leaflet-attribution-flag"><path fill="#4C9AFF" d="M0 0h12v4H0z"/><path fill="#FFF" d="M0 4h12v3H0z"/><path fill="#FD817D" d="M0 7h12v1H0z"/></svg> Leaflet</a>',
      `&copy; ${year} <a href="/">WaterLevels.org</a> - <a href="${privacy}">Privacy</a> - <a href="${terms}">Terms</a>`
    ].join(" | ")
  }

  zoomIn() {
    this.map?.zoomIn()
  }

  zoomOut() {
    this.map?.zoomOut()
  }

  locate() {
    if (!this.map) return

    if (!navigator.geolocation) {
      this.showGeolocationError()
      return
    }

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
      (error) => this.showGeolocationError(error),
      { enableHighAccuracy: true, timeout: 10000 }
    )
  }

  showGeolocationError(error) {
    if (!this.hasDialogOutlet) return
    this.dialogOutlet.show(geolocationErrorMessage(error))
  }

  toggleSettings() {
    if (!this.hasSettingsPanelTarget) return
    if (this.settingsPanelTarget.hidden) this.openSettings()
    else this.closeSettings()
  }

  openSettings() {
    if (!this.hasSettingsPanelTarget) return
    this.settingsPanelTarget.hidden = false
    if (this.hasSettingsButtonTarget) {
      this.settingsButtonTarget.setAttribute("aria-expanded", "true")
      this.settingsButtonTarget.classList.add("is-active")
    }
  }

  closeSettings() {
    if (!this.hasSettingsPanelTarget) return
    this.settingsPanelTarget.hidden = true
    if (this.hasSettingsButtonTarget) {
      this.settingsButtonTarget.setAttribute("aria-expanded", "false")
      this.settingsButtonTarget.classList.remove("is-active")
    }
  }

  openMobileSearch() {
    if (!this.hasMobileSearchTarget) return
    this.mobileSearchTarget.hidden = false
    this.element.setAttribute("data-search-open", "")
    this.closeSettings()
    requestAnimationFrame(() => this.searchTarget?.focus())
  }

  closeMobileSearch() {
    if (!this.hasMobileSearchTarget) return
    this.mobileSearchTarget.hidden = true
    this.element.removeAttribute("data-search-open")
    this.query = ""
    this.searchResults = []
    if (this.hasSearchTarget) this.searchTarget.value = ""
    this.renderSearchResults()
  }

  onKeydown(event) {
    if (event.key === "Escape") {
      this.closeMobileSearch()
      this.closeSettings()
    }
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

  async submitSearch(event) {
    if (event) event.preventDefault()

    this.query = (this.searchTarget.value || "").trim()
    if (this.searchTimer) {
      clearTimeout(this.searchTimer)
      this.searchTimer = null
    }

    if (this.query.length >= 2) {
      await this.fetchSearchResults()
    }

    if (this.searchResults[0]?.path) {
      window.location.href = this.searchResults[0].path
    }
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
      const style = this.markerStyle(station)
      const marker = L.circleMarker([station.lat, station.lon], {
        radius: station.flood_alert ? 7 : 6,
        color: style.color,
        fillColor: style.fill,
        fillOpacity: 0.85,
        weight: 2
      })
      marker.bindPopup(this.popupHtml(station))
      this.markersById.set(station.id, marker)
      this.cluster.addLayer(marker)
    })
  }

  markerStyle(station) {
    if (station.stale) return { color: "#71717a", fill: "#a1a1aa" }
    const flood = this.constructor.FLOOD_COLORS[station.flood_category]
    if (flood) return flood
    return { color: "#22d3ee", fill: "#06b6d4" }
  }

  renderSearchResults({ waiting = false } = {}) {
    if (!this.hasResultsTarget) return

    if (!this.query || waiting) {
      this.resultsTarget.innerHTML = ""
      this.resultsTarget.hidden = true
      return
    }

    const matches = this.searchResults
    this.resultsTarget.hidden = false

    if (!matches.length) {
      this.resultsTarget.innerHTML = `<p class="empty">No matching stations.</p>`
      return
    }

    this.resultsTarget.innerHTML = matches.map((result) => this.searchResultItemHtml(result)).join("")
  }

  searchResultItemHtml(result) {
    if (result.type === "state") {
      return `
        <a href="${this.escapeHtml(result.path)}" class="item">
          <div class="icon" aria-hidden="true">
            <svg fill="none" stroke="currentColor" viewBox="0 0 24 24">
              <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M9 20l-5.447-2.724A1 1 0 013 16.382V5.618a1 1 0 011.447-.894L9 7m0 13l6-3m-6 3V7m6 10l4.553 2.276A1 1 0 0021 18.382V7.618a1 1 0 00-.553-.894L15 4m0 13V4m0 0L9 7"></path>
            </svg>
          </div>
          <div class="copy">
            <p class="name">${this.escapeHtml(result.name)}</p>
            <p class="meta">Browse all stations in ${this.escapeHtml(result.name)}</p>
          </div>
          <span class="status state">State</span>
        </a>
      `
    }

    const status = result.stale ? "Inactive" : "Active"
    const statusClass = result.stale ? "inactive" : "active"
    return `
      <a href="${this.escapeHtml(result.path)}" class="item">
        <div class="icon" aria-hidden="true">
          <svg fill="none" stroke="currentColor" viewBox="0 0 24 24">
            <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M17.657 16.657L13.414 20.9a1.998 1.998 0 01-2.827 0l-4.244-4.243a8 8 0 1111.314 0z"></path>
          </svg>
        </div>
        <div class="copy">
          <p class="name">${this.escapeHtml(result.name)}</p>
          <p class="meta">Station ID: ${this.escapeHtml(result.id)} · ${this.escapeHtml((result.state || "").toUpperCase())}</p>
        </div>
        <span class="status ${statusClass}">${status}</span>
      </a>
    `
  }

  popupHtml(station) {
    const rows = []
    const status = station.stale
      ? "Inactive"
      : (station.flood_category_label || (station.flood_category === "no_flooding" ? "Normal" : "Active"))
    rows.push(`<div class="popup-meta">Status: <strong>${this.escapeHtml(status)}</strong></div>`)

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
