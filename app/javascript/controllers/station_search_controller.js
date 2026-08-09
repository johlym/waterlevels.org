import { Controller } from "@hotwired/stimulus"
import { geolocationErrorMessage } from "../lib/geolocation_errors"

export default class extends Controller {
  static targets = ["input", "results", "locateButton", "status"]
  static outlets = ["dialog"]
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
    this.setExpanded(false)
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
      this.inputTarget.focus()
    }
  }

  async submit() {
    this.query = (this.inputTarget.value || "").trim()

    if (this.searchTimer) {
      clearTimeout(this.searchTimer)
      this.searchTimer = null
    }

    if (this.query.length >= 2) {
      await this.fetchResults()
    }

    if (this.results[0]?.path) {
      window.location.href = this.results[0].path
      return
    }

    if (this.hasMapUrlValue && this.mapUrlValue) {
      window.location.href = this.mapUrlValue
    }
  }

  locate() {
    if (!this.hasNearestUrlValue) return

    if (!navigator.geolocation) {
      this.showGeolocationError()
      return
    }

    this.setLocateBusy(true)
    navigator.geolocation.getCurrentPosition(
      async (pos) => {
        try {
          const { latitude, longitude } = pos.coords
          const url = `${this.nearestUrlValue}?lat=${encodeURIComponent(latitude)}&lon=${encodeURIComponent(longitude)}`
          const response = await fetch(url, { headers: { Accept: "application/json" }, cache: "no-store" })
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
      (error) => {
        this.setLocateBusy(false)
        this.showGeolocationError(error)
      },
      { enableHighAccuracy: true, timeout: 10000 }
    )
  }

  showGeolocationError(error) {
    if (!this.hasDialogOutlet) return
    this.dialogOutlet.show(geolocationErrorMessage(error))
  }

  async fetchResults() {
    if (!this.hasSearchUrlValue || !this.searchUrlValue) return

    const requestId = ++this.requestId
    const query = this.query
    const url = `${this.searchUrlValue}?q=${encodeURIComponent(query)}`
    const response = await fetch(url, { headers: { Accept: "application/json" }, cache: "no-store" })
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
    this.setExpanded(true)

    if (!this.results.length) {
      this.resultsTarget.innerHTML = `<p class="empty" role="option" aria-disabled="true">No matching stations.</p>`
      this.announce("No matching stations")
      this.clearActiveDescendant()
      return
    }

    const items = this.results.map((result, index) => this.resultItemHtml(result, index)).join("")

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
    const count = this.results.length
    this.announce(`${count} ${count === 1 ? "result" : "results"} available`)
    this.clearActiveDescendant()
  }

  resultItemHtml(result, index) {
    const optionId = `home-search-option-${index}`

    if (result.type === "state") {
      return `
        <a href="${this.escapeHtml(result.path)}" class="item" role="option" id="${optionId}">
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

    if (result.type === "zip") {
      return `
        <a href="${this.escapeHtml(result.path)}" class="item" role="option" id="${optionId}">
          <div class="icon" aria-hidden="true">
            <svg fill="none" stroke="currentColor" viewBox="0 0 24 24">
              <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M17.657 16.657L13.414 20.9a1.998 1.998 0 01-2.827 0l-4.244-4.243a8 8 0 1111.314 0z"></path>
              <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M15 11a3 3 0 11-6 0 3 3 0 016 0z"></path>
            </svg>
          </div>
          <div class="copy">
            <p class="name">${this.escapeHtml(result.name)}</p>
            <p class="meta">Show this ZIP code on the map</p>
          </div>
          <span class="status zip">ZIP</span>
        </a>
      `
    }

    const status = result.stale ? "Inactive" : "Active"
    const statusClass = result.stale ? "inactive" : "active"
    return `
      <a href="${this.escapeHtml(result.path)}" class="item" role="option" id="${optionId}">
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

  hideResults() {
    if (!this.hasResultsTarget) return
    this.resultsTarget.innerHTML = ""
    this.resultsTarget.hidden = true
    this.activeIndex = -1
    this.setExpanded(false)
    this.clearActiveDescendant()
    this.announce("")
  }

  onDocumentClick(event) {
    if (!this.element.contains(event.target)) this.hideResults()
  }

  resultItems() {
    return Array.from(this.resultsTarget.querySelectorAll("a.item"))
  }

  syncActiveItem(items) {
    items.forEach((item, index) => {
      const active = index === this.activeIndex
      item.classList.toggle("is-active", active)
      item.setAttribute("aria-selected", active ? "true" : "false")
    })
    const activeItem = items[this.activeIndex]
    if (activeItem) {
      this.inputTarget.setAttribute("aria-activedescendant", activeItem.id)
    } else {
      this.clearActiveDescendant()
    }
  }

  setExpanded(expanded) {
    if (!this.hasInputTarget) return
    this.inputTarget.setAttribute("aria-expanded", expanded ? "true" : "false")
  }

  clearActiveDescendant() {
    if (!this.hasInputTarget) return
    this.inputTarget.removeAttribute("aria-activedescendant")
  }

  announce(message) {
    if (!this.hasStatusTarget) return
    this.statusTarget.textContent = message
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
