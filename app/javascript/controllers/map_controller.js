import { Controller } from "@hotwired/stimulus"
import L from "leaflet"
import "leaflet.markercluster"

export default class extends Controller {
  static targets = ["canvas"]
  static values = { stationsUrl: String }

  connect() {
    this.map = L.map(this.canvasTarget, { zoomControl: true }).setView([39.5, -98.35], 4)
    const tiles = window.matchMedia("(prefers-color-scheme: dark)").matches
      ? "https://{s}.basemaps.cartocdn.com/dark_all/{z}/{x}/{y}{r}.png"
      : "https://{s}.basemaps.cartocdn.com/light_all/{z}/{x}/{y}{r}.png"
    L.tileLayer(tiles, {
      attribution: '&copy; <a href="https://www.openstreetmap.org/copyright">OpenStreetMap</a> &copy; <a href="https://carto.com/attributions">CARTO</a>',
      maxZoom: 18
    }).addTo(this.map)

    this.cluster = L.markerClusterGroup()
    this.map.addLayer(this.cluster)
    this.map.on("moveend", () => this.loadStations())
    this.loadStations()
  }

  disconnect() {
    if (this.map) this.map.remove()
  }

  locate() {
    if (!navigator.geolocation) return
    navigator.geolocation.getCurrentPosition(
      (pos) => {
        const { latitude, longitude } = pos.coords
        this.map.setView([latitude, longitude], 9)
        L.circleMarker([latitude, longitude], { radius: 6, color: "#2f4ea8" }).addTo(this.map)
      },
      () => {},
      { enableHighAccuracy: true, timeout: 10000 }
    )
  }

  async loadStations() {
    const bounds = this.map.getBounds()
    const bbox = [bounds.getWest(), bounds.getSouth(), bounds.getEast(), bounds.getNorth()].join(",")
    const url = `${this.stationsUrlValue}?bbox=${encodeURIComponent(bbox)}`
    const response = await fetch(url, { headers: { Accept: "application/json" } })
    if (!response.ok) return
    const data = await response.json()
    this.cluster.clearLayers()
    ;(data.stations || []).forEach((station) => {
      const marker = L.circleMarker([station.lat, station.lon], {
        radius: 6,
        color: station.stale ? "#6b7280" : "#2f4ea8",
        fillColor: station.stale ? "#9ca3af" : "#3b6fd9",
        fillOpacity: 0.85
      })
      marker.bindPopup(this.popupHtml(station))
      this.cluster.addLayer(marker)
    })
  }

  popupHtml(station) {
    const lines = [`<strong>${station.name}</strong>`]
    if (station.water_level != null) lines.push(`Water level: <strong>${station.water_level} ${station.water_level_unit || ""}</strong>`)
    if (station.discharge != null) lines.push(`Flow: <strong>${station.discharge} ${station.discharge_unit || ""}</strong>`)
    if (station.temperature_c != null) {
      const unit = this.tempUnit()
      const value = unit === "c" ? station.temperature_c : (station.temperature_c * 9) / 5 + 32
      lines.push(`Temp: <strong>${value.toFixed(1)} °${unit.toUpperCase()}</strong>`)
    }
    if (station.stale) lines.push("Status: Stale")
    if (station.observed_at) lines.push(`Updated: ${station.observed_at}`)
    lines.push(`<a href="${station.path}">View station history</a>`)
    return lines.join("<br>")
  }

  tempUnit() {
    const match = document.cookie.match(/(?:^|; )temperature_unit=([^;]*)/)
    return match && match[1] === "c" ? "c" : "f"
  }
}
