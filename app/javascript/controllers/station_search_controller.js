import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["input", "results", "locateButton"]
  static values = {
    searchUrl: String,
    nearestUrl: String,
    mapUrl: String
  }

  connect() {
    this.query = ""
    this.results = []
    this.requestId = 0
    this.activeIndex = -1
    this.onDocumentClick = this.onDocumentClick.bind(this)
    document.addEventListener("click", this.onDocumentClick)
  }

  disconnect() {
    document.removeEventListener("click", this.onDocumentClick)
    if (this.searchTimer) clearTimeout(this.searchTimer)
  }

  search() {
    this.query = (this.inputTarget.value || "").trim()
    this.activeIndex = -1
    if (this.searchTimer) clearTimeout(this.searchTimer)

    if (this.query.length < 2) {
      this.requestId += 1
      this.results = []
      this.renderResults({ waiting: this.query.length === 1 })
      return
    }

    this.searchTimer = setTimeout(() => this.fetchResults(), 200)
  }

  keydown(event) {
    if (!this.hasResultsTarget || this.resultsTarget.hidden) {
      if (event.key === "Enter") {
        event.preventDefault()
        this.submit()
      }
      return
    }

    const items = this.resultItems()
    if (event.key === "ArrowDown") {
      event.preventDefault()
      this.activeIndex = Math.min(this.activeIndex + 1, items.length - 1)
      this.syncActiveItem(items)
    } else if (event.key === "ArrowUp") {
      event.preventDefault()
      this.activeIndex = Math.max(this.activeIndex - 1, 0)
      this.syncActiveItem(items)
    } else if (event.key === "Enter") {
      event.preventDefault()
      if (this.activeIndex >= 0 && items[this.activeIndex]) {
        items[this.activeIndex].click()
      } else {
        this.submit()
      }
    } else if (event.key === "Escape") {
      this.hideResults()
    }
  }

  submit() {
    if (this.results[0]?.path) {
      window.location.href = this.results[0].path
      return
    }

    if (this.hasMapUrlValue && this.mapUrlValue) {
      window.location.href = this.mapUrlValue
    }
  }

  locate() {
    if (!navigator.geolocation || !this.hasNearestUrlValue) return

    this.setLocateBusy(true)
    navigator.geolocation.getCurrentPosition(
      async (pos) => {
        try {
          const { latitude, longitude } = pos.coords
          const url = `${this.nearestUrlValue}?lat=${encodeURIComponent(latitude)}&lon=${encodeURIComponent(longitude)}`
          const response = await fetch(url, { headers: { Accept: "application/json" } })
          if (!response.ok) throw new Error("nearest lookup failed")
          const data = await response.json()
          if (data.station?.path) {
            window.location.href = data.station.path
            return
          }
        } catch (_error) {
          // fall through to clear busy state
        } finally {
          this.setLocateBusy(false)
        }
      },
      () => this.setLocateBusy(false),
      { enableHighAccuracy: true, timeout: 10000 }
    )
  }

  async fetchResults() {
    if (!this.hasSearchUrlValue || !this.searchUrlValue) return

    const requestId = ++this.requestId
    const query = this.query
    const url = `${this.searchUrlValue}?q=${encodeURIComponent(query)}`
    const response = await fetch(url, { headers: { Accept: "application/json" } })
    if (!response.ok) return
    if (requestId !== this.requestId || query !== this.query) return

    const data = await response.json()
    this.results = data.stations || []
    this.renderResults()
  }

  renderResults({ waiting = false } = {}) {
    if (!this.hasResultsTarget) return

    if (!this.query || waiting) {
      this.hideResults()
      return
    }

    this.resultsTarget.hidden = false

    if (!this.results.length) {
      this.resultsTarget.innerHTML = `<p class="empty">No matching stations.</p>`
      return
    }

    const items = this.results.map((station) => {
      const status = station.stale ? "Inactive" : "Active"
      const statusClass = station.stale ? "inactive" : "active"
      return `
        <a href="${this.escapeHtml(station.path)}" class="item">
          <div class="icon" aria-hidden="true">
            <svg fill="none" stroke="currentColor" viewBox="0 0 24 24">
              <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M17.657 16.657L13.414 20.9a1.998 1.998 0 01-2.827 0l-4.244-4.243a8 8 0 1111.314 0z"></path>
            </svg>
          </div>
          <div class="copy">
            <p class="name">${this.escapeHtml(station.name)}</p>
            <p class="meta">Station ID: ${this.escapeHtml(station.id)} · ${this.escapeHtml((station.state || "").toUpperCase())}</p>
          </div>
          <span class="status ${statusClass}">${status}</span>
        </a>
      `
    }).join("")

    const browse = this.hasMapUrlValue
      ? `<div class="footer">
          <a href="${this.escapeHtml(this.mapUrlValue)}">
            <svg fill="none" stroke="currentColor" viewBox="0 0 24 24" aria-hidden="true">
              <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M9 20l-5.447-2.724A1 1 0 013 16.382V5.618a1 1 0 011.447-.894L9 7m0 13l6-3m-6 3V7m6 10l4.553 2.276A1 1 0 0021 18.382V7.618a1 1 0 00-.553-.894L15 4m0 13V4m0 0L9 7"></path>
            </svg>
            Browse all stations on map
          </a>
        </div>`
      : ""

    this.resultsTarget.innerHTML = items + browse
  }

  hideResults() {
    if (!this.hasResultsTarget) return
    this.resultsTarget.innerHTML = ""
    this.resultsTarget.hidden = true
    this.activeIndex = -1
  }

  onDocumentClick(event) {
    if (!this.element.contains(event.target)) this.hideResults()
  }

  resultItems() {
    return Array.from(this.resultsTarget.querySelectorAll("a.item"))
  }

  syncActiveItem(items) {
    items.forEach((item, index) => {
      item.classList.toggle("is-active", index === this.activeIndex)
    })
  }

  setLocateBusy(busy) {
    if (!this.hasLocateButtonTarget) return
    this.locateButtonTarget.disabled = busy
    this.locateButtonTarget.setAttribute("aria-busy", busy ? "true" : "false")
  }

  escapeHtml(value) {
    return String(value ?? "")
      .replaceAll("&", "&amp;")
      .replaceAll("<", "&lt;")
      .replaceAll(">", "&gt;")
      .replaceAll('"', "&quot;")
  }
}
